// airc.cpp: Ycode R8 proof of concept, AIR (from a .metallib) to SPIR-V for
// Vulkan. Written for stage 8a research from public sources only: the
// LLVM API (Apache-2.0 WITH LLVM-exception), the SPIR-V specification and
// SPIRV-Tools API (Apache-2.0), and our own spec
// specs/simulator/metal-shaders.md. It reads only shaders we compiled
// ourselves.
//
// Scope (PoC): compute kernels (!air.kernel), and vertex and fragment
// functions with stage-in, varyings, render targets and 2D texture
// sampling (!air.vertex, !air.fragment); buffer arguments in address
// spaces 1 (device) and 2 (constant); the thread-position built-ins; scalar
// and vector integer and float arithmetic, compares, casts, select, phi;
// loads and stores through buffer pointers; structured if and loops; a few
// air.* math intrinsics and air.convert.*. Everything else is reported as
// unsupported.
//
// Model ("R8 PoC compute ABI", see vk/vkrun.c):
//   * every pointer into a Metal buffer is a 64-bit integer address
//     (SPV_KHR_physical_storage_buffer); each load or store converts it to
//     a PhysicalStorageBuffer pointer with an Aligned memory operand;
//   * buffer slot k comes from push constant member 0, element k;
//   * threads_per_grid comes from push constant member 1;
//   * the threadgroup size is LocalSizeId from specialization constants
//     0, 1, 2 (Metal sets it at dispatch time, not in the shader).
//
// Build (Thor): see build-thor.sh. Usage:
//   airc IN.metallib|IN.bc FUNCTION OUT.spv [--asm OUT.spvasm] [--opt]
//        [--link-vs VERTEX_FUNCTION]   (fragment functions: varying locations)
//
// Graphics PoC ABI (vk/vkdraw.c): push constants hold the vertex stage's
// buffer slots 0..3 at offset 0 and the fragment stage's at offset 32;
// texture slot n is element n of the sampled-image array at set 0,
// binding 0, sampler slot n element n of the sampler array at binding 1;
// varyings get Locations in the vertex function's output order; 16-bit
// floats are widened at stage boundaries.
#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/PostDominators.h"
#include "llvm/Bitcode/BitcodeReader.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/GetElementPtrTypeIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Operator.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"
#include "llvm/Transforms/Utils/LoopSimplify.h"
#include "llvm/Transforms/Utils/LowerSwitch.h"
#include "llvm/Transforms/Utils/UnifyFunctionExitNodes.h"
#include "spirv-tools/libspirv.hpp"
#include "spirv-tools/optimizer.hpp"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

using namespace llvm;

[[noreturn]] static void fail(const std::string &m) {
    fprintf(stderr, "airc: %s\n", m.c_str());
    exit(1);
}

// ---------------------------------------------------------------------------
// metallib container (specs/simulator/metal-shaders.md section 2)

static uint16_t rd16(const uint8_t *p) { return p[0] | (p[1] << 8); }
static uint32_t rd32(const uint8_t *p) { return rd16(p) | ((uint32_t)rd16(p + 2) << 16); }
static uint64_t rd64(const uint8_t *p) { return rd32(p) | ((uint64_t)rd32(p + 4) << 32); }

// Returns the bitcode module that holds FUNCTION, or the whole input when
// the input is bitcode already.
static std::string module_for(const std::string &data, const std::string &fn) {
    const uint8_t *b = (const uint8_t *)data.data();
    if (data.size() < 88 || memcmp(b, "MTLB", 4) != 0) return data;
    uint64_t flOff = rd64(b + 24), bcOff = rd64(b + 72);
    uint32_t count = rd32(b + flOff);
    const uint8_t *e = b + flOff + 4;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t size = rd32(e);
        const uint8_t *t = e + 4, *end = e + size;
        std::string name;
        uint64_t off = 0, len = 0;
        while (t < end && memcmp(t, "ENDT", 4) != 0) {
            uint16_t n = rd16(t + 4);
            const uint8_t *d = t + 6;
            if (!memcmp(t, "NAME", 4)) name.assign((const char *)d, strnlen((const char *)d, n));
            if (!memcmp(t, "OFFT", 4)) off = rd64(d + 16);
            if (!memcmp(t, "MDSZ", 4)) len = rd64(d);
            t = d + n;
        }
        if (name == fn) {
            fprintf(stderr, "airc: %s: module at bitcode+0x%llx, %llu bytes\n", fn.c_str(),
                    (unsigned long long)off, (unsigned long long)len);
            return data.substr(bcOff + off, len);
        }
        e += size;
    }
    fail("function not in metallib: " + fn);
}

// ---------------------------------------------------------------------------
// SPIR-V assembly writer

struct Emitter {
    const DataLayout &DL;
    std::set<std::string> caps{"Shader", "Int64", "PhysicalStorageBufferAddresses"};
    std::set<std::string> exts;
    std::ostringstream decor, globals, body, names;
    std::map<std::string, std::string> typeIds, constIds;
    std::map<const Value *, std::string> vals;
    std::map<const BasicBlock *, std::string> labels;
    std::vector<std::string> interface;
    unsigned next = 1;
    std::string glsl = "%glsl";

    explicit Emitter(const DataLayout &dl) : DL(dl) {}
    std::string fresh() { return "%" + std::to_string(next++); }

    std::string ty(const std::string &key, const std::string &decl) {
        auto it = typeIds.find(key);
        if (it != typeIds.end()) return it->second;
        std::string id = fresh();
        globals << id << " = " << decl << "\n";
        return typeIds[key] = id;
    }
    std::string tVoid() { return ty("void", "OpTypeVoid"); }
    std::string tBool() { return ty("bool", "OpTypeBool"); }
    std::string tInt(unsigned w) {
        if (w == 8) caps.insert("Int8");
        if (w == 16) caps.insert("Int16");
        return ty("i" + std::to_string(w), "OpTypeInt " + std::to_string(w) + " 0");
    }
    std::string tFloat(unsigned w) {
        if (w == 16) caps.insert("Float16");
        if (w == 64) caps.insert("Float64");
        return ty("f" + std::to_string(w), "OpTypeFloat " + std::to_string(w));
    }
    std::string tVec(const std::string &e, unsigned n) {
        return ty("v" + std::to_string(n) + e, "OpTypeVector " + e + " " + std::to_string(n));
    }
    // LLVM type -> SPIR-V type. Pointers into buffers are 64-bit integers.
    std::string type(Type *T) {
        if (T->isVoidTy()) return tVoid();
        if (T->isIntegerTy(1)) return tBool();
        if (T->isIntegerTy()) return tInt(T->getIntegerBitWidth());
        if (T->isHalfTy()) return tFloat(16);
        if (T->isFloatTy()) return tFloat(32);
        if (T->isDoubleTy()) return tFloat(64);
        if (T->isPointerTy()) {
            unsigned as = T->getPointerAddressSpace();
            if (as != 1 && as != 2) fail("pointer in address space " + std::to_string(as) + " (PoC handles 1 and 2)");
            return tInt(64);
        }
        if (auto *V = dyn_cast<FixedVectorType>(T)) return tVec(type(V->getElementType()), V->getNumElements());
        if (auto *S = dyn_cast<StructType>(T)) {
            std::string key = "struct", decl = "OpTypeStruct";
            for (Type *E : S->elements()) { std::string e = type(E); key += "_" + e; decl += " " + e; }
            return ty(key, decl);
        }
        if (auto *A = dyn_cast<ArrayType>(T)) {
            std::string e = type(A->getElementType());
            std::string n = cst(tInt(32), std::to_string(A->getNumElements()));
            return ty("arr" + e + "_" + n, "OpTypeArray " + e + " " + n);
        }
        std::string s; raw_string_ostream os(s); T->print(os);
        fail("unsupported type " + s);
    }
    std::string ptrTy(const std::string &storage, const std::string &pointee) {
        return ty("p" + storage + pointee, "OpTypePointer " + storage + " " + pointee);
    }
    std::string cst(const std::string &t, const std::string &lit) {
        std::string key = t + ":" + lit;
        auto it = constIds.find(key);
        if (it != constIds.end()) return it->second;
        std::string id = fresh();
        globals << id << " = OpConstant " << t << " " << lit << "\n";
        return constIds[key] = id;
    }
    std::string u32(uint32_t v) { return cst(tInt(32), std::to_string(v)); }
    std::string u64(uint64_t v) { return cst(tInt(64), std::to_string(v)); }

    std::string constant(Constant *C) {
        Type *T = C->getType();
        if (isa<UndefValue>(C) || isa<PoisonValue>(C)) {
            std::string t = type(T), key = "undef" + t;
            auto it = constIds.find(key);
            if (it != constIds.end()) return it->second;
            std::string id = fresh();
            globals << id << " = OpUndef " << t << "\n";
            return constIds[key] = id;
        }
        if (auto *CI = dyn_cast<ConstantInt>(C)) {
            if (T->isIntegerTy(1)) {
                std::string key = CI->isOne() ? "true" : "false";
                auto it = constIds.find(key);
                if (it != constIds.end()) return it->second;
                std::string id = fresh();
                globals << id << " = " << (CI->isOne() ? "OpConstantTrue " : "OpConstantFalse ") << tBool() << "\n";
                return constIds[key] = id;
            }
            return cst(type(T), std::to_string(CI->getZExtValue()));
        }
        if (auto *CF = dyn_cast<ConstantFP>(C)) {
            // %.17g round-trips every float and half value exactly.
            bool lost = false;
            APFloat v = CF->getValueAPF();
            v.convert(APFloat::IEEEdouble(), APFloat::rmNearestTiesToEven, &lost);
            char buf[64];
            snprintf(buf, sizeof buf, "%.17g", v.convertToDouble());
            return cst(type(T), buf);
        }
        if (isa<ConstantPointerNull>(C)) return u64(0);
        if (isa<ConstantAggregateZero>(C) || isa<ConstantDataVector>(C) || isa<ConstantVector>(C)) {
            std::string t = type(T), parts;
            auto *VT = cast<FixedVectorType>(T);
            for (unsigned i = 0; i < VT->getNumElements(); i++)
                parts += " " + constant(C->getAggregateElement(i));
            std::string key = "comp" + t + parts;
            auto it = constIds.find(key);
            if (it != constIds.end()) return it->second;
            std::string id = fresh();
            globals << id << " = OpConstantComposite " << t << parts << "\n";
            return constIds[key] = id;
        }
        std::string s; raw_string_ostream os(s); C->print(os);
        fail("unsupported constant " + s);
    }

    std::string val(Value *V) {
        if (auto *C = dyn_cast<Constant>(V)) return constant(C);
        auto it = vals.find(V);
        if (it == vals.end()) {
            // Forward reference (a phi operand): allocate the id now.
            std::string id = fresh();
            vals[V] = id;
            return id;
        }
        return it->second;
    }
    std::string def(Value *V) {
        auto it = vals.find(V);
        if (it != vals.end()) return it->second;
        return vals[V] = fresh();
    }
    std::string label(const BasicBlock *B) {
        auto it = labels.find(B);
        if (it != labels.end()) return it->second;
        return labels[B] = fresh();
    }
};

// ---------------------------------------------------------------------------
// AIR entry-point metadata (!air.kernel, !air.vertex, !air.fragment)

struct ArgInfo {
    std::string kind;   // air.buffer, air.vertex_input, air.position, ...
    std::string ident;  // e.g. generated(2uvDv2_f) for stage-in/out matching
    int location = -1;  // air.location_index, or render-target index
    std::set<std::string> flags;  // air.flat, air.no_perspective, ...
};

struct StageInfo {
    std::string stage;  // kernel, vertex, fragment
    std::vector<ArgInfo> outputs;
    std::map<unsigned, ArgInfo> args;
};

static ArgInfo parse_node(MDNode *A, unsigned first) {
    ArgInfo info;
    info.kind = cast<MDString>(A->getOperand(first))->getString().str();
    for (unsigned i = first + 1; i < A->getNumOperands(); i++) {
        auto *S = dyn_cast<MDString>(A->getOperand(i));
        if (!S) {
            // The first integer after air.render_target is its index.
            if (info.kind == "air.render_target" && info.location < 0)
                if (auto *C = mdconst::dyn_extract<ConstantInt>(A->getOperand(i)))
                    info.location = C->getZExtValue();
            continue;
        }
        StringRef str = S->getString();
        if (str == "air.location_index" && i + 1 < A->getNumOperands())
            info.location = mdconst::extract<ConstantInt>(A->getOperand(i + 1))->getZExtValue();
        else if (str == "air.arg_type_name" || str == "air.arg_name") i++;  // skip the value
        else if (!str.starts_with("air.") && info.ident.empty()) info.ident = str.str();
        else info.flags.insert(str.str());
    }
    return info;
}

static StageInfo stage_info(Module &M, Function *F) {
    for (const char *stage : {"kernel", "vertex", "fragment"}) {
        NamedMDNode *K = M.getNamedMetadata(std::string("air.") + stage);
        if (!K) continue;
        for (MDNode *N : K->operands()) {
            auto *FV = dyn_cast_or_null<ValueAsMetadata>(N->getOperand(0).get());
            if (!FV || FV->getValue() != F) continue;
            StageInfo si;
            si.stage = stage;
            for (const MDOperand &O : cast<MDNode>(N->getOperand(1).get())->operands())
                si.outputs.push_back(parse_node(cast<MDNode>(O.get()), 0));
            for (const MDOperand &AO : cast<MDNode>(N->getOperand(2).get())->operands()) {
                auto *A = cast<MDNode>(AO.get());
                unsigned idx = mdconst::extract<ConstantInt>(A->getOperand(0))->getZExtValue();
                si.args[idx] = parse_node(A, 1);
            }
            return si;
        }
    }
    fail("function is not an AIR kernel, vertex or fragment function: " + F->getName().str());
}

// Varying locations: Metal matches vertex outputs to fragment inputs by
// name, Vulkan by Location. The vertex function's output order assigns
// the locations; the fragment function looks its inputs up by name.
static std::map<std::string, unsigned> varying_locations(const StageInfo &vs) {
    std::map<std::string, unsigned> m;
    unsigned next = 0;
    for (const ArgInfo &o : vs.outputs)
        if (o.kind == "air.vertex_output") m[o.ident] = next++;
    return m;
}

// ---------------------------------------------------------------------------
// translation

struct Translator {
    Module &M;
    Function &F;
    Emitter E;
    StageInfo SI;
    std::map<std::string, unsigned> varyings;  // ident -> Location
    std::string pcVar, pcStruct, specX, specY, specZ, wgSize;
    std::map<std::string, std::string> builtinVars;
    std::map<const Value *, unsigned> texSlot, smpSlot;
    std::string texArr, smpArr, imgT, smpT;
    std::vector<std::pair<std::string, Type *>> outVars;  // per output: variable, AIR type
    DominatorTree DT;
    PostDominatorTree PDT;
    LoopInfo LI;

    Translator(Module &m, Function &f, const StageInfo &si, std::map<std::string, unsigned> vary)
        : M(m), F(f), E(m.getDataLayout()), SI(si), varyings(std::move(vary)) {}

    // Interface type: 16-bit floats are widened to 32 bits at stage
    // boundaries (the Thor lacks storageInputOutput16).
    Type *ioType(Type *T) {
        if (T->getScalarType()->isHalfTy()) {
            Type *f = Type::getFloatTy(T->getContext());
            if (auto *V = dyn_cast<FixedVectorType>(T)) return FixedVectorType::get(f, V->getNumElements());
            return f;
        }
        return T;
    }
    std::string ioVar(const std::string &storage, Type *T, const std::string &decoration) {
        std::string pt = E.ptrTy(storage, E.type(ioType(T)));
        std::string var = E.fresh();
        E.globals << var << " = OpVariable " << pt << " " << storage << "\n";
        E.decor << "OpDecorate " << var << " " << decoration << "\n";
        E.interface.push_back(var);
        return var;
    }
    std::string loadIO(const std::string &var, Type *T) {
        std::string r = E.fresh();
        E.body << r << " = OpLoad " << E.type(ioType(T)) << " " << var << "\n";
        if (ioType(T) == T) return r;
        std::string c = E.fresh();
        E.body << c << " = OpFConvert " << E.type(T) << " " << r << "\n";
        return c;
    }
    void storeIO(const std::string &var, Type *T, const std::string &v) {
        std::string x = v;
        if (ioType(T) != T) {
            x = E.fresh();
            E.body << x << " = OpFConvert " << E.type(ioType(T)) << " " << v << "\n";
        }
        E.body << "OpStore " << var << " " << x << "\n";
    }
    std::string resourceArray(bool sampler) {
        std::string &arr = sampler ? smpArr : texArr;
        if (!arr.empty()) return arr;
        if (imgT.empty()) {
            imgT = E.ty("img2d", "OpTypeImage " + E.tFloat(32) + " 2D 0 0 0 1 Unknown");
            smpT = E.ty("sampler", "OpTypeSampler");
        }
        std::string at = E.ty(std::string("arr16") + (sampler ? smpT : imgT),
                              "OpTypeArray " + (sampler ? smpT : imgT) + " " + E.u32(16));
        std::string pt = E.ptrTy("UniformConstant", at);
        arr = E.fresh();
        E.globals << arr << " = OpVariable " << pt << " UniformConstant\n";
        E.decor << "OpDecorate " << arr << " DescriptorSet 0\nOpDecorate " << arr << " Binding " << (sampler ? 1 : 0) << "\n";
        E.interface.push_back(arr);
        return arr;
    }

    std::string builtin(const std::string &name) {
        auto it = builtinVars.find(name);
        if (it != builtinVars.end()) return it->second;
        std::string t = (name == "LocalInvocationIndex" || name == "SubgroupLocalInvocationId" ||
                         name == "SubgroupId" || name == "SubgroupSize")
                            ? E.tInt(32) : E.tVec(E.tInt(32), 3);
        if (name.rfind("Subgroup", 0) == 0) E.caps.insert("GroupNonUniform");
        std::string pt = E.ptrTy("Input", t);  // emit the type before the variable
        std::string var = E.fresh();
        E.globals << var << " = OpVariable " << pt << " Input\n";
        E.decor << "OpDecorate " << var << " BuiltIn " << name << "\n";
        E.interface.push_back(var);
        return builtinVars[name] = var;
    }

    void setupInterface() {
        std::string u32 = E.tInt(32), u64 = E.tInt(64), v3 = E.tVec(u32, 3);
        if (SI.stage != "kernel") {
            // Graphics PoC ABI: push constants hold the vertex stage's buffer
            // slots 0..3 at offset 0 and the fragment stage's at offset 32.
            std::string arr4 = E.ty("pcarr4", "OpTypeArray " + u64 + " " + E.u32(4));
            E.decor << "OpDecorate " << arr4 << " ArrayStride 8\n";
            pcStruct = E.ty("pcgfx", "OpTypeStruct " + arr4 + " " + arr4);
            E.decor << "OpDecorate " << pcStruct << " Block\n"
                    << "OpMemberDecorate " << pcStruct << " 0 Offset 0\n"
                    << "OpMemberDecorate " << pcStruct << " 1 Offset 32\n";
            std::string pcPtr = E.ptrTy("PushConstant", pcStruct);
            pcVar = E.fresh();
            E.globals << pcVar << " = OpVariable " << pcPtr << " PushConstant\n";
            E.interface.push_back(pcVar);
            // Outputs, in AIR output order (the return value's members).
            Type *RT = F.getReturnType();
            for (unsigned i = 0; i < SI.outputs.size(); i++) {
                Type *T = RT->isStructTy() ? RT->getStructElementType(i) : RT;
                const ArgInfo &o = SI.outputs[i];
                std::string dec;
                if (o.kind == "air.position") dec = "BuiltIn Position";
                else if (o.kind == "air.point_size") dec = "BuiltIn PointSize";
                else if (o.kind == "air.vertex_output") dec = "Location " + std::to_string(varyings.at(o.ident));
                else if (o.kind == "air.render_target") dec = "Location " + std::to_string(o.location);
                else fail("PoC does not handle output kind " + o.kind);
                outVars.push_back({ioVar("Output", T, dec), T});
                if (T->isIntOrIntVectorTy() && o.kind == "air.vertex_output")
                    E.decor << "OpDecorate " << outVars.back().first << " Flat\n";
            }
            return;
        }
        // Push constants: buffer slots 0..3 (the PoC harness), then the grid.
        // A full implementation sizes the table from the pipeline layout.
        std::string arr4 = E.ty("pcarr4", "OpTypeArray " + u64 + " " + E.u32(4));
        E.decor << "OpDecorate " << arr4 << " ArrayStride 8\n";
        pcStruct = E.ty("pcstruct4", "OpTypeStruct " + arr4 + " " + v3);
        E.decor << "OpDecorate " << pcStruct << " Block\n"
                << "OpMemberDecorate " << pcStruct << " 0 Offset 0\n"
                << "OpMemberDecorate " << pcStruct << " 1 Offset 32\n";
        std::string pcPtr = E.ptrTy("PushConstant", pcStruct);
        pcVar = E.fresh();
        E.globals << pcVar << " = OpVariable " << pcPtr << " PushConstant\n";
        E.interface.push_back(pcVar);
        specX = E.fresh(); specY = E.fresh(); specZ = E.fresh();
        E.globals << specX << " = OpSpecConstant " << u32 << " 1\n"
                  << specY << " = OpSpecConstant " << u32 << " 1\n"
                  << specZ << " = OpSpecConstant " << u32 << " 1\n";
        E.decor << "OpDecorate " << specX << " SpecId 0\nOpDecorate " << specY
                << " SpecId 1\nOpDecorate " << specZ << " SpecId 2\n";
        wgSize = E.fresh();
        E.globals << wgSize << " = OpSpecConstantComposite " << v3 << " " << specX << " " << specY << " " << specZ << "\n";
    }

    // Narrow a uint3 built-in to the argument's AIR type (uint, uint2, uint3).
    std::string fitVec3(const std::string &v3val, Type *T) {
        std::string u32 = E.tInt(32);
        if (T->isIntegerTy(32)) {
            std::string r = E.fresh();
            E.body << r << " = OpCompositeExtract " << u32 << " " << v3val << " 0\n";
            return r;
        }
        if (auto *VT = dyn_cast<FixedVectorType>(T)) {
            if (VT->getNumElements() == 3) return v3val;
            std::string r = E.fresh();
            E.body << r << " = OpVectorShuffle " << E.tVec(u32, 2) << " " << v3val << " " << v3val << " 0 1\n";
            return r;
        }
        fail("unsupported built-in argument type");
    }

    void prologue(const std::map<unsigned, ArgInfo> &args) {
        std::string u32 = E.tInt(32), u64 = E.tInt(64), v3 = E.tVec(u32, 3);
        for (Argument &A : F.args()) {
            auto it = args.find(A.getArgNo());
            if (it == args.end()) fail("argument without AIR metadata");
            const ArgInfo &ai = it->second;
            std::string r;
            if (SI.stage != "kernel" && ai.kind == "air.buffer") {
                if (ai.location < 0 || ai.location > 3) fail("PoC ABI has buffer slots 0..3");
                std::string p = E.fresh();
                E.body << p << " = OpAccessChain " << E.ptrTy("PushConstant", u64) << " " << pcVar << " "
                       << E.u32(SI.stage == "vertex" ? 0 : 1) << " " << E.u32(ai.location) << "\n";
                r = E.fresh();
                E.body << r << " = OpLoad " << u64 << " " << p << "\n";
            } else if (ai.kind == "air.texture" || ai.kind == "air.sampler") {
                if (ai.location < 0 || ai.location > 15) fail("PoC has texture and sampler slots 0..15");
                (ai.kind == "air.texture" ? texSlot : smpSlot)[&A] = ai.location;
                resourceArray(ai.kind == "air.sampler");
                continue;
            } else if (ai.kind == "air.vertex_input") {
                r = loadIO(ioVar("Input", A.getType(), "Location " + std::to_string(ai.location)), A.getType());
            } else if (ai.kind == "air.fragment_input") {
                auto lit = varyings.find(ai.ident);
                if (lit == varyings.end()) fail("fragment input " + ai.ident + " has no vertex output (use --link-vs)");
                std::string var = ioVar("Input", A.getType(), "Location " + std::to_string(lit->second));
                if (ai.flags.count("air.flat") || A.getType()->isIntOrIntVectorTy())
                    E.decor << "OpDecorate " << var << " Flat\n";
                if (ai.flags.count("air.no_perspective")) E.decor << "OpDecorate " << var << " NoPerspective\n";
                if (ai.flags.count("air.centroid")) E.decor << "OpDecorate " << var << " Centroid\n";
                r = loadIO(var, A.getType());
            } else if (ai.kind == "air.position" && SI.stage == "fragment") {
                r = loadIO(ioVar("Input", A.getType(), "BuiltIn FragCoord"), A.getType());
            } else if (ai.kind == "air.vertex_id" || ai.kind == "air.instance_id") {
                r = loadIO(ioVar("Input", A.getType(), ai.kind == "air.vertex_id" ? "BuiltIn VertexIndex"
                                                                                  : "BuiltIn InstanceIndex"), A.getType());
            } else if (ai.kind == "air.front_facing") {
                r = loadIO(ioVar("Input", A.getType(), "BuiltIn FrontFacing"), A.getType());
            } else if (ai.kind == "air.buffer") {
                if (A.getType()->getPointerAddressSpace() == 3)
                    fail("threadgroup-memory arguments (address space 3) are not in the PoC");
                if (ai.location < 0 || ai.location > 3) fail("PoC ABI has buffer slots 0..3");
                std::string p = E.fresh();
                E.body << p << " = OpAccessChain " << E.ptrTy("PushConstant", u64) << " " << pcVar << " "
                       << E.u32(0) << " " << E.u32(ai.location) << "\n";
                r = E.fresh();
                E.body << r << " = OpLoad " << u64 << " " << p << "\n";
            } else if (ai.kind == "air.threads_per_grid") {
                std::string p = E.fresh(), g = E.fresh();
                E.body << p << " = OpAccessChain " << E.ptrTy("PushConstant", v3) << " " << pcVar << " " << E.u32(1) << "\n";
                E.body << g << " = OpLoad " << v3 << " " << p << "\n";
                r = fitVec3(g, A.getType());
            } else if (ai.kind == "air.threads_per_threadgroup") {
                r = fitVec3(wgSize, A.getType());
            } else {
                static const std::map<std::string, std::string> vec3 = {
                    {"air.thread_position_in_grid", "GlobalInvocationId"},
                    {"air.thread_position_in_threadgroup", "LocalInvocationId"},
                    {"air.threadgroup_position_in_grid", "WorkgroupId"},
                    {"air.threadgroups_per_grid", "NumWorkgroups"}};
                static const std::map<std::string, std::string> scalar = {
                    {"air.thread_index_in_threadgroup", "LocalInvocationIndex"},
                    {"air.thread_index_in_simdgroup", "SubgroupLocalInvocationId"},
                    {"air.simdgroup_index_in_threadgroup", "SubgroupId"},
                    {"air.threads_per_simdgroup", "SubgroupSize"}};
                if (vec3.count(ai.kind)) {
                    std::string g = E.fresh();
                    E.body << g << " = OpLoad " << v3 << " " << builtin(vec3.at(ai.kind)) << "\n";
                    r = fitVec3(g, A.getType());
                } else if (scalar.count(ai.kind)) {
                    r = E.fresh();
                    E.body << r << " = OpLoad " << u32 << " " << builtin(scalar.at(ai.kind)) << "\n";
                } else {
                    fail("PoC does not handle kernel argument kind " + ai.kind);
                }
            }
            // Bind the argument to the computed id.
            auto vit = E.vals.find(&A);
            if (vit != E.vals.end()) {
                E.body << vit->second << " = OpCopyObject " << E.type(A.getType()) << " " << r << "\n";
            } else {
                E.vals[&A] = r;
            }
        }
    }

    std::string ext(const std::string &resT, const std::string &op, const std::vector<std::string> &a) {
        std::string r = E.fresh();
        E.body << r << " = OpExtInst " << resT << " " << E.glsl << " " << op;
        for (auto &x : a) E.body << " " << x;
        E.body << "\n";
        return r;
    }

    // Byte offset of a GEP, as a 64-bit integer id.
    std::string gepAddress(GetElementPtrInst *G) {
        std::string u64 = E.tInt(64);
        std::string addr = E.val(G->getPointerOperand());
        for (auto GTI = gep_type_begin(G), GTE = gep_type_end(G); GTI != GTE; ++GTI) {
            Value *Idx = GTI.getOperand();
            std::string off;
            if (StructType *ST = GTI.getStructTypeOrNull()) {
                unsigned field = cast<ConstantInt>(Idx)->getZExtValue();
                uint64_t o = E.DL.getStructLayout(ST)->getElementOffset(field);
                if (!o) continue;
                off = E.u64(o);
            } else {
                uint64_t size = E.DL.getTypeAllocSize(GTI.getIndexedType());
                if (auto *CI = dyn_cast<ConstantInt>(Idx)) {
                    int64_t o = CI->getSExtValue() * (int64_t)size;
                    if (!o) continue;
                    off = E.u64((uint64_t)o);
                } else {
                    std::string i = E.val(Idx);
                    if (!Idx->getType()->isIntegerTy(64)) {
                        std::string w = E.fresh();
                        E.body << w << " = OpSConvert " << u64 << " " << i << "\n";
                        i = w;
                    }
                    off = E.fresh();
                    E.body << off << " = OpIMul " << u64 << " " << i << " " << E.u64(size) << "\n";
                }
            }
            std::string n = E.fresh();
            E.body << n << " = OpIAdd " << u64 << " " << addr << " " << off << "\n";
            addr = n;
        }
        return addr;
    }

    std::string psbPointer(Value *P, Type *T) {
        std::string p = E.fresh();
        E.body << p << " = OpConvertUToPtr " << E.ptrTy("PhysicalStorageBuffer", E.type(T)) << " " << E.val(P) << "\n";
        unsigned bits = E.DL.getTypeSizeInBits(T->getScalarType());
        if (bits == 8) E.caps.insert("StorageBuffer8BitAccess");
        if (bits == 16) E.caps.insert("StorageBuffer16BitAccess");
        return p;
    }

    void call(CallInst *C) {
        Function *Fn = C->getCalledFunction();
        if (!Fn) fail("indirect call");
        StringRef n = Fn->getName();
        if (n.starts_with("llvm.lifetime") || n.starts_with("llvm.assume") ||
            n.starts_with("llvm.experimental.noalias.scope.decl") || n.starts_with("llvm.dbg"))
            return;
        std::string rt = C->getType()->isVoidTy() ? "" : E.type(C->getType());
        auto arg = [&](unsigned i) { return E.val(C->getArgOperand(i)); };
        std::string r;
        // air.convert.<dk>.<dt>.<sk>.<st>: k is f (float), s (signed), u (unsigned).
        if (n.starts_with("air.convert.")) {
            SmallVector<StringRef, 6> p;
            n.split(p, '.');
            if (p.size() < 6) fail("bad convert name " + n.str());
            char dk = p[2][0], sk = p[4][0];
            const char *op = nullptr;
            if (dk == 'f' && sk == 'f') op = "OpFConvert";
            else if (dk == 'f' && sk == 'u') op = "OpConvertUToF";
            else if (dk == 'f' && sk == 's') op = "OpConvertSToF";
            else if (dk == 'u' && sk == 'f') op = "OpConvertFToU";
            else if (dk == 's' && sk == 'f') op = "OpConvertFToS";
            else op = (sk == 's') ? "OpSConvert" : "OpUConvert";
            r = E.def(C);
            E.body << r << " = " << op << " " << rt << " " << arg(0) << "\n";
            return;
        }
        // air.sample_texture_2d.<T>(texture, sampler, float2 coord, i1, int2 offset,
        //   i1 explicit-LOD, float bias-or-LOD, float min-LOD clamp, i32)
        // -> { <4 x T>, i8 } (spec section 3.4; the i8 is returned as 0 here).
        if (n.starts_with("air.sample_texture_2d.")) {
            auto ts = texSlot.find(C->getArgOperand(0)), ss = smpSlot.find(C->getArgOperand(1));
            if (ts == texSlot.end() || ss == smpSlot.end()) fail("sample with a texture or sampler that is not a direct argument");
            std::string f32 = E.tFloat(32), v4 = E.tVec(f32, 4);
            std::string sit = E.ty("sampledimg", "OpTypeSampledImage " + imgT);
            std::string ip = E.ptrTy("UniformConstant", imgT), sp = E.ptrTy("UniformConstant", smpT);
            std::string a = E.fresh(), img = E.fresh(), b = E.fresh(), smp = E.fresh(), si = E.fresh(), res = E.fresh();
            E.body << a << " = OpAccessChain " << ip << " " << texArr << " " << E.u32(ts->second) << "\n"
                   << img << " = OpLoad " << imgT << " " << a << "\n"
                   << b << " = OpAccessChain " << sp << " " << smpArr << " " << E.u32(ss->second) << "\n"
                   << smp << " = OpLoad " << smpT << " " << b << "\n"
                   << si << " = OpSampledImage " << sit << " " << img << " " << smp << "\n";
            bool explicitLod = cast<ConstantInt>(C->getArgOperand(5))->isOne();
            auto *off = dyn_cast<Constant>(C->getArgOperand(4));
            if (!off) fail("non-constant texel offset");
            bool hasOff = !off->isNullValue();
            auto *bias = dyn_cast<ConstantFP>(C->getArgOperand(6));
            bool hasBias = !explicitLod && !(bias && bias->isZero());
            std::string ops;
            std::vector<std::string> opv;
            if (hasBias) { ops += "Bias"; opv.push_back(arg(6)); }
            if (explicitLod) { ops += "Lod"; opv.push_back(arg(6)); }
            if (hasOff) { ops += ops.empty() ? "ConstOffset" : "|ConstOffset"; opv.push_back(arg(4)); }
            if (hasBias && explicitLod) fail("bias with explicit LOD");
            E.body << res << " = " << (explicitLod ? "OpImageSampleExplicitLod " : "OpImageSampleImplicitLod ")
                   << v4 << " " << si << " " << arg(2);
            if (!ops.empty()) { E.body << " " << ops; for (auto &x : opv) E.body << " " << x; }
            E.body << "\n";
            Type *VT = cast<StructType>(C->getType())->getElementType(0);
            std::string vec = res;
            if (VT->getScalarType()->isHalfTy()) {
                vec = E.fresh();
                E.body << vec << " = OpFConvert " << E.type(VT) << " " << res << "\n";
            }
            r = E.def(C);
            E.body << r << " = OpCompositeConstruct " << rt << " " << vec << " " << E.cst(E.tInt(8), "0") << "\n";
            return;
        }
        static const std::map<std::string, std::string> glslOps = {
            {"fmax", "FMax"}, {"fmin", "FMin"}, {"fabs", "FAbs"}, {"sqrt", "Sqrt"}, {"rsqrt", "InverseSqrt"},
            {"floor", "Floor"}, {"ceil", "Ceil"}, {"trunc", "Trunc"}, {"fract", "Fract"}, {"round", "Round"},
            {"rint", "RoundEven"}, {"sin", "Sin"}, {"cos", "Cos"}, {"tan", "Tan"}, {"asin", "Asin"},
            {"acos", "Acos"}, {"atan", "Atan"}, {"atan2", "Atan2"}, {"exp", "Exp"}, {"exp2", "Exp2"},
            {"log", "Log"}, {"log2", "Log2"}, {"pow", "Pow"}, {"powr", "Pow"}, {"fma", "Fma"},
            {"mix", "FMix"}, {"sign", "FSign"}, {"clamp", "FClamp"}};
        if (n.starts_with("air.")) {
            StringRef base = n.drop_front(4);
            base = base.take_until([](char c) { return c == '.'; });
            bool fast = base.consume_front("fast_");
            (void)fast;  // fast and precise variants map to the same GLSL op here
            base.consume_front("precise_");
            auto it = glslOps.find(base.str());
            if (it != glslOps.end()) {
                std::vector<std::string> a;
                for (unsigned i = 0; i < C->arg_size(); i++) a.push_back(arg(i));
                r = ext(rt, it->second, a);
                E.vals[C] = r;
                return;
            }
            if (base == "saturate") {
                std::string z = E.constant(ConstantFP::get(C->getType(), 0.0));
                std::string o = E.constant(ConstantFP::get(C->getType(), 1.0));
                E.vals[C] = ext(rt, "FClamp", {arg(0), z, o});
                return;
            }
            if (base == "dot") {
                r = E.def(C);
                E.body << r << " = OpDot " << rt << " " << arg(0) << " " << arg(1) << "\n";
                return;
            }
        }
        if (n.starts_with("llvm.fmuladd")) { E.vals[C] = ext(rt, "Fma", {arg(0), arg(1), arg(2)}); return; }
        if (n.starts_with("llvm.umax")) { E.vals[C] = ext(rt, "UMax", {arg(0), arg(1)}); return; }
        if (n.starts_with("llvm.umin")) { E.vals[C] = ext(rt, "UMin", {arg(0), arg(1)}); return; }
        if (n.starts_with("llvm.smax")) { E.vals[C] = ext(rt, "SMax", {arg(0), arg(1)}); return; }
        if (n.starts_with("llvm.smin")) { E.vals[C] = ext(rt, "SMin", {arg(0), arg(1)}); return; }
        fail("PoC does not handle call to " + n.str());
    }

    void instruction(Instruction &I) {
        std::string t = I.getType()->isVoidTy() ? "" : E.type(I.getType());
        if (auto *B = dyn_cast<BinaryOperator>(&I)) {
            bool isBool = I.getType()->isIntOrIntVectorTy(1);
            const char *op = nullptr;
            switch (B->getOpcode()) {
            case Instruction::Add: op = "OpIAdd"; break;
            case Instruction::Sub: op = "OpISub"; break;
            case Instruction::Mul: op = "OpIMul"; break;
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
            default: fail("binary operator");
            }
            E.body << E.def(&I) << " = " << op << " " << t << " " << E.val(I.getOperand(0)) << " "
                   << E.val(I.getOperand(1)) << "\n";
            return;
        }
        if (auto *Ng = dyn_cast<UnaryOperator>(&I)) {
            E.body << E.def(&I) << " = OpFNegate " << t << " " << E.val(Ng->getOperand(0)) << "\n";
            return;
        }
        if (auto *C = dyn_cast<ICmpInst>(&I)) {
            static const std::map<CmpInst::Predicate, const char *> ops = {
                {CmpInst::ICMP_EQ, "OpIEqual"}, {CmpInst::ICMP_NE, "OpINotEqual"},
                {CmpInst::ICMP_UGT, "OpUGreaterThan"}, {CmpInst::ICMP_UGE, "OpUGreaterThanEqual"},
                {CmpInst::ICMP_ULT, "OpULessThan"}, {CmpInst::ICMP_ULE, "OpULessThanEqual"},
                {CmpInst::ICMP_SGT, "OpSGreaterThan"}, {CmpInst::ICMP_SGE, "OpSGreaterThanEqual"},
                {CmpInst::ICMP_SLT, "OpSLessThan"}, {CmpInst::ICMP_SLE, "OpSLessThanEqual"}};
            const char *op = ops.at(C->getPredicate());
            if (C->getOperand(0)->getType()->isIntOrIntVectorTy(1))
                op = C->getPredicate() == CmpInst::ICMP_EQ ? "OpLogicalEqual" : "OpLogicalNotEqual";
            E.body << E.def(&I) << " = " << op << " " << t << " " << E.val(C->getOperand(0)) << " "
                   << E.val(C->getOperand(1)) << "\n";
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
            auto it = ops.find(C->getPredicate());
            if (it == ops.end()) fail("fcmp predicate");
            E.body << E.def(&I) << " = " << it->second << " " << t << " " << E.val(C->getOperand(0)) << " "
                   << E.val(C->getOperand(1)) << "\n";
            return;
        }
        if (auto *Cst = dyn_cast<CastInst>(&I)) {
            Value *S = Cst->getOperand(0);
            Type *ST = S->getType(), *DT = I.getType();
            std::string s = E.val(S);
            switch (Cst->getOpcode()) {
            case Instruction::ZExt:
            case Instruction::SExt:
                if (ST->isIntOrIntVectorTy(1)) {
                    Constant *One = Cst->getOpcode() == Instruction::ZExt ? ConstantInt::get(DT, 1)
                                                                         : Constant::getAllOnesValue(DT);
                    E.body << E.def(&I) << " = OpSelect " << t << " " << s << " " << E.constant(One) << " "
                           << E.constant(Constant::getNullValue(DT)) << "\n";
                } else {
                    E.body << E.def(&I) << " = " << (Cst->getOpcode() == Instruction::ZExt ? "OpUConvert" : "OpSConvert")
                           << " " << t << " " << s << "\n";
                }
                return;
            case Instruction::Trunc:
                if (DT->isIntOrIntVectorTy(1)) {
                    std::string m = E.fresh();
                    E.body << m << " = OpBitwiseAnd " << E.type(ST) << " " << s << " " << E.constant(ConstantInt::get(ST, 1)) << "\n";
                    E.body << E.def(&I) << " = OpINotEqual " << t << " " << m << " " << E.constant(Constant::getNullValue(ST)) << "\n";
                } else {
                    E.body << E.def(&I) << " = OpUConvert " << t << " " << s << "\n";
                }
                return;
            case Instruction::FPToUI: E.body << E.def(&I) << " = OpConvertFToU " << t << " " << s << "\n"; return;
            case Instruction::FPToSI: E.body << E.def(&I) << " = OpConvertFToS " << t << " " << s << "\n"; return;
            case Instruction::UIToFP: E.body << E.def(&I) << " = OpConvertUToF " << t << " " << s << "\n"; return;
            case Instruction::SIToFP: E.body << E.def(&I) << " = OpConvertSToF " << t << " " << s << "\n"; return;
            case Instruction::FPTrunc:
            case Instruction::FPExt: E.body << E.def(&I) << " = OpFConvert " << t << " " << s << "\n"; return;
            case Instruction::BitCast:
            case Instruction::AddrSpaceCast:
                if (E.type(ST) == t) { E.vals[&I] = s; return; }
                E.body << E.def(&I) << " = OpBitcast " << t << " " << s << "\n";
                return;
            case Instruction::PtrToInt:
            case Instruction::IntToPtr:
                if (E.type(ST) == t) { E.vals[&I] = s; return; }
                E.body << E.def(&I) << " = OpUConvert " << t << " " << s << "\n";
                return;
            default: fail("cast");
            }
        }
        if (auto *G = dyn_cast<GetElementPtrInst>(&I)) {
            std::string a = gepAddress(G);
            auto it = E.vals.find(&I);
            if (it != E.vals.end()) E.body << it->second << " = OpCopyObject " << t << " " << a << "\n";
            else E.vals[&I] = a;
            return;
        }
        if (auto *L = dyn_cast<LoadInst>(&I)) {
            std::string p = psbPointer(L->getPointerOperand(), L->getType());
            E.body << E.def(&I) << " = OpLoad " << t << " " << p << " Aligned " << L->getAlign().value() << "\n";
            return;
        }
        if (auto *S = dyn_cast<StoreInst>(&I)) {
            std::string p = psbPointer(S->getPointerOperand(), S->getValueOperand()->getType());
            E.body << "OpStore " << p << " " << E.val(S->getValueOperand()) << " Aligned " << S->getAlign().value() << "\n";
            return;
        }
        if (auto *Sel = dyn_cast<SelectInst>(&I)) {
            E.body << E.def(&I) << " = OpSelect " << t << " " << E.val(Sel->getCondition()) << " "
                   << E.val(Sel->getTrueValue()) << " " << E.val(Sel->getFalseValue()) << "\n";
            return;
        }
        if (auto *P = dyn_cast<PHINode>(&I)) {
            E.body << E.def(&I) << " = OpPhi " << t;
            for (unsigned i = 0; i < P->getNumIncomingValues(); i++)
                E.body << " " << E.val(P->getIncomingValue(i)) << " " << E.label(P->getIncomingBlock(i));
            E.body << "\n";
            return;
        }
        if (auto *X = dyn_cast<ExtractElementInst>(&I)) {
            if (auto *CI = dyn_cast<ConstantInt>(X->getIndexOperand()))
                E.body << E.def(&I) << " = OpCompositeExtract " << t << " " << E.val(X->getVectorOperand()) << " " << CI->getZExtValue() << "\n";
            else
                E.body << E.def(&I) << " = OpVectorExtractDynamic " << t << " " << E.val(X->getVectorOperand()) << " " << E.val(X->getIndexOperand()) << "\n";
            return;
        }
        if (auto *X = dyn_cast<InsertElementInst>(&I)) {
            if (auto *CI = dyn_cast<ConstantInt>(X->getOperand(2)))
                E.body << E.def(&I) << " = OpCompositeInsert " << t << " " << E.val(X->getOperand(1)) << " " << E.val(X->getOperand(0)) << " " << CI->getZExtValue() << "\n";
            else
                E.body << E.def(&I) << " = OpVectorInsertDynamic " << t << " " << E.val(X->getOperand(0)) << " " << E.val(X->getOperand(1)) << " " << E.val(X->getOperand(2)) << "\n";
            return;
        }
        if (auto *X = dyn_cast<ShuffleVectorInst>(&I)) {
            E.body << E.def(&I) << " = OpVectorShuffle " << t << " " << E.val(X->getOperand(0)) << " " << E.val(X->getOperand(1));
            for (int m : X->getShuffleMask()) E.body << " " << (m < 0 ? 0xFFFFFFFFu : (unsigned)m);
            E.body << "\n";
            return;
        }
        if (auto *X = dyn_cast<ExtractValueInst>(&I)) {
            E.body << E.def(&I) << " = OpCompositeExtract " << t << " " << E.val(X->getAggregateOperand());
            for (unsigned i : X->indices()) E.body << " " << i;
            E.body << "\n";
            return;
        }
        if (auto *X = dyn_cast<InsertValueInst>(&I)) {
            E.body << E.def(&I) << " = OpCompositeInsert " << t << " " << E.val(X->getInsertedValueOperand()) << " " << E.val(X->getAggregateOperand());
            for (unsigned i : X->indices()) E.body << " " << i;
            E.body << "\n";
            return;
        }
        if (auto *C = dyn_cast<CallInst>(&I)) { call(C); return; }
        std::string s; raw_string_ostream os(s); I.print(os);
        fail("PoC does not handle instruction: " + s);
    }

    // Structured control flow: loop headers get OpLoopMerge (merge = the
    // unique exit block, continue = the dedicated back-edge block created by
    // normalize()); other conditional branches get OpSelectionMerge at the
    // immediate post-dominator, unless the branch only leaves the loop.
    void terminator(BasicBlock &B) {
        Instruction *T = B.getTerminator();
        Loop *L = LI.getLoopFor(&B);
        bool header = L && L->getHeader() == &B;
        if (header) {
            BasicBlock *exit = L->getUniqueExitBlock();
            BasicBlock *latch = L->getLoopLatch();
            if (!exit || !latch) fail("loop without unique exit or latch");
            E.body << "OpLoopMerge " << E.label(exit) << " " << E.label(latch) << " None\n";
        }
        if (auto *Br = dyn_cast<BranchInst>(T)) {
            if (Br->isUnconditional()) {
                E.body << "OpBranch " << E.label(Br->getSuccessor(0)) << "\n";
                return;
            }
            BasicBlock *t0 = Br->getSuccessor(0), *t1 = Br->getSuccessor(1);
            if (!header) {
                auto escapes = [&](BasicBlock *S) {
                    return L && (S == L->getUniqueExitBlock() || S == L->getLoopLatch());
                };
                bool e0 = escapes(t0), e1 = escapes(t1);
                if (!(e0 && e1)) {
                    BasicBlock *merge = nullptr;
                    if (e0) merge = t1;
                    else if (e1) merge = t0;
                    else {
                        auto *N = PDT.getNode(&B);
                        merge = N && N->getIDom() ? N->getIDom()->getBlock() : nullptr;
                    }
                    if (!merge) fail("no merge block for a selection");
                    E.body << "OpSelectionMerge " << E.label(merge) << " None\n";
                }
            }
            E.body << "OpBranchConditional " << E.val(Br->getCondition()) << " " << E.label(t0) << " "
                   << E.label(t1) << "\n";
            return;
        }
        if (auto *R = dyn_cast<ReturnInst>(T)) {
            if (Value *V = R->getReturnValue()) {
                std::string v = E.val(V);
                for (unsigned i = 0; i < outVars.size(); i++) {
                    std::string m = v;
                    if (V->getType()->isStructTy()) {
                        m = E.fresh();
                        E.body << m << " = OpCompositeExtract " << E.type(outVars[i].second) << " " << v << " " << i << "\n";
                    }
                    storeIO(outVars[i].first, outVars[i].second, m);
                }
            }
            E.body << "OpReturn\n";
            return;
        }
        if (isa<UnreachableInst>(T)) { E.body << "OpUnreachable\n"; return; }
        fail("terminator");
    }

    std::string run(const std::string &entryName) {
        setupInterface();
        auto &args = SI.args;
        DT.recalculate(F);
        PDT.recalculate(F);
        LI.analyze(DT);
        std::string fnT = E.ty("fnvoid", "OpTypeFunction " + E.tVoid());
        std::string main = E.fresh();
        E.body << main << " = OpFunction " << E.tVoid() << " None " << fnT << "\n";
        bool first = true;
        ReversePostOrderTraversal<Function *> RPOT(&F);
        for (BasicBlock *B : RPOT) {
            E.body << E.label(B) << " = OpLabel\n";
            if (first) { prologue(args); first = false; }
            for (Instruction &I : *B) {
                if (I.isTerminator()) break;
                instruction(I);
            }
            terminator(*B);
        }
        E.body << "OpFunctionEnd\n";

        std::ostringstream out;
        out << "; SPIR-V produced by Ycode airc (R8 PoC) from AIR function " << F.getName().str() << "\n";
        for (auto &c : E.caps) out << "OpCapability " << c << "\n";
        for (auto &x : E.exts) out << "OpExtension \"" << x << "\"\n";
        out << E.glsl << " = OpExtInstImport \"GLSL.std.450\"\n";
        out << "OpMemoryModel PhysicalStorageBuffer64 GLSL450\n";
        const char *model = SI.stage == "kernel" ? "GLCompute" : SI.stage == "vertex" ? "Vertex" : "Fragment";
        out << "OpEntryPoint " << model << " " << main << " \"" << entryName << "\"";
        for (auto &v : E.interface) out << " " << v;
        out << "\n";
        if (SI.stage == "kernel")
            out << "OpExecutionModeId " << main << " LocalSizeId " << specX << " " << specY << " " << specZ << "\n";
        if (SI.stage == "fragment") out << "OpExecutionMode " << main << " OriginUpperLeft\n";
        out << E.decor.str() << E.globals.str() << E.body.str();
        return out.str();
    }
};

// CFG normalization with LLVM's own passes: switches become branches, one
// return block, loop-simplify form (preheader, single latch, dedicated
// exits), and a dedicated back-edge block per loop (the SPIR-V continue
// target).
static void normalize(Function &F) {
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
    FunctionPassManager FPM;
    FPM.addPass(LowerSwitchPass());
    FPM.addPass(UnifyFunctionExitNodesPass());
    FPM.addPass(LoopSimplifyPass());
    FPM.run(F, FAM);
    DominatorTree DT(F);
    LoopInfo LI(DT);
    std::vector<std::pair<BasicBlock *, BasicBlock *>> edges;
    for (Loop *L : LI.getLoopsInPreorder())
        if (BasicBlock *latch = L->getLoopLatch())
            if (latch == L->getHeader() || latch->getTerminator()->getNumSuccessors() > 1)
                edges.push_back({latch, L->getHeader()});
    for (auto &e : edges) SplitEdge(e.first, e.second);
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: airc IN.metallib|IN.bc FUNCTION OUT.spv [--asm OUT.spvasm] [--opt] [--link-vs VS]\n");
        return 2;
    }
    std::string asmPath, linkVS;
    bool opt = false;
    for (int i = 4; i < argc; i++) {
        if (!strcmp(argv[i], "--asm") && i + 1 < argc) asmPath = argv[++i];
        else if (!strcmp(argv[i], "--opt")) opt = true;
        else if (!strcmp(argv[i], "--link-vs") && i + 1 < argc) linkVS = argv[++i];
    }
    std::ifstream in(argv[1], std::ios::binary);
    std::string data((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    std::string bc = module_for(data, argv[2]);

    LLVMContext ctx;
    auto mod = parseBitcodeFile(MemoryBufferRef(StringRef(bc), "air"), ctx);
    if (!mod) fail("bitcode: " + toString(mod.takeError()));
    Module &M = **mod;
    fprintf(stderr, "airc: triple %s, producer %s\n", M.getTargetTriple().c_str(),
            M.getNamedMetadata("llvm.ident")
                ? cast<MDString>(M.getNamedMetadata("llvm.ident")->getOperand(0)->getOperand(0))->getString().str().c_str()
                : "?");
    Function *F = M.getFunction(argv[2]);
    if (!F || F->isDeclaration()) fail(std::string("no definition of ") + argv[2]);
    StageInfo SI = stage_info(M, F);
    std::map<std::string, unsigned> vary;
    if (SI.stage == "vertex") vary = varying_locations(SI);
    if (SI.stage == "fragment" && !linkVS.empty()) {
        // The vertex function may live in another module of the metallib.
        std::string vbc = module_for(data, linkVS);
        LLVMContext vctx;
        auto vmod = parseBitcodeFile(MemoryBufferRef(StringRef(vbc), "air-vs"), vctx);
        if (!vmod) fail("bitcode: " + toString(vmod.takeError()));
        Function *VF = (*vmod)->getFunction(linkVS);
        if (!VF) fail("no vertex function " + linkVS);
        vary = varying_locations(stage_info(**vmod, VF));
    }
    fprintf(stderr, "airc: %s function, %zu outputs, %zu varyings\n", SI.stage.c_str(), SI.outputs.size(), vary.size());
    normalize(*F);
    Translator T(M, *F, SI, vary);
    std::string text = T.run(argv[2]);
    if (!asmPath.empty()) std::ofstream(asmPath) << text;

    spvtools::SpirvTools tools(SPV_ENV_VULKAN_1_3);
    tools.SetMessageConsumer([](spv_message_level_t, const char *, const spv_position_t &pos, const char *msg) {
        fprintf(stderr, "spirv-tools: %zu: %s\n", pos.index, msg);
    });
    std::vector<uint32_t> words;
    if (!tools.Assemble(text, &words, SPV_TEXT_TO_BINARY_OPTION_PRESERVE_NUMERIC_IDS)) fail("assembly failed");
    if (!tools.Validate(words)) fail("validation failed");
    fprintf(stderr, "airc: valid SPIR-V, %zu words\n", words.size());
    if (opt) {
        spvtools::Optimizer o(SPV_ENV_VULKAN_1_3);
        o.RegisterPerformancePasses();
        std::vector<uint32_t> out;
        if (!o.Run(words.data(), words.size(), &out)) fail("optimizer failed");
        if (!tools.Validate(out)) fail("optimized module failed validation");
        fprintf(stderr, "airc: optimized, %zu words\n", out.size());
        words.swap(out);
    }
    std::ofstream(argv[3], std::ios::binary).write((const char *)words.data(), words.size() * 4);
    return 0;
}
