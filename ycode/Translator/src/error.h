// error.h: structured translation errors. Every failure of ycode-airc is
// reported with a stable code and a detail naming what was not handled
// (an intrinsic, an instruction, a metadata kind, ...).
#pragma once

#include <stdexcept>
#include <string>

namespace airc {

// Stable error codes (part of the reply format).
//   bad-request          the request itself is malformed
//   bad-container        not a metallib, or offsets out of bounds
//   function-not-found   the named function is not in the metallib
//   bad-bitcode          LLVM could not read the module
//   not-an-entry-point   the function has no vertex, fragment or kernel metadata
//   unsupported-stage    a function kind the translator does not handle
//                        (visible, Core Image, mesh, object, intersection, tile)
//   unsupported-intrinsic   an air.* or llvm.* call without a lowering
//   unsupported-feature  an AIR feature without a lowering (imageblocks,
//                        programmable blending, function tables, ...)
//   unsupported-instruction an LLVM instruction without a lowering
//   unsupported-type     an LLVM type without a SPIR-V mapping
//   structurize-failed   the control flow could not be made structured
//   validation-failed    spirv-val rejected the output (a translator bug)
//   internal             anything else
struct Error : std::runtime_error {
    std::string code, detail;
    Error(std::string c, std::string d)
        : std::runtime_error(c + ": " + d), code(std::move(c)), detail(std::move(d)) {}
};

[[noreturn]] inline void fail(const std::string &code, const std::string &detail) { throw Error(code, detail); }

}  // namespace airc
