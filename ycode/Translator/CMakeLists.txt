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
find_library(SPIRV_TOOLS_OPT_LIB SPIRV-Tools-opt)
find_library(SPIRV_TOOLS_LIB SPIRV-Tools)
target_link_libraries(ycode-airc PRIVATE ${AIRC_LLVM_LIBS} ${SPIRV_TOOLS_OPT_LIB} ${SPIRV_TOOLS_LIB})

# GPU test harness (Vulkan; tests/gpu).
find_library(VULKAN_LIB vulkan)
if(VULKAN_LIB AND EXISTS ${CMAKE_SOURCE_DIR}/tests/gpu/airc-gpu.c)
  add_executable(airc-gpu tests/gpu/airc-gpu.c)
  target_link_libraries(airc-gpu PRIVATE ${VULKAN_LIB} m)
endif()
