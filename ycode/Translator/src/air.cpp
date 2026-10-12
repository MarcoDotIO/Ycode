// air.cpp: AIR metadata readers.
#include "air.h"

#include "error.h"

#include "llvm/IR/Constants.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Metadata.h"
#include "llvm/IR/Module.h"

#include <cmath>

using namespace llvm;

namespace airc {

bool AirNode::has(const std::string &k) const {
    for (auto &p : keys)
        if (p.first == k) return true;
    return false;
}

int64_t AirNode::intAt(const std::string &k, unsigned i, int64_t dflt) const {
    for (auto &p : keys)
        if (p.first == k && i < p.second.size())
            if (auto *C = mdconst::dyn_extract_or_null<ConstantInt>(p.second[i])) return C->getSExtValue();
    return dflt;
}

std::string AirNode::strAt(const std::string &k, unsigned i) const {
    for (auto &p : keys)
        if (p.first == k && i < p.second.size())
            if (auto *S = dyn_cast_or_null<MDString>(p.second[i])) return S->getString().str();
    return "";
}

int AirNode::location() const {
    if (kind == "air.render_target") return (int)intAt(kind, 0, -1);
    return (int)intAt("air.location_index", 0, -1);
}

GlobalVariable *AirNode::locationGlobal() const {
    for (auto &p : keys)
        if (p.first == "air.location_index" && !p.second.empty())
            if (auto *V = dyn_cast_or_null<ValueAsMetadata>(p.second[0]))
                return dyn_cast<GlobalVariable>(V->getValue()->stripPointerCasts());
    return nullptr;
}

std::string AirNode::access() const {
    for (const char *a : {"air.read_write", "air.read", "air.write", "air.sample"})
        if (has(a)) return std::string(a + 4);
    return "";
}

const char *stageName(Stage s) {
    switch (s) {
    case Stage::Vertex: return "vertex";
    case Stage::Fragment: return "fragment";
    case Stage::Kernel: return "kernel";
    }
    return "?";
}

// Parses a node; `first` is the operand index of the kind string.
static AirNode parseNode(MDNode *N, unsigned first) {
    AirNode n;
    auto *K = dyn_cast_or_null<MDString>(N->getOperand(first).get());
    // [[function_constant(name)]] on an argument or output: the node starts
    // with air.function_constant and a {predicate global, type, name} node.
    if (K && K->getString() == "air.function_constant" && first + 2 < N->getNumOperands()) {
        if (auto *P = dyn_cast_or_null<MDNode>(N->getOperand(first + 1).get()))
            if (P->getNumOperands() > 2)
                if (auto *S = dyn_cast_or_null<MDString>(P->getOperand(2).get())) n.fcPredicate = S->getString().str();
        first += 2;
        K = dyn_cast_or_null<MDString>(N->getOperand(first).get());
    }
    if (!K) fail("internal", "AIR node without a kind string");
    n.kind = K->getString().str();
    // The kind is a key too: its own values (render-target indices) follow it.
    n.keys.push_back({n.kind, {}});
    for (unsigned i = first + 1; i < N->getNumOperands(); i++) {
        Metadata *M = N->getOperand(i).get();
        if (auto *S = dyn_cast_or_null<MDString>(M)) {
            StringRef s = S->getString();
            if (s.starts_with("air.")) {
                n.keys.push_back({s.str(), {}});
                continue;
            }
            if (n.ident.empty() && n.keys.size() == 1 &&
                (n.kind == "air.vertex_output" || n.kind == "air.fragment_input")) {
                n.ident = s.str();
                continue;
            }
        }
        n.keys.back().second.push_back(M);
    }
    return n;
}

EntryInfo entryInfo(Module &M, Function *F) {
    static const std::pair<const char *, Stage> lists[] = {
        {"air.vertex", Stage::Vertex}, {"air.fragment", Stage::Fragment}, {"air.kernel", Stage::Kernel}};
    for (auto &l : lists) {
        NamedMDNode *K = M.getNamedMetadata(l.first);
        if (!K) continue;
        for (MDNode *N : K->operands()) {
            auto *FV = dyn_cast_or_null<ValueAsMetadata>(N->getOperand(0).get());
            if (!FV || FV->getValue()->stripPointerCasts() != F) continue;
            EntryInfo e;
            e.stage = l.second;
            e.fn = F;
            if (N->getNumOperands() < 3) fail("internal", "entry node with fewer than 3 operands");
            for (const MDOperand &O : cast<MDNode>(N->getOperand(1).get())->operands())
                e.outputs.push_back(parseNode(cast<MDNode>(O.get()), 0));
            for (const MDOperand &AO : cast<MDNode>(N->getOperand(2).get())->operands()) {
                auto *A = cast<MDNode>(AO.get());
                auto *idx = mdconst::dyn_extract_or_null<ConstantInt>(A->getOperand(0));
                if (!idx) fail("internal", "argument node without an index");
                AirNode n = parseNode(A, 1);
                n.argIndex = (int)idx->getZExtValue();
                e.args[(unsigned)n.argIndex] = n;
            }
            return e;
        }
    }
    static const char *others[] = {"air.visible", "air.ci", "air.mesh", "air.object", "air.intersection", "air.tile"};
    for (const char *o : others)
        if (NamedMDNode *K = M.getNamedMetadata(o))
            for (MDNode *N : K->operands())
                if (N->getNumOperands())
                    if (auto *FV = dyn_cast_or_null<ValueAsMetadata>(N->getOperand(0).get()))
                        if (FV->getValue()->stripPointerCasts() == F)
                            fail("unsupported-stage", std::string(o + 4) + " function");
    fail("not-an-entry-point", F->getName().str());
}

std::vector<ConstexprSampler> constexprSamplers(Module &M) {
    std::vector<ConstexprSampler> out;
    NamedMDNode *S = M.getNamedMetadata("air.sampler_states");
    if (!S) return out;
    for (MDNode *N : S->operands()) {
        // Operands: a name string and the global (order as observed); find the global.
        for (const MDOperand &O : N->operands()) {
            auto *V = dyn_cast_or_null<ValueAsMetadata>(O.get());
            if (!V) continue;
            auto *G = dyn_cast<GlobalVariable>(V->getValue()->stripPointerCasts());
            if (!G) continue;
            ConstexprSampler cs;
            cs.global = G;
            if (G->hasInitializer()) {
                Constant *I = G->getInitializer();
                if (auto *C = dyn_cast_or_null<ConstantInt>(I->getAggregateElement(0u))) cs.word0 = C->getZExtValue();
                if (auto *C = dyn_cast_or_null<ConstantInt>(I->getAggregateElement(1u))) cs.word1 = C->getZExtValue();
            }
            out.push_back(cs);
        }
    }
    return out;
}

std::vector<FunctionConstant> functionConstants(Module &M) {
    std::vector<FunctionConstant> out;
    NamedMDNode *L = M.getNamedMetadata("air.function_constants");
    if (!L) return out;
    for (MDNode *N : L->operands()) {
        if (N->getNumOperands() < 4) continue;
        FunctionConstant fc;
        if (auto *V = dyn_cast_or_null<ValueAsMetadata>(N->getOperand(0).get()))
            fc.init = dyn_cast<GlobalVariable>(V->getValue()->stripPointerCasts());
        if (auto *S = dyn_cast_or_null<MDString>(N->getOperand(1).get())) fc.typeName = S->getString().str();
        if (auto *S = dyn_cast_or_null<MDString>(N->getOperand(2).get())) fc.name = S->getString().str();
        if (auto *C = mdconst::dyn_extract_or_null<ConstantInt>(N->getOperand(3))) fc.index = (unsigned)C->getZExtValue();
        if (!fc.init) continue;
        // The static initializer copies the initializer global into the
        // internal global that functions load: store (load INIT), VALUE.
        for (User *U : fc.init->users()) {
            auto *LI = dyn_cast<LoadInst>(U);
            if (!LI) continue;
            for (User *LU : LI->users())
                if (auto *SI = dyn_cast<StoreInst>(LU))
                    if (auto *G = dyn_cast<GlobalVariable>(SI->getPointerOperand()->stripPointerCasts())) fc.value = G;
        }
        out.push_back(fc);
    }
    return out;
}

static float halfToFloat(uint16_t h) {
    unsigned e = (h >> 10) & 31, m = h & 1023;
    float v;
    if (e == 0) v = std::ldexp((float)m, -24);
    else if (e == 31) v = m ? NAN : INFINITY;
    else v = std::ldexp((float)(m | 1024), (int)e - 25);
    return (h & 0x8000) ? -v : v;
}

SamplerFields decodeSampler(uint64_t w) {
    SamplerFields f;
    f.addrS = w & 7;
    f.addrT = (w >> 3) & 7;
    f.addrR = (w >> 6) & 7;
    f.magFilter = (w >> 9) & 3;
    f.minFilter = (w >> 11) & 3;
    f.mipFilter = (w >> 13) & 3;
    f.normalized = ((w >> 15) & 1) ? 0 : 1;
    f.compare = (w >> 16) & 7;
    f.maxAnisotropy = (unsigned)(((w >> 19) & 31) + 1) / 2;
    f.lodMin = halfToFloat((uint16_t)(w >> 24));
    f.lodMax = halfToFloat((uint16_t)(w >> 40));
    f.borderColor = (w >> 56) & 3;
    f.reduction = (w >> 58) & 3;
    return f;
}

}  // namespace airc
