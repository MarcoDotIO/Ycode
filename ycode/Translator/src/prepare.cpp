// prepare.cpp: LLVM passes and the structured-control-flow plan.
#include "prepare.h"

#include "error.h"

#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/Analysis/AssumptionCache.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/ScalarEvolution.h"
#include "llvm/Analysis/TargetLibraryInfo.h"
#include "llvm/Analysis/PostDominators.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/Analysis/TargetTransformInfo.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Verifier.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Transforms/IPO/AlwaysInliner.h"
#include "llvm/Transforms/Scalar/ADCE.h"
#include "llvm/Transforms/Scalar/EarlyCSE.h"
#include "llvm/Transforms/Scalar/SCCP.h"
#include "llvm/Transforms/Scalar/SROA.h"
#include "llvm/Transforms/Scalar/SimplifyCFG.h"
#include "llvm/Transforms/Scalar/StructurizeCFG.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"
#include "llvm/Transforms/Utils/Cloning.h"
#include "llvm/Transforms/Utils/FixIrreducible.h"
#include "llvm/Transforms/Utils/Local.h"
#include "llvm/Transforms/Utils/LoopUtils.h"
#include "llvm/Transforms/Utils/LoopSimplify.h"
#include "llvm/Transforms/Utils/LowerMemIntrinsics.h"
#include "llvm/Transforms/Utils/LowerSwitch.h"
#include "llvm/Transforms/Utils/UnifyFunctionExitNodes.h"
#include "llvm/Transforms/Utils/UnifyLoopExits.h"

#include <functional>
#include <set>

using namespace llvm;

namespace airc {

// Replaces every constant expression operand of F's instructions by an
// equivalent instruction (GEPs and casts of globals, mostly).
static void lowerConstantExprs(Function &F) {
    std::function<Value *(ConstantExpr *, Instruction *)> materialize = [&](ConstantExpr *CE, Instruction *before) -> Value * {
        Instruction *I = CE->getAsInstruction();
        I->insertBefore(before);
        for (unsigned i = 0; i < I->getNumOperands(); i++)
            if (auto *Op = dyn_cast<ConstantExpr>(I->getOperand(i))) I->setOperand(i, materialize(Op, I));
        return I;
    };
    std::vector<Instruction *> work;
    for (BasicBlock &B : F)
        for (Instruction &I : B) work.push_back(&I);
    for (Instruction *I : work) {
        for (unsigned i = 0; i < I->getNumOperands(); i++) {
            auto *CE = dyn_cast<ConstantExpr>(I->getOperand(i));
            if (!CE) continue;
            Instruction *before = I;
            if (auto *P = dyn_cast<PHINode>(I)) before = P->getIncomingBlock(i)->getTerminator();
            I->setOperand(i, materialize(CE, before));
        }
    }
}

// Constant-length memcpy/memmove/memset become loads and stores; other
// lengths become loops (LLVM's LowerMemIntrinsics).
static void expandMemIntrinsics(Function &F) {
    std::vector<MemIntrinsic *> work;
    for (BasicBlock &B : F)
        for (Instruction &I : B)
            if (auto *MI = dyn_cast<MemIntrinsic>(&I)) work.push_back(MI);
    if (work.empty()) return;
    TargetTransformInfo TTI(F.getParent()->getDataLayout());
    LLVMContext &C = F.getContext();
    for (MemIntrinsic *MI : work) {
        auto *Len = dyn_cast<ConstantInt>(MI->getLength());
        uint64_t len = Len ? Len->getZExtValue() : 0;
        if (Len && len <= 1024) {
            IRBuilder<> B(MI);
            uint64_t dstAlign = MI->getDestAlign().valueOrOne().value();
            uint64_t align = dstAlign;
            if (auto *MT = dyn_cast<MemTransferInst>(MI)) align = std::min(align, (uint64_t)MT->getSourceAlign().valueOrOne().value());
            unsigned unit = (align >= 4 && len % 4 == 0) ? 4 : (align >= 2 && len % 2 == 0) ? 2 : 1;
            Type *T = Type::getIntNTy(C, unit * 8);
            Value *fill = nullptr;
            if (auto *MS = dyn_cast<MemSetInst>(MI)) {
                Value *v = MS->getValue();
                if (unit == 1) fill = v;
                else {
                    Value *w = B.CreateZExt(v, T);
                    uint64_t mul = unit == 2 ? 0x0101 : 0x01010101;
                    fill = B.CreateMul(w, ConstantInt::get(T, mul));
                }
            }
            auto *MT = dyn_cast<MemTransferInst>(MI);
            // memmove with overlap: load everything first, then store.
            std::vector<Value *> loaded;
            for (uint64_t off = 0; off < len; off += unit) {
                if (!MT) break;
                Value *s = B.CreateConstInBoundsGEP1_64(Type::getInt8Ty(C), MT->getSource(), off);
                loaded.push_back(B.CreateAlignedLoad(T, s, commonAlignment(MT->getSourceAlign().valueOrOne(), off)));
            }
            for (uint64_t off = 0, k = 0; off < len; off += unit, k++) {
                Value *d = B.CreateConstInBoundsGEP1_64(Type::getInt8Ty(C), MI->getDest(), off);
                B.CreateAlignedStore(MT ? loaded[k] : fill, d, commonAlignment(MI->getDestAlign().valueOrOne(), off));
            }
            MI->eraseFromParent();
            continue;
        }
        if (auto *MC = dyn_cast<MemCpyInst>(MI)) expandMemCpyAsLoop(MC, TTI);
        else if (auto *MM = dyn_cast<MemMoveInst>(MI)) {
            if (!expandMemMoveAsLoop(MM, TTI)) fail("unsupported-feature", "memmove between address spaces");
        } else if (auto *MS = dyn_cast<MemSetInst>(MI)) expandMemSetAsLoop(MS);
        else fail("unsupported-intrinsic", MI->getCalledFunction()->getName().str());
        MI->eraseFromParent();
    }
}

static void insertGridGuard(Function &F) {
    BasicBlock &entry = F.getEntryBlock();
    auto it = entry.getFirstInsertionPt();
    while (isa<AllocaInst>(&*it)) ++it;
    BasicBlock *rest = entry.splitBasicBlock(it, "grid.in");
    BasicBlock *out = BasicBlock::Create(F.getContext(), "grid.out", &F);
    ReturnInst::Create(F.getContext(), out);
    entry.getTerminator()->eraseFromParent();
    IRBuilder<> B(&entry);
    FunctionCallee oob = F.getParent()->getOrInsertFunction("airc.grid_oob", Type::getInt1Ty(F.getContext()));
    Value *c = B.CreateCall(oob);
    B.CreateCondBr(c, out, rest);
}

// Function constants and values derived from them live in mutable
// address-space-2 globals that the static initializer (section
// "air.static_init") fills. Run the initializer at the start of F and turn
// those globals into private memory, so SROA leaves SSA values computed
// from the initializer globals (which the emitter maps to specialization
// constants).
static void rewritePointer(Value *old, Value *newPtr) {
    std::vector<User *> users(old->user_begin(), old->user_end());
    for (User *U : users) {
        auto *I = dyn_cast<Instruction>(U);
        if (!I) fail("unsupported-feature", "constant use of a function-constant global");
        if (auto *L = dyn_cast<LoadInst>(I)) {
            auto *N = new LoadInst(L->getType(), newPtr, L->getName(), L->isVolatile(), L->getAlign(), L);
            L->replaceAllUsesWith(N);
            L->eraseFromParent();
        } else if (auto *S = dyn_cast<StoreInst>(I)) {
            if (S->getPointerOperand() != old) fail("unsupported-feature", "address of a function-constant global stored");
            new StoreInst(S->getValueOperand(), newPtr, S->isVolatile(), S->getAlign(), S);
            S->eraseFromParent();
        } else if (auto *G = dyn_cast<GetElementPtrInst>(I)) {
            std::vector<Value *> idx(G->idx_begin(), G->idx_end());
            auto *N = GetElementPtrInst::Create(G->getSourceElementType(), newPtr, idx, G->getName(), G);
            rewritePointer(G, N);
            G->eraseFromParent();
        } else if (isa<BitCastInst>(I) || isa<AddrSpaceCastInst>(I)) {
            rewritePointer(I, newPtr);
            I->eraseFromParent();
        } else {
            fail("unsupported-feature", std::string("use of a function-constant global by ") + I->getOpcodeName());
        }
    }
}

static void runStaticInitializers(Module &M, Function &F) {
    // Function constants with values (specialized): their loads are constants.
    for (GlobalVariable &G : M.globals())
        if (G.hasSection() && G.getSection() == "air.fc_initializer" && G.hasInitializer() && !isa<UndefValue>(G.getInitializer())) {
            std::vector<User *> users(G.user_begin(), G.user_end());
            for (User *U : users)
                if (auto *L = dyn_cast<LoadInst>(U))
                    if (L->getType() == G.getValueType()) {
                        L->replaceAllUsesWith(G.getInitializer());
                        L->eraseFromParent();
                    }
        }
    std::vector<Function *> inits;
    for (Function &G : M)
        if (!G.isDeclaration() && G.getSection() == "air.static_init") inits.push_back(&G);
    if (inits.empty()) return;
    std::set<GlobalVariable *> written;
    for (Function *I : inits)
        for (BasicBlock &B : *I)
            for (Instruction &X : B)
                if (auto *S = dyn_cast<StoreInst>(&X))
                    if (auto *G = dyn_cast<GlobalVariable>(getUnderlyingObject(S->getPointerOperand())))
                        if (!G->isConstant()) written.insert(G);
    bool used = false;
    for (GlobalVariable *G : written)
        for (User *U : G->users()) {
            if (auto *I = dyn_cast<Instruction>(U)) used |= I->getFunction() == &F;
            else used = true;  // constant expressions: check conservatively
        }
    if (!used) return;
    IRBuilder<> B(&*F.getEntryBlock().getFirstInsertionPt());
    for (Function *I : inits) B.CreateCall(I);
    for (Function *I : inits) {
        I->removeFnAttr(Attribute::NoInline);
        I->addFnAttr(Attribute::AlwaysInline);
    }
    // Inline, then move the globals into allocas.
    PassBuilder PB;
    LoopAnalysisManager LAM;
    FunctionAnalysisManager FAM;
    CGSCCAnalysisManager CGAM;
    ModuleAnalysisManager MAM;
    PB.registerModuleAnalyses(MAM);
    PB.registerCGSCCAnalyses(CGAM);
    PB.registerFunctionAnalyses(FAM);
    PB.registerLoopAnalyses(LAM);
    PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);
    ModulePassManager MPM;
    MPM.addPass(AlwaysInlinerPass(false));
    MPM.run(M, MAM);
    lowerConstantExprs(F);
    // Selects of pointers into these globals: sink the select below GEPs and
    // loads (select c, p, q)[i] -> select c, p[i], q[i]; loads of globals
    // can be speculated.
    std::function<void(SelectInst *)> sink = [&](SelectInst *S) {
        std::vector<User *> users(S->user_begin(), S->user_end());
        for (User *U : users) {
            if (auto *L = dyn_cast<LoadInst>(U)) {
                IRBuilder<> LB(L);
                Value *a = LB.CreateAlignedLoad(L->getType(), S->getTrueValue(), L->getAlign());
                Value *b = LB.CreateAlignedLoad(L->getType(), S->getFalseValue(), L->getAlign());
                L->replaceAllUsesWith(LB.CreateSelect(S->getCondition(), a, b));
                L->eraseFromParent();
            } else if (auto *G = dyn_cast<GetElementPtrInst>(U)) {
                if (G->getPointerOperand() != S) continue;
                IRBuilder<> GB(G);
                std::vector<Value *> idx(G->idx_begin(), G->idx_end());
                Value *a = GB.CreateGEP(G->getSourceElementType(), S->getTrueValue(), idx);
                Value *b = GB.CreateGEP(G->getSourceElementType(), S->getFalseValue(), idx);
                auto *NS = cast<SelectInst>(GB.CreateSelect(S->getCondition(), a, b));
                G->replaceAllUsesWith(NS);
                G->eraseFromParent();
                sink(NS);
            }
        }
        if (S->use_empty()) S->eraseFromParent();
    };
    std::vector<SelectInst *> sels;
    for (BasicBlock &BB : F)
        for (Instruction &X : BB)
            if (auto *S = dyn_cast<SelectInst>(&X))
                if (S->getType()->isPointerTy() && S->getType()->getPointerAddressSpace() == 2) sels.push_back(S);
    for (SelectInst *S : sels) sink(S);
    for (GlobalVariable *G : written) {
        auto *A = new AllocaInst(G->getValueType(), 0, G->getName() + ".init", &*F.getEntryBlock().getFirstInsertionPt());
        A->setAlignment(G->getAlign().valueOrOne());
        std::vector<User *> users(G->user_begin(), G->user_end());
        for (User *U : users) {
            auto *I = dyn_cast<Instruction>(U);
            if (!I || I->getFunction() != &F) continue;
            // Rewrite this user only.
            Value *tmp = nullptr;
            (void)tmp;
            if (auto *L = dyn_cast<LoadInst>(I)) {
                auto *N = new LoadInst(L->getType(), A, L->getName(), L->isVolatile(), L->getAlign(), L);
                L->replaceAllUsesWith(N);
                L->eraseFromParent();
            } else if (auto *S = dyn_cast<StoreInst>(I)) {
                if (S->getPointerOperand() != G) fail("unsupported-feature", "address of a function-constant global stored");
                new StoreInst(S->getValueOperand(), A, S->isVolatile(), S->getAlign(), S);
                S->eraseFromParent();
            } else {
                Value *N = nullptr;
                if (auto *GEP = dyn_cast<GetElementPtrInst>(I)) {
                    std::vector<Value *> idx(GEP->idx_begin(), GEP->idx_end());
                    N = GetElementPtrInst::Create(GEP->getSourceElementType(), A, idx, GEP->getName(), GEP);
                } else if (isa<BitCastInst>(I) || isa<AddrSpaceCastInst>(I)) {
                    N = A;
                } else {
                    fail("unsupported-feature", std::string("use of a function-constant global by ") + I->getOpcodeName());
                }
                rewritePointer(I, N);
                I->eraseFromParent();
            }
        }
    }
}

// Helpers kept out of line (emitted as SPIR-V functions marked DontInline):
// the Thor's driver compile time grows faster than linearly with function
// size and honours DontInline (measured: a helper called 13 times compiled
// in 42 ms out of line, 213 ms inlined). A helper qualifies when it is
// called from several places and is not small, and when nothing in it
// depends on the entry function (static-initializer globals, interpolants,
// by-value aggregates, recursion).
static std::vector<Function *> chooseOutOfLine(Module &M, Function &F) {
    std::vector<Function *> keep;
    if (getenv("AIRC_INLINE_ALL")) return keep;
    unsigned minSize = 40;
    if (const char *v = getenv("AIRC_OUTLINE_MIN")) minSize = (unsigned)atoi(v);
    std::map<Function *, unsigned> sites;
    std::set<Function *> reach;
    std::vector<Function *> work{&F};
    while (!work.empty()) {
        Function *G = work.back();
        work.pop_back();
        if (!reach.insert(G).second) continue;
        for (BasicBlock &B : *G)
            for (Instruction &I : B)
                if (auto *C = dyn_cast<CallBase>(&I))
                    if (Function *H = C->getCalledFunction())
                        if (!H->isDeclaration()) {
                            sites[H]++;
                            work.push_back(H);
                        }
    }
    // Globals the static initializer writes (function-constant values).
    std::set<const GlobalVariable *> written;
    for (Function &G : M)
        if (!G.isDeclaration() && G.getSection() == "air.static_init")
            for (BasicBlock &B : G)
                for (Instruction &I : B)
                    if (auto *S = dyn_cast<StoreInst>(&I))
                        if (auto *GV = dyn_cast<GlobalVariable>(getUnderlyingObject(S->getPointerOperand()))) written.insert(GV);
    std::map<Function *, bool> eligibleMemo;
    std::function<bool(Function *, std::set<Function *> &)> eligible = [&](Function *H, std::set<Function *> &stack) -> bool {
        auto m = eligibleMemo.find(H);
        if (m != eligibleMemo.end()) return m->second;
        if (!stack.insert(H).second) return false;  // recursion
        bool ok = !H->isVarArg();
        for (Argument &A : H->args())
            if (A.hasByValAttr() || A.hasStructRetAttr() || A.hasInAllocaAttr()) ok = false;
        for (BasicBlock &B : *H)
            for (Instruction &I : B) {
                for (Value *Op : I.operands()) {
                    std::vector<Value *> todo{Op};
                    while (!todo.empty() && ok) {
                        Value *V = todo.back();
                        todo.pop_back();
                        if (auto *GV = dyn_cast<GlobalVariable>(V)) {
                            if (written.count(GV) || (GV->getAddressSpace() == 2 && !GV->isConstant())) ok = false;
                        } else if (auto *CE = dyn_cast<ConstantExpr>(V)) {
                            for (Value *O : CE->operands()) todo.push_back(O);
                        }
                    }
                }
                if (auto *C = dyn_cast<CallBase>(&I)) {
                    Function *G = C->getCalledFunction();
                    if (!G) { ok = false; continue; }
                    StringRef n = G->getName();
                    if (n.starts_with("air.interpolate_") || n.starts_with("airc.") || n.starts_with("air.write_imageblock_slice")) ok = false;
                    if (!G->isDeclaration() && !eligible(G, stack)) ok = false;
                }
            }
        stack.erase(H);
        eligibleMemo[H] = ok;
        return ok;
    };
    for (auto &p : sites) {
        Function *H = p.first;
        if (H == &F) continue;
        size_t n = 0;
        for (BasicBlock &B : *H) n += B.size();
        std::set<Function *> stack;
        if (p.second >= 2 && n >= minSize && eligible(H, stack)) keep.push_back(H);
    }
    return keep;
}

// ---------------------------------------------------------------------------
// Helpers entered under divergent control flow (stage8-contract.md §13.3).
//
// The Thor's driver compiles a DontInline function as a real call. When the
// lanes of one subgroup take different paths and two groups of them are
// inside out-of-line functions at the same time, the subgroup can stop for
// good: measured with the guest driver's `astc` kernel, two threads of one
// subgroup decoding blocks of different kinds never finish, the same two
// threads in different subgroups finish at once, and the kernel with its
// two helpers inlined (or without DontInline) finishes. So a helper stays
// out of line only when every call to it runs in uniform control flow: all
// the subgroup's remaining lanes call it together.
//
// The analysis is conservative (anything not shown uniform is divergent):
//  - values: the entry function's non-pointer arguments (thread positions,
//    stage inputs) and every argument of a helper are divergent; loads from
//    private or threadgroup memory, atomics and calls that read memory or
//    depend on the lane are divergent; anything computed from a divergent
//    value is divergent;
//  - control: a conditional branch or switch on a divergent value makes
//    every block reachable from it before its immediate post-dominator
//    divergent (this covers the bodies of loops with a divergent exit), and
//    phis in those blocks or at that post-dominator are divergent;
//  - the grid guard's branch (`airc.grid_oob`) does not count: lanes outside
//    the grid return at once and never call anything.
namespace {
struct Divergence {
    std::set<const Value *> values;
    std::set<const BasicBlock *> blocks;  // executed under divergent control

    static bool laneDependentCall(const CallBase *C) {
        const Function *G = C->getCalledFunction();
        if (!G) return true;
        StringRef n = G->getName();
        if (n == "airc.grid_oob") return false;
        if (!G->isDeclaration()) return true;  // helpers kept out of line
        if (!C->doesNotAccessMemory()) return true;
        if (!(n.starts_with("llvm.") || n.starts_with("air."))) return true;
        for (const char *k : {"simd", "quad", "thread", "get_", "lane", "random", "dfd", "fwidth", "interpolat", "sample", "read", "atomic"})
            if (n.contains(k)) return true;
        return false;
    }

    Divergence(Function &G, bool isEntry) {
        for (Argument &A : G.args())
            if (!isEntry || !A.getType()->isPointerTy()) values.insert(&A);
        PostDominatorTree PDT(G);
        for (bool changed = true; changed;) {
            changed = false;
            for (BasicBlock &B : G)
                for (Instruction &I : B) {
                    if (values.count(&I)) continue;
                    bool d = false;
                    if (isa<PHINode>(&I)) d = blocks.count(&B) || joins.count(&B);
                    else if (auto *L = dyn_cast<LoadInst>(&I)) {
                        unsigned as = L->getPointerAddressSpace();
                        d = L->isVolatile() || L->isAtomic() || as == 0 || as == 3 || as == 4;
                    } else if (auto *C = dyn_cast<CallBase>(&I)) d = laneDependentCall(C);
                    else if (isa<AtomicRMWInst>(&I) || isa<AtomicCmpXchgInst>(&I)) d = true;
                    for (Value *Op : I.operands())
                        if (values.count(Op)) d = true;
                    if (d) {
                        values.insert(&I);
                        changed = true;
                    }
                }
            for (BasicBlock &B : G) {
                Instruction *T = B.getTerminator();
                Value *cond = nullptr;
                if (auto *Br = dyn_cast<BranchInst>(T)) cond = Br->isConditional() ? Br->getCondition() : nullptr;
                else if (auto *SW = dyn_cast<SwitchInst>(T)) cond = SW->getCondition();
                if (!cond || !values.count(cond) || divergentBranches.count(&B)) continue;
                divergentBranches.insert(&B);
                changed = true;
                auto *N = PDT.getNode(&B);
                BasicBlock *stop = (N && N->getIDom()) ? N->getIDom()->getBlock() : nullptr;
                if (stop) joins.insert(stop);
                std::vector<BasicBlock *> work(succ_begin(&B), succ_end(&B));
                while (!work.empty()) {
                    BasicBlock *X = work.back();
                    work.pop_back();
                    if (X == stop || !blocks.insert(X).second) continue;
                    for (BasicBlock *S : successors(X)) work.push_back(S);
                }
            }
        }
    }

private:
    std::set<const BasicBlock *> divergentBranches, joins;  // joins: post-dominators of divergent branches
};
}  // namespace

// Inlines every helper of `keep` that some function of `all` calls under
// divergent control flow (see above), until no such call is left; the
// callers are cleaned up again after inlining. Returns the helpers still
// out of line.
static std::vector<Function *> inlineDivergentHelpers(Function &F, std::vector<Function *> keep, FunctionAnalysisManager &FAM,
                                                      const std::function<void(Function &)> &cleanup) {
    for (bool changed = true; changed && !keep.empty();) {
        changed = false;
        std::set<Function *> keepSet(keep.begin(), keep.end()), divergent;
        std::vector<Function *> all{&F};
        all.insert(all.end(), keep.begin(), keep.end());
        for (Function *G : all) {
            Divergence D(*G, G == &F);
            for (BasicBlock &B : *G)
                for (Instruction &I : B)
                    if (auto *C = dyn_cast<CallInst>(&I))
                        if (Function *H = C->getCalledFunction())
                            if (keepSet.count(H) && D.blocks.count(&B)) divergent.insert(H);
        }
        if (divergent.empty()) break;
        std::vector<Function *> left;
        for (Function *H : keep)
            if (!divergent.count(H)) left.push_back(H);
        keep = left;
        // Inline every call to these helpers in the functions that remain,
        // again after each round: an inlined body may call another of them.
        std::set<Function *> touched;
        std::vector<Function *> callers{&F};
        callers.insert(callers.end(), keep.begin(), keep.end());
        for (bool more = true; more;) {
            more = false;
            for (Function *G : callers) {
                std::vector<CallInst *> sites;
                for (BasicBlock &B : *G)
                    for (Instruction &I : B)
                        if (auto *C = dyn_cast<CallInst>(&I))
                            if (divergent.count(C->getCalledFunction())) sites.push_back(C);
                for (CallInst *C : sites) {
                    InlineFunctionInfo IFI;
                    if (!InlineFunction(*C, IFI).isSuccess()) fail("internal", "could not inline helper " + C->getCalledFunction()->getName().str());
                    touched.insert(G);
                    more = true;
                }
            }
        }
        for (Function *G : touched) {
            FAM.invalidate(*G, PreservedAnalyses::none());
            lowerConstantExprs(*G);
            removeUnreachableBlocks(*G);
            cleanup(*G);
        }
        if (getenv("AIRC_STATS")) fprintf(stderr, "airc-helpers: %zu inlined (called under divergent control), %zu kept\n", divergent.size(), keep.size());
        changed = true;
    }
    return keep;
}

// The per-function pipeline after inlining: scalar replacement, clean-up,
// memory intrinsics, then the CFG normalizations for structured control
// flow.
static void cleanupFunction(Function &F, FunctionAnalysisManager &FAM) {
    // Pure AIR intrinsics (math, conversions) may run speculatively, so that
    // CFG simplification can turn small branches into selects (the Thor's
    // driver compile time grows with the number of branches).
    if (!getenv("AIRC_NO_SPECULATE"))
        for (Function &D : *F.getParent())
            if (D.isDeclaration() && D.getName().starts_with("air.") && D.doesNotAccessMemory() && !D.isConvergent() &&
                !D.getName().starts_with("air.discard"))
                D.addFnAttr(Attribute::Speculatable);
    {
        // Scalar replacement and light clean-up: constant propagation, dead
        // code, CFG simplification (branches on specialized function
        // constants disappear here). No InstCombine: it would introduce
        // LLVM intrinsics outside the lowered set.
        FunctionPassManager FPM;
        FPM.addPass(SROAPass(SROAOptions::PreserveCFG));
        if (!getenv("AIRC_NO_SIMPLIFY")) {
            FPM.addPass(EarlyCSEPass());
            FPM.addPass(SCCPPass());
            FPM.addPass(ADCEPass());
            FPM.addPass(SimplifyCFGPass());
        }
        FPM.run(F, FAM);
    }
    expandMemIntrinsics(F);
    FAM.invalidate(F, PreservedAnalyses::none());
}

static size_t condBranches(Function &F) {
    size_t n = 0;
    for (BasicBlock &B : F)
        if (auto *Br = dyn_cast<BranchInst>(B.getTerminator())) n += Br->isConditional();
        else if (auto *SW = dyn_cast<SwitchInst>(B.getTerminator())) n += SW->getNumCases();
    return n;
}

// Loop guard (stage8-contract.md §13.3): every loop header first calls
// the marker `airc.loop_budget`, which the emitter lowers to "count one
// more loop iteration of this invocation and say whether the count is now
// over the limit"; when it is, the header leaves the loop through one of
// its exit blocks. The count is per invocation and shared by every loop
// of every function, so after it runs out each loop ends at its next
// header and the invocation finishes along an acyclic path: a kernel whose
// loop would never end (for example a trip count that skips past its
// bound) costs at most the limit instead of stalling the GPU queue.
// Values the exit block's phis would take from inside the loop are zero
// on the guard edge (the results of a stopped invocation are not
// meaningful anyway). Runs after FixIrreducible, so every cycle has a
// loop header, and in LCSSA form, so no value defined in the loop is used
// past an exit except through such a phi. Loops whose trip count scalar
// evolution bounds by a constant (the usual `for (i = 0; i < 4; i++)`)
// end by themselves and get no guard, so they keep their known trip count.
static void insertLoopGuards(Function &F, FunctionAnalysisManager &FAM) {
    DominatorTree DT(F);
    LoopInfo LI(DT);
    if (LI.empty()) return;
    for (Loop *L : LI) formLCSSARecursively(*L, DT, &LI, nullptr);
    std::vector<std::pair<BasicBlock *, BasicBlock *>> guards;  // header, exit
    {
        TargetLibraryInfoImpl TLII(Triple(F.getParent()->getTargetTriple()));
        TargetLibraryInfo TLI(TLII, &F);
        AssumptionCache AC(F);
        ScalarEvolution SE(F, TLI, AC, DT, LI);
        for (Loop *L : LI.getLoopsInPreorder()) {
            SmallVector<BasicBlock *, 4> exits;
            L->getUniqueExitBlocks(exits);
            if (exits.empty()) continue;  // no way out at all: nothing to branch to
            if (SE.getSmallConstantMaxTripCount(L) != 0) continue;  // bounded
            guards.push_back({L->getHeader(), exits[0]});
        }
    }
    FunctionCallee budget = F.getParent()->getOrInsertFunction("airc.loop_budget", Type::getInt1Ty(F.getContext()));
    for (auto &g : guards) {
        BasicBlock *H = g.first, *X = g.second;
        BasicBlock *body = H->splitBasicBlock(H->getFirstNonPHI(), H->getName() + ".guarded");
        H->getTerminator()->eraseFromParent();
        IRBuilder<> B(H);
        Value *over = B.CreateCall(budget);
        B.CreateCondBr(over, X, body);
        for (PHINode &P : X->phis()) P.addIncoming(Constant::getNullValue(P.getType()), H);
    }
    FAM.invalidate(F, PreservedAnalyses::none());
}

static void structureFunction(Function &F, FunctionAnalysisManager &FAM, bool loopGuard) {
    FAM.invalidate(F, PreservedAnalyses::none());
    {
        FunctionPassManager FPM;
        FPM.addPass(LowerSwitchPass());
        FPM.addPass(UnifyFunctionExitNodesPass());
        FPM.addPass(FixIrreduciblePass());
        FPM.run(F, FAM);
    }
    if (loopGuard) insertLoopGuards(F, FAM);
    {
        FunctionPassManager FPM;
        FPM.addPass(UnifyLoopExitsPass());
        FPM.addPass(LoopSimplifyPass());
        if (!getenv("AIRC_NO_STRUCTURIZE")) FPM.addPass(StructurizeCFGPass());
        FPM.run(F, FAM);
    }
    removeUnreachableBlocks(F);
    lowerConstantExprs(F);  // the passes may fold new ones
    std::string err;
    raw_string_ostream os(err);
    if (verifyFunction(F, &os)) fail("internal", "LLVM verifier after preparation: " + os.str());
}

bool prepareFunction(Module &M, Function &F, bool gridGuard, const std::function<void(Function &)> &afterInline,
                     std::vector<Function *> *helpers, bool loopGuard) {
    // 1. Inline every defined function into F, except helpers kept out of line.
    std::vector<Function *> keep = chooseOutOfLine(M, F);
    std::set<Function *> keepSet(keep.begin(), keep.end());
    bool calls = false;
    for (Function &G : M) {
        if (&G == &F || G.isDeclaration()) continue;
        G.removeFnAttr(Attribute::OptimizeNone);
        if (keepSet.count(&G)) {
            G.removeFnAttr(Attribute::AlwaysInline);
            G.addFnAttr(Attribute::NoInline);
            continue;
        }
        G.removeFnAttr(Attribute::NoInline);
        G.addFnAttr(Attribute::AlwaysInline);
        calls = true;
    }
    PassBuilder PB;
    LoopAnalysisManager LAM;
    FunctionAnalysisManager FAM;
    CGSCCAnalysisManager CGAM;
    ModuleAnalysisManager MAM;
    PB.registerModuleAnalyses(MAM);
    PB.registerCGSCCAnalyses(CGAM);
    PB.registerFunctionAnalyses(FAM);
    PB.registerLoopAnalyses(LAM);
    PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);
    if (calls) {
        ModulePassManager MPM;
        MPM.addPass(AlwaysInlinerPass(false));
        MPM.run(M, MAM);
    }
    // Function-constant globals are now used by F itself (helpers that use
    // them are never kept out of line).
    runStaticInitializers(M, F);
    std::vector<Function *> all{&F};
    all.insert(all.end(), keep.begin(), keep.end());
    for (Function *G : all)
        for (BasicBlock &B : *G)
            for (Instruction &I : B)
                if (auto *C = dyn_cast<CallInst>(&I))
                    if (Function *H = C->getCalledFunction())
                        if (!H->isDeclaration() && !keepSet.count(H))
                            fail("unsupported-feature", "call that could not be inlined: " + H->getName().str());

    // 2. Constant expressions, memory intrinsics, unreachable blocks.
    for (Function *G : all) {
        lowerConstantExprs(*G);
        if (afterInline) afterInline(*G);
        removeUnreachableBlocks(*G);
    }
    if (gridGuard) {
        for (Function *G : all)
            for (BasicBlock &B : *G)
                for (Instruction &I : B)
                    if (auto *C = dyn_cast<CallInst>(&I))
                        if (Function *H = C->getCalledFunction())
                            if (H->getName().contains("barrier")) gridGuard = false;
    }
    if (gridGuard) insertGridGuard(F);

    // 3. Per-function clean-up and structuring. Helpers called under
    // divergent control flow are inlined after the clean-up (which leaves
    // the SSA form the divergence analysis needs).
    for (Function *G : all) cleanupFunction(*G, FAM);
    if (!keep.empty() && !getenv("AIRC_OUTLINE_DIVERGENT")) {
        keep = inlineDivergentHelpers(F, keep, FAM, [&](Function &G) { cleanupFunction(G, FAM); });
        all.assign(1, &F);
        all.insert(all.end(), keep.begin(), keep.end());
    }
    for (Function *G : all) {
        size_t before = G->size();
        structureFunction(*G, FAM, loopGuard);
        if (getenv("AIRC_STATS")) fprintf(stderr, "airc-structure: %zu -> %zu blocks, %zu conditional branches\n", before, G->size(), condBranches(*G));
    }
    if (helpers) *helpers = keep;
    return gridGuard;
}

// ---------------------------------------------------------------------------
// Structured control flow plan (SPIR-V 2.11 structured control flow).

namespace {
struct Analysis {
    DominatorTree DT;
    PostDominatorTree PDT;
    LoopInfo LI;
    explicit Analysis(Function &F) : DT(F), PDT(F), LI(DT) {}
};
}  // namespace

static BasicBlock *unreachableBlock(Function &F) {
    BasicBlock *B = BasicBlock::Create(F.getContext(), "merge.unreachable", &F);
    new UnreachableInst(F.getContext(), B);
    return B;
}

StructurePlan planStructure(Function &F) {
    std::vector<BasicBlock *> synthetic;
    for (int iter = 0; iter < 2000; iter++) {
        for (BasicBlock *U : synthetic) U->eraseFromParent();
        synthetic.clear();
        // Loops: the back-edge block must not be the header itself, and a
        // header's conditional branch must leave the loop (OpLoopMerge
        // covers it); otherwise the branch starts a selection in a block of
        // its own. All loops are fixed in one pass.
        {
            DominatorTree DT(F);
            LoopInfo LI(DT);
            std::vector<BasicBlock *> selfLoops, headers;
            for (Loop *L : LI.getLoopsInPreorder()) {
                BasicBlock *latch = L->getLoopLatch();
                if (!latch) fail("structurize-failed", "loop without a single latch");
                if (latch == L->getHeader()) {
                    selfLoops.push_back(latch);
                    continue;
                }
                auto *Br = dyn_cast<BranchInst>(L->getHeader()->getTerminator());
                BasicBlock *exit = L->getUniqueExitBlock();
                if (Br && Br->isConditional() && Br->getSuccessor(0) != exit && Br->getSuccessor(1) != exit) headers.push_back(L->getHeader());
            }
            for (BasicBlock *B : selfLoops) SplitEdge(B, B);
            for (BasicBlock *H : headers) SplitBlock(H, H->getTerminator(), (DominatorTree *)nullptr, (LoopInfo *)nullptr, nullptr, "loop.body");
            if (!selfLoops.empty() || !headers.empty()) continue;
        }
        Analysis A(F);
        StructurePlan plan;
        std::map<BasicBlock *, std::vector<BasicBlock *>> claims;  // merge -> headers
        ReversePostOrderTraversal<Function *> RPOT(&F);
        std::map<BasicBlock *, unsigned> rpoIndex;
        for (BasicBlock *B : RPOT) {
            rpoIndex[B] = (unsigned)plan.order.size();
            plan.order.push_back(B);
            Instruction *T = B->getTerminator();
            Loop *L = A.LI.getLoopFor(B);
            if (L && L->getHeader() == B) {
                Construct c;
                c.loop = true;
                c.cont = L->getLoopLatch();
                c.merge = L->getUniqueExitBlock();
                if (!c.merge) {
                    SmallVector<BasicBlock *, 4> exits;
                    L->getExitBlocks(exits);
                    if (!exits.empty()) fail("structurize-failed", "loop with several exit blocks");
                    c.merge = unreachableBlock(F);
                    synthetic.push_back(c.merge);
                }
                plan.headers[B] = c;
                claims[c.merge].push_back(B);
                // The continue target belongs to this loop only: no inner
                // construct may merge there.
                claims[c.cont].push_back(B);
                continue;
            }
            auto *Br = dyn_cast<BranchInst>(T);
            if (!Br || Br->isUnconditional()) continue;
            BasicBlock *s0 = Br->getSuccessor(0), *s1 = Br->getSuccessor(1);
            if (s0 == s1) continue;  // no real choice; emitted as OpBranch
            auto exitOrCont = [&](BasicBlock *S) {
                return L && (S == L->getUniqueExitBlock() || S == L->getLoopLatch() || S == L->getHeader());
            };
            bool e0 = exitOrCont(s0), e1 = exitOrCont(s1);
            if (L && B == L->getLoopLatch()) continue;  // the back-edge block: header or exit
            if (e0 && e1) continue;
            Construct c;
            if (e0) c.merge = s1;
            else if (e1) c.merge = s0;
            else {
                auto *N = A.PDT.getNode(B);
                c.merge = (N && N->getIDom()) ? N->getIDom()->getBlock() : nullptr;
                if (!c.merge) {
                    c.merge = unreachableBlock(F);
                    synthetic.push_back(c.merge);
                }
            }
            plan.headers[B] = c;
            claims[c.merge].push_back(B);
        }
        // A block can be the merge of one construct only; a merge must be
        // dominated by its header. Split the innermost claimant's edges.
        // Splits are collected on this analysis and applied together.
        std::vector<std::pair<BasicBlock *, SmallVector<BasicBlock *, 8>>> splits;
        for (auto &cl : claims) {
            BasicBlock *M = cl.first;
            if (M->getTerminator() && isa<UnreachableInst>(M->getTerminator()) && pred_empty(M) && cl.second.size() > 1) {
                // Synthetic merges: give each claimant its own.
                for (size_t i = 1; i < cl.second.size(); i++) {
                    BasicBlock *U = unreachableBlock(F);
                    synthetic.push_back(U);
                    plan.headers[cl.second[i]].merge = U;
                }
                continue;
            }
            std::vector<BasicBlock *> hs = cl.second;
            BasicBlock *needsSplit = nullptr;
            if (hs.size() > 1) {
                // Innermost: the latest claimant in reverse post-order.
                needsSplit = hs[0];
                for (BasicBlock *h : hs)
                    if (rpoIndex[h] > rpoIndex[needsSplit]) needsSplit = h;
            } else if (!pred_empty(M) && !A.DT.dominates(hs[0], M)) {
                needsSplit = hs[0];
            }
            if (!needsSplit) continue;
            SmallVector<BasicBlock *, 8> preds;
            for (BasicBlock *P : predecessors(M))
                if (A.DT.dominates(needsSplit, P)) preds.push_back(P);
            if (preds.empty()) fail("structurize-failed", "merge block " + M->getName().str() + " without predecessors in its construct");
            splits.push_back({M, preds});
        }
        for (auto &sp : splits) SplitBlockPredecessors(sp.first, sp.second, ".merge");
        if (!splits.empty()) continue;
        // Unreachable merges go last.
        for (BasicBlock *U : synthetic)
            if (pred_empty(U)) plan.order.push_back(U);
        return plan;
    }
    fail("structurize-failed", "no fixed point");
}

}  // namespace airc
