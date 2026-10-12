// cache.cpp: in-memory and on-disk translation cache.
#include "cache.h"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <unistd.h>

namespace airc {

static bool slurp(const std::string &path, std::string &out) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    std::ostringstream ss;
    ss << in.rdbuf();
    out = ss.str();
    return true;
}

static bool spill(const std::string &path, const std::string &data) {
    std::string tmp = path + ".tmp" + std::to_string(getpid());
    {
        std::ofstream o(tmp, std::ios::binary);
        if (!o) return false;
        o.write(data.data(), (std::streamsize)data.size());
        if (!o) return false;
    }
    return rename(tmp.c_str(), path.c_str()) == 0;
}

bool Cache::lookup(const std::string &key, std::vector<uint32_t> &spirv, Json &reflection) {
    auto it = mem_.find(key);
    if (it != mem_.end()) {
        spirv = it->second.spirv;
        reflection = it->second.reflection;
        return true;
    }
    if (dir_.empty()) return false;
    std::string words, json;
    if (!slurp(dir_ + "/" + key + ".spv", words) || !slurp(dir_ + "/" + key + ".json", json)) return false;
    if (words.size() % 4 || words.empty()) return false;
    try {
        reflection = Json::parse(json);
    } catch (...) {
        return false;
    }
    spirv.resize(words.size() / 4);
    memcpy(spirv.data(), words.data(), words.size());
    mem_[key] = {spirv, reflection};
    return true;
}

void Cache::store(const std::string &key, const std::vector<uint32_t> &spirv, const Json &reflection) {
    mem_[key] = {spirv, reflection};
    if (dir_.empty()) return;
    spill(dir_ + "/" + key + ".spv", std::string((const char *)spirv.data(), spirv.size() * 4));
    spill(dir_ + "/" + key + ".json", reflection.dump());
}

bool Cache::reflectionByHash(const std::string &hash, Json &reflection) const {
    auto it = byHash_.find(hash);
    if (it == byHash_.end()) return false;
    reflection = it->second;
    return true;
}

}  // namespace airc
