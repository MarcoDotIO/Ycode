# ycode-airc

`ycode-airc` translates Metal shader functions (AIR, inside a metallib) to
SPIR-V for Vulkan, together with a JSON reflection document. It is the
shader translator of the simulator's Metal host service (stage 8a,
`specs/simulator/stage8-contract.md` §5.2 row SH). The design follows
`specs/simulator/metal-shaders.md` §4. How functions reach the host is in
`specs/simulator/metal-sim-protocol.md` §6.

Clean room: the code comes from those specs, from the public LLVM, SPIR-V
and Vulkan documentation, and from our own test shaders. Shaders of the
simulator runtime are input data only. Never copy them into the repository
or read their logic.

## Build and run

- **Linux build** (the Thor): `build.sh [BUILD_DIR]`. It needs LLVM 17 or
  newer (LLVM 18 is tested) and SPIRV-Tools. `libvulkan` is needed only for
  the GPU test harness. The command needs no sudo.
- **Installed binary used by VK:**
  `$YCODE_DATA/work/8-SH/build/ycode-airc`.
- **Command usage:** see the header comment of `src/main.cpp`. The commands
  are `translate`, `serve`, `corpus`, `list`, `decls`, `replay` and
  `version`.
- **Persistent mode (`serve`):** length-prefixed JSON + binary frames on
  stdin and stdout. Each translation runs in a forked child, so a crash
  becomes an error reply. A cache is keyed by the module's SHA-256 and the
  options.
- **`--dump-dir DIR`:** saves every request for `replay`. The approved path
  is `.../work/8-SH/dumps/<run-name>/`. Keep dumps on the Thor: they contain
  guest shader bytes.

## Source map

| File | Role |
|---|---|
| `src/metallib.*` | Container reader (spec §2): MTLB and universal forms, function list, module slices, SHA-256 |
| `src/air.*` | AIR metadata: entry nodes (vertex, fragment, kernel), argument and output nodes (including `air.function_constant`-gated ones), constexpr samplers, function constants |
| `src/prepare.*` | LLVM work before emission. Steps 1–5 below, then the structure plan (step 6) |
| `src/translate.cpp` | Emitter core: types, constants, memory model, stage interface, built-ins, instructions, structured branches, multiple functions, reflection, validation |
| `src/intrinsics.cpp` | `air.*` and `llvm.*` calls: textures (operands recognised by type), SIMD and quad, atomics, math, conversions, pack/unpack, barriers, imageblocks, interpolants |
| `src/abi.h` | The Metal-on-Vulkan ABI (below). VK depends on it, so changes go through the orchestrator |
| `src/emitter.h` | SPIR-V text builder. SPIRV-Tools assembles it and validates it in process |
| `src/cache.*`, `src/json.*`, `src/main.cpp` | Cache, JSON, command line and serve protocol |

The steps in `src/prepare.*`:

1. Keep large helpers that are called from several places out of line.
   They become SPIR-V functions marked DontInline. Everything else is
   inlined.
2. Run the static initializers, so that function-constant-derived globals
   become SSA values.
3. Clean up with SROA, EarlyCSE, SCCP, ADCE and SimplifyCFG. Expand memory
   intrinsics.
4. Normalize the CFG with LowerSwitch, UnifyFunctionExitNodes,
   FixIrreducible, UnifyLoopExits, LoopSimplify and StructurizeCFG.
5. Insert the grid guard for kernels.
6. Plan the structure: merge and continue blocks, splitting blocks where two
   constructs would share a merge.

## ABI (`src/abi.h`, version 1)

- **Push constants** (32 bytes, all stages):
  - offset 0: device address of the vertex or kernel stage's argument table
  - offset 8: device address of the fragment stage's argument table
  - offset 16: the exact Metal grid, three u32
- **Argument table**: 192 u64 entries.

| Entries | Contents |
|---|---|
| 0–30 | Buffer address plus offset |
| 31 | The function's constant data (`constant_data` in the reflection) |
| 32–159 | Texture heap indices |
| 160–175 | Sampler heap indices |
| 176–191 | Constexpr samplers |

- **Bindless heap**, descriptor set 0:
  - binding 0: sampled images
  - binding 1: storage images
  - binding 2: samplers
  - Index 0 is null.
  - A texture handle h is sampled index h. A storage write at mip level L
    uses storage index h + L.
- **Input attachments** (programmable blending): set 1, binding n.
- **Specialization IDs:**

| ID | Meaning |
|---|---|
| 0–2 | Workgroup size |
| 3 | Threadgroup bytes |
| 4 | Raster sample count |
| 100 + n | Offset of threadgroup slot n |
| 2²⁰ + 8·index + component | Function constants |

- **Memory model:**
  - Buffer pointers are 64-bit device addresses (PhysicalStorageBuffer).
  - Threadgroup memory and compute imageblocks use aliased explicit-layout
    Workgroup arrays.
  - Private memory is one per-invocation word arena shared by all functions.
- **Stage I/O:** 8- and 16-bit stage I/O is widened to 32 bits. Varyings are
  matched by their match string. The vertex shader keeps Metal's y-up
  convention; the host flips with a negative viewport height.

## Testing

On the Mac (our shaders only):

1. Compile the test shaders:
   `tests/compile-shaders.sh OUT_DIR`, which uses `xcrun -sdk iphonesimulator metal`.
2. Build the Metal oracle:
   `clang -fobjc-arc -framework Metal -framework Foundation tests/gpu/mtl-oracle.m -o mtl-oracle`.
3. Run it:
   `mtl-oracle tests/shaders tests/gpu/tests.txt ORACLE_DIR`. It writes the
   expected outputs.

On the Thor, copy `OUT_DIR` and `ORACLE_DIR` over, then:

- `tests/run-thor.sh WORK METALLIB_DIR ORACLE_DIR [RUNTIME_ROOT]`. It builds
  and runs the own corpus (with and without spirv-opt), the GPU tests
  (`run-gpu-tests.sh` with `tests/gpu/airc-gpu.c`, compared with the
  oracle), the texture operand forms (`tests/ir/texture-forms.sh`) and the
  serve tests (`serve-test.py`). If a runtime root is given, it also prints
  statistics for the runtime's home-screen libraries.
- `airc-gpu --compile VS.spv VS_ENTRY FS.spv FS_ENTRY` times a pipeline
  creation. Set `__GL_SHADER_DISK_CACHE=0` to measure a cold compile.

Debug environment variables (see `src/main.cpp`):

- `AIRC_DUMP`: SPIR-V text
- `AIRC_DUMP_LL`: prepared LLVM IR
- `AIRC_STATS` and `AIRC_STATS_OPS`: phase times and opcode counts
- `AIRC_STATS_CALLS`: helper call-graph sizes
- `AIRC_INLINE_ALL` and `AIRC_OUTLINE_MIN`: helper outlining policy
- `AIRC_LLVM_OPTIONS`: LLVM `cl` options

## Known limits

- Not translated:
  - function tables, which wait on R7's protocol
  - tessellation, mesh, object and ray-tracing functions
  - tile functions in render passes
  - render-target indices set by function constants in unspecialized
    files (guest-specialized functions should not have them)
- Visible and Core Image functions are translated only when linked into
  their callers (`--link`, `linked`). `corpus` wraps them in test functions
  for coverage.
- On the Thor, driver compile time is about 3 ms per conditional branch.
  QuartzCore's `fixed_frag_*` uber-shaders take about 3.5 s cold, so VK
  compiles them as pipeline libraries, asynchronously.
- Thor driver workarounds:
  - signed remainder is computed as a − (a/b)·b
  - `OpQuantizeToF16` is used for `fpext(fptrunc(x))`
