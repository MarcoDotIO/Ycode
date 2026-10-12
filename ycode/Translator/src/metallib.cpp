// metallib.cpp: metallib container reader (metal-shaders.md section 2.9:
// accept MTLB and the two universal forms, bound every offset, parse tag
// lists generically, keep NAME, TYPE, HASH, VERS and the module slice).
#include "metallib.h"

#include "error.h"

#include "llvm/ADT/ArrayRef.h"
#include "llvm/Support/SHA256.h"

#include <cstring>

namespace airc {

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32(const uint8_t *p) { return rd16(p) | ((uint32_t)rd16(p + 2) << 16); }
static uint64_t rd64(const uint8_t *p) { return rd32(p) | ((uint64_t)rd32(p + 4) << 32); }
static uint32_t rd32be(const uint8_t *p) { return ((uint32_t)p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]; }

std::string MetallibFunction::hashHex() const {
    static const char *hex = "0123456789abcdef";
    std::string s;
    for (uint8_t b : hash) { s += hex[b >> 4]; s += hex[b & 15]; }
    return s;
}

const MetallibFunction *Metallib::find(const std::string &name) const {
    for (const auto &f : functions)
        if (f.name == name) return &f;
    return nullptr;
}

std::string sha256Hex(const std::string &bytes) {
    auto h = llvm::SHA256::hash(llvm::ArrayRef<uint8_t>((const uint8_t *)bytes.data(), bytes.size()));
    MetallibFunction tmp;
    memcpy(tmp.hash, h.data(), 32);
    return tmp.hashHex();
}

// Picks the MTLB slice of a universal container (section 2.8).
static std::string sliceOf(const std::string &data) {
    const uint8_t *b = (const uint8_t *)data.data();
    if (data.size() < 8) fail("bad-container", "too short");
    uint32_t magic = rd32be(b);
    if (magic != 0xCAFEBABE && magic != 0xCBFEBABE) return data;
    uint32_t n = rd32be(b + 4);
    if (n > 64 || 8 + (uint64_t)n * 20 > data.size()) fail("bad-container", "universal header out of bounds");
    int64_t best = -1;
    uint32_t bestSub = 0;
    uint64_t off = 0, size = 0;
    for (uint32_t i = 0; i < n; i++) {
        const uint8_t *s = b + 8 + i * 20;
        uint32_t cpu = rd32be(s), sub = rd32be(s + 4), o = rd32be(s + 8), z = rd32be(s + 12);
        if ((uint64_t)o + z > data.size() || z < 4) fail("bad-container", "universal slice out of bounds");
        if (cpu != 0x01000017 || memcmp(b + o, "MTLB", 4) != 0) continue;
        if (best < 0 || sub > bestSub) { best = i; bestSub = sub; off = o; size = z; }
    }
    if (best < 0) fail("bad-container", "universal container without an MTLB slice");
    return data.substr(off, size);
}

Metallib parseMetallib(const std::string &input) {
    Metallib lib;
    lib.blob = sliceOf(input);
    const std::string &d = lib.blob;
    const uint8_t *b = (const uint8_t *)d.data();
    const uint64_t n = d.size();
    if (n < 88 || memcmp(b, "MTLB", 4) != 0) fail("bad-container", "no MTLB magic");
    lib.versionMajor = rd16(b + 6);
    lib.versionMinor = rd16(b + 8);
    lib.fileType = b[10] & 0x7f;
    lib.platform = b[11] & 0x7f;
    auto section = [&](unsigned at, const char *what, uint64_t &off, uint64_t &size) {
        off = rd64(b + at);
        size = rd64(b + at + 8);
        if (off > n || size > n - off) fail("bad-container", std::string(what) + " section out of bounds");
    };
    uint64_t flOff, flSize, pubOff, pubSize, privOff, privSize, bcOff, bcSize;
    section(24, "function list", flOff, flSize);
    section(40, "public metadata", pubOff, pubSize);
    section(56, "private metadata", privOff, privSize);
    section(72, "bitcode", bcOff, bcSize);
    (void)pubSize; (void)privSize;
    if (flOff + 4 > n) fail("bad-container", "function list out of bounds");
    uint32_t count = rd32(b + flOff);
    uint64_t at = flOff + 4, end = flOff + 4 + flSize;
    if (end > n) fail("bad-container", "function list size out of bounds");
    for (uint32_t i = 0; i < count; i++) {
        if (at + 4 > end) fail("bad-container", "function entry out of bounds");
        uint32_t size = rd32(b + at);
        if (size < 8 || at + size > end) fail("bad-container", "function entry size out of bounds");
        MetallibFunction f;
        uint64_t t = at + 4, e = at + size;
        uint64_t modRel = UINT64_MAX;
        bool haveSize = false;
        while (t + 4 <= e) {
            if (!memcmp(b + t, "ENDT", 4)) break;
            if (t + 6 > e) fail("bad-container", "tag header out of bounds");
            uint32_t len = rd16(b + t + 4);
            uint64_t p = t + 6;
            if (p + len > e) fail("bad-container", "tag payload out of bounds");
            const uint8_t *v = b + p;
            if (!memcmp(b + t, "NAME", 4)) f.name.assign((const char *)v, strnlen((const char *)v, len));
            else if (!memcmp(b + t, "TYPE", 4) && len >= 1) f.type = v[0];
            else if (!memcmp(b + t, "HASH", 4) && len >= 32) { memcpy(f.hash, v, 32); f.hasHash = true; }
            else if (!memcmp(b + t, "OFFT", 4) && len >= 24) modRel = rd64(v + 16);
            else if (!memcmp(b + t, "MDSZ", 4) && len >= 8) { f.moduleSize = rd64(v); haveSize = true; }
            else if (!memcmp(b + t, "VERS", 4) && len >= 8) {
                f.airMajor = rd16(v); f.airMinor = rd16(v + 2); f.langMajor = rd16(v + 4); f.langMinor = rd16(v + 6);
            }
            t = p + len;
        }
        if (modRel == UINT64_MAX || !haveSize) fail("bad-container", "function " + f.name + " without OFFT or MDSZ");
        if (modRel > bcSize || f.moduleSize > bcSize - modRel) fail("bad-container", "module of " + f.name + " outside the bitcode section");
        f.moduleOffset = bcOff + modRel;
        lib.functions.push_back(std::move(f));
        at += size;
    }
    return lib;
}

}  // namespace airc
