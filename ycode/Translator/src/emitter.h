// emitter.h: SPIR-V text builder used by the translator. Ids are "%N";
// the module is assembled by SPIRV-Tools (numeric ids preserved).
#pragma once

#include <cstdint>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace airc {

struct Emitter {
    std::set<std::string> caps{"Shader", "Int64", "PhysicalStorageBufferAddresses"};
    std::set<std::string> exts;
    std::ostringstream names, decor, globals, fnvars, body;
    std::vector<std::string> interface;
    std::map<std::string, std::string> memo;   // types, constants, other module-level ids
    std::set<std::string> decorated;            // "id|decoration" already written
    unsigned next = 1;
    const std::string glsl = "%glsl";

    std::string fresh() { return "%" + std::to_string(next++); }

    // A module-level declaration, memoized by key.
    std::string global(const std::string &key, const std::string &decl) {
        auto it = memo.find(key);
        if (it != memo.end()) return it->second;
        std::string id = fresh();
        globals << id << " = " << decl << "\n";
        return memo[key] = id;
    }
    void decorate(const std::string &id, const std::string &d) {
        if (decorated.insert(id + "|" + d).second) decor << "OpDecorate " << id << " " << d << "\n";
    }
    void memberDecorate(const std::string &id, unsigned m, const std::string &d) {
        if (decorated.insert(id + "|" + std::to_string(m) + "|" + d).second)
            decor << "OpMemberDecorate " << id << " " << m << " " << d << "\n";
    }

    // Types.
    std::string tVoid() { return global("void", "OpTypeVoid"); }
    std::string tBool() { return global("bool", "OpTypeBool"); }
    std::string tInt(unsigned w) {
        if (w == 8) caps.insert("Int8");
        if (w == 16) caps.insert("Int16");
        return global("i" + std::to_string(w), "OpTypeInt " + std::to_string(w) + " 0");
    }
    std::string tSInt(unsigned w) {  // signed int type (only where SPIR-V requires signedness, e.g. image types)
        if (w == 8) caps.insert("Int8");
        if (w == 16) caps.insert("Int16");
        return global("s" + std::to_string(w), "OpTypeInt " + std::to_string(w) + " 1");
    }
    std::string tFloat(unsigned w) {
        if (w == 16) caps.insert("Float16");
        if (w == 64) caps.insert("Float64");
        return global("f" + std::to_string(w), "OpTypeFloat " + std::to_string(w));
    }
    std::string tVec(const std::string &e, unsigned n) {
        if (n == 1) return e;
        return global("v" + std::to_string(n) + e, "OpTypeVector " + e + " " + std::to_string(n));
    }
    std::string tPtr(const std::string &storage, const std::string &pointee) {
        return global("p" + storage + pointee, "OpTypePointer " + storage + " " + pointee);
    }
    std::string tFunc(const std::string &ret) { return global("fn" + ret, "OpTypeFunction " + ret); }

    // Constants.
    std::string constant(const std::string &type, const std::string &literal) {
        return global("c" + type + ":" + literal, "OpConstant " + type + " " + literal);
    }
    std::string u32(uint64_t v) { return constant(tInt(32), std::to_string((uint32_t)v)); }
    std::string u64(uint64_t v) { return constant(tInt(64), std::to_string(v)); }
    std::string boolean(bool v) { return global(v ? "true" : "false", std::string(v ? "OpConstantTrue " : "OpConstantFalse ") + tBool()); }
    std::string null(const std::string &type) { return global("null" + type, "OpConstantNull " + type); }
    std::string undef(const std::string &type) { return global("undef" + type, "OpUndef " + type); }
    std::string composite(const std::string &type, const std::vector<std::string> &parts) {
        std::string key = "cc" + type, decl = "OpConstantComposite " + type;
        for (auto &p : parts) { key += "," + p; decl += " " + p; }
        return global(key, decl);
    }

    // Body instructions.
    std::string op(const std::string &opcode, const std::string &type, const std::vector<std::string> &args) {
        std::string r = fresh();
        body << r << " = " << opcode << " " << type;
        for (auto &a : args) body << " " << a;
        body << "\n";
        return r;
    }
    void stmt(const std::string &text) { body << text << "\n"; }
    std::string ext(const std::string &type, const std::string &inst, const std::vector<std::string> &args) {
        std::string r = fresh();
        body << r << " = OpExtInst " << type << " " << glsl << " " << inst;
        for (auto &a : args) body << " " << a;
        body << "\n";
        return r;
    }
};

}  // namespace airc
