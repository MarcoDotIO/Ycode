// json.cpp: JSON writer and parser (RFC 8259 subset: no surrogate-pair
// decoding beyond the BMP, which request headers never need).
#include "json.h"

#include <cmath>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <stdexcept>

namespace airc {

// Length of a valid UTF-8 sequence starting at s[i], or 0.
static size_t utf8Len(const std::string &s, size_t i) {
    unsigned char c = (unsigned char)s[i];
    size_t n = c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : (c >> 3) == 30 ? 4 : 0;
    if (n == 0 || i + n > s.size()) return 0;
    for (size_t k = 1; k < n; k++)
        if (((unsigned char)s[i + k] >> 6) != 2) return 0;
    return n;
}

static void quote(std::string &o, const std::string &s) {
    o += '"';
    for (size_t i = 0; i < s.size(); i++) {
        unsigned char c = (unsigned char)s[i];
        if (c >= 0x80) {
            // Valid UTF-8 passes through; other bytes become U+00XX.
            size_t n = utf8Len(s, i);
            if (n) {
                o.append(s, i, n);
                i += n - 1;
            } else {
                char buf[8];
                snprintf(buf, sizeof buf, "\\u%04x", c);
                o += buf;
            }
            continue;
        }
        switch (c) {
        case '"': o += "\\\""; break;
        case '\\': o += "\\\\"; break;
        case '\n': o += "\\n"; break;
        case '\r': o += "\\r"; break;
        case '\t': o += "\\t"; break;
        default:
            if (c < 0x20) {
                char buf[8];
                snprintf(buf, sizeof buf, "\\u%04x", c);
                o += buf;
            } else {
                o += (char)c;
            }
        }
    }
    o += '"';
}

static void write(std::string &o, const Json &j, int indent, int depth) {
    auto nl = [&](int d) {
        if (indent < 0) return;
        o += '\n';
        o.append((size_t)(indent * d), ' ');
    };
    switch (j.kind) {
    case Json::Null: o += "null"; break;
    case Json::Bool: o += j.b ? "true" : "false"; break;
    case Json::Number: {
        char buf[40];
        if (std::isfinite(j.num) && j.num == std::floor(j.num) && std::fabs(j.num) < 1e18)
            snprintf(buf, sizeof buf, "%lld", (long long)j.num);
        else
            snprintf(buf, sizeof buf, "%.17g", j.num);
        o += buf;
        break;
    }
    case Json::String: quote(o, j.str); break;
    case Json::Array:
        o += '[';
        for (size_t i = 0; i < j.arr.size(); i++) {
            if (i) o += ',';
            nl(depth + 1);
            write(o, j.arr[i], indent, depth + 1);
        }
        if (!j.arr.empty()) nl(depth);
        o += ']';
        break;
    case Json::Object:
        o += '{';
        for (size_t i = 0; i < j.obj.size(); i++) {
            if (i) o += ',';
            nl(depth + 1);
            quote(o, j.obj[i].first);
            o += indent < 0 ? ":" : ": ";
            write(o, j.obj[i].second, indent, depth + 1);
        }
        if (!j.obj.empty()) nl(depth);
        o += '}';
        break;
    }
}

std::string Json::dump(int indent) const {
    std::string o;
    write(o, *this, indent, 0);
    return o;
}

namespace {
struct Parser {
    const std::string &s;
    size_t i = 0;
    [[noreturn]] void bad(const char *m) { throw std::runtime_error(std::string("json: ") + m); }
    void ws() { while (i < s.size() && (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t')) i++; }
    bool lit(const char *w) {
        size_t n = strlen(w);
        if (s.compare(i, n, w) == 0) { i += n; return true; }
        return false;
    }
    std::string string() {
        if (s[i] != '"') bad("expected string");
        i++;
        std::string o;
        while (i < s.size() && s[i] != '"') {
            char c = s[i++];
            if (c != '\\') { o += c; continue; }
            if (i >= s.size()) bad("bad escape");
            char e = s[i++];
            switch (e) {
            case 'n': o += '\n'; break;
            case 't': o += '\t'; break;
            case 'r': o += '\r'; break;
            case 'b': o += '\b'; break;
            case 'f': o += '\f'; break;
            case 'u': {
                if (i + 4 > s.size()) bad("bad \\u");
                unsigned v = (unsigned)std::stoul(s.substr(i, 4), nullptr, 16);
                i += 4;
                if (v < 0x80) o += (char)v;
                else if (v < 0x800) { o += (char)(0xC0 | (v >> 6)); o += (char)(0x80 | (v & 0x3F)); }
                else { o += (char)(0xE0 | (v >> 12)); o += (char)(0x80 | ((v >> 6) & 0x3F)); o += (char)(0x80 | (v & 0x3F)); }
                break;
            }
            default: o += e;
            }
        }
        if (i >= s.size()) bad("unterminated string");
        i++;
        return o;
    }
    Json value() {
        ws();
        if (i >= s.size()) bad("unexpected end");
        char c = s[i];
        if (c == '{') {
            i++;
            Json j = Json::object();
            ws();
            if (s[i] == '}') { i++; return j; }
            for (;;) {
                ws();
                std::string k = string();
                ws();
                if (s[i] != ':') bad("expected ':'");
                i++;
                j.set(k, value());
                ws();
                if (s[i] == ',') { i++; continue; }
                if (s[i] == '}') { i++; return j; }
                bad("expected ',' or '}'");
            }
        }
        if (c == '[') {
            i++;
            Json j = Json::array();
            ws();
            if (s[i] == ']') { i++; return j; }
            for (;;) {
                j.push(value());
                ws();
                if (s[i] == ',') { i++; continue; }
                if (s[i] == ']') { i++; return j; }
                bad("expected ',' or ']'");
            }
        }
        if (c == '"') return Json(string());
        if (lit("true")) return Json(true);
        if (lit("false")) return Json(false);
        if (lit("null")) return Json();
        size_t end = i;
        while (end < s.size() && (isdigit((unsigned char)s[end]) || strchr("+-.eE", s[end]))) end++;
        if (end == i) bad("unexpected character");
        double v = std::stod(s.substr(i, end - i));
        i = end;
        return Json(v);
    }
};
}  // namespace

Json Json::parse(const std::string &text) {
    Parser p{text};
    Json j = p.value();
    p.ws();
    if (p.i != text.size()) p.bad("trailing characters");
    return j;
}

}  // namespace airc
