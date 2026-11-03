/*
 * Build configuration for the vendored ThorVG (what meson would generate).
 *
 * Vendored copy: ThorVG 1.1.3 (tag v1.1.3, commit 589bc4120f2097fb1b135e552c2ef39f6581612b,
 * released 2026-10-15), cloned from https://github.com/thorvg/thorvg on 2026-10-30.
 * Licence: MIT (thorvg/LICENSE, kept unchanged; every file keeps its notice).
 * Subset kept: inc/thorvg.h, src/common, src/renderer (core) and
 * src/renderer/cpu_engine, the raw/png/jpg loaders and the C API binding
 * (thorvg_capi.h is in ../include for Swift). Files are unmodified.
 * Configuration: CPU engine only, no threads (the task scheduler runs
 * inline, so rendering is deterministic), PNG and JPEG loaders (lodepng and
 * jpgd as bundled by ThorVG), C API on, no SIMD, no partial rendering
 * (OVRender computes damage itself).
 */
#ifndef OV_THORVG_CONFIG_H
#define OV_THORVG_CONFIG_H
#define THORVG_VERSION_STRING "1.1.3"
#define THORVG_CPU_ENGINE_SUPPORT 1
#define THORVG_PNG_LOADER_SUPPORT 1
#define THORVG_JPG_LOADER_SUPPORT 1
#define THORVG_CAPI_BINDING_SUPPORT 1
#endif
