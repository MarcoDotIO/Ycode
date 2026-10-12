// cache.h: translation cache keyed by the function's HASH plus everything
// that changes the output (translator version, options, linked varyings).
// In memory always; on disk when a directory is given (<key>.spv and
// <key>.json, written atomically by rename).
#pragma once

#include "json.h"

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace airc {

class Cache {
public:
    explicit Cache(std::string dir) : dir_(std::move(dir)) {}
    bool lookup(const std::string &key, std::vector<uint32_t> &spirv, Json &reflection);
    void store(const std::string &key, const std::vector<uint32_t> &spirv, const Json &reflection);
    // The last reflection seen for a function HASH (for link_vertex).
    void rememberHash(const std::string &hash, const Json &reflection) { byHash_[hash] = reflection; }
    bool reflectionByHash(const std::string &hash, Json &reflection) const;

private:
    struct Entry {
        std::vector<uint32_t> spirv;
        Json reflection;
    };
    std::string dir_;
    std::map<std::string, Entry> mem_;
    std::map<std::string, Json> byHash_;
};

}  // namespace airc
