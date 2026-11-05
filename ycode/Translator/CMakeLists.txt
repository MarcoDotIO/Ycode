# ycode-airc: AIR (Metal) -> SPIR-V (Vulkan) translator for the Ycode
# simulator's Metal host service (stage 8a, specs/simulator/metal-shaders.md).
# Builds against LLVM 18 (Apache-2.0 WITH LLVM-exception) and SPIRV-Tools
# (Apache-2.0). Linux is the target (the Thor); see build.sh.
cmake_minimum_required(VERSION 3.20)
project(ycode-airc CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

find_package(LLVM REQUIRED CONFIG)
if(LLVM_VERSION_MAJOR LESS 17)
  message(FATAL_ERROR "ycode-airc needs LLVM 17 or newer (found ${LLVM_PACKAGE_VERSION})")
endif()
find_package(PkgConfig REQUIRED)
pkg_check_modules(SPIRV_TOOLS REQUIRED SPIRV-Tools)

message(STATUS "LLVM ${LLVM_PACKAGE_VERSION} in ${LLVM_DIR}")

add_executable(ycode-airc
  src/main.cpp
  src/metallib.cpp
  src/json.cpp
  src/air.cpp
  src/prepare.cpp
  src/translate.cpp
  src/intrinsics.cpp
  src/cache.cpp)

# The release's version (ycode/VERSION) for `ycode-airc --version`.
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/../VERSION" YCODE_RELEASE_VERSION LIMIT_COUNT 1)
target_compile_definitions(ycode-airc PRIVATE YCODE_RELEASE_VERSION="${YCODE_RELEASE_VERSION}")

target_include_directories(ycode-airc PRIVATE ${LLVM_INCLUDE_DIRS} ${SPIRV_TOOLS_INCLUDE_DIRS})
separate_arguments(LLVM_DEFS NATIVE_COMMAND ${LLVM_DEFINITIONS})
target_compile_definitions(ycode-airc PRIVATE ${LLVM_DEFS})
target_compile_options(ycode-airc PRIVATE -Wall -Wno-unused-parameter -fno-rtti)

# Link the shared libLLVM when the distribution has it (Ubuntu: libLLVM-18.so),
# else the component libraries.
if(TARGET LLVM)
  set(AIRC_LLVM_LIBS LLVM)
else()
  llvm_map_components_to_libnames(AIRC_LLVM_LIBS core bitreader analysis transformutils scalaropts ipo passes linker support)
endif()
# HINTS: pkg-config's directory, for a prefix CMake does not search on its
# own (the Flatpak build installs SPIRV-Tools into /app).
find_library(SPIRV_TOOLS_OPT_LIB SPIRV-Tools-opt HINTS ${SPIRV_TOOLS_LIBRARY_DIRS})
find_library(SPIRV_TOOLS_LIB SPIRV-Tools HINTS ${SPIRV_TOOLS_LIBRARY_DIRS})
target_link_libraries(ycode-airc PRIVATE ${AIRC_LLVM_LIBS} ${SPIRV_TOOLS_OPT_LIB} ${SPIRV_TOOLS_LIB})

# A packaged build names the run-time search path (the Flatpak and the release
# tarball: $ORIGIN/../../.., where libLLVM sits). The binary then carries only
# that path, not the build machine's LLVM folder. Set here rather than in
# LDFLAGS: CMake escapes $ORIGIN for the build tool, and Ninja would read it as
# one of its own variables and drop it.
set(YCODE_AIRC_RPATH "" CACHE STRING "Run-time search path of a packaged ycode-airc")
if(YCODE_AIRC_RPATH)
  set_target_properties(ycode-airc PROPERTIES BUILD_WITH_INSTALL_RPATH ON INSTALL_RPATH "${YCODE_AIRC_RPATH}")
endif()

# GPU test harness (Vulkan; tests/gpu).
find_library(VULKAN_LIB vulkan)
if(VULKAN_LIB AND EXISTS ${CMAKE_SOURCE_DIR}/tests/gpu/airc-gpu.c)
  add_executable(airc-gpu tests/gpu/airc-gpu.c)
  target_link_libraries(airc-gpu PRIVATE ${VULKAN_LIB} m)
endif()
