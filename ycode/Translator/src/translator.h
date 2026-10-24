// translator.h: AIR function -> SPIR-V for Vulkan plus a reflection
// document (ycode-airc's core; metal-shaders.md section 4).
#pragma once

#include "json.h"

#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <vector>

namespace airc {

struct TranslateOptions {
    // Fragment functions: varying match string -> Location, from the
    // linked vertex function's reflection ("varyings"). Without it, the
    // fragment inputs get Locations in their own declaration order and the
    // reflection says "linked": false.
    std::map<std::string, unsigned> varyings;
    bool haveVaryings = false;
    std::string linkedVertexHash;   // reported only
    bool optimize = false;          // spirv-opt performance passes (validated again)
    // Modules (bitcode) of visible functions linked into this function: each
    // call to `<name>.MTL_VISIBLE_FN_REF` binds to the definition of <name>.
    std::vector<std::string> linkModules;
    // Visible (and stitchable) functions are not entry points. With this
    // set, such a function is translated inside a generated test kernel
    // that loads its arguments from buffer 0 (coverage of the function
    // body; reflection says "wrapped_visible_function").
    bool wrapVisible = false;
    // Supplies the module of a visible function referenced but not linked
    // (by name); used to link functions of the same library.
    std::function<bool(const std::string &name, std::string &module)> resolveVisible;
    bool wantAssembly = false;      // keep the SPIR-V text
    // Loop guard: when nonzero, each invocation may pass loop headers at
    // most this many times in all; after that every loop is left at its
    // header (stage8-contract.md §13.3). Reflection reports it as
    // "loop_limit".
    uint32_t loopLimit = 0;

    // Function constant values by index (specializes the function the way
    // MTLFunctionConstantValues does; constants not given stay
    // specialization constants).
    std::map<unsigned, double> functionConstantValues;
};

struct TranslateResult {
    std::vector<uint32_t> spirv;
    Json reflection;
    std::string assembly;
};

// Translates the function `name` of an AIR module (bitcode, with or
// without the wrapper). `hashHex` is the metallib HASH (reported), `kind`
// the metallib TYPE (or -1). Throws airc::Error.
TranslateResult translate(const std::string &module, const std::string &name, const std::string &hashHex, int kind,
                          const TranslateOptions &opts);

// The translator version, part of every cache key.
extern const char *kTranslatorVersion;

}  // namespace airc
