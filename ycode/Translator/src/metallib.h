// metallib.h: reader for the metallib container (specs/simulator/
// metal-shaders.md section 2). Ycode, clean-room implementation.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace airc {

// One record of the function list (section 2.3).
struct MetallibFunction {
    std::string name;
    int type = -1;                 // TYPE: 0 vertex, 1 fragment, 2 kernel, 3 none, 4 visible, 5 CI, ...
    uint8_t hash[32] = {};         // HASH: SHA-256 of the module bytes
    bool hasHash = false;
    uint16_t airMajor = 0, airMinor = 0, langMajor = 0, langMinor = 0;  // VERS
    uint64_t moduleOffset = 0;     // absolute offset of the module in the blob
    uint64_t moduleSize = 0;       // MDSZ
    std::string hashHex() const;
};

struct Metallib {
    uint16_t versionMajor = 0, versionMinor = 0;
    uint8_t fileType = 0, platform = 0;
    std::vector<MetallibFunction> functions;
    std::string blob;              // the MTLB slice (owns the bytes)

    // The module bytes (bitcode wrapper included) of a function.
    std::string module(const MetallibFunction &f) const { return blob.substr(f.moduleOffset, f.moduleSize); }
    const MetallibFunction *find(const std::string &name) const;
};

// Parses a metallib (or one of the two universal forms; the MTLB slice with
// the highest subtype is used). Throws airc::Error on malformed input.
Metallib parseMetallib(const std::string &data);

// SHA-256 of bytes as lowercase hex.
std::string sha256Hex(const std::string &bytes);

}  // namespace airc
