// prepare.cpp: LLVM passes and the structured-control-flow plan.
#include "prepare.h"

#include "error.h"

#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/Analysis/LoopInfo.h"
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
#include "llvm/Transforms/Utils/FixIrreducible.h"
#include "llvm/Transforms/Utils/Local.h"
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

bool prepareFunction(Module &M, Function &F, bool gridGuard, const std::function<void(Function &)> &afterInline) {
    runStaticInitializers(M, F);
    // 1. Inline every defined function into F.
    bool calls = false;
    for (Function &G : M) {
        if (&G == &F || G.isDeclaration()) continue;
        G.removeFnAttr(Attribute::NoInline);
        G.removeFnAttr(Attribute::OptimizeNone);
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
    for (BasicBlock &B : F)
        for (Instruction &I : B)
            if (auto *C = dyn_cast<CallInst>(&I))
                if (Function *G = C->getCalledFunction())
                    if (!G->isDeclaration()) fail("unsupported-feature", "call that could not be inlined: " + G->getName().str());

    // 2. Constant expressions, memory intrinsics, unreachable blocks.
    lowerConstantExprs(F);
    if (afterInline) afterInline(F);
    removeUnreachableBlocks(F);
    if (gridGuard) {
        for (BasicBlock &B : F)
            for (Instruction &I : B)
                if (auto *C = dyn_cast<CallInst>(&I))
                    if (Function *G = C->getCalledFunction())
                        if (G->getName().contains("barrier")) gridGuard = false;
    }
    if (gridGuard) insertGridGuard(F);

    // 3. Scalar replacement, then the CFG normalizations.
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
    {
        FunctionPassManager FPM;
        FPM.addPass(LowerSwitchPass());
        FPM.addPass(UnifyFunctionExitNodesPass());
        FPM.addPass(FixIrreduciblePass());
        FPM.addPass(UnifyLoopExitsPass());
        FPM.addPass(LoopSimplifyPass());
        FPM.addPass(StructurizeCFGPass());
        FPM.run(F, FAM);
    }
    removeUnreachableBlocks(F);
    lowerConstantExprs(F);  // the passes may fold new ones
    std::string err;
    raw_string_ostream os(err);
    if (verifyFunction(F, &os)) fail("internal", "LLVM verifier after preparation: " + os.str());
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
