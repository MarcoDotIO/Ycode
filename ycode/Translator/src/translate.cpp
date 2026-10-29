// translate.cpp: AIR -> SPIR-V emission (metal-shaders.md section 4):
// types and constants, the memory model of section 4.3 (buffers as 64-bit
// device addresses, threadgroup memory as aliased explicit-layout arrays,
// private memory as a word arena), the binding model of section 4.4 (abi.h),
// the stage interface of section 4.5, compute built-ins of section 4.6,
// structured control flow of section 4.8, validation and reflection.
#include "translator_impl.h"

#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/Bitcode/BitcodeReader.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/GetElementPtrTypeIterator.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/Linker/Linker.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/Operator.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/raw_ostream.h"
#include "spirv-tools/libspirv.hpp"
#include "spirv-tools/optimizer.hpp"

#include <chrono>
#include <functional>
#include <cmath>
#include <cstring>

using namespace llvm;

namespace airc {

const char *kTranslatorVersion = "ycode-airc 0.1 (abi 1)";

std::string printType(Type *T) {
    std::string s;
    raw_string_ostream os(s);
    T->print(os);
    return os.str();
}

static std::string printValue(const Value *V) {
    std::string s;
    raw_string_ostream os(s);
    V->print(os);
    std::string r = os.str();
    if (r.size() > 200) r = r.substr(0, 200) + "...";
    return r;
}

bool isSignedTypeName(const std::string &t) {
    for (const char *p : {"int", "short", "char", "long"})
        if (t.rfind(p, 0) == 0) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Types, constants, values

std::string Translator::type(Type *T) {
    if (T->isVoidTy()) return E.tVoid();
    if (T->isIntegerTy(1)) return E.tBool();
    if (T->isIntegerTy()) {
        unsigned w = T->getIntegerBitWidth();
        if (w != 8 && w != 16 && w != 32 && w != 64) fail("unsupported-type", printType(T));
        return E.tInt(w);
    }
    if (T->isHalfTy()) return E.tFloat(16);
    if (T->isFloatTy()) return E.tFloat(32);
    if (T->isDoubleTy()) return E.tFloat(64);
    if (T->isPointerTy()) return E.tInt(64);
    if (auto *V = dyn_cast<FixedVectorType>(T)) {
        unsigned n = V->getNumElements();
        if (n < 2 || n > 4) fail("unsupported-type", printType(T));
        return E.tVec(type(V->getElementType()), n);
    }
    if (auto *S = dyn_cast<StructType>(T)) {
        std::string key = "struct", decl = "OpTypeStruct";
        for (Type *e : S->elements()) {
            std::string id = type(e);
            key += "_" + id;
            decl += " " + id;
        }
        return E.global(key, decl);
    }
    if (auto *A = dyn_cast<ArrayType>(T)) {
        if (!A->getNumElements()) fail("unsupported-type", printType(T));
        std::string e = type(A->getElementType()), n = E.u32(A->getNumElements());
        return E.global("arr" + e + "_" + n, "OpTypeArray " + e + " " + n);
    }
    fail("unsupported-type", printType(T));
}

static std::string floatLiteral(const APFloat &v, unsigned bits) {
    const char *big = bits == 16 ? "16" : bits == 32 ? "128" : "1024";
    if (v.isNaN()) return std::string("0x1.8p+") + big;
    if (v.isInfinity()) return std::string(v.isNegative() ? "-" : "") + "0x1p+" + big;
    APFloat d = v;
    bool lost = false;
    d.convert(APFloat::IEEEdouble(), APFloat::rmNearestTiesToEven, &lost);
    char buf[64];
    snprintf(buf, sizeof buf, "%a", d.convertToDouble());
    return buf;
}

std::string Translator::constant(Constant *C) {
    Type *T = C->getType();
    if (isa<PoisonValue>(C) || isa<UndefValue>(C)) return E.undef(type(T));
    if (auto *G = dyn_cast<GlobalVariable>(C)) {
        auto it = globalAddr.find(G);
        if (it == globalAddr.end())
            fail("unsupported-feature", "use of global " + G->getName().str() + " in address space " +
                                            std::to_string(G->getAddressSpace()));
        return it->second;
    }
    if (isa<ConstantPointerNull>(C)) return E.u64(0);
    if (auto *CI = dyn_cast<ConstantInt>(C)) {
        if (T->isIntegerTy(1)) return E.boolean(CI->isOne());
        return E.constant(type(T), std::to_string(CI->getZExtValue()));
    }
    if (auto *CF = dyn_cast<ConstantFP>(C)) return E.constant(type(T), floatLiteral(CF->getValueAPF(), T->getPrimitiveSizeInBits()));
    if (isa<ConstantAggregateZero>(C)) return E.null(type(T));
    if (isa<ConstantDataSequential>(C) || isa<ConstantVector>(C) || isa<ConstantStruct>(C) || isa<ConstantArray>(C)) {
        unsigned n = T->isStructTy() ? T->getStructNumElements()
                     : T->isArrayTy() ? (unsigned)T->getArrayNumElements()
                                      : cast<FixedVectorType>(T)->getNumElements();
        std::vector<std::string> parts;
        for (unsigned i = 0; i < n; i++) parts.push_back(constant(C->getAggregateElement(i)));
        return E.composite(type(T), parts);
    }
    if (isa<Function>(C)) fail("unsupported-feature", "function pointer " + C->getName().str());
    fail("unsupported-feature", "constant " + printValue(C));
}

std::string Translator::val(Value *V) {
    if (auto *C = dyn_cast<Constant>(V)) return constant(C);
    auto it = vals.find(V);
    if (it != vals.end()) return it->second;
    if (isa<Argument>(V)) fail("internal", "argument without a value: " + printValue(V));
    std::string id = E.fresh();  // forward reference (phi operand)
    vals[V] = id;
    return id;
}

std::string Translator::def(Value *V) {
    auto it = vals.find(V);
    if (it != vals.end()) return it->second;
    return vals[V] = E.fresh();
}

void Translator::bind(Value *V, const std::string &id) {
    auto it = vals.find(V);
    if (it != vals.end() && it->second != id) {
        E.stmt(it->second + " = OpCopyObject " + type(V->getType()) + " " + id);
        return;
    }
    vals[V] = id;
}

std::string Translator::label(const BasicBlock *B) {
    auto it = labels.find(B);
    if (it != labels.end()) return it->second;
    return labels[B] = E.fresh();
}

std::string Translator::addConst(const std::string &addr, int64_t off) {
    if (!off) return addr;
    return E.op("OpIAdd", E.tInt(64), {addr, E.u64((uint64_t)off)});
}

std::string Translator::toU32(const std::string &v) { return E.op("OpUConvert", E.tInt(32), {v}); }

// Integer width change with the given signedness (vectors too).
std::string Translator::castInt(const std::string &v, Type *from, unsigned toBits, bool sign) {
    unsigned fb = from->getScalarSizeInBits();
    if (fb == toBits) return v;
    std::string t = E.tInt(toBits);
    if (auto *VT = dyn_cast<FixedVectorType>(from)) t = E.tVec(t, VT->getNumElements());
    return E.op(sign && toBits > fb ? "OpSConvert" : "OpUConvert", t, {v});
}

// ---------------------------------------------------------------------------
// Memory (section 4.3)

// Whether a device or constant load through P gets the null guard: P is
// not derived from a bound buffer argument, a table entry, a global or a
// private allocation (it was loaded from memory, made from an integer, or
// merged from such values). `all`: every such load (bisection).
bool Translator::nullGuardLoad(Value *P, bool all) const {
    static const bool off = getenv("AIRC_NULL_GUARD") && std::string(getenv("AIRC_NULL_GUARD")) == "0";
    if (all) return true;
    if (off) return false;
    const Value *O = getUnderlyingObject(P, 64);
    if (isa<Argument>(O) || isa<GlobalValue>(O) || isa<AllocaInst>(O) || isa<ConstantPointerNull>(O)) return false;
    if (auto *CI = dyn_cast<CallInst>(O))
        if (CI->getCalledFunction() && CI->getCalledFunction()->getName().starts_with("airc.table_entry")) return false;
    return true;
}

// The argument table's address in the function being emitted (always
// mapped: a safe address for guarded loads).
std::string Translator::tableAddrHere() { return tableAddr; }

bool Translator::experiment(const char *what) const {
    const char *e = getenv("AIRC_EXP");
    if (!e || !*e) return false;
    std::string list = std::string(",") + e + ",";
    if (list.find(std::string(",") + what + ",") == std::string::npos) return false;
    const char *fn = getenv("AIRC_EXP_FN");
    return !fn || !*fn || F.getName() == fn;
}

std::string Translator::psbPointer(const std::string &addr, const std::string &pointee, unsigned bits) {
    if (bits == 8) E.caps.insert("StorageBuffer8BitAccess");
    if (bits == 16) E.caps.insert("StorageBuffer16BitAccess");
    return E.op("OpConvertUToPtr", E.tPtr("PhysicalStorageBuffer", pointee), {addr});
}

std::string Translator::workgroupElement(const std::string &addr, unsigned width) {
    auto it = wgVars.find(width);
    std::string var;
    std::string elem = E.tInt(width);
    std::string arrT, structT;
    if (it == wgVars.end()) {
        E.caps.insert("WorkgroupMemoryExplicitLayoutKHR");
        if (width == 8) E.caps.insert("WorkgroupMemoryExplicitLayout8BitAccessKHR");
        if (width == 16) E.caps.insert("WorkgroupMemoryExplicitLayout16BitAccessKHR");
        E.exts.insert("SPV_KHR_workgroup_memory_explicit_layout");
        std::string len;
        if (wgDynamic)
            len = width == 8 ? wgBytesId
                             : E.global("wglen" + std::to_string(width), "OpSpecConstantOp " + E.tInt(32) + " UDiv " + wgBytesId + " " + E.u32(width / 8));
        else
            len = E.u32(wgStaticBytesAligned() / (width / 8));
        arrT = E.global("wgarr" + std::to_string(width), "OpTypeArray " + elem + " " + len);
        E.decorate(arrT, "ArrayStride " + std::to_string(width / 8));
        structT = E.global("wgstruct" + std::to_string(width), "OpTypeStruct " + arrT);
        E.decorate(structT, "Block");
        E.memberDecorate(structT, 0, "Offset 0");
        std::string pt = E.tPtr("Workgroup", structT);
        var = E.fresh();
        E.globals << var << " = OpVariable " << pt << " Workgroup\n";
        E.decorate(var, "Aliased");
        E.interface.push_back(var);
        wgVars[width] = var;
    } else {
        var = it->second;
    }
    std::string idx = addr;
    if (width > 8) idx = E.op("OpShiftRightLogical", E.tInt(64), {addr, E.u64(width == 16 ? 1 : width == 32 ? 2 : 3)});
    idx = toU32(idx);
    return E.op("OpAccessChain", E.tPtr("Workgroup", elem), {var, E.u32(0), idx});
}

std::string Translator::privateWord(const std::string &wordIndex) {
    if (arenaVar.empty()) {
        // One per-invocation arena shared by all functions (pointers to
        // private memory are byte offsets into it).
        std::string arr = E.global("arena", "OpTypeArray " + E.tInt(32) + " " + E.u32(std::max<uint64_t>(4, (privateBytes + 3) / 4)));
        std::string pt = E.tPtr("Private", arr);
        arenaVar = E.fresh();
        E.globals << arenaVar << " = OpVariable " << pt << " Private\n";
        E.interface.push_back(arenaVar);
    }
    return E.op("OpAccessChain", E.tPtr("Private", E.tInt(32)), {arenaVar, toU32(wordIndex)});
}

std::vector<Function *> Translator::allFunctions() {
    std::vector<Function *> v{&F};
    v.insert(v.end(), helpers.begin(), helpers.end());
    return v;
}

void Translator::loadTableAddr() {
    unsigned member = EI.stage == Stage::Fragment ? 1 : 0;
    std::string p = E.op("OpAccessChain", E.tPtr("PushConstant", E.tInt(64)), {pcVar, E.u32(member)});
    tableAddr = E.op("OpLoad", E.tInt(64), {p});
}

void Translator::globalAddresses(Function &G) {
    std::set<GlobalVariable *> used;
    for (BasicBlock &B : G)
        for (Instruction &I : B)
            for (Value *Op : I.operands())
                if (auto *GV = dyn_cast<GlobalVariable>(Op)) used.insert(GV);
    for (GlobalVariable *GV : used) {
        if (wgStaticOffset.count(GV)) globalAddr[GV] = E.u64(wgStaticOffset[GV]);
        else if (constDataOffset.count(GV)) globalAddr[GV] = addConst(tableEntry(abi::kTableConstantData), (int64_t)constDataOffset[GV]);
        else if (constexprSamplerIndex.count(GV)) {
            unsigned i = constexprSamplerIndex[GV];
            if (i >= abi::kMaxConstexprSamplers) fail("unsupported-feature", "more than 16 constexpr samplers");
            globalAddr[GV] = tableEntry(abi::kTableConstexprSampler0 + i);
        }
    }
}

static unsigned bitsOf(Type *T) { return T->isPointerTy() ? 64 : T->getPrimitiveSizeInBits(); }

std::string Translator::scalarLoad(const std::string &addr, unsigned as, Type *T, uint64_t align) {
    std::string t = type(T);
    if (T->isIntegerTy(1)) {
        std::string b = scalarLoad(addr, as, Type::getInt8Ty(T->getContext()), align);
        return E.op("OpINotEqual", E.tBool(), {b, E.constant(E.tInt(8), "0")});
    }
    unsigned bits = bitsOf(T);
    if (as == kDevice || as == kConstant) {
        if (experiment("psb")) return E.null(t);
        std::string p = psbPointer(addr, t, bits);
        std::string r = E.fresh();
        E.body << r << " = OpLoad " << t << " " << p << " Aligned " << std::min<uint64_t>(align, 65536) << "\n";
        return r;
    }
    std::string it = E.tInt(bits);
    std::string raw;
    if (as == kImageblock && hasImageblock) as = kThreadgroup;
    if (as == kThreadgroup) {
        raw = E.op("OpLoad", it, {workgroupElement(addr, bits)});
    } else if (as == kPrivate) {
        std::string w = E.op("OpShiftRightLogical", E.tInt(64), {addr, E.u64(2)});
        if (bits == 32) {
            raw = E.op("OpLoad", E.tInt(32), {privateWord(w)});
        } else if (bits == 64) {
            std::string lo = E.op("OpLoad", E.tInt(32), {privateWord(w)});
            std::string hi = E.op("OpLoad", E.tInt(32), {privateWord(addConst(w, 1))});
            std::string lo64 = E.op("OpUConvert", it, {lo}), hi64 = E.op("OpUConvert", it, {hi});
            hi64 = E.op("OpShiftLeftLogical", it, {hi64, E.u64(32)});
            raw = E.op("OpBitwiseOr", it, {lo64, hi64});
        } else {
            std::string word = E.op("OpLoad", E.tInt(32), {privateWord(w)});
            std::string sh = E.op("OpBitwiseAnd", E.tInt(64), {addr, E.u64(3)});
            sh = toU32(E.op("OpShiftLeftLogical", E.tInt(64), {sh, E.u64(3)}));
            std::string v = E.op("OpShiftRightLogical", E.tInt(32), {word, sh});
            raw = E.op("OpUConvert", it, {v});
        }
    } else {
        fail("unsupported-feature", "memory access in address space " + std::to_string(as));
    }
    if (it == t) return raw;
    return E.op("OpBitcast", t, {raw});
}

void Translator::scalarStore(const std::string &addr, unsigned as, Type *T, const std::string &v, uint64_t align) {
    std::string t = type(T);
    if (T->isIntegerTy(1)) {
        std::string b = E.op("OpSelect", E.tInt(8), {v, E.constant(E.tInt(8), "1"), E.constant(E.tInt(8), "0")});
        scalarStore(addr, as, Type::getInt8Ty(T->getContext()), b, align);
        return;
    }
    unsigned bits = bitsOf(T);
    if (as == kDevice || as == kConstant) {
        std::string p = psbPointer(addr, t, bits);
        E.body << "OpStore " << p << " " << v << " Aligned " << std::min<uint64_t>(align, 65536) << "\n";
        return;
    }
    std::string it = E.tInt(bits);
    std::string raw = it == t ? v : E.op("OpBitcast", it, {v});
    if (as == kImageblock && hasImageblock) as = kThreadgroup;
    if (as == kThreadgroup) {
        E.stmt("OpStore " + workgroupElement(addr, bits) + " " + raw);
        return;
    }
    if (as != kPrivate) fail("unsupported-feature", "memory access in address space " + std::to_string(as));
    std::string w = E.op("OpShiftRightLogical", E.tInt(64), {addr, E.u64(2)});
    if (bits == 32) {
        E.stmt("OpStore " + privateWord(w) + " " + raw);
    } else if (bits == 64) {
        std::string lo = E.op("OpUConvert", E.tInt(32), {raw});
        std::string hi = E.op("OpUConvert", E.tInt(32), {E.op("OpShiftRightLogical", it, {raw, E.u64(32)})});
        E.stmt("OpStore " + privateWord(w) + " " + lo);
        E.stmt("OpStore " + privateWord(addConst(w, 1)) + " " + hi);
    } else {
        std::string p = privateWord(w);
        std::string word = E.op("OpLoad", E.tInt(32), {p});
        std::string sh = E.op("OpBitwiseAnd", E.tInt(64), {addr, E.u64(3)});
        sh = toU32(E.op("OpShiftLeftLogical", E.tInt(64), {sh, E.u64(3)}));
        std::string mask = E.op("OpShiftLeftLogical", E.tInt(32), {E.u32(bits == 8 ? 0xFF : 0xFFFF), sh});
        std::string keep = E.op("OpBitwiseAnd", E.tInt(32), {word, E.op("OpNot", E.tInt(32), {mask})});
        std::string nv = E.op("OpShiftLeftLogical", E.tInt(32), {E.op("OpUConvert", E.tInt(32), {raw}), sh});
        E.stmt("OpStore " + p + " " + E.op("OpBitwiseOr", E.tInt(32), {keep, nv}));
    }
}

std::string Translator::load(const std::string &addr, unsigned as, Type *T, uint64_t align) {
    if (auto *S = dyn_cast<StructType>(T)) {
        const StructLayout *SL = DL.getStructLayout(S);
        std::vector<std::string> parts;
        for (unsigned i = 0; i < S->getNumElements(); i++) {
            uint64_t o = SL->getElementOffset(i);
            parts.push_back(load(addConst(addr, (int64_t)o), as, S->getElementType(i), commonAlignment(Align(align), o).value()));
        }
        return E.op("OpCompositeConstruct", type(T), parts);
    }
    if (auto *A = dyn_cast<ArrayType>(T)) {
        uint64_t sz = DL.getTypeAllocSize(A->getElementType());
        std::vector<std::string> parts;
        for (uint64_t i = 0; i < A->getNumElements(); i++)
            parts.push_back(load(addConst(addr, (int64_t)(i * sz)), as, A->getElementType(), commonAlignment(Align(align), i * sz).value()));
        return E.op("OpCompositeConstruct", type(T), parts);
    }
    if (auto *V = dyn_cast<FixedVectorType>(T)) {
        Type *el = V->getElementType();
        if ((as == kDevice || as == kConstant) && !el->isIntegerTy(1)) {
            if (experiment("psb")) return E.null(type(T));
            std::string p = psbPointer(addr, type(T), bitsOf(el));
            std::string r = E.fresh();
            E.body << r << " = OpLoad " << type(T) << " " << p << " Aligned " << std::min<uint64_t>(align, 65536) << "\n";
            return r;
        }
        if (el->isIntegerTy(1)) {
            // Booleans are bytes in memory.
            auto *BT = FixedVectorType::get(Type::getInt8Ty(T->getContext()), V->getNumElements());
            std::string b = load(addr, as, BT, align);
            return E.op("OpINotEqual", type(T), {b, E.null(type(BT))});
        }
        uint64_t sz = bitsOf(el) / 8;
        std::vector<std::string> parts;
        for (unsigned i = 0; i < V->getNumElements(); i++)
            parts.push_back(scalarLoad(addConst(addr, (int64_t)(i * sz)), as, el, commonAlignment(Align(align), i * sz).value()));
        return E.op("OpCompositeConstruct", type(T), parts);
    }
    return scalarLoad(addr, as, T, align);
}

void Translator::store(const std::string &addr, unsigned as, Type *T, const std::string &v, uint64_t align) {
    if (auto *S = dyn_cast<StructType>(T)) {
        const StructLayout *SL = DL.getStructLayout(S);
        for (unsigned i = 0; i < S->getNumElements(); i++) {
            uint64_t o = SL->getElementOffset(i);
            std::string e = E.op("OpCompositeExtract", type(S->getElementType(i)), {v, std::to_string(i)});
            store(addConst(addr, (int64_t)o), as, S->getElementType(i), e, commonAlignment(Align(align), o).value());
        }
        return;
    }
    if (auto *A = dyn_cast<ArrayType>(T)) {
        uint64_t sz = DL.getTypeAllocSize(A->getElementType());
        for (uint64_t i = 0; i < A->getNumElements(); i++) {
            std::string e = E.op("OpCompositeExtract", type(A->getElementType()), {v, std::to_string(i)});
            store(addConst(addr, (int64_t)(i * sz)), as, A->getElementType(), e, commonAlignment(Align(align), i * sz).value());
        }
        return;
    }
    if (auto *V = dyn_cast<FixedVectorType>(T)) {
        Type *el = V->getElementType();
        if ((as == kDevice || as == kConstant) && !el->isIntegerTy(1)) {
            std::string p = psbPointer(addr, type(T), bitsOf(el));
            E.body << "OpStore " << p << " " << v << " Aligned " << std::min<uint64_t>(align, 65536) << "\n";
            return;
        }
        if (el->isIntegerTy(1)) {
            auto *BT = FixedVectorType::get(Type::getInt8Ty(T->getContext()), V->getNumElements());
            std::string one = constant(ConstantInt::get(BT, 1)), zero = E.null(type(BT));
            store(addr, as, BT, E.op("OpSelect", type(BT), {v, one, zero}), align);
            return;
        }
        uint64_t sz = bitsOf(el) / 8;
        for (unsigned i = 0; i < V->getNumElements(); i++) {
            std::string e = E.op("OpCompositeExtract", type(el), {v, std::to_string(i)});
            scalarStore(addConst(addr, (int64_t)(i * sz)), as, el, e, commonAlignment(Align(align), i * sz).value());
        }
        return;
    }
    scalarStore(addr, as, T, v, align);
}

// Serializes a constant initializer into bytes with the data layout.
static void serialize(const DataLayout &DL, Constant *C, std::string &out, uint64_t at) {
    Type *T = C->getType();
    uint64_t size = DL.getTypeStoreSize(T);
    if (out.size() < at + DL.getTypeAllocSize(T)) out.resize(at + DL.getTypeAllocSize(T), '\0');
    if (isa<ConstantAggregateZero>(C) || isa<UndefValue>(C) || isa<ConstantPointerNull>(C)) return;
    if (auto *CI = dyn_cast<ConstantInt>(C)) {
        APInt v = CI->getValue();
        for (uint64_t i = 0; i < size; i++) out[at + i] = (char)v.extractBitsAsZExtValue(8, (unsigned)(i * 8) < v.getBitWidth() ? (unsigned)i * 8 : 0);
        if (v.getBitWidth() == 1) out[at] = CI->isOne() ? 1 : 0;
        return;
    }
    if (auto *CF = dyn_cast<ConstantFP>(C)) {
        APInt v = CF->getValueAPF().bitcastToAPInt();
        for (uint64_t i = 0; i < size; i++) out[at + i] = (char)v.extractBitsAsZExtValue(8, (unsigned)i * 8);
        return;
    }
    if (auto *S = dyn_cast<StructType>(T)) {
        const StructLayout *SL = DL.getStructLayout(S);
        for (unsigned i = 0; i < S->getNumElements(); i++) serialize(DL, C->getAggregateElement(i), out, at + SL->getElementOffset(i));
        return;
    }
    if (auto *A = dyn_cast<ArrayType>(T)) {
        uint64_t sz = DL.getTypeAllocSize(A->getElementType());
        for (uint64_t i = 0; i < A->getNumElements(); i++) serialize(DL, C->getAggregateElement((unsigned)i), out, at + i * sz);
        return;
    }
    if (auto *V = dyn_cast<FixedVectorType>(T)) {
        uint64_t sz = V->getElementType()->getPrimitiveSizeInBits() / 8;
        for (unsigned i = 0; i < V->getNumElements(); i++) serialize(DL, C->getAggregateElement(i), out, at + i * sz);
        return;
    }
    fail("unsupported-feature", "constant global initializer " + printValue(C));
}

void Translator::layoutMemory() {
    // Private memory: every alloca of every function gets a fixed offset in
    // one word arena (Metal functions do not recurse, so frames of
    // different functions never need to coexist twice).
    for (Function *G : allFunctions())
    for (BasicBlock &B : *G)
        for (Instruction &I : B)
            if (auto *A = dyn_cast<AllocaInst>(&I)) {
                auto *N = dyn_cast<ConstantInt>(A->getArraySize());
                if (!N) fail("unsupported-feature", "dynamic alloca");
                uint64_t align = std::max<uint64_t>(4, A->getAlign().value());
                uint64_t off = alignTo(privateBytes, align);
                allocaOffset[A] = off;
                privateBytes = off + DL.getTypeAllocSize(A->getAllocatedType()) * N->getZExtValue();
            }
    // Globals referenced by the functions.
    std::set<GlobalVariable *> used;
    for (Function *G : allFunctions())
    for (BasicBlock &B : *G)
        for (Instruction &I : B)
            for (Value *Op : I.operands())
                if (auto *G = dyn_cast<GlobalVariable>(Op)) used.insert(G);
    samplers = constexprSamplers(M);
    for (unsigned i = 0; i < samplers.size(); i++) constexprSamplerIndex[samplers[i].global] = i;
    for (auto &fc : functionConstants(M)) {
        if (fc.value) fconsts[fc.value] = fc;
        fconsts[fc.init] = fc;
    }
    for (GlobalVariable *G : used) {
        unsigned as = G->getAddressSpace();
        Type *VT = G->getValueType();
        if (as == kThreadgroup) {
            uint64_t align = std::max<uint64_t>(4, G->getAlign() ? G->getAlign()->value() : DL.getABITypeAlign(VT).value());
            uint64_t off = alignTo(wgStaticBytes, align);
            wgStaticOffset[G] = off;
            wgStaticBytes = off + DL.getTypeAllocSize(VT);
            continue;
        }
        if (constexprSamplerIndex.count(G) || fconsts.count(G)) continue;
        // Address-space-2 memory is read-only for shaders: an initialized
        // global the static initializer does not write is constant data.
        if ((as == kConstant || as == kDevice) && G->hasInitializer() && (G->isConstant() || as == kConstant)) {
            uint64_t align = std::max<uint64_t>(16, G->getAlign() ? G->getAlign()->value() : 16);
            uint64_t off = alignTo(constData.size(), align);
            constDataOffset[G] = off;
            serialize(DL, G->getInitializer(), constData, off);
            continue;
        }
        std::string why = std::string(" (") + (G->isConstant() ? "constant" : "mutable") +
                          (G->hasInitializer() ? (isa<UndefValue>(G->getInitializer()) ? ", undef initializer" : ", initialized") : ", external") +
                          ", " + printType(G->getValueType()) + (G->hasSection() ? ", section " + G->getSection().str() : "") + ")";
        fail("unsupported-feature", "global variable " + G->getName().str() + " in address space " + std::to_string(as) + why);
    }
}

uint64_t Translator::wgStaticBytesAligned() const { return std::max<uint64_t>(16, alignTo(wgStaticBytes, 16)); }

// ---------------------------------------------------------------------------
// Interface (sections 4.4 to 4.6)

std::string Translator::tableEntry(unsigned e) {
    auto it = tableLoads.find(e);
    if (it != tableLoads.end()) return it->second;
    std::string a = addConst(tableAddr, (int64_t)e * 8);
    std::string p = psbPointer(a, E.tInt(64), 64);
    std::string r = E.fresh();
    E.body << r << " = OpLoad " << E.tInt(64) << " " << p << " Aligned 8\n";
    return tableLoads[e] = r;
}

std::string Translator::ioVar(const std::string &storage, const std::string &t, const std::string &decoration) {
    // Built-in outputs that occur twice (members gated by different
    // function constants) share one variable.
    std::string key = "io|" + storage + "|" + t + "|" + decoration;
    if (decoration.rfind("BuiltIn ", 0) == 0 && E.memo.count(key)) return E.memo[key];
    std::string pt = E.tPtr(storage, t);
    std::string var = E.fresh();
    E.globals << var << " = OpVariable " << pt << " " << storage << "\n";
    if (!decoration.empty()) E.decorate(var, decoration);
    E.interface.push_back(var);
    if (decoration.rfind("BuiltIn ", 0) == 0) E.memo[key] = var;
    return var;
}

std::string Translator::builtin(const std::string &name, const std::string &t) {
    auto it = builtins.find(name);
    if (it != builtins.end()) return it->second;
    if (name.rfind("Subgroup", 0) == 0 || name == "NumSubgroups") E.caps.insert("GroupNonUniform");
    std::string var = ioVar("Input", t, "BuiltIn " + name);
    if (EI.stage == Stage::Fragment && t != E.tVec(E.tFloat(32), 4) && t != E.tBool() &&
        name != "SubgroupLocalInvocationId" && name != "SubgroupSize" && name != "SubgroupId" && name != "NumSubgroups")
        E.decorate(var, "Flat");
    return builtins[name] = var;
}

// Converts a built-in value (u32 scalar or vector of n) to the AIR argument type T.
std::string Translator::fitBuiltin(const std::string &v, const std::string &vType, unsigned n, Type *T) {
    (void)vType;
    unsigned want = 1;
    if (auto *VT = dyn_cast<FixedVectorType>(T)) want = VT->getNumElements();
    std::string r = v;
    std::string u32 = E.tInt(32);
    if (want != n) {
        if (want == 1) r = E.op("OpCompositeExtract", u32, {v, "0"});
        else {
            std::vector<std::string> a = {v, v};
            for (unsigned i = 0; i < want; i++) a.push_back(std::to_string(i));
            r = E.op("OpVectorShuffle", E.tVec(u32, want), a);
        }
    }
    unsigned bits = T->getScalarSizeInBits();
    if (bits != 32) r = E.op("OpUConvert", type(T), {r});
    return r;
}

// Stage I/O type: 8/16-bit values are widened to 32 bits (the Thor lacks
// storageInputOutput16); signedness follows the Metal type name.
struct IOType {
    std::string spv;      // SPIR-V type of the variable
    bool widened = false;
    bool isInt = false, isSigned = false;
};

static IOType ioTypeOf(Translator &X, Type *T, const std::string &metalType) {
    IOType r;
    Type *S = T->getScalarType();
    unsigned n = T->isVectorTy() ? cast<FixedVectorType>(T)->getNumElements() : 1;
    if (S->isIntegerTy(1)) fail("unsupported-feature", "boolean stage I/O");
    if (S->isIntegerTy()) {
        r.isInt = true;
        r.isSigned = isSignedTypeName(metalType);
        r.widened = S->getIntegerBitWidth() != 32;
        if (S->getIntegerBitWidth() == 64) fail("unsupported-type", "64-bit stage I/O");
        r.spv = X.E.tVec(r.isSigned ? X.E.tSInt(32) : X.E.tInt(32), n);
    } else if (S->isHalfTy() || S->isFloatTy()) {
        r.widened = S->isHalfTy();
        r.spv = X.E.tVec(X.E.tFloat(32), n);
    } else if (auto *A = dyn_cast<ArrayType>(T)) {
        (void)A;
        fail("unsupported-type", "array stage I/O " + printType(T));
    } else {
        fail("unsupported-type", "stage I/O " + printType(T));
    }
    return r;
}

// Reads an input variable and converts it to the AIR type.
static std::string readIO(Translator &X, const std::string &var, const IOType &io, Type *T) {
    std::string v = X.E.op("OpLoad", io.spv, {var});
    std::string t = X.type(T);
    if (io.isInt) {
        std::string u = v;
        if (io.isSigned) u = X.E.op("OpBitcast", X.E.tVec(X.E.tInt(32), T->isVectorTy() ? cast<FixedVectorType>(T)->getNumElements() : 1), {v});
        if (!io.widened) return u;
        return X.E.op("OpUConvert", t, {u});
    }
    if (io.widened) return X.E.op("OpFConvert", t, {v});
    return v;
}

static std::string writeIOValue(Translator &X, const std::string &v, const IOType &io, Type *T) {
    unsigned n = T->isVectorTy() ? cast<FixedVectorType>(T)->getNumElements() : 1;
    if (io.isInt) {
        std::string u = v;
        if (io.widened) u = X.E.op(io.isSigned ? "OpSConvert" : "OpUConvert", X.E.tVec(X.E.tInt(32), n), {v});
        if (io.isSigned) u = X.E.op("OpBitcast", io.spv, {u});
        return u;
    }
    if (io.widened) return X.E.op("OpFConvert", io.spv, {v});
    return v;
}

void Translator::setupInterface() {
    std::string u32 = E.tInt(32), u64 = E.tInt(64), v3 = E.tVec(u32, 3);
    // Push constants (abi.h).
    std::string pcT = E.global("pcblock", "OpTypeStruct " + u64 + " " + u64 + " " + v3 + " " + u32);
    E.decorate(pcT, "Block");
    E.memberDecorate(pcT, 0, "Offset " + std::to_string(abi::kPushTableVertexOrKernel));
    E.memberDecorate(pcT, 1, "Offset " + std::to_string(abi::kPushTableFragment));
    E.memberDecorate(pcT, 2, "Offset " + std::to_string(abi::kPushGrid));
    E.memberDecorate(pcT, 3, "Offset 28");
    std::string pcPtr = E.tPtr("PushConstant", pcT);
    pcVar = E.fresh();
    E.globals << pcVar << " = OpVariable " << pcPtr << " PushConstant\n";
    E.interface.push_back(pcVar);
    if (EI.stage == Stage::Kernel) {
        specX = E.fresh(); specY = E.fresh(); specZ = E.fresh();
        E.globals << specX << " = OpSpecConstant " << u32 << " 1\n"
                  << specY << " = OpSpecConstant " << u32 << " 1\n"
                  << specZ << " = OpSpecConstant " << u32 << " 1\n";
        E.decorate(specX, "SpecId " + std::to_string(abi::kSpecWorkgroupX));
        E.decorate(specY, "SpecId " + std::to_string(abi::kSpecWorkgroupY));
        E.decorate(specZ, "SpecId " + std::to_string(abi::kSpecWorkgroupZ));
        wgSizeId = E.fresh();
        E.globals << wgSizeId << " = OpSpecConstantComposite " << v3 << " " << specX << " " << specY << " " << specZ << "\n";
    }
    // Outputs: the members of the return value, in order.
    Type *RT = F.getReturnType();
    if (RT->isVoidTy()) return;
    for (unsigned i = 0; i < EI.outputs.size(); i++) {
        const AirNode &o = EI.outputs[i];
        Type *T = RT->isStructTy() ? RT->getStructElementType(i) : RT;
        Output out;
        out.type = T;
        std::string name = o.argName().empty() ? o.kind : o.argName();
        if (o.kind == "air.position") {
            out.ioType = E.tVec(E.tFloat(32), 4);
            out.var = ioVar("Output", out.ioType, "BuiltIn Position");
            if (o.has("air.invariant")) E.decorate(out.var, "Invariant");
            jBuiltins.push("position");
        } else if (o.kind == "air.point_size") {
            out.ioType = E.tFloat(32);
            out.var = ioVar("Output", out.ioType, "BuiltIn PointSize");
            jBuiltins.push("point_size");
        } else if (o.kind == "air.clip_distance") {
            E.caps.insert("ClipDistance");
            out.ioType = type(T);
            if (!T->isArrayTy()) {
                out.ioType = E.global("arr" + E.tFloat(32) + "_1", "OpTypeArray " + E.tFloat(32) + " " + E.u32(1));
            }
            out.var = ioVar("Output", out.ioType, "BuiltIn ClipDistance");
            jBuiltins.push("clip_distance");
        } else if (o.kind == "air.render_target_array_index") {
            E.caps.insert("ShaderLayer");
            out.ioType = E.tInt(32);
            out.var = ioVar("Output", out.ioType, "BuiltIn Layer");
            jBuiltins.push("render_target_array_index");
        } else if (o.kind == "air.viewport_array_index") {
            jBuiltins.push("viewport_array_index");
            // Ycode's render passes have one viewport and one scissor (the
            // host keeps the first of a setViewports: array), so every
            // primitive uses viewport 0: the output is not written. An index
            // of 1 or more would select a Vulkan viewport and scissor that
            // were never set; with the stereo pipelines of visionOS (an
            // instance per eye, the index from the instance) that hung the
            // Thor's GPU (visionos.md section 10.13). AIRC_VIEWPORT_INDEX=1
            // writes it as before (experiments).
            static const bool keep = getenv("AIRC_VIEWPORT_INDEX") && std::string(getenv("AIRC_VIEWPORT_INDEX")) == "1";
            if (!keep) {
                out.ioType = "";
                out.var = "";
                uses.insert("viewport_index_dropped");
                outputs.push_back(out);
                continue;
            }
            E.caps.insert("ShaderViewportIndex");
            out.ioType = E.tInt(32);
            out.var = ioVar("Output", out.ioType, "BuiltIn ViewportIndex");
        } else if (o.kind == "air.vertex_output") {
            IOType io = ioTypeOf(*this, T, o.typeName());
            unsigned loc = (unsigned)jVaryings.arr.size();
            out.ioType = io.spv;
            out.var = ioVar("Output", io.spv, "Location " + std::to_string(loc));
            Json j = Json::object();
            j.set("name", o.ident);
            j.set("location", loc);
            j.set("type", o.typeName());
            j.set("widened", io.widened);
            jVaryings.push(j);
        } else if (o.kind == "air.render_target") {
            IOType io = ioTypeOf(*this, T, o.typeName());
            int loc = o.location();
            int index = (int)o.intAt("air.render_target", 1, 0);
            if (loc < 0 || index < 0) fail("unsupported-feature", "render target index set by a function constant (needs the specialized function)");
            out.ioType = io.spv;
            out.var = ioVar("Output", io.spv, "Location " + std::to_string(loc));
            if (index) E.decorate(out.var, "Index " + std::to_string(index));
            Json j = Json::object();
            j.set("index", loc);
            j.set("dual_source_index", index);
            j.set("type", o.typeName());
            j.set("widened", io.widened);
            if (!o.fcPredicate.empty()) j.set("function_constant", o.fcPredicate);
            jRenderTargets.push(j);
        } else if (o.kind == "air.depth") {
            out.ioType = E.tFloat(32);
            out.var = ioVar("Output", out.ioType, "BuiltIn FragDepth");
            uses.insert(o.has("air.greater") ? "depth_greater" : o.has("air.less") ? "depth_less" : "depth_any");
            jBuiltins.push("depth");
        } else if (o.kind == "air.sample_mask") {
            out.ioType = E.global("arr" + E.tInt(32) + "_1", "OpTypeArray " + E.tInt(32) + " " + E.u32(1));
            out.var = ioVar("Output", out.ioType, "BuiltIn SampleMask");
            jBuiltins.push("sample_mask");
        } else if (o.kind == "air.stencil") {
            E.caps.insert("StencilExportEXT");
            E.exts.insert("SPV_EXT_shader_stencil_export");
            out.ioType = E.tSInt(32);
            out.var = ioVar("Output", out.ioType, "BuiltIn FragStencilRefEXT");
            jBuiltins.push("stencil");
        } else if (o.kind == "air.imageblock_data" && EI.stage == Stage::Fragment) {
            // A fragment function's explicit imageblock result goes to tile
            // memory, which only tile functions and later imageblock reads
            // of the same pass see. Ycode has neither in render passes
            // (metal-shaders.md section 4.9), so the value has no reader:
            // it is not written anywhere (no Vulkan output); the function's
            // other outputs and side effects are kept.
            out.ioType = "";
            out.var = "";
            uses.insert("imageblock_output_dropped");
        } else {
            fail("unsupported-feature", "output kind " + o.kind);
        }
        outputs.push_back(out);
    }
}

void Translator::prologue() {
    std::string u32 = E.tInt(32), u64 = E.tInt(64), v3 = E.tVec(u32, 3);
    // This stage's argument table address.
    loadTableAddr();
    // Threadgroup memory size and slots (kernels).
    std::string wgBase;
    for (auto &a : EI.args)
        if ((a.second.kind == "air.buffer") && a.second.intAt("air.address_space", 0, 1) == kThreadgroup) {
            wgDynamic = true;
            wgSlots.push_back((unsigned)a.second.location());
        }
    for (auto &a : EI.args) {
        if (a.second.kind != "air.imageblock") continue;
        if (EI.stage != Stage::Kernel) fail("unsupported-feature", "imageblock in a tile or fragment function");
        const AirNode &n = a.second;
        hasImageblock = true;
        // Field offsets and pixel size from air.struct_type_info (offset,
        // size, count, type name, member name per field).
        uint64_t end = 0;
        for (auto &kv : n.keys)
            if (kv.first == "air.struct_type_info" && !kv.second.empty())
                if (auto *S = dyn_cast_or_null<MDNode>(kv.second[0]))
                    for (unsigned i = 0; i + 4 < S->getNumOperands(); i++) {
                        auto *o = mdconst::dyn_extract_or_null<ConstantInt>(S->getOperand(i));
                        auto *z = mdconst::dyn_extract_or_null<ConstantInt>(S->getOperand(i + 1));
                        auto *c = mdconst::dyn_extract_or_null<ConstantInt>(S->getOperand(i + 2));
                        if (!o || !z || !c || !isa<MDString>(S->getOperand(i + 3)) || !isa<MDString>(S->getOperand(i + 4))) continue;
                        ibFieldOffsets.push_back(o->getZExtValue());
                        end = std::max<uint64_t>(end, o->getZExtValue() + z->getZExtValue() * std::max<uint64_t>(1, c->getZExtValue()));
                        i += 4;
                    }
        int64_t ds = n.intAt("air.imageblock_data_size", 0, -1);
        ibStride = ds > 0 ? (uint64_t)ds : alignTo(std::max<uint64_t>(end, 4), 4);
        uses.insert("imageblock");
    }
    if (wgDynamic) {
        uint64_t base = wgStaticBytesAligned();
        wgBytesId = E.fresh();
        E.globals << wgBytesId << " = OpSpecConstant " << u32 << " " << base + 16 * wgSlots.size() << "\n";
        E.decorate(wgBytesId, "SpecId " + std::to_string(abi::kSpecThreadgroupBytes));
    } else if (hasImageblock) {
        // Size = imageblock base + threadgroup width * height * pixel size.
        wgDynamic = true;
        std::string xy = E.global("ibxy", "OpSpecConstantOp " + u32 + " IMul " + specX + " " + specY);
        std::string st = E.u32(ibStride), base = E.u32(imageblockBase());
        std::string sz = E.global("ibsize", "OpSpecConstantOp " + u32 + " IMul " + xy + " " + st);
        wgBytesId = E.global("ibtotal", "OpSpecConstantOp " + u32 + " IAdd " + sz + " " + base);
    }
    for (Argument &A : F.args()) {
        auto it = EI.args.find(A.getArgNo());
        if (it == EI.args.end()) fail("internal", "argument " + std::to_string(A.getArgNo()) + " without AIR metadata");
        const AirNode &n = it->second;
        const std::string &k = n.kind;
        bool used = !A.use_empty();
        int loc = n.location();
        bool dynamicIndex = n.locationGlobal() != nullptr;
        int count = n.count();
        std::string r;
        Type *T = A.getType();
        if (k == "air.buffer" || k == "air.indirect_buffer") {
            int as = (int)n.intAt("air.address_space", 0, 1);
            if (as == kThreadgroup) {
                std::string spec = E.fresh();
                unsigned idx = (unsigned)(std::find(wgSlots.begin(), wgSlots.end(), (unsigned)loc) - wgSlots.begin());
                E.globals << spec << " = OpSpecConstant " << u32 << " " << wgStaticBytesAligned() + 16 * idx << "\n";
                E.decorate(spec, "SpecId " + std::to_string(abi::kSpecThreadgroupSlot0 + loc));
                Json j = Json::object();
                j.set("index", loc);
                j.set("offset_spec_id", abi::kSpecThreadgroupSlot0 + loc);
                j.set("type", n.typeName());
                j.set("used", used);
                jThreadgroup.push(j);
                if (used) r = E.op("OpUConvert", u64, {spec});
            } else if (dynamicIndex || A.hasByValAttr()) {
                Json j = Json::object();
                j.set("index", loc);
                if (dynamicIndex) j.set("index_function_constant", true);
                j.set("count", count);
                j.set("kind", k.substr(4));
                j.set("address_space", as == kConstant ? "constant" : "device");
                j.set("type", n.typeName());
                j.set("name", n.argName());
                jBuffers.push(j);
                continue;
            } else {
                if (loc < 0 || loc >= (int)abi::kMaxBuffers) fail("unsupported-feature", "buffer index " + std::to_string(loc));
                Json j = Json::object();
                j.set("index", loc);
                j.set("table_entry", abi::kTableBuffer0 + loc);
                j.set("kind", k.substr(4));
                j.set("address_space", as == kConstant ? "constant" : "device");
                j.set("access", n.access());
                j.set("type", n.typeName());
                if (n.intAt("air.buffer_size", 0, -1) >= 0) j.set("size", (long long)n.intAt("air.buffer_size"));
                j.set("name", n.argName());
                j.set("used", used);
                if (!n.fcPredicate.empty()) j.set("function_constant", n.fcPredicate);
                jBuffers.push(j);
                if (used) r = tableEntry(abi::kTableBuffer0 + loc);
            }
        } else if (k == "air.texture") {
            if (dynamicIndex || A.hasByValAttr()) {
                Json j = Json::object();
                j.set("index", loc);
                if (dynamicIndex) j.set("index_function_constant", true);
                j.set("count", count);
                j.set("type", n.typeName());
                j.set("access", n.access());
                j.set("name", n.argName());
                j.set("used", true);
                jTextures.push(j);
                if (used) fail("internal", "dynamic texture argument still used");
                continue;
            }
            if (loc < 0 || loc >= (int)abi::kMaxTextures) {
                std::string keys;
                for (auto &kv : n.keys) keys += " " + kv.first;
                fail("unsupported-feature", "texture index " + std::to_string(loc) + " (" + n.typeName() + ";" + keys + ")");
            }
            Json j = Json::object();
            j.set("index", loc);
            j.set("table_entry", abi::kTableTexture0 + loc);
            j.set("type", n.typeName());
            j.set("access", n.access());
            j.set("name", n.argName());
            j.set("used", used);
            jTextures.push(j);
            if (used) r = tableEntry(abi::kTableTexture0 + loc);
        } else if (k == "air.sampler") {
            if (dynamicIndex || A.hasByValAttr()) {
                Json j = Json::object();
                j.set("index", loc);
                if (dynamicIndex) j.set("index_function_constant", true);
                j.set("count", count);
                j.set("name", n.argName());
                jSamplers.push(j);
                continue;
            }
            if (loc < 0 || loc >= (int)abi::kMaxSamplers) fail("unsupported-feature", "sampler index " + std::to_string(loc));
            Json j = Json::object();
            j.set("index", loc);
            j.set("table_entry", abi::kTableSampler0 + loc);
            j.set("name", n.argName());
            j.set("used", used);
            jSamplers.push(j);
            if (used) r = tableEntry(abi::kTableSampler0 + loc);
        } else if (k == "air.vertex_input" && dynamicIndex) {
            fail("unsupported-feature", "vertex attribute index set by a function constant (needs the specialized function)");
        } else if (k == "air.vertex_input" && !used && !getenv("AIRC_UNUSED_VERTEX_INPUTS")) {
            // A stage-in attribute the function never reads gets no input
            // variable: the pipeline's vertex descriptor need not describe
            // it (Metal's does not), and a Vulkan vertex shader input with
            // no vertex attribute behind it is undefined (visionOS
            // RealityKit's vsUnlit declares 15 and reads 2; visionos.md
            // §10.13). AIRC_UNUSED_VERTEX_INPUTS=1 declares them as before.
            Json j = Json::object();
            j.set("location", loc);
            j.set("type", n.typeName());
            j.set("name", n.argName());
            j.set("used", false);
            j.set("declared", false);
            jVertexInputs.push(j);
            continue;
        } else if (k == "air.vertex_input") {
            IOType io = ioTypeOf(*this, T, n.typeName());
            if (loc < 0) fail("unsupported-feature", "vertex attribute index " + std::to_string(loc));
            std::string var = ioVar("Input", io.spv, "Location " + std::to_string(loc));
            Json j = Json::object();
            j.set("location", loc);
            j.set("type", n.typeName());
            j.set("name", n.argName());
            j.set("widened", io.widened);
            j.set("used", used);
            jVertexInputs.push(j);
            r = readIO(*this, var, io, T);
        } else if (k == "air.fragment_input" && opts.haveVaryings && !used && !opts.varyings.count(n.ident)) {
            // An input the function never reads and the linked vertex
            // function does not write: no interface variable (Vulkan would
            // reject an input without a matching output); the argument has
            // no uses, so its value is irrelevant (metal-shaders.md 4.5).
            Json j = Json::object();
            j.set("name", n.ident);
            j.set("type", n.typeName());
            j.set("used", false);
            j.set("linked", false);
            jVaryings.push(j);
            continue;
        } else if (k == "air.fragment_input" && n.has("air.interpolation_function")) {
            // interpolant<T, ...>: the shader interpolates explicitly.
            std::string tn = n.typeName();
            Interpolant ip;
            ip.half = tn.rfind("half", 0) == 0;
            if (!(tn.rfind("float", 0) == 0 || ip.half)) fail("unsupported-type", "interpolant of " + tn);
            char last = tn.empty() ? '1' : tn.back();
            ip.n = (last >= '2' && last <= '4') ? (unsigned)(last - '0') : 1;
            ip.ioType = E.tVec(E.tFloat(32), ip.n);
            unsigned l;
            if (opts.haveVaryings) {
                auto v = opts.varyings.find(n.ident);
                if (v == opts.varyings.end()) fail("bad-request", "fragment input " + n.ident + " is not an output of the linked vertex function");
                l = v->second;
                linked = true;
            } else {
                l = nextFragmentLocation++;
            }
            ip.var = ioVar("Input", ip.ioType, "Location " + std::to_string(l));
            if (n.has("air.no_perspective")) E.decorate(ip.var, "NoPerspective");
            E.caps.insert("InterpolationFunction");
            interpolants[&A] = ip;
            Json j = Json::object();
            j.set("name", n.ident);
            j.set("location", l);
            j.set("type", tn);
            j.set("interpolation", n.has("air.no_perspective") ? "no_perspective" : "perspective");
            j.set("sampling", "interpolant");
            j.set("widened", ip.half);
            j.set("used", used);
            jVaryings.push(j);
            r = E.u64(0);
        } else if (k == "air.fragment_input") {
            IOType io = ioTypeOf(*this, T, n.typeName());
            unsigned l;
            if (opts.haveVaryings) {
                auto v = opts.varyings.find(n.ident);
                if (v == opts.varyings.end()) fail("bad-request", "fragment input " + n.ident + " is not an output of the linked vertex function");
                l = v->second;
                linked = true;
            } else {
                l = nextFragmentLocation++;
            }
            std::string var = ioVar("Input", io.spv, "Location " + std::to_string(l));
            std::string interp = "perspective", sampling = "center";
            if (n.has("air.flat") || io.isInt) { E.decorate(var, "Flat"); interp = "flat"; }
            else if (n.has("air.no_perspective")) { E.decorate(var, "NoPerspective"); interp = "no_perspective"; }
            if (n.has("air.centroid")) { E.decorate(var, "Centroid"); sampling = "centroid"; }
            if (n.has("air.sample")) { E.decorate(var, "Sample"); E.caps.insert("SampleRateShading"); sampling = "sample"; }
            Json j = Json::object();
            j.set("name", n.ident);
            j.set("location", l);
            j.set("type", n.typeName());
            j.set("interpolation", interp);
            j.set("sampling", sampling);
            j.set("widened", io.widened);
            j.set("used", used);
            jVaryings.push(j);
            r = readIO(*this, var, io, T);
        } else if (k == "air.position" && EI.stage == Stage::Fragment) {
            r = E.op("OpLoad", E.tVec(E.tFloat(32), 4), {builtin("FragCoord", E.tVec(E.tFloat(32), 4))});
            if (T->getScalarType()->isHalfTy()) r = E.op("OpFConvert", type(T), {r});
            jBuiltins.push("position");
        } else if (k == "air.imageblock_data" && EI.stage == Stage::Fragment && !T->isPointerTy()) {
            // The pixel's explicit imageblock as a fragment input. Ycode keeps
            // no tile memory between draws (fragment imageblock results are
            // dropped, see the outputs), so the value read is all zeros.
            if (used) r = E.null(type(T));
            uses.insert("imageblock_input_zero");
        } else if (k == "air.imageblock") {
            r = E.u64(0);  // accessed through the imageblock intrinsics only
            uses.insert(n.intAt("air.imageblock_data_size", 0, -1) > 0 ? "imageblock_explicit" : "imageblock_implicit");
        } else if (k == "air.render_target") {
            // Programmable blending: the current colour of attachment `loc`
            // through an input attachment (abi.h).
            if (EI.stage != Stage::Fragment) fail("unsupported-feature", "render target input outside a fragment function");
            E.caps.insert("InputAttachment");
            char st = 'f';
            Type *S = T->getScalarType();
            if (S->isIntegerTy()) st = isSignedTypeName(n.typeName()) ? 'i' : 'u';
            std::string sampled = st == 'f' ? E.tFloat(32) : st == 'i' ? E.tSInt(32) : E.tInt(32);
            std::string it = E.global(std::string("subpass") + st, "OpTypeImage " + sampled + " SubpassData 0 0 0 2 Unknown");
            std::string pt = E.tPtr("UniformConstant", it);
            std::string var = E.fresh();
            E.globals << var << " = OpVariable " << pt << " UniformConstant\n";
            E.decorate(var, "DescriptorSet " + std::to_string(abi::kInputAttachmentSet));
            E.decorate(var, "Binding " + std::to_string(loc));
            E.decorate(var, "InputAttachmentIndex " + std::to_string(loc));
            E.interface.push_back(var);
            std::string img = E.op("OpLoad", it, {var});
            std::string zero2 = E.null(E.tVec(E.tSInt(32), 2));
            std::string v4 = E.op("OpImageRead", E.tVec(sampled, 4), {img, zero2});
            if (st == 'i') v4 = E.op("OpBitcast", E.tVec(E.tInt(32), 4), {v4});
            unsigned cnt = T->isVectorTy() ? cast<FixedVectorType>(T)->getNumElements() : 1;
            std::string et = st == 'f' ? E.tFloat(32) : E.tInt(32);
            if (cnt == 1) r = E.op("OpCompositeExtract", et, {v4, "0"});
            else if (cnt == 4) r = v4;
            else {
                std::vector<std::string> a = {v4, v4};
                for (unsigned c = 0; c < cnt; c++) a.push_back(std::to_string(c));
                r = E.op("OpVectorShuffle", E.tVec(et, cnt), a);
            }
            if (S->isHalfTy()) r = E.op("OpFConvert", type(T), {r});
            else if (S->isIntegerTy() && S->getIntegerBitWidth() != 32) r = E.op("OpUConvert", type(T), {r});
            Json j = Json::object();
            j.set("index", loc);
            j.set("set", abi::kInputAttachmentSet);
            j.set("binding", loc);
            j.set("type", n.typeName());
            jInputAttachments.push(j);
            uses.insert("framebuffer_fetch");
        } else {
            // Scalar and vector built-ins.
            static const std::map<std::string, std::pair<std::string, unsigned>> table = {
                {"air.thread_position_in_grid", {"GlobalInvocationId", 3}},
                {"air.thread_position_in_threadgroup", {"LocalInvocationId", 3}},
                {"air.threadgroup_position_in_grid", {"WorkgroupId", 3}},
                {"air.threadgroups_per_grid", {"NumWorkgroups", 3}},
                {"air.thread_index_in_threadgroup", {"LocalInvocationIndex", 1}},
                {"air.thread_index_in_simdgroup", {"SubgroupLocalInvocationId", 1}},
                {"air.simdgroup_index_in_threadgroup", {"SubgroupId", 1}},
                {"air.threads_per_simdgroup", {"SubgroupSize", 1}},
                {"air.simdgroups_per_threadgroup", {"NumSubgroups", 1}},
                {"air.vertex_id", {"VertexIndex", 1}},
                {"air.instance_id", {"InstanceIndex", 1}},
                {"air.sample_id", {"SampleId", 1}},
                {"air.primitive_id", {"PrimitiveId", 1}},
                {"air.render_target_array_index", {"Layer", 1}},
                {"air.viewport_array_index", {"ViewportIndex", 1}},
                {"air.amplification_id", {"ViewIndex", 1}},
            };
            auto b = table.find(k);
            if (k == "air.threads_per_grid") {
                std::string p = E.op("OpAccessChain", E.tPtr("PushConstant", v3), {pcVar, E.u32(2)});
                if (used) r = fitBuiltin(E.op("OpLoad", v3, {p}), v3, 3, T);
            } else if (k == "air.threads_per_threadgroup") {
                if (used) r = fitBuiltin(wgSizeId, v3, 3, T);
            } else if (k == "air.dispatch_threads_per_threadgroup") {
                // Edge threadgroups of a non-uniform grid are smaller.
                if (used) {
                    std::string p = E.op("OpAccessChain", E.tPtr("PushConstant", v3), {pcVar, E.u32(2)});
                    std::string grid = E.op("OpLoad", v3, {p});
                    std::string wg = E.op("OpLoad", v3, {builtin("WorkgroupId", v3)});
                    std::string start = E.op("OpIMul", v3, {wg, wgSizeId});
                    std::string left = E.op("OpISub", v3, {grid, start});
                    r = fitBuiltin(E.ext(v3, "UMin", {left, wgSizeId}), v3, 3, T);
                }
            } else if (k == "air.thread_index_in_quadgroup" || k == "air.quadgroup_index_in_threadgroup") {
                if (used) {
                    std::string v = k == "air.thread_index_in_quadgroup"
                                        ? E.op("OpBitwiseAnd", u32, {E.op("OpLoad", u32, {builtin("SubgroupLocalInvocationId", u32)}), E.u32(3)})
                                        : E.op("OpShiftRightLogical", u32, {E.op("OpLoad", u32, {builtin("LocalInvocationIndex", u32)}), E.u32(2)});
                    r = fitBuiltin(v, u32, 1, T);
                }
            } else if (k == "air.front_facing") {
                r = E.op("OpLoad", E.tBool(), {builtin("FrontFacing", E.tBool())});
                // A `bool` argument may arrive widened (i8: RenderBox's
                // path_interior fragments): 1 or 0 of that width.
                if (T->isIntegerTy() && !T->isIntegerTy(1)) {
                    std::string it = type(T);
                    r = E.op("OpSelect", it, {r, E.constant(it, "1"), E.null(it)});
                } else if (!T->isIntegerTy(1)) {
                    fail("unsupported-type", "front_facing of type " + printType(T));
                }
            } else if (k == "air.point_coord") {
                r = E.op("OpLoad", E.tVec(E.tFloat(32), 2), {builtin("PointCoord", E.tVec(E.tFloat(32), 2))});
                if (T->getScalarType()->isHalfTy()) r = E.op("OpFConvert", type(T), {r});
            } else if (k == "air.sample_mask_in") {
                std::string at = E.global("arr" + u32 + "_1", "OpTypeArray " + u32 + " " + E.u32(1));
                std::string var = builtin("SampleMask", at);
                E.decorate(var, "Flat");
                std::string p = E.op("OpAccessChain", E.tPtr("Input", u32), {var, E.u32(0)});
                r = fitBuiltin(E.op("OpLoad", u32, {p}), u32, 1, T);
            } else if (k == "air.barycentric_coord") {
                E.caps.insert("FragmentBarycentricKHR");
                E.exts.insert("SPV_KHR_fragment_shader_barycentric");
                std::string v3f = E.tVec(E.tFloat(32), 3);
                r = E.op("OpLoad", v3f, {builtin(n.has("air.no_perspective") ? "BaryCoordNoPerspKHR" : "BaryCoordKHR", v3f)});
                if (T->getScalarType()->isHalfTy()) r = E.op("OpFConvert", type(T), {r});
                if (!T->isVectorTy() || cast<FixedVectorType>(T)->getNumElements() != 3) fail("unsupported-type", "barycentric_coord " + printType(T));
            } else if (b != table.end()) {
                if (b->second.first == "PrimitiveId") E.caps.insert("Geometry");
                if (b->second.first == "Layer") E.caps.insert("Geometry");
                if (b->second.first == "ViewportIndex") E.caps.insert("MultiViewport");
                if (b->second.first == "ViewIndex") E.caps.insert("MultiView");
                if (b->second.first == "SampleId") E.caps.insert("SampleRateShading");
                std::string bt = b->second.second == 3 ? v3 : u32;
                if (used) r = fitBuiltin(E.op("OpLoad", bt, {builtin(b->second.first, bt)}), bt, b->second.second, T);
            } else {
                fail("unsupported-feature", "argument kind " + k);
            }
            jBuiltins.push(k.substr(4));
        }
        if (used) {
            if (r.empty()) fail("internal", "no value for argument kind " + k);
            vals[&A] = r;
        }
    }
    // Global addresses.
    globalAddresses(F);
}

// ---------------------------------------------------------------------------
// Instructions

void Translator::instruction(Instruction &I) {
    Type *RT = I.getType();
    std::string t = RT->isVoidTy() ? "" : type(RT);
    if (auto *B = dyn_cast<BinaryOperator>(&I)) {
        bool isBool = RT->isIntOrIntVectorTy(1);
        const char *op = nullptr;
        switch (B->getOpcode()) {
        case Instruction::Add: op = isBool ? "OpLogicalNotEqual" : "OpIAdd"; break;
        case Instruction::Sub: op = isBool ? "OpLogicalNotEqual" : "OpISub"; break;
        case Instruction::Mul: op = isBool ? "OpLogicalAnd" : "OpIMul"; break;
        case Instruction::UDiv: op = "OpUDiv"; break;
        case Instruction::SDiv: op = "OpSDiv"; break;
        case Instruction::URem: op = "OpUMod"; break;
        case Instruction::SRem: op = "OpSRem"; break;
        case Instruction::Shl: op = "OpShiftLeftLogical"; break;
        case Instruction::LShr: op = "OpShiftRightLogical"; break;
        case Instruction::AShr: op = "OpShiftRightArithmetic"; break;
        case Instruction::And: op = isBool ? "OpLogicalAnd" : "OpBitwiseAnd"; break;
        case Instruction::Or: op = isBool ? "OpLogicalOr" : "OpBitwiseOr"; break;
        case Instruction::Xor: op = isBool ? "OpLogicalNotEqual" : "OpBitwiseXor"; break;
        case Instruction::FAdd: op = "OpFAdd"; break;
        case Instruction::FSub: op = "OpFSub"; break;
        case Instruction::FMul: op = "OpFMul"; break;
        case Instruction::FDiv: op = "OpFDiv"; break;
        case Instruction::FRem: op = "OpFRem"; break;
        default: fail("unsupported-instruction", B->getOpcodeName());
        }
        if (isBool && (B->getOpcode() == Instruction::UDiv || B->getOpcode() == Instruction::Shl))
            fail("unsupported-instruction", std::string("boolean ") + B->getOpcodeName());
        if (B->getOpcode() == Instruction::SDiv || B->getOpcode() == Instruction::SRem) {
            // Use signed integer types: the Thor's driver takes OpSRem's
            // signedness from the type (observed: -500 % 7 gave 1).
            unsigned n = RT->isVectorTy() ? cast<FixedVectorType>(RT)->getNumElements() : 1;
            std::string st = E.tVec(E.tSInt(RT->getScalarSizeInBits()), n);
            std::string a = E.op("OpBitcast", st, {val(I.getOperand(0))}), b = E.op("OpBitcast", st, {val(I.getOperand(1))});
            std::string r;
            if (B->getOpcode() == Instruction::SDiv) r = E.op("OpSDiv", st, {a, b});
            else {
                // a - (a / b) * b: the Thor's driver computed OpSRem of a
                // negative dividend by a constant as an unsigned remainder.
                std::string q = E.op("OpSDiv", st, {a, b});
                r = E.op("OpISub", st, {a, E.op("OpIMul", st, {q, b})});
            }
            bind(&I, E.op("OpBitcast", t, {r}));
            return;
        }
        E.body << def(&I) << " = " << op << " " << t << " " << val(I.getOperand(0)) << " " << val(I.getOperand(1)) << "\n";
        return;
    }
    if (auto *N = dyn_cast<UnaryOperator>(&I)) {
        E.body << def(&I) << " = OpFNegate " << t << " " << val(N->getOperand(0)) << "\n";
        return;
    }
    if (auto *C = dyn_cast<ICmpInst>(&I)) {
        static const std::map<CmpInst::Predicate, const char *> ops = {
            {CmpInst::ICMP_EQ, "OpIEqual"}, {CmpInst::ICMP_NE, "OpINotEqual"},
            {CmpInst::ICMP_UGT, "OpUGreaterThan"}, {CmpInst::ICMP_UGE, "OpUGreaterThanEqual"},
            {CmpInst::ICMP_ULT, "OpULessThan"}, {CmpInst::ICMP_ULE, "OpULessThanEqual"},
            {CmpInst::ICMP_SGT, "OpSGreaterThan"}, {CmpInst::ICMP_SGE, "OpSGreaterThanEqual"},
            {CmpInst::ICMP_SLT, "OpSLessThan"}, {CmpInst::ICMP_SLE, "OpSLessThanEqual"}};
        Value *a = C->getOperand(0), *b = C->getOperand(1);
        if (a->getType()->isIntOrIntVectorTy(1)) {
            // Booleans: eq/ne directly; orderings through 0/1 integers.
            if (C->getPredicate() == CmpInst::ICMP_EQ || C->getPredicate() == CmpInst::ICMP_NE) {
                E.body << def(&I) << " = " << (C->getPredicate() == CmpInst::ICMP_EQ ? "OpLogicalEqual" : "OpLogicalNotEqual")
                       << " " << t << " " << val(a) << " " << val(b) << "\n";
                return;
            }
            Type *IT = Type::getInt32Ty(I.getContext());
            if (auto *VT = dyn_cast<FixedVectorType>(a->getType())) IT = FixedVectorType::get(IT, VT->getNumElements());
            // i1 true is -1 as a signed value.
            std::string one = constant(C->isSigned() ? Constant::getAllOnesValue(IT) : ConstantInt::get(IT, 1));
            std::string zero = constant(ConstantInt::get(IT, 0));
            std::string ai = E.op("OpSelect", type(IT), {val(a), one, zero});
            std::string bi = E.op("OpSelect", type(IT), {val(b), one, zero});
            E.body << def(&I) << " = " << ops.at(C->getPredicate()) << " " << t << " " << ai << " " << bi << "\n";
            return;
        }
        E.body << def(&I) << " = " << ops.at(C->getPredicate()) << " " << t << " " << val(a) << " " << val(b) << "\n";
        return;
    }
    if (auto *C = dyn_cast<FCmpInst>(&I)) {
        static const std::map<CmpInst::Predicate, const char *> ops = {
            {CmpInst::FCMP_OEQ, "OpFOrdEqual"}, {CmpInst::FCMP_ONE, "OpFOrdNotEqual"},
            {CmpInst::FCMP_OGT, "OpFOrdGreaterThan"}, {CmpInst::FCMP_OGE, "OpFOrdGreaterThanEqual"},
            {CmpInst::FCMP_OLT, "OpFOrdLessThan"}, {CmpInst::FCMP_OLE, "OpFOrdLessThanEqual"},
            {CmpInst::FCMP_UEQ, "OpFUnordEqual"}, {CmpInst::FCMP_UNE, "OpFUnordNotEqual"},
            {CmpInst::FCMP_UGT, "OpFUnordGreaterThan"}, {CmpInst::FCMP_UGE, "OpFUnordGreaterThanEqual"},
            {CmpInst::FCMP_ULT, "OpFUnordLessThan"}, {CmpInst::FCMP_ULE, "OpFUnordLessThanEqual"}};
        std::string a = val(C->getOperand(0)), b = val(C->getOperand(1));
        auto it = ops.find(C->getPredicate());
        if (it != ops.end()) {
            E.body << def(&I) << " = " << it->second << " " << t << " " << a << " " << b << "\n";
            return;
        }
        switch (C->getPredicate()) {
        case CmpInst::FCMP_ORD:
        case CmpInst::FCMP_UNO: {
            std::string na = E.op("OpIsNan", t, {a}), nb = E.op("OpIsNan", t, {b});
            std::string any = E.op("OpLogicalOr", t, {na, nb});
            if (C->getPredicate() == CmpInst::FCMP_UNO) bind(&I, any);
            else bind(&I, E.op("OpLogicalNot", t, {any}));
            return;
        }
        case CmpInst::FCMP_TRUE:
        case CmpInst::FCMP_FALSE:
            bind(&I, constant(C->getPredicate() == CmpInst::FCMP_TRUE ? ConstantInt::getTrue(RT) : ConstantInt::getFalse(RT)));
            return;
        default: fail("unsupported-instruction", "fcmp predicate");
        }
    }
    if (auto *Cst = dyn_cast<CastInst>(&I)) {
        Value *S = Cst->getOperand(0);
        Type *ST = S->getType();
        std::string s = val(S);
        switch (Cst->getOpcode()) {
        case Instruction::ZExt:
        case Instruction::SExt:
            if (ST->isIntOrIntVectorTy(1)) {
                Constant *One = Cst->getOpcode() == Instruction::ZExt ? ConstantInt::get(RT, 1) : Constant::getAllOnesValue(RT);
                E.body << def(&I) << " = OpSelect " << t << " " << s << " " << constant(One) << " "
                       << constant(Constant::getNullValue(RT)) << "\n";
            } else {
                E.body << def(&I) << " = " << (Cst->getOpcode() == Instruction::ZExt ? "OpUConvert" : "OpSConvert") << " " << t
                       << " " << s << "\n";
            }
            return;
        case Instruction::Trunc:
            if (RT->isIntOrIntVectorTy(1)) {
                std::string m = E.op("OpBitwiseAnd", type(ST), {s, constant(ConstantInt::get(ST, 1))});
                E.body << def(&I) << " = OpINotEqual " << t << " " << m << " " << constant(Constant::getNullValue(ST)) << "\n";
            } else {
                E.body << def(&I) << " = OpUConvert " << t << " " << s << "\n";
            }
            return;
        case Instruction::FPToUI: E.body << def(&I) << " = OpConvertFToU " << t << " " << s << "\n"; return;
        case Instruction::FPToSI: E.body << def(&I) << " = OpConvertFToS " << t << " " << s << "\n"; return;
        case Instruction::UIToFP:
            if (ST->isIntOrIntVectorTy(1)) s = E.op("OpSelect", type(ST->getWithNewBitWidth(32)), {s, constant(ConstantInt::get(ST->getWithNewBitWidth(32), 1)), constant(ConstantInt::get(ST->getWithNewBitWidth(32), 0))});
            E.body << def(&I) << " = OpConvertUToF " << t << " " << s << "\n";
            return;
        case Instruction::SIToFP:
            if (ST->isIntOrIntVectorTy(1)) s = E.op("OpSelect", type(ST->getWithNewBitWidth(32)), {s, constant(Constant::getAllOnesValue(ST->getWithNewBitWidth(32))), constant(ConstantInt::get(ST->getWithNewBitWidth(32), 0))});
            E.body << def(&I) << " = OpConvertSToF " << t << " " << s << "\n";
            return;
        case Instruction::FPTrunc:
            E.body << def(&I) << " = OpFConvert " << t << " " << s << "\n";
            return;
        case Instruction::FPExt:
            // fpext(fptrunc(x)): the Thor's driver folds the conversion
            // pair away (observed); OpQuantizeToF16 keeps the rounding.
            if (ST->getScalarType()->isHalfTy() && RT->getScalarType()->isFloatTy())
                if (auto *Tr = dyn_cast<FPTruncInst>(S))
                    if (Tr->getSrcTy() == RT) {
                        bind(&I, E.op("OpQuantizeToF16", t, {val(Tr->getOperand(0))}));
                        return;
                    }
            E.body << def(&I) << " = OpFConvert " << t << " " << s << "\n";
            return;
        case Instruction::BitCast:
        case Instruction::AddrSpaceCast:
            if (type(ST) == t) { bind(&I, s); return; }
            if (ST->isIntOrIntVectorTy(1) || RT->isIntOrIntVectorTy(1)) fail("unsupported-instruction", "bitcast of booleans");
            E.body << def(&I) << " = OpBitcast " << t << " " << s << "\n";
            return;
        case Instruction::PtrToInt:
        case Instruction::IntToPtr:
            if (type(ST) == t) { bind(&I, s); return; }
            E.body << def(&I) << " = OpUConvert " << t << " " << s << "\n";
            return;
        default: fail("unsupported-instruction", Cst->getOpcodeName());
        }
    }
    if (auto *G = dyn_cast<GetElementPtrInst>(&I)) {
        if (G->getType()->isVectorTy()) fail("unsupported-instruction", "vector getelementptr");
        std::string u64 = E.tInt(64);
        std::string addr = val(G->getPointerOperand());
        int64_t constOff = 0;
        for (auto GTI = gep_type_begin(G), GTE = gep_type_end(G); GTI != GTE; ++GTI) {
            Value *Idx = GTI.getOperand();
            if (StructType *ST = GTI.getStructTypeOrNull()) {
                constOff += (int64_t)DL.getStructLayout(ST)->getElementOffset((unsigned)cast<ConstantInt>(Idx)->getZExtValue());
                continue;
            }
            int64_t size = (int64_t)GTI.getSequentialElementStride(DL);
            if (auto *CI = dyn_cast<ConstantInt>(Idx)) {
                constOff += CI->getSExtValue() * size;
                continue;
            }
            std::string i = val(Idx);
            if (!Idx->getType()->isIntegerTy(64)) i = E.op("OpSConvert", u64, {i});
            std::string off = size == 1 ? i : E.op("OpIMul", u64, {i, E.u64((uint64_t)size)});
            addr = E.op("OpIAdd", u64, {addr, off});
        }
        bind(&I, addConst(addr, constOff));
        return;
    }
    if (auto *A = dyn_cast<AllocaInst>(&I)) {
        bind(&I, E.u64(allocaOffset.at(A)));
        return;
    }
    if (auto *L = dyn_cast<LoadInst>(&I)) {
        Value *P = L->getPointerOperand();
        if (auto *G = dyn_cast<GlobalVariable>(P->stripPointerCasts())) {
            auto fc = fconsts.find(G);
            if (fc != fconsts.end() && G == fc->second.init && G->hasInitializer() && !isa<UndefValue>(G->getInitializer())) {
                // A resolved function constant (the guest specialized the function).
                bind(&I, constant(G->getInitializer()));
                return;
            }
            if (fc != fconsts.end()) {
                // A function constant: a specialization constant.
                unsigned base = abi::kSpecFunctionConstant0 + fc->second.index * 8;
                Type *VT = L->getType();
                std::string id = E.memo.count("fc" + std::to_string(fc->second.index) + t) ? E.memo["fc" + std::to_string(fc->second.index) + t] : "";
                if (id.empty() && VT->isVectorTy()) {
                    // One specialization constant per component.
                    auto *VV = cast<FixedVectorType>(VT);
                    Type *ET = VV->getElementType();
                    if (ET->isIntegerTy(1)) fail("unsupported-feature", "boolean vector function constant " + fc->second.name);
                    std::string et = type(ET);
                    std::string zero = ET->isFloatingPointTy() ? "0x0p+0" : "0";
                    std::vector<std::string> comps;
                    for (unsigned c = 0; c < VV->getNumElements(); c++) {
                        std::string sc = E.fresh();
                        E.globals << sc << " = OpSpecConstant " << et << " " << zero << "\n";
                        E.decorate(sc, "SpecId " + std::to_string(base + c));
                        comps.push_back(sc);
                    }
                    id = E.fresh();
                    std::string line = id + " = OpSpecConstantComposite " + t;
                    for (auto &c : comps) line += " " + c;
                    E.globals << line << "\n";
                    E.memo["fc" + std::to_string(fc->second.index) + t] = id;
                    Json j = Json::object();
                    j.set("index", fc->second.index);
                    j.set("name", fc->second.name);
                    j.set("type", fc->second.typeName);
                    j.set("spec_id", base);
                    j.set("components", VV->getNumElements());
                    jFunctionConstants.push(j);
                }
                if (id.empty()) {
                    if (fc->second.typeName == "bool") {
                        std::string bt = E.tBool();
                        std::string one = constant(ConstantInt::get(VT, 1)), zero = constant(ConstantInt::get(VT, 0));
                        std::string b = E.fresh();
                        E.globals << b << " = OpSpecConstantFalse " << bt << "\n";
                        E.decorate(b, "SpecId " + std::to_string(base));
                        if (VT->isIntegerTy(1)) id = b;
                        else {
                            id = E.fresh();
                            E.globals << id << " = OpSpecConstantOp " << t << " Select " << b << " " << one << " " << zero << "\n";
                        }
                    } else {
                        id = E.fresh();
                        E.globals << id << " = OpSpecConstant " << t << " " << (VT->isFloatingPointTy() ? "0x0p+0" : "0") << "\n";
                        E.decorate(id, "SpecId " + std::to_string(base));
                    }
                    E.memo["fc" + std::to_string(fc->second.index) + t] = id;
                    Json j = Json::object();
                    j.set("index", fc->second.index);
                    j.set("name", fc->second.name);
                    j.set("type", fc->second.typeName);
                    j.set("spec_id", base);
                    jFunctionConstants.push(j);
                }
                bind(&I, id);
                return;
            }
        }
        unsigned as = P->getType()->getPointerAddressSpace();
        if ((as == kDevice || as == kConstant) && isa<ConstantPointerNull>(getUnderlyingObject(P, 32))) {
            // A load through a null buffer pointer has no defined value
            // (functions specialized with a constant that disables a
            // buffer keep such loads on dead paths).
            bind(&I, E.undef(type(L->getType())));
            return;
        }
        if ((as == kDevice || as == kConstant) && experiment("psbslot") && getenv("AIRC_EXP_SLOTS")) {
            // Bisection: loads through buffer arguments of the listed indices.
            if (auto *A = dyn_cast<Argument>(getUnderlyingObject(P, 64))) {
                auto it = EI.args.find(A->getArgNo());
                std::string slots = std::string(",") + getenv("AIRC_EXP_SLOTS") + ",";
                if (it != EI.args.end() && slots.find("," + std::to_string(it->second.location()) + ",") != std::string::npos) {
                    bind(&I, E.null(type(L->getType())));
                    return;
                }
            }
        }
        if ((as == kDevice || as == kConstant) && experiment("psbindslot") && getenv("AIRC_EXP_SLOTS")) {
            // Bisection: loads through a pointer loaded from a buffer argument of the listed indices.
            if (auto *L2 = dyn_cast<LoadInst>(getUnderlyingObject(P, 64)))
                if (auto *A = dyn_cast<Argument>(getUnderlyingObject(L2->getPointerOperand(), 64))) {
                    auto it = EI.args.find(A->getArgNo());
                    std::string slots = std::string(",") + getenv("AIRC_EXP_SLOTS") + ",";
                    if (it != EI.args.end() && slots.find("," + std::to_string(it->second.location()) + ",") != std::string::npos) {
                        bind(&I, E.null(type(L->getType())));
                        return;
                    }
                }
        }
        if ((as == kDevice || as == kConstant) && nullGuardLoad(P, experiment("psbnullall"))) {
            // A load through a pointer the function took from memory (or
            // made from an integer): an address below 64 KiB is a null
            // pointer plus a field offset. Such a read is undefined; on the
            // Thor a read of unmapped memory does not fault but stalls the
            // GPU until the driver kills the context (stage8-contract.md
            // §15.6), which visionOS RealityKit's fsCALayer did in every
            // boot (visionos.md §10.13). The guarded load reads the
            // argument table instead and yields zero. AIRC_NULL_GUARD=0
            // turns it off.
            std::string a = val(P);
            std::string ok = E.op("OpUGreaterThanEqual", E.tBool(), {a, E.u64(65536)});
            std::string safe = E.op("OpSelect", E.tInt(64), {ok, a, tableAddrHere()});
            std::string v = load(safe, as, L->getType(), L->getAlign().value());
            bind(&I, E.op("OpSelect", type(L->getType()), {ok, v, E.null(type(L->getType()))}));
            nullGuardedLoads++;
            return;
        }
        if ((as == kDevice || as == kConstant) && (experiment("psbind") || experiment("psbdir"))) {
            // Bisection: loads through a pointer that is a bound buffer
            // (an argument-table entry) or through one loaded from memory.
            const Value *O = getUnderlyingObject(P, 64);
            auto *CI = dyn_cast<CallInst>(O);
            bool direct = isa<Argument>(O) || (CI && CI->getCalledFunction() &&
                                               CI->getCalledFunction()->getName().starts_with("airc.table_entry"));
            if (direct ? experiment("psbdir") : experiment("psbind")) { bind(&I, E.null(type(L->getType()))); return; }
        }
        bind(&I, load(val(P), as, L->getType(), L->getAlign().value()));
        return;
    }
    if (auto *S = dyn_cast<StoreInst>(&I)) {
        Value *P = S->getPointerOperand();
        unsigned as = P->getType()->getPointerAddressSpace();
        if (as == kConstant) fail("unsupported-feature", "store to constant address space");
        store(val(P), as, S->getValueOperand()->getType(), val(S->getValueOperand()), S->getAlign().value());
        return;
    }
    if (auto *Sel = dyn_cast<SelectInst>(&I)) {
        E.body << def(&I) << " = OpSelect " << t << " " << val(Sel->getCondition()) << " " << val(Sel->getTrueValue()) << " "
               << val(Sel->getFalseValue()) << "\n";
        return;
    }
    if (auto *P = dyn_cast<PHINode>(&I)) {
        std::string r = def(&I);
        E.body << r << " = OpPhi " << t;
        for (unsigned i = 0; i < P->getNumIncomingValues(); i++)
            E.body << " " << val(P->getIncomingValue(i)) << " " << label(P->getIncomingBlock(i));
        E.body << "\n";
        return;
    }
    if (auto *X = dyn_cast<ExtractElementInst>(&I)) {
        if (auto *CI = dyn_cast<ConstantInt>(X->getIndexOperand()))
            E.body << def(&I) << " = OpCompositeExtract " << t << " " << val(X->getVectorOperand()) << " " << CI->getZExtValue() << "\n";
        else
        {
            std::string idx = val(X->getIndexOperand());
            if (X->getIndexOperand()->getType()->isIntegerTy(1)) idx = E.op("OpSelect", E.tInt(32), {idx, E.u32(1), E.u32(0)});
            E.body << def(&I) << " = OpVectorExtractDynamic " << t << " " << val(X->getVectorOperand()) << " " << idx << "\n";
        }
        return;
    }
    if (auto *X = dyn_cast<InsertElementInst>(&I)) {
        if (auto *CI = dyn_cast<ConstantInt>(X->getOperand(2)))
            E.body << def(&I) << " = OpCompositeInsert " << t << " " << val(X->getOperand(1)) << " " << val(X->getOperand(0)) << " " << CI->getZExtValue() << "\n";
        else
        {
            std::string idx = val(X->getOperand(2));
            if (X->getOperand(2)->getType()->isIntegerTy(1)) idx = E.op("OpSelect", E.tInt(32), {idx, E.u32(1), E.u32(0)});
            E.body << def(&I) << " = OpVectorInsertDynamic " << t << " " << val(X->getOperand(0)) << " " << val(X->getOperand(1)) << " " << idx << "\n";
        }
        return;
    }
    if (auto *X = dyn_cast<ShuffleVectorInst>(&I)) {
        unsigned n0 = cast<FixedVectorType>(X->getOperand(0)->getType())->getNumElements();
        auto mask = X->getShuffleMask();
        if (mask.size() == 1) {
            // <1 x T> results are not SPIR-V vectors; not produced by Metal.
            fail("unsupported-type", "single-element vector");
        }
        E.body << def(&I) << " = OpVectorShuffle " << t << " " << val(X->getOperand(0)) << " " << val(X->getOperand(1));
        for (int m : mask) E.body << " " << (m < 0 ? 0xFFFFFFFFu : (unsigned)m);
        E.body << "\n";
        (void)n0;
        return;
    }
    if (auto *X = dyn_cast<ExtractValueInst>(&I)) {
        E.body << def(&I) << " = OpCompositeExtract " << t << " " << val(X->getAggregateOperand());
        for (unsigned i : X->indices()) E.body << " " << i;
        E.body << "\n";
        return;
    }
    if (auto *X = dyn_cast<InsertValueInst>(&I)) {
        E.body << def(&I) << " = OpCompositeInsert " << t << " " << val(X->getInsertedValueOperand()) << " " << val(X->getAggregateOperand());
        for (unsigned i : X->indices()) E.body << " " << i;
        E.body << "\n";
        return;
    }
    if (auto *Fr = dyn_cast<FreezeInst>(&I)) {
        bind(&I, val(Fr->getOperand(0)));
        return;
    }
    if (auto *C = dyn_cast<CallInst>(&I)) {
        call(C);
        return;
    }
    fail("unsupported-instruction", std::string(I.getOpcodeName()) + ": " + printValue(&I));
}

void Translator::terminator(BasicBlock &B) {
    Instruction *T = B.getTerminator();
    auto h = plan.headers.find(&B);
    if (h != plan.headers.end()) {
        if (h->second.loop) E.stmt("OpLoopMerge " + label(h->second.merge) + " " + label(h->second.cont) + " None");
        else if (isa<BranchInst>(T) && cast<BranchInst>(T)->isConditional()) E.stmt("OpSelectionMerge " + label(h->second.merge) + " None");
    }
    if (auto *Br = dyn_cast<BranchInst>(T)) {
        if (Br->isUnconditional() || Br->getSuccessor(0) == Br->getSuccessor(1)) {
            E.stmt("OpBranch " + label(Br->getSuccessor(0)));
            return;
        }
        E.stmt("OpBranchConditional " + val(Br->getCondition()) + " " + label(Br->getSuccessor(0)) + " " + label(Br->getSuccessor(1)));
        return;
    }
    if (auto *R = dyn_cast<ReturnInst>(T)) {
        if (cur && cur != &F) {
            if (Value *V = R->getReturnValue()) E.stmt("OpReturnValue " + val(V));
            else E.stmt("OpReturn");
            return;
        }
        if (Value *V = R->getReturnValue()) {
            std::string v = val(V);
            for (unsigned i = 0; i < outputs.size(); i++) {
                Output &o = outputs[i];
                if (o.var.empty()) continue;  // dropped (imageblock data, viewport index)
                std::string m = v;
                if (V->getType()->isStructTy()) m = E.op("OpCompositeExtract", type(o.type), {v, std::to_string(i)});
                const AirNode &n = EI.outputs[i];
                if (n.kind == "air.vertex_output" || n.kind == "air.render_target") {
                    IOType io = ioTypeOf(*this, o.type, n.typeName());
                    m = writeIOValue(*this, m, io, o.type);
                } else if (n.kind == "air.sample_mask") {
                    std::string p = E.op("OpAccessChain", E.tPtr("Output", E.tInt(32)), {o.var, E.u32(0)});
                    E.stmt("OpStore " + p + " " + castInt(m, o.type, 32, false));
                    continue;
                } else if (n.kind == "air.clip_distance" && !o.type->isArrayTy()) {
                    std::string p = E.op("OpAccessChain", E.tPtr("Output", E.tFloat(32)), {o.var, E.u32(0)});
                    E.stmt("OpStore " + p + " " + m);
                    continue;
                } else if (n.kind == "air.render_target_array_index" || n.kind == "air.viewport_array_index" || n.kind == "air.stencil") {
                    m = castInt(m, o.type, 32, false);
                    if (n.kind == "air.stencil") m = E.op("OpBitcast", E.tSInt(32), {m});
                } else if (o.type->getScalarType()->isHalfTy()) {
                    m = E.op("OpFConvert", o.ioType, {m});
                }
                E.stmt("OpStore " + o.var + " " + m);
            }
        }
        E.stmt("OpReturn");
        return;
    }
    if (isa<UnreachableInst>(T)) {
        E.stmt("OpUnreachable");
        return;
    }
    fail("unsupported-instruction", std::string("terminator ") + T->getOpcodeName());
}

// ---------------------------------------------------------------------------
// Module assembly, validation, reflection

void Translator::emitBlocks(Function &G) {
    bool first = true;
    for (BasicBlock *B : plan.order) {
        E.body << label(B) << " = OpLabel\n";
        if (first) {
            if (&G == &F) {
                E.body << "@FNVARS@\n";
                prologue();
            } else {
                loadTableAddr();
                globalAddresses(G);
            }
            first = false;
        }
        for (Instruction &I : *B) {
            if (I.isTerminator()) break;
            instruction(I);
        }
        terminator(*B);
    }
    E.body << "OpFunctionEnd\n";
}

std::string Translator::run() {
    layoutMemory();
    setupInterface();
    std::string fnT = E.tFunc(E.tVoid());
    std::string mainId = E.fresh();
    for (Function *H : helpers) fnIds[H] = E.fresh();
    std::ostringstream head;
    head << mainId << " = OpFunction " << E.tVoid() << " None " << fnT << "\n";
    cur = &F;
    emitBlocks(F);
    // Helpers: fresh per-function state.
    StructurePlan entryPlanSaved = plan;
    for (Function *H : helpers) {
        vals.clear();
        labels.clear();
        tableLoads.clear();
        globalAddr.clear();
        cur = H;
        plan = helperPlans[H];
        std::string rt = type(H->getReturnType());
        std::string key = "fn" + rt, decl = "OpTypeFunction " + rt;
        std::vector<std::string> pts;
        for (Argument &A : H->args()) {
            pts.push_back(type(A.getType()));
            key += "," + pts.back();
            decl += " " + pts.back();
        }
        std::string ft = E.global(key, decl);
        E.body << fnIds[H] << " = OpFunction " << rt << " DontInline " << ft << "\n";
        for (Argument &A : H->args()) {
            std::string p = E.fresh();
            E.body << p << " = OpFunctionParameter " << type(A.getType()) << "\n";
            vals[&A] = p;
        }
        emitBlocks(*H);
    }
    plan = entryPlanSaved;
    cur = &F;
    std::string bodyText = E.body.str();
    size_t at = bodyText.find("@FNVARS@\n");
    bodyText.replace(at, 9, E.fnvars.str());

    std::ostringstream out;
    out << "; SPIR-V for Vulkan from AIR function " << F.getName().str() << " (" << kTranslatorVersion << ")\n";
    for (auto &c : E.caps) out << "OpCapability " << c << "\n";
    for (auto &x : E.exts) out << "OpExtension \"" << x << "\"\n";
    out << E.glsl << " = OpExtInstImport \"GLSL.std.450\"\n";
    out << "OpMemoryModel PhysicalStorageBuffer64 GLSL450\n";
    const char *model = EI.stage == Stage::Kernel ? "GLCompute" : EI.stage == Stage::Vertex ? "Vertex" : "Fragment";
    out << "OpEntryPoint " << model << " " << mainId << " \"" << F.getName().str() << "\"";
    for (auto &v : E.interface) out << " " << v;
    out << "\n";
    if (EI.stage == Stage::Kernel) out << "OpExecutionModeId " << mainId << " LocalSizeId " << specX << " " << specY << " " << specZ << "\n";
    if (uses.count("compute_derivatives_linear")) out << "OpExecutionMode " << mainId << " DerivativeGroupLinearKHR\n";
    if (EI.stage == Stage::Fragment) {
        out << "OpExecutionMode " << mainId << " OriginUpperLeft\n";
        if (uses.count("depth_any") || uses.count("depth_greater") || uses.count("depth_less")) out << "OpExecutionMode " << mainId << " DepthReplacing\n";
        if (uses.count("depth_greater")) out << "OpExecutionMode " << mainId << " DepthGreater\n";
        if (uses.count("depth_less")) out << "OpExecutionMode " << mainId << " DepthLess\n";
    }
    out << E.decor.str() << E.globals.str() << head.str() << bodyText;
    return out.str();
}

Json Translator::reflection() {
    Json r = Json::object();
    r.set("stage", stageName(EI.stage));
    r.set("entry_point", F.getName().str());
    Json abiJ = Json::object();
    abiJ.set("version", abi::kVersion);
    abiJ.set("push_constant_size", abi::kPushSize);
    abiJ.set("table_push_offset", EI.stage == Stage::Fragment ? abi::kPushTableFragment : abi::kPushTableVertexOrKernel);
    abiJ.set("table_entries", abi::kTableEntries);
    abiJ.set("descriptor_set", abi::kSet);
    r.set("abi", abiJ);
    r.set("buffers", jBuffers);
    r.set("textures", jTextures);
    r.set("samplers", jSamplers);
    Json cs = Json::array();
    for (auto &s : samplers) {
        if (!globalAddr.count(s.global)) continue;
        SamplerFields f = decodeSampler(s.word0);
        Json j = Json::object();
        j.set("table_entry", abi::kTableConstexprSampler0 + constexprSamplerIndex[s.global]);
        char buf[32];
        snprintf(buf, sizeof buf, "0x%016llx", (unsigned long long)s.word0);
        j.set("state", buf);
        static const char *addr[] = {"clamp_to_zero", "clamp_to_edge", "repeat", "mirrored_repeat", "4", "5", "6", "7"};
        static const char *filt[] = {"nearest", "linear", "2", "3"};
        static const char *mip[] = {"none", "nearest", "linear", "3"};
        static const char *cmp[] = {"never", "less", "less_equal", "greater", "greater_equal", "equal", "not_equal", "always"};
        static const char *border[] = {"transparent_black", "opaque_black", "opaque_white", "3"};
        static const char *red[] = {"weighted_average", "minimum", "maximum", "3"};
        j.set("s_address", addr[f.addrS]);
        j.set("t_address", addr[f.addrT]);
        j.set("r_address", addr[f.addrR]);
        j.set("mag_filter", filt[f.magFilter]);
        j.set("min_filter", filt[f.minFilter]);
        j.set("mip_filter", mip[f.mipFilter]);
        j.set("normalized_coordinates", (bool)f.normalized);
        j.set("compare_function", cmp[f.compare]);
        j.set("max_anisotropy", f.maxAnisotropy);
        j.set("lod_min", (double)f.lodMin);
        j.set("lod_max", (double)f.lodMax);
        j.set("border_color", border[f.borderColor]);
        j.set("reduction", red[f.reduction]);
        cs.push(j);
    }
    r.set("constexpr_samplers", cs);
    if (!constData.empty()) {
        Json j = Json::object();
        j.set("table_entry", abi::kTableConstantData);
        j.set("size", (unsigned long long)constData.size());
        static const char *b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        std::string enc;
        for (size_t i = 0; i < constData.size(); i += 3) {
            uint32_t v = (uint8_t)constData[i] << 16;
            if (i + 1 < constData.size()) v |= (uint8_t)constData[i + 1] << 8;
            if (i + 2 < constData.size()) v |= (uint8_t)constData[i + 2];
            enc += b64[(v >> 18) & 63];
            enc += b64[(v >> 12) & 63];
            enc += i + 1 < constData.size() ? b64[(v >> 6) & 63] : '=';
            enc += i + 2 < constData.size() ? b64[v & 63] : '=';
        }
        j.set("base64", enc);
        r.set("constant_data", j);
    }
    if (EI.stage == Stage::Kernel) {
        Json k = Json::object();
        Json ids = Json::array();
        ids.push(abi::kSpecWorkgroupX);
        ids.push(abi::kSpecWorkgroupY);
        ids.push(abi::kSpecWorkgroupZ);
        k.set("workgroup_size_spec_ids", ids);
        k.set("grid_push_offset", abi::kPushGrid);
        k.set("grid_guard", gridGuard);
        Json tg = Json::object();
        tg.set("static_bytes", (unsigned long long)wgStaticBytes);
        tg.set("dynamic", wgDynamic);
        if (!wgSlots.empty()) {
            tg.set("size_spec_id", abi::kSpecThreadgroupBytes);
            tg.set("slots_base", (unsigned long long)wgStaticBytesAligned());
        }
        if (hasImageblock) {
            Json ib = Json::object();
            ib.set("offset", (unsigned long long)imageblockBase());
            ib.set("bytes_per_pixel", (unsigned long long)ibStride);
            ib.set("size", "threadgroup width x height");
            tg.set("imageblock", ib);
        }
        tg.set("slots", jThreadgroup);
        k.set("threadgroup_memory", tg);
        r.set("compute", k);
    }
    if (EI.stage == Stage::Vertex) r.set("vertex_inputs", jVertexInputs);
    if (EI.stage != Stage::Kernel) {
        r.set("varyings", jVaryings);
        if (EI.stage == Stage::Fragment) {
            r.set("linked", linked);
            if (linked && !opts.linkedVertexHash.empty()) r.set("linked_vertex", opts.linkedVertexHash);
            r.set("render_targets", jRenderTargets);
            r.set("input_attachments", jInputAttachments);
        }
    }
    r.set("builtins", jBuiltins);
    r.set("function_constants", jFunctionConstants);
    r.set("private_bytes", (unsigned long long)privateBytes);
    if (!loopBudgetVar.empty()) r.set("loop_limit", (unsigned long long)opts.loopLimit);
    if (nullGuardedLoads) r.set("null_guarded_loads", (unsigned long long)nullGuardedLoads);
    Json u = Json::array();
    for (auto &s : uses) u.push(s);
    r.set("uses", u);
    Json c = Json::array();
    for (auto &s : E.caps) c.push(s);
    r.set("capabilities", c);
    Json x = Json::array();
    for (auto &s : E.exts) x.push(s);
    r.set("extensions", x);
    return r;
}

// Resource arguments whose slot is a function-constant expression, and
// arrays of resources (passed as a private array), read their handles or
// addresses from the argument table through `airc.table_entry(i32 entry)`
// calls at the start of the function (lowered by the emitter).
static void lowerResourceArgs(Module &M, Function &F, EntryInfo &EI) {
    LLVMContext &C = F.getContext();
    Type *I32 = Type::getInt32Ty(C);
    for (Argument &A : F.args()) {
        auto it = EI.args.find(A.getArgNo());
        if (it == EI.args.end() || A.use_empty()) continue;
        const AirNode &n = it->second;
        unsigned base;
        if (n.kind == "air.texture") base = abi::kTableTexture0;
        else if (n.kind == "air.sampler") base = abi::kTableSampler0;
        else if ((n.kind == "air.buffer" || n.kind == "air.indirect_buffer") && n.intAt("air.address_space", 0, 1) != kThreadgroup)
            base = abi::kTableBuffer0;
        else continue;
        GlobalVariable *LG = n.locationGlobal();
        Type *AT = A.getType();
        bool byvalArray = A.hasByValAttr() && A.getParamByValType() && A.getParamByValType()->isArrayTy();
        if (!LG && !byvalArray) continue;
        IRBuilder<> B(&*F.getEntryBlock().getFirstInsertionPt());
        Value *index = nullptr;
        if (LG) index = B.CreateAdd(B.CreateLoad(I32, LG), ConstantInt::get(I32, base));
        else index = ConstantInt::get(I32, base + (unsigned)std::max(0, n.location()));
        auto entryFn = [&](Type *RT) {
            std::string nm = "airc.table_entry." + std::to_string(RT->isPointerTy() ? RT->getPointerAddressSpace() : 99);
            return M.getOrInsertFunction(nm, FunctionType::get(RT, {I32}, false));
        };
        if (byvalArray) {
            auto *ArrT = cast<ArrayType>(A.getParamByValType());
            Type *ET = ArrT->getElementType();
            AllocaInst *Arr = B.CreateAlloca(ArrT);
            for (uint64_t i = 0; i < ArrT->getNumElements(); i++) {
                Value *e = B.CreateAdd(index, ConstantInt::get(I32, i));
                Value *h = B.CreateCall(entryFn(ET), {e});
                B.CreateStore(h, B.CreateConstInBoundsGEP2_32(ArrT, Arr, 0, (unsigned)i));
            }
            A.replaceAllUsesWith(Arr);
        } else {
            A.replaceAllUsesWith(B.CreateCall(entryFn(AT), {index}));
        }
    }
}

// Visible-function test kernel (TranslateOptions::wrapVisible).
static Function *wrapVisible(Module &M, Function *V, EntryInfo &EI) {
    LLVMContext &C = M.getContext();
    Type *P1 = PointerType::get(C, kDevice);
    Function *W = Function::Create(FunctionType::get(Type::getVoidTy(C), {P1}, false), GlobalValue::ExternalLinkage,
                                   "__airc_visible_" + V->getName(), M);
    BasicBlock *BB = BasicBlock::Create(C, "entry", W);
    IRBuilder<> B(BB);
    const DataLayout &DL = M.getDataLayout();
    Value *args = W->getArg(0);
    uint64_t off = 0;
    auto slot = [&](Type *T) {
        off = alignTo(off, 16);
        Value *p = B.CreateConstInBoundsGEP1_64(Type::getInt8Ty(C), args, off);
        off += std::max<uint64_t>(DL.getTypeAllocSize(T), 8);
        return p;
    };
    std::vector<Value *> callArgs;
    for (Argument &A : V->args()) {
        Type *T = A.getType();
        Type *byval = A.hasByValAttr() ? A.getParamByValType() : A.hasStructRetAttr() ? A.getParamStructRetType() : nullptr;
        if (T->isPointerTy() && T->getPointerAddressSpace() == kPrivate) {
            Type *ST = byval ? byval : ArrayType::get(Type::getInt8Ty(C), 256);
            AllocaInst *Al = B.CreateAlloca(ST);
            if (byval) B.CreateStore(B.CreateAlignedLoad(ST, slot(ST), Align(16)), Al);
            callArgs.push_back(Al);
        } else {
            callArgs.push_back(B.CreateAlignedLoad(T, slot(T), Align(16)));
        }
    }
    CallInst *R = B.CreateCall(V, callArgs);
    if (!R->getType()->isVoidTy()) B.CreateAlignedStore(R, slot(R->getType()), Align(16));
    for (unsigned i = 0; i < V->arg_size(); i++)
        if (V->getArg(i)->hasStructRetAttr())
            B.CreateAlignedStore(B.CreateLoad(V->getArg(i)->getParamStructRetType(), callArgs[i]), slot(V->getArg(i)->getParamStructRetType()), Align(16));
    B.CreateRetVoid();
    // The test function's interface: buffer 0, device, read-write. A
    // fragment function when the body needs fragment-only operations.
    bool fragmentOnly = false;
    std::set<Function *> seen;
    std::function<void(Function *)> scan = [&](Function *Fn) {
        if (!seen.insert(Fn).second || Fn->isDeclaration()) return;
        for (BasicBlock &BB2 : *Fn)
            for (Instruction &I : BB2)
                if (auto *CI = dyn_cast<CallInst>(&I))
                    if (Function *G = CI->getCalledFunction()) {
                        StringRef nm = G->getName();
                        if (nm.starts_with("air.dfdx") || nm.starts_with("air.dfdy") || nm.starts_with("air.fwidth") ||
                            nm.starts_with("air.discard_fragment") || nm.starts_with("air.interpolate_"))
                            fragmentOnly = true;
                        scan(G);
                    }
    };
    scan(V);
    EI = EntryInfo();
    EI.stage = fragmentOnly ? Stage::Fragment : Stage::Kernel;
    EI.fn = W;
    AirNode n;
    n.argIndex = 0;
    n.kind = "air.buffer";
    Type *I32 = Type::getInt32Ty(C);
    n.keys.push_back({"air.buffer", {}});
    n.keys.push_back({"air.location_index", {ConstantAsMetadata::get(ConstantInt::get(I32, 0)), ConstantAsMetadata::get(ConstantInt::get(I32, 1))}});
    n.keys.push_back({"air.read_write", {}});
    n.keys.push_back({"air.address_space", {ConstantAsMetadata::get(ConstantInt::get(I32, 1))}});
    n.keys.push_back({"air.arg_name", {MDString::get(C, "visible_arguments")}});
    EI.args[0] = n;
    return W;
}

static bool isVisible(Module &M, Function *F) {
    for (const char *list : {"air.visible", "air.ci"})
    if (NamedMDNode *K = M.getNamedMetadata(list))
        for (MDNode *N : K->operands())
            if (N->getNumOperands())
                if (auto *FV = dyn_cast_or_null<ValueAsMetadata>(N->getOperand(0).get()))
                    if (FV->getValue()->stripPointerCasts() == F) return true;
    return false;
}

// Links visible-function modules and binds the `.MTL_VISIBLE_FN_REF`
// declarations to their definitions; unresolved ones are asked from the
// resolver (functions of the same library).
static void linkVisible(Module &M, const TranslateOptions &opts) {
    auto link = [&](const std::string &bytes) {
        auto lm = parseBitcodeFile(MemoryBufferRef(StringRef(bytes), "air-linked"), M.getContext());
        if (!lm) fail("bad-bitcode", "linked module: " + toString(lm.takeError()));
        for (const char *nm : {"air.vertex", "air.fragment", "air.kernel"})
            if (NamedMDNode *K = (*lm)->getNamedMetadata(nm)) (*lm)->eraseNamedMetadata(K);
        if (Linker::linkModules(M, std::move(*lm))) fail("bad-request", "linking a visible function failed");
    };
    for (const std::string &bytes : opts.linkModules) link(bytes);
    for (int round = 0; round < 64; round++) {
        std::vector<Function *> refs;
        for (Function &D : M) {
            StringRef nm = D.getName();
            if (D.isDeclaration() && !D.use_empty() && !nm.starts_with("air.") && !nm.starts_with("llvm.") && !nm.starts_with("airc."))
                refs.push_back(&D);
        }
        bool progress = false;
        for (Function *D : refs) {
            if (!D->getName().ends_with(".MTL_VISIBLE_FN_REF")) {
                // A function of a linked library (dynamic library): linking
                // its module defines the declaration.
                std::string bytes;
                if (opts.resolveVisible && opts.resolveVisible(D->getName().str(), bytes)) {
                    link(bytes);
                    progress = true;
                }
                continue;
            }
            std::string base = D->getName().drop_back(strlen(".MTL_VISIBLE_FN_REF")).str();
            Function *G = M.getFunction(base);
            if ((!G || G->isDeclaration()) && opts.resolveVisible) {
                std::string bytes;
                if (opts.resolveVisible(base, bytes)) {
                    link(bytes);
                    G = M.getFunction(base);
                    progress = true;
                }
            }
            if (!G || G->isDeclaration()) continue;
            if (G->getFunctionType() != D->getFunctionType()) fail("bad-request", "linked function " + base + " has another signature");
            D->replaceAllUsesWith(G);
            progress = true;
        }
        if (!progress) break;
    }
}

// write_imageblock_slice_to_texture_2d(texture, member pointer, i1,
// ushort2 origin, ushort2 size (undef: the whole imageblock), ushort2
// texture coordinate, ushort lod, i1, i32 access): one thread writes one
// member of every pixel of the imageblock to the texture. Expanded into two
// loops of write_texture_2d calls before structurization.
static void expandImageblockSlices(Function &F, uint64_t stride) {
    std::vector<CallInst *> calls;
    for (BasicBlock &B : F)
        for (Instruction &I : B)
            if (auto *C = dyn_cast<CallInst>(&I))
                if (Function *G = C->getCalledFunction())
                    if (G->getName().starts_with("air.write_imageblock_slice_to_texture_2d")) calls.push_back(C);
    if (calls.empty()) return;
    if (!stride) fail("unsupported-feature", "imageblock slice without an imageblock argument");
    Module &M = *F.getParent();
    LLVMContext &Cx = F.getContext();
    Type *I16 = Type::getInt16Ty(Cx), *I32 = Type::getInt32Ty(Cx), *I64 = Type::getInt64Ty(Cx);
    for (CallInst *C : calls) {
        StringRef name = C->getCalledFunction()->getName();
        StringRef suffix = name.substr(name.rfind('.') + 1);  // v4f16, v4f32, ...
        if (!suffix.contains('f')) fail("unsupported-intrinsic", name.str() + " (integer slices)");
        Value *tex = C->getArgOperand(0), *member = C->getArgOperand(1);
        Value *origin = C->getArgOperand(3), *size = C->getArgOperand(4), *dst = C->getArgOperand(5);
        Value *lod = C->getArgOperand(6), *access = C->getArgOperand(8);
        // The element type from the suffix: vNfM.
        unsigned n = 1, bits = 32;
        if (suffix.starts_with("v")) n = (unsigned)(suffix[1] - '0');
        bits = suffix.ends_with("f16") ? 16 : 32;
        Type *ET = bits == 16 ? Type::getHalfTy(Cx) : Type::getFloatTy(Cx);
        Type *VT = n > 1 ? (Type *)FixedVectorType::get(ET, n) : ET;
        BasicBlock *pre = C->getParent();
        BasicBlock *after = pre->splitBasicBlock(C, "slice.after");
        pre->getTerminator()->eraseFromParent();
        IRBuilder<> B(pre);
        auto widthFn = M.getOrInsertFunction("air.get_imageblock_width", I16);
        auto heightFn = M.getOrInsertFunction("air.get_imageblock_height", I16);
        auto baseFn = M.getOrInsertFunction("airc.imageblock_base", I64);
        Value *W = B.CreateZExt(B.CreateCall(widthFn), I32);
        Value *H = B.CreateZExt(B.CreateCall(heightFn), I32);
        Value *base = B.CreateCall(baseFn);
        Value *memberOff = B.CreateURem(B.CreateSub(B.CreatePtrToInt(member, I64), base), ConstantInt::get(I64, stride));
        auto comp = [&](Value *v2, unsigned i, Value *dflt) -> Value * {
            if (isa<UndefValue>(v2)) return dflt;
            return B.CreateZExt(B.CreateExtractElement(v2, (uint64_t)i), I32);
        };
        Value *ox = comp(origin, 0, ConstantInt::get(I32, 0)), *oy = comp(origin, 1, ConstantInt::get(I32, 0));
        Value *sw = comp(size, 0, W), *sh = comp(size, 1, H);
        Value *dx = comp(dst, 0, ConstantInt::get(I32, 0)), *dy = comp(dst, 1, ConstantInt::get(I32, 0));
        Value *lod32 = B.CreateZExt(lod, I32);
        BasicBlock *hy = BasicBlock::Create(Cx, "slice.y", &F, after);
        BasicBlock *hx = BasicBlock::Create(Cx, "slice.x", &F, after);
        BasicBlock *body = BasicBlock::Create(Cx, "slice.body", &F, after);
        BasicBlock *latch = BasicBlock::Create(Cx, "slice.ynext", &F, after);
        B.CreateBr(hy);
        B.SetInsertPoint(hy);
        PHINode *y = B.CreatePHI(I32, 2);
        y->addIncoming(ConstantInt::get(I32, 0), pre);
        B.CreateCondBr(B.CreateICmpULT(y, sh), hx, after);
        B.SetInsertPoint(hx);
        PHINode *x = B.CreatePHI(I32, 2);
        x->addIncoming(ConstantInt::get(I32, 0), hy);
        B.CreateCondBr(B.CreateICmpULT(x, sw), body, latch);
        B.SetInsertPoint(body);
        Value *px = B.CreateAdd(B.CreateMul(B.CreateAdd(y, oy), W), B.CreateAdd(x, ox));
        Value *addr = B.CreateAdd(B.CreateAdd(base, B.CreateMul(B.CreateZExt(px, I64), ConstantInt::get(I64, stride))), memberOff);
        Value *p = B.CreateIntToPtr(addr, PointerType::get(Cx, kImageblock));
        Value *v = B.CreateAlignedLoad(VT, p, Align(bits / 8));
        if (n == 1) v = B.CreateInsertElement(PoisonValue::get(FixedVectorType::get(ET, 4)), v, (uint64_t)0);
        else if (n != 4) {
            SmallVector<int, 4> mask;
            for (unsigned i = 0; i < 4; i++) mask.push_back(i < n ? (int)i : -1);
            v = B.CreateShuffleVector(v, PoisonValue::get(VT), mask);
        }
        Type *V4 = FixedVectorType::get(ET, 4);
        Value *coord = B.CreateInsertElement(B.CreateInsertElement(PoisonValue::get(FixedVectorType::get(I32, 2)), B.CreateAdd(dx, x), (uint64_t)0),
                                             B.CreateAdd(dy, y), (uint64_t)1);
        auto writeFn = M.getOrInsertFunction(std::string("air.write_texture_2d.v4") + (bits == 16 ? "f16" : "f32"), Type::getVoidTy(Cx),
                                             tex->getType(), FixedVectorType::get(I32, 2), V4, I32, I32);
        B.CreateCall(writeFn, {tex, coord, v, lod32, access});
        Value *x1 = B.CreateAdd(x, ConstantInt::get(I32, 1));
        x->addIncoming(x1, body);
        B.CreateBr(hx);
        B.SetInsertPoint(latch);
        Value *y1 = B.CreateAdd(y, ConstantInt::get(I32, 1));
        y->addIncoming(y1, latch);
        B.CreateBr(hy);
        C->eraseFromParent();
        (void)I16;
    }
}

static uint64_t imageblockStride(const EntryInfo &EI) {
    for (auto &a : EI.args) {
        if (a.second.kind != "air.imageblock") continue;
        int64_t ds = a.second.intAt("air.imageblock_data_size", 0, -1);
        if (ds > 0) return (uint64_t)ds;
        uint64_t end = 0;
        for (auto &kv : a.second.keys)
            if (kv.first == "air.struct_type_info" && !kv.second.empty())
                if (auto *S = dyn_cast_or_null<MDNode>(kv.second[0]))
                    for (unsigned i = 0; i + 4 < S->getNumOperands(); i++) {
                        auto *o = mdconst::dyn_extract_or_null<ConstantInt>(S->getOperand(i));
                        auto *z = mdconst::dyn_extract_or_null<ConstantInt>(S->getOperand(i + 1));
                        auto *c = mdconst::dyn_extract_or_null<ConstantInt>(S->getOperand(i + 2));
                        if (!o || !z || !c || !isa<MDString>(S->getOperand(i + 3)) || !isa<MDString>(S->getOperand(i + 4))) continue;
                        end = std::max<uint64_t>(end, o->getZExtValue() + z->getZExtValue() * std::max<uint64_t>(1, c->getZExtValue()));
                        i += 4;
                    }
        return alignTo(std::max<uint64_t>(end, 4), 4);
    }
    return 0;
}

TranslateResult translate(const std::string &module, const std::string &name, const std::string &hashHex, int kind,
                          const TranslateOptions &opts) {
    LLVMContext ctx;
    auto mod = parseBitcodeFile(MemoryBufferRef(StringRef(module), "air"), ctx);
    if (!mod) fail("bad-bitcode", toString(mod.takeError()));
    Module &M = **mod;
    if (!StringRef(M.getTargetTriple()).starts_with("air64")) fail("bad-bitcode", "target triple " + M.getTargetTriple());
    Function *F = M.getFunction(name);
    if (!F || F->isDeclaration()) fail("function-not-found", name);
    if (!opts.linkModules.empty() || opts.resolveVisible) linkVisible(M, opts);
    EntryInfo EI;
    bool wrapped = false;
    if (opts.wrapVisible && isVisible(M, F)) {
        F = wrapVisible(M, F, EI);
        wrapped = true;
    } else {
        EI = entryInfo(M, F);
    }
    // Kernels without barriers get an early return for threads outside the
    // Metal grid (dispatchThreads with a non-uniform grid; section 4.6).
    bool wantGuard = EI.stage == Stage::Kernel;
    if (!opts.functionConstantValues.empty())
        for (auto &fc : functionConstants(M)) {
            auto v = opts.functionConstantValues.find(fc.index);
            if (v == opts.functionConstantValues.end() || !fc.init) continue;
            Type *T = fc.init->getValueType();
            Constant *C;
            Type *S = T->getScalarType();
            if (S->isFloatingPointTy()) C = ConstantFP::get(T, v->second);  // vectors: splat
            else if (S->isIntegerTy()) C = ConstantInt::get(T, (uint64_t)(int64_t)v->second, true);
            else fail("unsupported-feature", "value for function constant " + fc.name + " of type " + fc.typeName);
            fc.init->setInitializer(C);
            fc.init->setExternallyInitialized(false);
            fc.init->setConstant(true);
        }
    lowerResourceArgs(M, *F, EI);
    auto t0 = std::chrono::steady_clock::now();
    auto stats = [&](const char *when) {
        if (!getenv("AIRC_STATS")) return;
        fprintf(stderr, "airc-stats %.1f ms ", std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
        size_t blocks = 0, insts = 0, calls = 0, allocas = 0;
        for (BasicBlock &B : *F) {
            blocks++;
            for (Instruction &I : B) {
                insts++;
                calls += isa<CallInst>(I);
                allocas += isa<AllocaInst>(I);
            }
        }
        fprintf(stderr, "airc-stats %s: %zu blocks, %zu instructions, %zu calls, %zu allocas\n", when, blocks, insts, calls, allocas);
        if (getenv("AIRC_STATS_OPS")) {
            // Opcode and callee-name counts (names only).
            std::map<std::string, size_t> ops;
            for (BasicBlock &B : *F)
                for (Instruction &I : B) {
                    std::string k = I.getOpcodeName();
                    if (auto *CI = dyn_cast<CallInst>(&I))
                        if (Function *G = CI->getCalledFunction()) k += " " + G->getName().str().substr(0, 40);
                    ops[k]++;
                }
            std::vector<std::pair<size_t, std::string>> v;
            for (auto &o : ops) v.push_back({o.second, o.first});
            std::sort(v.rbegin(), v.rend());
            for (size_t i = 0; i < v.size() && i < 12; i++) fprintf(stderr, "    %6zu %s\n", v[i].first, v[i].second.c_str());
        }
    };
    stats("before");
    if (getenv("AIRC_STATS_CALLS")) {
        // Call graph of defined helpers reachable from F: size and call sites (counts only).
        std::map<Function *, size_t> sites;
        std::set<Function *> seen;
        std::vector<Function *> work{F};
        while (!work.empty()) {
            Function *G = work.back();
            work.pop_back();
            if (!seen.insert(G).second) continue;
            for (BasicBlock &B : *G)
                for (Instruction &I : B)
                    if (auto *CI = dyn_cast<CallInst>(&I))
                        if (Function *H = CI->getCalledFunction())
                            if (!H->isDeclaration()) { sites[H]++; work.push_back(H); }
        }
        std::vector<std::tuple<size_t, size_t, size_t>> v;
        for (auto &p : sites) {
            size_t n = 0;
            for (BasicBlock &B : *p.first) n += B.size();
            v.push_back({(p.second - 1) * n, n, p.second});
        }
        std::sort(v.rbegin(), v.rend());
        fprintf(stderr, "airc-calls: %zu helpers\n", v.size());
        for (size_t i = 0; i < v.size() && i < 15; i++)
            fprintf(stderr, "    size %zu sites %zu\n", std::get<1>(v[i]), std::get<2>(v[i]));
    }
    uint64_t ibStride = imageblockStride(EI);
    std::vector<Function *> helpers;
    bool guarded = prepareFunction(M, *F, wantGuard, [&](Function &G) { expandImageblockSlices(G, ibStride); }, &helpers,
                                   opts.loopLimit != 0);
    stats("prepared");
    if (EI.stage == Stage::Kernel) {
        // A kernel that still calls discard_fragment with no function
        // constant left to remove the call is what Metal refuses.
        bool discard = false, constants = false;
        std::set<const GlobalVariable *> fcGlobals;
        for (auto &fc : functionConstants(M)) {
            if (fc.value) fcGlobals.insert(fc.value);
            if (fc.init) fcGlobals.insert(fc.init);
        }
        std::vector<Function *> fs{F};
        fs.insert(fs.end(), helpers.begin(), helpers.end());
        for (Function *G : fs)
            for (BasicBlock &B : *G)
                for (Instruction &I : B) {
                    if (auto *C = dyn_cast<CallInst>(&I))
                        if (Function *H = C->getCalledFunction()) discard |= H->getName() == "air.discard_fragment";
                    if (auto *L = dyn_cast<LoadInst>(&I))
                        if (auto *GV = dyn_cast<GlobalVariable>(L->getPointerOperand()->stripPointerCasts()))
                            constants |= fcGlobals.count(GV) && !(GV->hasInitializer() && !isa<UndefValue>(GV->getInitializer()));
                }
        if (discard && !constants) fail("unsupported-feature", "kernel function calls discard_fragment (Metal refuses this function)");
    }
    Translator X(M, *F, EI, opts);
    X.gridGuard = guarded;
    X.plan = planStructure(*F);
    X.helpers = helpers;
    for (Function *H : helpers) X.helperPlans[H] = planStructure(*H);
    stats("planned");
    std::string text = X.run();
    stats("emitted");
    if (getenv("AIRC_STATS")) fprintf(stderr, "airc-stats: private %llu bytes, SPIR-V text %zu bytes\n", (unsigned long long)X.privateBytes, text.size());

    TranslateResult res;
    if (opts.wantAssembly) res.assembly = text;
    if (const char *dump = getenv("AIRC_DUMP")) {
        // Debugging aid: the SPIR-V text before assembly and validation.
        if (FILE *f = fopen(dump, "w")) { fputs(text.c_str(), f); fclose(f); }
    }
    if (const char *dump = getenv("AIRC_DUMP_LL")) {
        std::string s;
        raw_string_ostream os(s);
        F->print(os);
        if (FILE *f = fopen(dump, "w")) { fputs(os.str().c_str(), f); fclose(f); }
    }
    spvtools::SpirvTools tools(SPV_ENV_VULKAN_1_3);
    std::string diag;
    tools.SetMessageConsumer([&](spv_message_level_t, const char *, const spv_position_t &pos, const char *msg) {
        diag += "word " + std::to_string(pos.index) + ": " + msg + "\n";
    });
    if (!tools.Assemble(text, &res.spirv, SPV_TEXT_TO_BINARY_OPTION_PRESERVE_NUMERIC_IDS)) {
        if (res.assembly.empty()) res.assembly = text;
        Error e("internal", "SPIR-V assembly failed: " + diag);
        throw e;
    }
    // The same checks as `spirv-val --target-env vulkan1.3` with default options.
    spvtools::ValidatorOptions vo;
    stats("assembled");
    if (!tools.Validate(res.spirv.data(), res.spirv.size(), vo)) fail("validation-failed", diag);
    stats("validated");
    if (opts.optimize) {
        spvtools::Optimizer o(SPV_ENV_VULKAN_1_3);
        o.RegisterPerformancePasses();
        std::vector<uint32_t> optimized;
        if (!o.Run(res.spirv.data(), res.spirv.size(), &optimized)) fail("internal", "spirv-opt failed: " + diag);
        if (!tools.Validate(optimized.data(), optimized.size(), vo)) fail("validation-failed", "after spirv-opt: " + diag);
        res.spirv.swap(optimized);
    }
    res.reflection = X.reflection();
    Json top = Json::object();
    top.set("translator", kTranslatorVersion);
    top.set("function", name);
    if (wrapped) top.set("wrapped_visible_function", true);
    if (!hashHex.empty()) top.set("hash", hashHex);
    if (kind >= 0) top.set("metallib_type", kind);
    top.set("air_triple", M.getTargetTriple());
    top.set("spirv_words", (unsigned long long)res.spirv.size());
    for (auto &p : res.reflection.obj) top.set(p.first, p.second);
    res.reflection = top;
    return res;
}

}  // namespace airc
