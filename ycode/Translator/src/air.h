// air.h: AIR module metadata (specs/simulator/metal-shaders.md sections
// 3.4 to 3.8): entry points, argument and output nodes, constexpr
// samplers, function constants.
#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace llvm {
class Function;
class GlobalVariable;
class MDNode;
class Metadata;
class Module;
}  // namespace llvm

namespace airc {

// One argument or output node. Keys (`air.*` strings) are kept with the
// operands that follow them; the first non-`air.` string after the kind
// is the match string of varyings.
struct AirNode {
    int argIndex = -1;         // arguments only
    std::string kind;          // air.buffer, air.position, air.vertex_output, ...
    std::string ident;         // match string (generated(...)) or empty
    std::string fcPredicate;   // name of the function constant that gates this node, or empty
    std::vector<std::pair<std::string, std::vector<llvm::Metadata *>>> keys;

    bool has(const std::string &k) const;
    int64_t intAt(const std::string &k, unsigned i = 0, int64_t dflt = -1) const;
    std::string strAt(const std::string &k, unsigned i = 0) const;
    // Location: air.location_index's first value, or the render-target index.
    int location() const;
    // A location given by a function-constant expression: the global the
    // static initializer computes it into (null when constant).
    llvm::GlobalVariable *locationGlobal() const;
    // Array count of resource arguments (air.location_index's second value).
    int count() const { return (int)intAt("air.location_index", 1, 1); }
    std::string typeName() const { return strAt("air.arg_type_name"); }
    std::string argName() const { return strAt("air.arg_name"); }
    // "read", "write", "read_write", "sample" or "".
    std::string access() const;
};

enum class Stage { Vertex, Fragment, Kernel };
const char *stageName(Stage s);

struct EntryInfo {
    Stage stage;
    llvm::Function *fn = nullptr;
    std::vector<AirNode> outputs;            // in return-value member order
    std::map<unsigned, AirNode> args;        // by argument number
};

// Finds F in !air.vertex, !air.fragment or !air.kernel. Throws
// unsupported-stage for other entry lists and not-an-entry-point when absent.
EntryInfo entryInfo(llvm::Module &M, llvm::Function *F);

// A constexpr sampler (section 3.7): the global and its first state word.
struct ConstexprSampler {
    llvm::GlobalVariable *global = nullptr;
    uint64_t word0 = 0, word1 = 0;
};
std::vector<ConstexprSampler> constexprSamplers(llvm::Module &M);

// A function constant (section 3.8): the global the function loads (the
// internal copy the static initializer fills), the initializer global, its
// type name, name and index.
struct FunctionConstant {
    llvm::GlobalVariable *value = nullptr;   // loaded by functions
    llvm::GlobalVariable *init = nullptr;    // the air.fc_initializer global
    std::string typeName, name;
    unsigned index = 0;
};
std::vector<FunctionConstant> functionConstants(llvm::Module &M);

// Decodes a constexpr sampler word into named fields (for reflection).
struct SamplerFields {
    unsigned addrS, addrT, addrR, magFilter, minFilter, mipFilter, normalized, compare, maxAnisotropy;
    float lodMin, lodMax;
    unsigned borderColor, reduction;
};
SamplerFields decodeSampler(uint64_t word0);

}  // namespace airc
