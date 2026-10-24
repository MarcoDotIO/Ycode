// prepare.h: LLVM-level preparation of an AIR entry function before SPIR-V
// emission (metal-shaders.md section 4.1 step 3 and section 4.8): inline
// every call to a defined function, lower constant expressions into
// instructions, scalar replacement of aggregates, expand variable-length
// memory intrinsics, lower switches, unify exits, make loops and branches
// structured, and compute the merge and continue blocks SPIR-V needs.
#pragma once

#include <functional>
#include <map>
#include <vector>

namespace llvm {
class BasicBlock;
class Function;
class Module;
}  // namespace llvm

namespace airc {

struct Construct {
    bool loop = false;
    llvm::BasicBlock *merge = nullptr;       // never null (may be an unreachable block)
    llvm::BasicBlock *cont = nullptr;        // loops only
};

struct StructurePlan {
    std::map<llvm::BasicBlock *, Construct> headers;
    std::vector<llvm::BasicBlock *> order;   // emission order: reverse post-order, then unreachable merges
};

// `gridGuard`: insert an early return for threads outside the Metal grid
// (a call to the marker `airc.grid_oob`, lowered by the emitter) when the
// function, after inlining, has no barrier. Returns whether it did.
// `helpers` receives the functions kept out of line (each prepared like F);
// every other defined function is inlined. `loopGuard`: every loop header
// calls the marker `airc.loop_budget` (i1: the invocation's loop budget is
// spent) and leaves the loop when it returns true.
bool prepareFunction(llvm::Module &M, llvm::Function &F, bool gridGuard,
                     const std::function<void(llvm::Function &)> &afterInline = nullptr,
                     std::vector<llvm::Function *> *helpers = nullptr, bool loopGuard = false);

// Computes the structured-control-flow plan, splitting blocks where two
// constructs would share a merge block. Throws structurize-failed.
StructurePlan planStructure(llvm::Function &F);

}  // namespace airc
