// translator_impl.h: the translator's internal state, shared by
// translate.cpp (module structure, memory, instructions, stage interface)
// and intrinsics.cpp (air.* and llvm.* calls).
#pragma once

#include "abi.h"
#include "air.h"
#include "emitter.h"
#include "error.h"
#include "json.h"
#include "prepare.h"
#include "translator.h"

#include "llvm/IR/DataLayout.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"

#include <map>
#include <set>
#include <string>
#include <vector>

namespace airc {

// Address spaces (metal-shaders.md section 3.3).
enum AddrSpace : unsigned { kPrivate = 0, kDevice = 1, kConstant = 2, kThreadgroup = 3, kImageblock = 4 };

// An image type in the bindless heap.
struct ImageKind {
    std::string dim;        // 1D, 2D, 3D, Cube, Buffer
    bool arrayed = false, ms = false, depth = false;
    char sampled = 'f';     // f float, i int, u uint
};

struct Translator {
    llvm::Module &M;
    llvm::Function &F;
    EntryInfo EI;
    const llvm::DataLayout &DL;
    const TranslateOptions &opts;
    Emitter E;
    StructurePlan plan;

    std::map<const llvm::Value *, std::string> vals;
    std::map<const llvm::BasicBlock *, std::string> labels;

    // Interface.
    std::string pcVar, tableAddr;              // push-constant block, this stage's table address
    std::map<unsigned, std::string> tableLoads;  // entry -> u64 id (prologue)
    std::map<std::string, std::string> builtins; // BuiltIn name -> variable
    struct Output { std::string var; llvm::Type *type; std::string ioType; };
    std::vector<Output> outputs;
    std::string wgSizeId, specX, specY, specZ;   // kernels
    unsigned nextFragmentLocation = 0;

    // Memory.
    std::map<const llvm::AllocaInst *, uint64_t> allocaOffset;
    uint64_t privateBytes = 0;
    std::string arenaVar;
    std::map<const llvm::GlobalVariable *, uint64_t> wgStaticOffset;
    uint64_t wgStaticBytes = 0;
    std::vector<unsigned> wgSlots;              // [[threadgroup(n)]] slots used
    std::string wgBytesId;                      // u32 id of the total size (constant or spec constant)
    bool wgDynamic = false;
    std::map<unsigned, std::string> wgVars;     // element width -> Workgroup variable
    std::map<const llvm::GlobalVariable *, uint64_t> constDataOffset;
    std::string constData;                      // bytes of the constant-data blob
    std::map<const llvm::GlobalVariable *, unsigned> constexprSamplerIndex;
    std::vector<ConstexprSampler> samplers;
    std::map<const llvm::GlobalVariable *, FunctionConstant> fconsts;
    std::map<const llvm::GlobalVariable *, std::string> globalAddr;  // prologue ids

    // Compute imageblocks (explicit or implicit layout), kept in threadgroup
    // memory after the static threadgroup variables: pixel (x, y) at
    // imageblockBase + (y * width + x) * stride; width x height = the
    // threadgroup size.
    bool hasImageblock = false;
    uint64_t ibStride = 0;
    std::vector<uint64_t> ibFieldOffsets;
    uint64_t imageblockBase() const { return wgStaticBytesAligned(); }

    // Interpolant fragment inputs (interpolant<T, ...>): argument -> variable.
    struct Interpolant { std::string var, ioType; unsigned n = 1; bool half = false; };
    std::map<const llvm::Value *, Interpolant> interpolants;

    // Heap variables by key.
    std::map<std::string, std::string> heapVars;

    // Reflection facts gathered during translation.
    std::set<std::string> uses;                 // "discard", "derivatives", "subgroup", "barrier", ...
    Json jBuffers = Json::array(), jTextures = Json::array(), jSamplers = Json::array();
    Json jVertexInputs = Json::array(), jVaryings = Json::array(), jBuiltins = Json::array();
    Json jInputAttachments = Json::array();
    Json jRenderTargets = Json::array(), jThreadgroup = Json::array(), jFunctionConstants = Json::array();
    bool gridGuard = false;
    bool linked = false;

    Translator(llvm::Module &m, llvm::Function &f, EntryInfo ei, const TranslateOptions &o)
        : M(m), F(f), EI(std::move(ei)), DL(m.getDataLayout()), opts(o) {}

    // translate.cpp
    std::string run();
    std::string type(llvm::Type *T);
    std::string constant(llvm::Constant *C);
    std::string val(llvm::Value *V);
    std::string def(llvm::Value *V);
    std::string label(const llvm::BasicBlock *B);
    void bind(llvm::Value *V, const std::string &id);
    std::string addConst(const std::string &addr, int64_t off);
    std::string toU32(const std::string &u64v);
    std::string load(const std::string &addr, unsigned as, llvm::Type *T, uint64_t align);
    void store(const std::string &addr, unsigned as, llvm::Type *T, const std::string &v, uint64_t align);
    std::string scalarLoad(const std::string &addr, unsigned as, llvm::Type *T, uint64_t align);
    void scalarStore(const std::string &addr, unsigned as, llvm::Type *T, const std::string &v, uint64_t align);
    std::string workgroupElement(const std::string &addr, unsigned width);
    std::string privateWord(const std::string &wordIndex);
    std::string psbPointer(const std::string &addr, const std::string &pointee, unsigned bits);
    std::string tableEntry(unsigned e);
    std::string builtin(const std::string &name, const std::string &type);
    std::string ioVar(const std::string &storage, const std::string &type, const std::string &decoration);
    void setupInterface();
    void prologue();
    void layoutMemory();
    uint64_t wgStaticBytesAligned() const;
    void instruction(llvm::Instruction &I);
    void terminator(llvm::BasicBlock &B);
    std::string castInt(const std::string &v, llvm::Type *from, unsigned toBits, bool sign);
    std::string fitBuiltin(const std::string &v, const std::string &vType, unsigned n, llvm::Type *T);
    Json reflection();

    // intrinsics.cpp
    void call(llvm::CallInst *C);
    bool callTexture(llvm::CallInst *C, llvm::StringRef name);
    bool callSimd(llvm::CallInst *C, llvm::StringRef name);
    bool callAtomic(llvm::CallInst *C, llvm::StringRef name);
    bool callMath(llvm::CallInst *C, llvm::StringRef name);
    std::string imageType(const ImageKind &k, bool storage);
    std::string heapImage(const std::string &handle, const ImageKind &k, bool storage);
    std::string heapSampler(const std::string &handle);
};

// Helpers.
bool isSignedTypeName(const std::string &metalType);
std::string printType(llvm::Type *T);

}  // namespace airc
