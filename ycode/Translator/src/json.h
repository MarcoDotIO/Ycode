// json.h: a small JSON value type with a writer and a parser, enough for
// ycode-airc's request headers and reflection documents.
#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace airc {

struct Json {
    enum Kind { Null, Bool, Number, String, Array, Object } kind = Null;
    bool b = false;
    double num = 0;
    std::string str;
    std::vector<Json> arr;
    std::vector<std::pair<std::string, Json>> obj;  // insertion order kept

    Json() = default;
    Json(bool v) : kind(Bool), b(v) {}
    Json(int v) : kind(Number), num(v) {}
    Json(unsigned v) : kind(Number), num(v) {}
    Json(long v) : kind(Number), num((double)v) {}
    Json(unsigned long v) : kind(Number), num((double)v) {}
    Json(long long v) : kind(Number), num((double)v) {}
    Json(unsigned long long v) : kind(Number), num((double)v) {}
    Json(double v) : kind(Number), num(v) {}
    Json(const char *s) : kind(String), str(s) {}
    Json(std::string s) : kind(String), str(std::move(s)) {}

    static Json array() { Json j; j.kind = Array; return j; }
    static Json object() { Json j; j.kind = Object; return j; }

    Json &push(Json v) { kind = Array; arr.push_back(std::move(v)); return arr.back(); }
    Json &set(const std::string &k, Json v) {
        kind = Object;
        for (auto &p : obj)
            if (p.first == k) { p.second = std::move(v); return p.second; }
        obj.emplace_back(k, std::move(v));
        return obj.back().second;
    }
    const Json *get(const std::string &k) const {
        for (auto &p : obj)
            if (p.first == k) return &p.second;
        return nullptr;
    }
    std::string getString(const std::string &k, const std::string &dflt = "") const {
        const Json *j = get(k);
        return j && j->kind == String ? j->str : dflt;
    }
    bool getBool(const std::string &k, bool dflt = false) const {
        const Json *j = get(k);
        return j && j->kind == Bool ? j->b : dflt;
    }
    double getNumber(const std::string &k, double dflt = 0) const {
        const Json *j = get(k);
        return j && j->kind == Number ? j->num : dflt;
    }

    std::string dump(int indent = -1) const;
    // Throws std::runtime_error on malformed input.
    static Json parse(const std::string &text);
};

}  // namespace airc
