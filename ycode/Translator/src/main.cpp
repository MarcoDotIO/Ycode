// main.cpp: ycode-airc, the Ycode AIR -> SPIR-V translator (stage 8a, agent
// SH). Clean-room implementation from specs/simulator/metal-shaders.md and
// metal-sim-protocol.md section 6, LLVM (Apache-2.0 WITH LLVM-exception)
// and SPIRV-Tools (Apache-2.0).
//
// Usage:
//   ycode-airc version
//   ycode-airc list IN.metallib
//   ycode-airc decls IN.metallib...   (declared air.* functions and signatures, counted per module)
//   ycode-airc translate IN.metallib|IN.bc [-f NAME] [-o OUT.spv] [-r OUT.json] [-S OUT.spvasm]
//              [--opt] [--link-vertex VS.metallib[:NAME]] [--link LIB.metallib]...
//              [--constant INDEX=VALUE]... [--cache DIR]
//   ycode-airc serve [--cache DIR] [--timeout SECONDS] [--no-isolate] [--dump-dir DIR]
//   ycode-airc replay DIR [--changed-only]
//   ycode-airc corpus [--json REPORT.json] [--quiet] [--timeout SECONDS] [--opt] [--library LIB.metallib]... PATH...
//
// Exit status: 0 success, 1 translation error (a JSON error document is
// printed on stdout by `translate`), 2 usage or I/O error.
//
// Serve protocol (stdin/stdout, binary frames, little-endian):
//   frame    = u32 length L, then L bytes: u32 header length H, H bytes of
//              JSON header, L - 4 - H bytes of payload
//   request  : header {"id": any, "op": "translate" | "ping" | "version" |
//              "shutdown", "function": NAME?, "link_vertex": HASH?,
//              "varyings": {MATCH: LOCATION}?, "constants": {INDEX: VALUE}?,
//              "linked": [SIZE...]? (the payload ends with linked metallibs
//              of these sizes: visible functions the function calls),
//              "optimize": BOOL?, "assembly": BOOL?}; payload = the metallib
//              (functionIR)
//   --dump-dir DIR saves every translate request as NNNNNN.request.json
//   (header), NNNNNN.payload (payload as received) and NNNNNN.result.json
//   (status, error, key, stage, time); `replay DIR` runs them again in order.
//   Each translation runs in a forked child (a crash or a timeout becomes
//   an "internal" error reply; the server keeps running) unless
//   --no-isolate.
//   response : header {"id": same, "status": "ok", "cached": BOOL,
//              "key": CACHE_KEY, "reflection": {...}, "assembly"?: TEXT} and
//              payload = SPIR-V words; or header {"id", "status": "error",
//              "error": {"code", "detail", "function"}} and no payload.
//   "link_vertex" names the HASH of a vertex function this server
//   translated before: a fragment function's inputs then get the Locations
//   of that function's outputs with the same match strings. Cache keys use
//   the SHA-256 of the module bytes plus every option that changes output.
//
// Debugging aids (environment): AIRC_DUMP=FILE (SPIR-V text before
// validation), AIRC_DUMP_LL=FILE (LLVM IR after preparation), AIRC_STATS=1
// (phase times and sizes on stderr), AIRC_NO_SIMPLIFY=1 (skip the clean-up
// passes).
#include "cache.h"
#include "error.h"
#include "json.h"
#include "metallib.h"
#include "translator.h"

#include "llvm/Bitcode/BitcodeReader.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/InitLLVM.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/raw_ostream.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fstream>
#include <map>
#include <set>
#include <memory>
#include <poll.h>
#include <signal.h>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

using namespace airc;

static bool readFile(const std::string &path, std::string &out) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    std::ostringstream ss;
    ss << in.rdbuf();
    out = ss.str();
    return true;
}

static bool writeFile(const std::string &path, const void *data, size_t n) {
    std::ofstream o(path, std::ios::binary);
    if (!o) return false;
    o.write((const char *)data, (std::streamsize)n);
    return (bool)o;
}

static Json errorJson(const Error &e, const std::string &fn) {
    Json j = Json::object();
    j.set("code", e.code);
    j.set("detail", e.detail);
    if (!fn.empty()) j.set("function", fn);
    return j;
}

// Picks the function: by name, or the only one.
static const MetallibFunction &pick(const Metallib &lib, const std::string &name) {
    if (!name.empty()) {
        const MetallibFunction *f = lib.find(name);
        if (!f) fail("function-not-found", name);
        return *f;
    }
    if (lib.functions.size() != 1) fail("bad-request", "the metallib has " + std::to_string(lib.functions.size()) + " functions; name one");
    return lib.functions[0];
}

// One translation with the cache (shared by translate and serve).
struct Request {
    std::string function;
    std::string linkVertex;       // HASH of a vertex function translated before
    std::map<std::string, unsigned> varyings;
    bool haveVaryings = false;
    bool optimize = false;
    bool assembly = false;
    std::map<unsigned, double> constants;  // function constant values by index
    std::vector<std::string> linked;       // metallibs of linked (visible) functions
};

struct Reply {
    bool cached = false;
    std::string key;
    std::vector<uint32_t> spirv;
    Json reflection;
    std::string assembly;
};

struct Job {
    std::string key, module, name, hash, computed;
    int type = -1;
    TranslateOptions opts;
};

static bool isBitcode(const std::string &d) {
    return d.size() >= 4 && (((uint8_t)d[0] == 'B' && (uint8_t)d[1] == 'C' && (uint8_t)d[2] == 0xC0 && (uint8_t)d[3] == 0xDE) ||
                             ((uint8_t)d[0] == 0xDE && (uint8_t)d[1] == 0xC0 && (uint8_t)d[2] == 0x17 && (uint8_t)d[3] == 0x0B));
}

static Job planRequest(Cache &cache, const std::string &metallib, const Request &rq) {
    Job j;
    if (isBitcode(metallib)) {
        // A bare AIR module (tests): the function must be named.
        if (rq.function.empty()) fail("bad-request", "a bitcode input needs a function name");
        j.module = metallib;
        j.computed = j.hash = sha256Hex(j.module);
        j.name = rq.function;
    } else {
        Metallib lib = parseMetallib(metallib);
        const MetallibFunction &f = pick(lib, rq.function);
        j.module = lib.module(f);
        j.computed = sha256Hex(j.module);
        j.hash = f.hasHash ? f.hashHex() : j.computed;
        j.name = f.name;
        j.type = f.type;
    }
    TranslateOptions &opts = j.opts;
    opts.optimize = rq.optimize;
    opts.wantAssembly = rq.assembly;
    opts.functionConstantValues = rq.constants;
    if (!rq.linkVertex.empty()) {
        Json vr;
        if (!cache.reflectionByHash(rq.linkVertex, vr)) fail("bad-request", "link_vertex " + rq.linkVertex + " was not translated before");
        const Json *vy = vr.get("varyings");
        if (vr.getString("stage") != "vertex" || !vy) fail("bad-request", "link_vertex is not a vertex function");
        for (const Json &v : vy->arr) opts.varyings[v.getString("name")] = (unsigned)v.getNumber("location");
        opts.haveVaryings = true;
        opts.linkedVertexHash = rq.linkVertex;
    } else if (rq.haveVaryings) {
        opts.varyings = rq.varyings;
        opts.haveVaryings = true;
    }
    // The key uses the SHA-256 computed from the module bytes (equal to
    // HASH for well-formed input) so that altered modules never hit.
    std::string keyText = std::string(kTranslatorVersion) + "|" + j.computed + "|" + j.name + "|" + (opts.optimize ? "O" : "-");
    if (!rq.linked.empty()) {
        // Linked functions: calls to <name>.MTL_VISIBLE_FN_REF (and other
        // external functions) resolve to functions of these metallibs.
        auto libs = std::make_shared<std::vector<Metallib>>();
        for (const std::string &l : rq.linked) {
            libs->push_back(parseMetallib(l));
            for (auto &lf : libs->back().functions) keyText += "|link:" + lf.hashHex();
        }
        opts.resolveVisible = [libs](const std::string &name, std::string &module) {
            for (const Metallib &l : *libs)
                if (const MetallibFunction *g = l.find(name)) {
                    module = l.module(*g);
                    return true;
                }
            return false;
        };
    }
    if (opts.haveVaryings)
        for (auto &v : opts.varyings) keyText += "|" + v.first + "=" + std::to_string(v.second);
    for (auto &c : rq.constants) keyText += "|fc" + std::to_string(c.first) + "=" + std::to_string(c.second);
    j.key = sha256Hex(keyText);
    return j;
}

static Reply finish(Cache &cache, const Job &j, TranslateResult t) {
    if (j.computed != j.hash) t.reflection.set("hash_mismatch", true);
    cache.store(j.key, t.spirv, t.reflection);
    cache.rememberHash(j.hash, t.reflection);
    Reply r;
    r.key = j.key;
    r.spirv = std::move(t.spirv);
    r.reflection = std::move(t.reflection);
    r.assembly = std::move(t.assembly);
    return r;
}

static bool lookup(Cache &cache, const Job &j, const Request &rq, Reply &r) {
    r.key = j.key;
    if (rq.assembly || !cache.lookup(j.key, r.spirv, r.reflection)) return false;
    r.cached = true;
    cache.rememberHash(j.hash, r.reflection);
    return true;
}

static Reply translateRequest(Cache &cache, const std::string &metallib, const Request &rq) {
    Job j = planRequest(cache, metallib, rq);
    Reply r;
    if (lookup(cache, j, rq, r)) return r;
    return finish(cache, j, translate(j.module, j.name, j.hash, j.type, j.opts));
}

// Runs one translation in a child process (crash and hang isolation for
// input that comes from the guest); the result travels back over a pipe.
static bool writeAll(int fd, const void *buf, size_t n);
static TranslateResult translateIsolated(const Job &j, int timeoutSeconds) {
    int fds[2];
    if (pipe(fds) != 0) fail("internal", "pipe");
    pid_t pid = fork();
    if (pid < 0) fail("internal", "fork");
    if (pid == 0) {
        close(fds[0]);
        Json out = Json::object();
        std::vector<uint32_t> words;
        try {
            TranslateResult t = translate(j.module, j.name, j.hash, j.type, j.opts);
            out.set("ok", true);
            out.set("reflection", t.reflection);
            out.set("assembly", t.assembly);
            words = std::move(t.spirv);
        } catch (const Error &e) {
            out.set("ok", false);
            out.set("code", e.code);
            out.set("detail", e.detail);
        } catch (const std::exception &e) {
            out.set("ok", false);
            out.set("code", "internal");
            out.set("detail", e.what());
        }
        std::string h = out.dump();
        uint32_t hl = (uint32_t)h.size(), wl = (uint32_t)(words.size() * 4);
        writeAll(fds[1], &hl, 4);
        writeAll(fds[1], h.data(), h.size());
        writeAll(fds[1], &wl, 4);
        writeAll(fds[1], words.data(), wl);
        _exit(0);
    }
    close(fds[1]);
    std::string data;
    char buf[65536];
    bool timedOut = false;
    for (;;) {
        pollfd p{fds[0], POLLIN, 0};
        int pr = poll(&p, 1, timeoutSeconds * 1000);
        if (pr == 0) { timedOut = true; kill(pid, SIGKILL); break; }
        ssize_t r = read(fds[0], buf, sizeof buf);
        if (r <= 0) break;
        data.append(buf, (size_t)r);
    }
    close(fds[0]);
    int status = 0;
    waitpid(pid, &status, 0);
    if (timedOut) fail("internal", "translation timed out after " + std::to_string(timeoutSeconds) + " s");
    uint32_t hl = 0, wl = 0;
    if (data.size() < 4) fail("internal", "translator crashed (signal " + std::to_string(WIFSIGNALED(status) ? WTERMSIG(status) : 0) + ")");
    memcpy(&hl, data.data(), 4);
    if (data.size() < 8 + (size_t)hl) fail("internal", "truncated translator reply");
    Json out = Json::parse(data.substr(4, hl));
    memcpy(&wl, data.data() + 4 + hl, 4);
    if (data.size() < 8 + (size_t)hl + wl) fail("internal", "truncated translator reply");
    if (!out.getBool("ok")) throw Error(out.getString("code"), out.getString("detail"));
    TranslateResult t;
    t.reflection = *out.get("reflection");
    t.assembly = out.getString("assembly");
    t.spirv.resize(wl / 4);
    memcpy(t.spirv.data(), data.data() + 8 + hl, wl);
    return t;
}

// ---------------------------------------------------------------------------

static int cmdList(int argc, char **argv) {
    if (argc < 1) return 2;
    std::string data;
    if (!readFile(argv[0], data)) { fprintf(stderr, "ycode-airc: cannot read %s\n", argv[0]); return 2; }
    try {
        Metallib lib = parseMetallib(data);
        Json out = Json::object();
        out.set("version", std::to_string(lib.versionMajor) + "." + std::to_string(lib.versionMinor));
        out.set("platform", lib.platform);
        Json fs = Json::array();
        for (auto &f : lib.functions) {
            Json j = Json::object();
            j.set("name", f.name);
            j.set("type", f.type);
            j.set("hash", f.hashHex());
            j.set("module_size", (unsigned long long)f.moduleSize);
            fs.push(j);
        }
        out.set("functions", fs);
        printf("%s\n", out.dump(2).c_str());
    } catch (const Error &e) {
        printf("%s\n", errorJson(e, "").dump().c_str());
        return 1;
    }
    return 0;
}

static int cmdTranslate(int argc, char **argv) {
    std::string in, out, reflect, asmPath, cacheDir, linkVS;
    Request rq;
    for (int i = 0; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() -> std::string {
            if (i + 1 >= argc) { fprintf(stderr, "ycode-airc: %s needs a value\n", a.c_str()); exit(2); }
            return argv[++i];
        };
        if (a == "-f") rq.function = next();
        else if (a == "-o") out = next();
        else if (a == "-r") reflect = next();
        else if (a == "-S") asmPath = next();
        else if (a == "--opt") rq.optimize = true;
        else if (a == "--cache") cacheDir = next();
        else if (a == "--link-vertex") linkVS = next();
        else if (a == "--link") {
            std::string d;
            std::string path = next();
            if (!readFile(path, d)) { fprintf(stderr, "ycode-airc: cannot read %s\n", path.c_str()); return 2; }
            rq.linked.push_back(d);
        }
        else if (a == "--constant") {
            // INDEX=VALUE: specialize a function constant
            std::string kv = next();
            size_t eq = kv.find('=');
            if (eq == std::string::npos) { fprintf(stderr, "ycode-airc: --constant INDEX=VALUE\n"); return 2; }
            rq.constants[(unsigned)std::stoul(kv.substr(0, eq))] = std::stod(kv.substr(eq + 1));
        }
        else if (!a.empty() && a[0] == '-') { fprintf(stderr, "ycode-airc: unknown option %s\n", a.c_str()); return 2; }
        else in = a;
    }
    if (in.empty()) { fprintf(stderr, "ycode-airc translate: no input\n"); return 2; }
    std::string data;
    if (!readFile(in, data)) { fprintf(stderr, "ycode-airc: cannot read %s\n", in.c_str()); return 2; }
    rq.assembly = !asmPath.empty();
    Cache cache(cacheDir);
    try {
        if (!linkVS.empty()) {
            std::string vfile = linkVS, vname;
            size_t colon = linkVS.rfind(':');
            if (colon != std::string::npos && colon > 0) { vfile = linkVS.substr(0, colon); vname = linkVS.substr(colon + 1); }
            std::string vdata;
            if (!readFile(vfile, vdata)) { fprintf(stderr, "ycode-airc: cannot read %s\n", vfile.c_str()); return 2; }
            Request vr;
            vr.function = vname;
            Reply v = translateRequest(cache, vdata, vr);
            rq.linkVertex = v.reflection.getString("hash");
        }
        Reply r = translateRequest(cache, data, rq);
        if (!out.empty() && !writeFile(out, r.spirv.data(), r.spirv.size() * 4)) { fprintf(stderr, "ycode-airc: cannot write %s\n", out.c_str()); return 2; }
        if (!reflect.empty()) {
            std::string j = r.reflection.dump(2) + "\n";
            if (!writeFile(reflect, j.data(), j.size())) { fprintf(stderr, "ycode-airc: cannot write %s\n", reflect.c_str()); return 2; }
        }
        if (!asmPath.empty()) writeFile(asmPath, r.assembly.data(), r.assembly.size());
        if (out.empty() && reflect.empty()) printf("%s\n", r.reflection.dump(2).c_str());
    } catch (const Error &e) {
        printf("%s\n", errorJson(e, rq.function).dump().c_str());
        return 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// serve

static bool readAll(int fd, void *buf, size_t n) {
    char *p = (char *)buf;
    while (n) {
        ssize_t r = read(fd, p, n);
        if (r <= 0) return false;
        p += r;
        n -= (size_t)r;
    }
    return true;
}

static bool writeAll(int fd, const void *buf, size_t n) {
    const char *p = (const char *)buf;
    while (n) {
        ssize_t r = write(fd, p, n);
        if (r <= 0) return false;
        p += r;
        n -= (size_t)r;
    }
    return true;
}

static bool sendFrame(const Json &header, const void *payload, size_t n) {
    std::string h = header.dump();
    uint32_t hl = (uint32_t)h.size(), total = (uint32_t)(4 + h.size() + n);
    return writeAll(1, &total, 4) && writeAll(1, &hl, 4) && writeAll(1, h.data(), h.size()) && (n == 0 || writeAll(1, payload, n));
}

// Fills a Request from a serve header; `payload` keeps the main metallib.
static bool parseRequest(const Json &req, std::string &payload, Request &rq) {
    rq.function = req.getString("function");
    rq.linkVertex = req.getString("link_vertex");
    rq.optimize = req.getBool("optimize");
    rq.assembly = req.getBool("assembly");
    if (const Json *ls = req.get("linked")) {
        // Payload = the main metallib, then the linked metallibs of these sizes.
        size_t tail = 0;
        for (auto &n : ls->arr) tail += (size_t)n.num;
        if (tail > payload.size()) return false;
        size_t at = payload.size() - tail;
        for (auto &n : ls->arr) {
            rq.linked.push_back(payload.substr(at, (size_t)n.num));
            at += (size_t)n.num;
        }
        payload.resize(payload.size() - tail);
    }
    if (const Json *c = req.get("constants"))
        for (auto &p : c->obj) rq.constants[(unsigned)std::stoul(p.first)] = p.second.kind == Json::Bool ? (p.second.b ? 1 : 0) : p.second.num;
    if (const Json *v = req.get("varyings")) {
        rq.haveVaryings = true;
        for (auto &p : v->obj) rq.varyings[p.first] = (unsigned)p.second.num;
    }
    return true;
}

// serve --dump-dir: every translate request (header and payload, as
// received) and its outcome, for offline replay (`ycode-airc replay`).
static void dumpExchange(const std::string &dir, unsigned seq, const Json &req, const std::string &payload, const Json &rsp, double ms) {
    char base[32];
    snprintf(base, sizeof base, "/%06u", seq);
    std::string b = dir + base;
    std::string h = req.dump(1) + "\n";
    writeFile(b + ".request.json", h.data(), h.size());
    writeFile(b + ".payload", payload.data(), payload.size());
    Json out = Json::object();
    for (const char *k : {"status", "cached", "key", "error"})
        if (const Json *v = rsp.get(k)) out.set(k, *v);
    if (const Json *r = rsp.get("reflection")) {
        out.set("stage", r->getString("stage"));
        out.set("spirv_words", r->getNumber("spirv_words"));
        out.set("hash", r->getString("hash"));
    }
    out.set("ms", (double)(long long)(ms * 10) / 10);
    std::string o = out.dump(1) + "\n";
    writeFile(b + ".result.json", o.data(), o.size());
}

static int cmdServe(int argc, char **argv) {
    std::string cacheDir, dumpDir;
    bool isolate = true;
    int timeout = 60;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--cache") && i + 1 < argc) cacheDir = argv[++i];
        else if (!strcmp(argv[i], "--no-isolate")) isolate = false;
        else if (!strcmp(argv[i], "--timeout") && i + 1 < argc) timeout = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--dump-dir") && i + 1 < argc) dumpDir = argv[++i];
    }
    Cache cache(cacheDir);
    signal(SIGPIPE, SIG_IGN);
    unsigned seq = 0;
    if (!dumpDir.empty()) {
        mkdir(dumpDir.c_str(), 0755);
        // Continue numbering after earlier sessions in the same directory.
        if (DIR *d = opendir(dumpDir.c_str())) {
            while (dirent *e = readdir(d)) {
                unsigned n = 0;
                if (sscanf(e->d_name, "%u.request.json", &n) == 1 && n >= seq) seq = n + 1;
            }
            closedir(d);
        }
    }
    for (;;) {
        uint32_t total = 0, hl = 0;
        if (!readAll(0, &total, 4)) return 0;  // EOF: the host closed the pipe
        if (total < 4 || total > (256u << 20)) { fprintf(stderr, "ycode-airc serve: bad frame length %u\n", total); return 2; }
        std::string frame(total, '\0');
        if (!readAll(0, &frame[0], total)) return 2;
        memcpy(&hl, frame.data(), 4);
        Json rsp = Json::object();
        if (hl > total - 4) {
            rsp.set("status", "error");
            rsp.set("error", errorJson(Error("bad-request", "header length out of bounds"), ""));
            if (!sendFrame(rsp, nullptr, 0)) return 2;
            continue;
        }
        std::string payload = frame.substr(4 + hl);
        Json req;
        try {
            req = Json::parse(frame.substr(4, hl));
        } catch (const std::exception &e) {
            rsp.set("status", "error");
            rsp.set("error", errorJson(Error("bad-request", e.what()), ""));
            if (!sendFrame(rsp, nullptr, 0)) return 2;
            continue;
        }
        if (const Json *id = req.get("id")) rsp.set("id", *id);
        std::string op = req.getString("op", "translate");
        if (op == "ping") {
            rsp.set("status", "ok");
            if (!sendFrame(rsp, nullptr, 0)) return 2;
            continue;
        }
        if (op == "version") {
            rsp.set("status", "ok");
            rsp.set("version", kTranslatorVersion);
            if (!sendFrame(rsp, nullptr, 0)) return 2;
            continue;
        }
        if (op == "shutdown") {
            rsp.set("status", "ok");
            sendFrame(rsp, nullptr, 0);
            return 0;
        }
        std::string fullPayload = payload;
        Request rq;
        if (!parseRequest(req, payload, rq)) {
            rsp.set("status", "error");
            rsp.set("error", errorJson(Error("bad-request", "linked sizes exceed the payload"), ""));
            if (!dumpDir.empty()) dumpExchange(dumpDir, seq++, req, fullPayload, rsp, 0);
            if (!sendFrame(rsp, nullptr, 0)) return 2;
            continue;
        }
        auto t0 = std::chrono::steady_clock::now();
        try {
            if (op != "translate") fail("bad-request", "unknown op " + op);
            Job job = planRequest(cache, payload, rq);
            Reply r;
            if (!lookup(cache, job, rq, r))
                r = finish(cache, job, isolate ? translateIsolated(job, timeout) : translate(job.module, job.name, job.hash, job.type, job.opts));
            rsp.set("status", "ok");
            rsp.set("cached", r.cached);
            rsp.set("key", r.key);
            rsp.set("reflection", r.reflection);
            if (rq.assembly) rsp.set("assembly", r.assembly);
            if (!dumpDir.empty())
                dumpExchange(dumpDir, seq++, req, fullPayload, rsp, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
            if (!sendFrame(rsp, r.spirv.data(), r.spirv.size() * 4)) return 2;
        } catch (const Error &e) {
            rsp.set("status", "error");
            rsp.set("error", errorJson(e, rq.function));
            if (!dumpDir.empty())
                dumpExchange(dumpDir, seq++, req, fullPayload, rsp, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
            if (!sendFrame(rsp, nullptr, 0)) return 2;
        }
    }
}

// ---------------------------------------------------------------------------
// corpus: translate every function of every metallib under the given paths,
// each in a child process (a crash or a hang counts as a failure), and
// report statistics. Nothing is written except the report.

static void collect(const std::string &path, std::vector<std::string> &files) {
    struct stat st;
    if (stat(path.c_str(), &st) != 0) return;
    if (S_ISDIR(st.st_mode)) {
        DIR *d = opendir(path.c_str());
        if (!d) return;
        std::vector<std::string> names;
        while (dirent *e = readdir(d)) {
            std::string n = e->d_name;
            if (n == "." || n == "..") continue;
            names.push_back(n);
        }
        closedir(d);
        std::sort(names.begin(), names.end());
        for (auto &n : names) collect(path + "/" + n, files);
        return;
    }
    if (path.size() > 9 && path.compare(path.size() - 9, 9, ".metallib") == 0) files.push_back(path);
}

static int cmdCorpus(int argc, char **argv) {
    std::vector<std::string> paths, files;
    std::string report;
    bool quiet = false, optimize = false;
    int timeout = 120;
    std::vector<Metallib> libraries;  // --library: extra metallibs that define linked functions
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--library") && i + 1 < argc) {
            std::string d;
            if (!readFile(argv[++i], d)) { fprintf(stderr, "ycode-airc: cannot read %s\n", argv[i]); return 2; }
            try { libraries.push_back(parseMetallib(d)); } catch (const Error &e) { fprintf(stderr, "ycode-airc: %s: %s\n", argv[i], e.what()); return 2; }
        } else if (!strcmp(argv[i], "--json") && i + 1 < argc) report = argv[++i];
        else if (!strcmp(argv[i], "--quiet")) quiet = true;
        else if (!strcmp(argv[i], "--opt")) optimize = true;
        else if (!strcmp(argv[i], "--timeout") && i + 1 < argc) timeout = atoi(argv[++i]);
        else paths.push_back(argv[i]);
    }
    for (auto &p : paths) collect(p, files);
    Json results = Json::array();
    std::map<std::string, int> byReason;
    std::map<std::string, int> byStatus;
    unsigned total = 0;
    double totalMs = 0;
    for (auto &file : files) {
        std::string data;
        if (!readFile(file, data)) continue;
        Metallib lib;
        try {
            lib = parseMetallib(data);
        } catch (const Error &e) {
            Json j = Json::object();
            j.set("file", file);
            j.set("status", "error");
            j.set("error", errorJson(e, ""));
            results.push(j);
            byReason["bad-container: " + e.detail]++;
            continue;
        }
        for (auto &f : lib.functions) {
            total++;
            int fds[2];
            if (pipe(fds) != 0) return 2;
            auto t0 = std::chrono::steady_clock::now();
            pid_t pid = fork();
            if (pid == 0) {
                close(fds[0]);
                Json j = Json::object();
                try {
                    TranslateOptions o;
                    o.wrapVisible = true;
                    o.optimize = optimize;
                    // Link visible functions of the same library on demand.
                    o.resolveVisible = [&](const std::string &name, std::string &module) {
                        if (const MetallibFunction *g = lib.find(name)) {
                            module = lib.module(*g);
                            return true;
                        }
                        for (const Metallib &l : libraries)
                            if (const MetallibFunction *g = l.find(name)) {
                                module = l.module(*g);
                                return true;
                            }
                        return false;
                    };
                    TranslateResult r = translate(lib.module(f), f.name, f.hashHex(), f.type, o);
                    j.set("status", "ok");
                    if (r.reflection.getBool("wrapped_visible_function")) j.set("wrapped", true);
                    j.set("words", (unsigned long long)r.spirv.size());
                } catch (const Error &e) {
                    j.set("status", "error");
                    j.set("error", errorJson(e, ""));
                } catch (const std::exception &e) {
                    j.set("status", "error");
                    j.set("error", errorJson(Error("internal", e.what()), ""));
                }
                std::string s = j.dump();
                writeAll(fds[1], s.data(), s.size());
                _exit(0);
            }
            close(fds[1]);
            std::string out;
            char buf[4096];
            bool timedOut = false;
            for (;;) {
                pollfd p{fds[0], POLLIN, 0};
                int pr = poll(&p, 1, timeout * 1000);
                if (pr == 0) { timedOut = true; kill(pid, SIGKILL); break; }
                ssize_t r = read(fds[0], buf, sizeof buf);
                if (r <= 0) break;
                out.append(buf, (size_t)r);
            }
            close(fds[0]);
            int status = 0;
            waitpid(pid, &status, 0);
            double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
            totalMs += ms;
            Json j;
            if (timedOut) {
                j = Json::object();
                j.set("status", "error");
                j.set("error", errorJson(Error("internal", "timeout"), ""));
            } else if (out.empty()) {
                j = Json::object();
                j.set("status", "error");
                j.set("error", errorJson(Error("internal", "crash (signal " + std::to_string(WIFSIGNALED(status) ? WTERMSIG(status) : 0) + ")"), ""));
            } else {
                try { j = Json::parse(out); } catch (...) { j = Json::object(); j.set("status", "error"); }
            }
            Json rec = Json::object();
            rec.set("file", file);
            rec.set("function", f.name);
            rec.set("type", f.type);
            rec.set("ms", (double)(long long)(ms * 10) / 10);
            for (auto &p : j.obj) rec.set(p.first, p.second);
            std::string st = j.getString("status");
            byStatus[st]++;
            if (j.getBool("wrapped")) byStatus["wrapped"]++;
            if (st != "ok") {
                const Json *e = j.get("error");
                std::string reason = e ? e->getString("code") + ": " + e->getString("detail") : "?";
                if (reason.size() > 160) reason = reason.substr(0, 160);
                byReason[reason]++;
                if (!quiet) fprintf(stderr, "FAIL %s %s: %s\n", file.c_str(), f.name.c_str(), reason.c_str());
            }
            results.push(rec);
        }
    }
    Json summary = Json::object();
    summary.set("functions", total);
    summary.set("ok", byStatus["ok"]);
    summary.set("failed", (int)total - byStatus["ok"]);
    summary.set("ok_visible_in_test_kernel", byStatus["wrapped"]);
    summary.set("total_ms", (long long)totalMs);
    Json reasons = Json::array();
    std::vector<std::pair<int, std::string>> sorted;
    for (auto &r : byReason) sorted.push_back({r.second, r.first});
    std::sort(sorted.rbegin(), sorted.rend());
    for (auto &r : sorted) {
        Json j = Json::object();
        j.set("count", r.first);
        j.set("reason", r.second);
        reasons.push(j);
    }
    summary.set("reasons", reasons);
    printf("%s\n", summary.dump(2).c_str());
    if (!report.empty()) {
        Json all = Json::object();
        all.set("summary", summary);
        all.set("results", results);
        std::string s = all.dump(1);
        writeFile(report, s.data(), s.size());
    }
    return 0;
}

// decls: the declared air.* functions of every module with their LLVM
// signatures (names and types only), counted over the modules, for
// intrinsic inventories.
static int cmdDecls(int argc, char **argv) {
    std::map<std::string, int> counts;
    for (int a = 0; a < argc; a++) {
        std::string data;
        if (!readFile(argv[a], data)) continue;
        Metallib lib;
        try { lib = parseMetallib(data); } catch (...) { continue; }
        std::set<uint64_t> seen;
        for (auto &f : lib.functions) {
            if (!seen.insert(f.moduleOffset).second) continue;
            llvm::LLVMContext ctx;
            std::string mod = lib.module(f);
            auto m = llvm::parseBitcodeFile(llvm::MemoryBufferRef(llvm::StringRef(mod), "air"), ctx);
            if (!m) { llvm::consumeError(m.takeError()); continue; }
            for (llvm::Function &G : **m) {
                if (!G.isDeclaration() || !G.getName().starts_with("air.")) continue;
                std::string sig;
                llvm::raw_string_ostream os(sig);
                G.getFunctionType()->print(os);
                counts[G.getName().str() + " | " + os.str()]++;
            }
        }
    }
    for (auto &c : counts) printf("%6d %s\n", c.second, c.first.c_str());
    return 0;
}

// replay DIR: runs the requests a `serve --dump-dir` saved, in order, in one
// cache (so link_vertex resolves as it did), and compares the outcomes.
static int cmdReplay(int argc, char **argv) {
    if (argc < 1) { fprintf(stderr, "usage: ycode-airc replay DIR [--changed-only]\n"); return 2; }
    std::string dir = argv[0];
    bool changedOnly = argc > 1 && !strcmp(argv[1], "--changed-only");
    std::vector<unsigned> seqs;
    if (DIR *d = opendir(dir.c_str())) {
        while (dirent *e = readdir(d)) {
            unsigned n = 0;
            char tail[64] = {0};
            if (sscanf(e->d_name, "%u%63s", &n, tail) == 2 && !strcmp(tail, ".request.json")) seqs.push_back(n);
        }
        closedir(d);
    }
    std::sort(seqs.begin(), seqs.end());
    Cache cache("");
    std::map<std::string, int> counts;
    for (unsigned n : seqs) {
        char base[32];
        snprintf(base, sizeof base, "/%06u", n);
        std::string h, payload, before;
        if (!readFile(dir + base + ".request.json", h) || !readFile(dir + base + ".payload", payload)) continue;
        readFile(dir + base + ".result.json", before);
        std::string was = "?";
        try {
            Json b = Json::parse(before);
            was = b.getString("status");
            if (const Json *e = b.get("error")) was += " " + e->getString("code") + ": " + e->getString("detail");
        } catch (...) {}
        std::string now;
        Json req;
        try {
            req = Json::parse(h);
            Request rq;
            if (!parseRequest(req, payload, rq)) fail("bad-request", "linked sizes exceed the payload");
            Job job = planRequest(cache, payload, rq);
            Reply r;
            if (!lookup(cache, job, rq, r)) r = finish(cache, job, translateIsolated(job, 60));
            now = "ok";
        } catch (const Error &e) {
            now = "error " + e.code + ": " + e.detail;
        } catch (const std::exception &e) {
            now = std::string("error bad-request: ") + e.what();
        }
        bool changed = now.substr(0, 2) != was.substr(0, 2) || (now != "ok" && now != was);
        counts[now == "ok" ? "ok" : "error"]++;
        if (changed) counts["changed"]++;
        if (!changedOnly || changed)
            printf("%06u %-40s was: %s\n       %-40s now: %s\n", n, req.getString("function").c_str(), was.substr(0, 160).c_str(), "", now.substr(0, 160).c_str());
    }
    printf("replayed %zu requests: %d ok, %d errors, %d changed\n", seqs.size(), counts["ok"], counts["error"], counts["changed"]);
    return 0;
}

int main(int argc, char **argv) {
    if (const char *o = getenv("AIRC_LLVM_OPTIONS")) {
        // Experiments: LLVM options such as pass thresholds.
        std::vector<std::string> words;
        std::istringstream ss(o);
        for (std::string w; ss >> w;) words.push_back(w);
        std::vector<const char *> av{"ycode-airc"};
        for (auto &w : words) av.push_back(w.c_str());
        llvm::cl::ParseCommandLineOptions((int)av.size(), av.data());
    }
    if (argc < 2) {
        fprintf(stderr,
                "usage: ycode-airc version | list IN.metallib | translate IN.metallib [-f NAME] [-o OUT.spv] [-r OUT.json] "
                "[-S OUT.spvasm] [--opt] [--link-vertex VS.metallib[:NAME]] [--constant INDEX=VALUE]... [--cache DIR] | "
                "serve [--cache DIR] [--timeout S] [--no-isolate] [--dump-dir DIR] | replay DIR [--changed-only] | "
                "corpus [--json REPORT] [--quiet] [--timeout S] [--opt] [--library LIB.metallib]... PATH...\n");
        return 2;
    }
    std::string cmd = argv[1];
    if (cmd == "version") { printf("%s\n", kTranslatorVersion); return 0; }
    if (cmd == "list") return cmdList(argc - 2, argv + 2);
    if (cmd == "decls") return cmdDecls(argc - 2, argv + 2);
    if (cmd == "replay") return cmdReplay(argc - 2, argv + 2);
    if (cmd == "translate") return cmdTranslate(argc - 2, argv + 2);
    if (cmd == "serve") return cmdServe(argc - 2, argv + 2);
    if (cmd == "corpus") return cmdCorpus(argc - 2, argv + 2);
    fprintf(stderr, "ycode-airc: unknown command %s\n", cmd.c_str());
    return 2;
}
