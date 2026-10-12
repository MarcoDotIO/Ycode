// intrinsics.cpp: lowering of air.* and llvm.* calls (metal-shaders.md
// sections 3.9, 4.6 and 4.7). Operand layouts come from our own probe
// shaders (tests/shaders/*.metal compiled with the public toolchain).
#include "translator_impl.h"

#include "llvm/IR/Constants.h"
#include "llvm/IR/IntrinsicInst.h"

using namespace llvm;

namespace airc {

static unsigned numElements(Type *T) { return T->isVectorTy() ? cast<FixedVectorType>(T)->getNumElements() : 1; }

// ---------------------------------------------------------------------------
// Bindless heap (abi.h)

std::string Translator::imageType(const ImageKind &k, bool storage) {
    std::string st = k.sampled == 'f' ? E.tFloat(32) : k.sampled == 'i' ? E.tSInt(32) : E.tInt(32);
    std::string key = "img" + k.dim + (k.arrayed ? "a" : "") + (k.ms ? "m" : "") + (k.depth ? "d" : "") + k.sampled + (storage ? "s" : "t");
    if (k.dim == "1D") E.caps.insert(storage ? "Image1D" : "Sampled1D");
    if (k.dim == "Cube" && k.arrayed) E.caps.insert(storage ? "ImageCubeArray" : "SampledCubeArray");
    if (k.ms && k.arrayed && storage) E.caps.insert("ImageMSArray");
    if (storage && k.ms) E.caps.insert("StorageImageMultisample");
    return E.global(key, "OpTypeImage " + st + " " + k.dim + " " + (k.depth ? "1" : "0") + " " + (k.arrayed ? "1" : "0") + " " +
                             (k.ms ? "1" : "0") + " " + (storage ? "2" : "1") + " Unknown");
}

std::string Translator::heapImage(const std::string &handle, const ImageKind &k, bool storage) {
    std::string it = imageType(k, storage);
    std::string key = it;
    auto vit = heapVars.find(key);
    std::string var;
    if (vit == heapVars.end()) {
        E.caps.insert("RuntimeDescriptorArray");
        E.caps.insert("ShaderNonUniform");
        E.caps.insert(storage ? "StorageImageArrayNonUniformIndexing" : "SampledImageArrayNonUniformIndexing");
        if (storage) {
            E.caps.insert("StorageImageReadWithoutFormat");
            E.caps.insert("StorageImageWriteWithoutFormat");
        }
        std::string rt = E.global("rt" + it, "OpTypeRuntimeArray " + it);
        var = E.fresh();
        std::string pt = E.tPtr("UniformConstant", rt);
        E.globals << var << " = OpVariable " << pt << " UniformConstant\n";
        E.decorate(var, "DescriptorSet " + std::to_string(abi::kSet));
        E.decorate(var, "Binding " + std::to_string(storage ? abi::kBindingStorageImages : abi::kBindingSampledImages));
        E.interface.push_back(var);
        heapVars[key] = var;
    } else {
        var = vit->second;
    }
    std::string idx = toU32(handle);
    E.decorate(idx, "NonUniform");
    std::string p = E.op("OpAccessChain", E.tPtr("UniformConstant", it), {var, idx});
    E.decorate(p, "NonUniform");
    std::string img = E.op("OpLoad", it, {p});
    E.decorate(img, "NonUniform");
    return img;
}

std::string Translator::heapSampler(const std::string &handle) {
    std::string st = E.global("sampler", "OpTypeSampler");
    std::string var;
    auto vit = heapVars.find("sampler");
    if (vit == heapVars.end()) {
        E.caps.insert("RuntimeDescriptorArray");
        E.caps.insert("ShaderNonUniform");
        std::string rt = E.global("rtsampler", "OpTypeRuntimeArray " + st);
        var = E.fresh();
        std::string pt = E.tPtr("UniformConstant", rt);
        E.globals << var << " = OpVariable " << pt << " UniformConstant\n";
        E.decorate(var, "DescriptorSet " + std::to_string(abi::kSet));
        E.decorate(var, "Binding " + std::to_string(abi::kBindingSamplers));
        E.interface.push_back(var);
        heapVars["sampler"] = var;
    } else {
        var = vit->second;
    }
    std::string idx = toU32(handle);
    E.decorate(idx, "NonUniform");
    std::string p = E.op("OpAccessChain", E.tPtr("UniformConstant", st), {var, idx});
    E.decorate(p, "NonUniform");
    std::string s = E.op("OpLoad", st, {p});
    E.decorate(s, "NonUniform");
    return s;
}

// ---------------------------------------------------------------------------
// Textures

namespace {
struct TexName {
    std::string op;      // sample, sample_compare, gather, gather_compare, read, write, get_width, ...
    bool depth = false;
    bool grad = false;
    ImageKind kind;
    std::string dimToken;
};
}  // namespace

static bool parseTexName(StringRef n, TexName &t) {
    static const char *ops[] = {"sample_compare", "gather_compare", "sample", "gather", "read", "write",
                                "get_width", "get_height", "get_depth", "get_array_size", "get_num_mip_levels",
                                "get_num_samples", "is_null", "get_null"};
    if (!n.consume_front("air.")) return false;
    for (const char *o : ops) {
        StringRef s = n;
        if (!s.consume_front(o)) continue;
        if (!s.consume_front("_")) continue;
        bool depth;
        if (s.consume_front("texture_")) depth = false;
        else if (s.consume_front("depth_")) depth = true;
        else continue;
        t.op = o;
        t.depth = depth;
        StringRef dim = s.take_until([](char c) { return c == '.'; });
        if (dim.consume_back("_grad")) t.grad = true;
        t.dimToken = dim.str();
        ImageKind &k = t.kind;
        k.depth = depth;
        if (dim.consume_back("_array")) k.arrayed = true;
        if (dim.consume_back("_ms")) k.ms = true;
        if (dim == "1d") k.dim = "1D";
        else if (dim == "2d") k.dim = "2D";
        else if (dim == "3d") k.dim = "3D";
        else if (dim == "cube") k.dim = "Cube";
        else if (dim == "buffer_1d" || dim == "buffer") k.dim = "Buffer";
        else return false;
        StringRef rest = s.drop_front(t.dimToken.size());
        k.sampled = 'f';
        SmallVector<StringRef, 6> parts;
        rest.split(parts, '.');
        for (StringRef q : parts) {
            if (q == "u") k.sampled = 'u';
            else if (q == "s") k.sampled = 'i';
        }
        return true;
    }
    return false;
}

bool Translator::callTexture(CallInst *C, StringRef name) {
    TexName t;
    if (!parseTexName(name, t)) return false;
    if (t.kind.dim == "Buffer") fail("unsupported-feature", "texture buffers: " + name.str());
    auto arg = [&](unsigned i) -> Value * {
        if (i >= C->arg_size()) fail("unsupported-intrinsic", name.str() + " (unexpected operand count)");
        return C->getArgOperand(i);
    };
    Type *RT = C->getType();
    std::string f32 = E.tFloat(32), u32 = E.tInt(32);
    ImageKind &k = t.kind;
    bool cube = k.dim == "Cube";

    if (t.op == "is_null") {
        bind(C, E.op("OpIEqual", E.tBool(), {val(arg(0)), E.u64(0)}));
        return true;
    }
    if (t.op == "get_null") {
        bind(C, E.u64(0));
        return true;
    }
    if (t.op.rfind("get_", 0) == 0) {
        E.caps.insert("ImageQuery");
        std::string img = heapImage(val(arg(0)), k, false);
        std::string r;
        if (t.op == "get_num_mip_levels") r = E.op("OpImageQueryLevels", u32, {img});
        else if (t.op == "get_num_samples") r = E.op("OpImageQuerySamples", u32, {img});
        else {
            unsigned n = (k.dim == "1D" ? 1 : k.dim == "3D" ? 3 : 2) + (k.arrayed ? 1 : 0);
            std::string st = E.tVec(u32, n);
            std::string size;
            if (k.ms) size = E.op("OpImageQuerySize", st, {img});
            else {
                std::string lod = C->arg_size() > 1 ? val(arg(1)) : E.u32(0);
                size = E.op("OpImageQuerySizeLod", st, {img, lod});
            }
            unsigned comp = t.op == "get_width" ? 0 : t.op == "get_height" ? 1 : t.op == "get_depth" ? 2 : n - 1;
            r = n == 1 ? size : E.op("OpCompositeExtract", u32, {size, std::to_string(comp)});
        }
        bind(C, castInt(r, Type::getInt32Ty(C->getContext()), RT->getScalarSizeInBits(), false));
        return true;
    }

    // Result element type: {<4 x T>, i8} or {T, i8} for depth.
    Type *valT = RT->isStructTy() ? RT->getStructElementType(0) : nullptr;
    std::string sampledT = k.sampled == 'f' ? f32 : k.sampled == 'i' ? E.tSInt(32) : u32;
    std::string v4 = E.tVec(sampledT, 4);
    // Converts a vec4 of the image's sampled type to the AIR value type.
    auto finish = [&](const std::string &v4val) {
        std::string v = v4val;
        Type *el = valT->getScalarType();
        unsigned n = numElements(valT);
        if (k.sampled == 'i') v = E.op("OpBitcast", E.tVec(u32, 4), {v});
        if (n != 4) {
            if (n == 1) v = E.op("OpCompositeExtract", k.sampled == 'f' ? f32 : u32, {v, "0"});
            else {
                std::vector<std::string> a = {v, v};
                for (unsigned i = 0; i < n; i++) a.push_back(std::to_string(i));
                v = E.op("OpVectorShuffle", E.tVec(k.sampled == 'f' ? f32 : u32, n), a);
            }
        }
        if (el->isHalfTy()) v = E.op("OpFConvert", type(valT), {v});
        else if (el->isIntegerTy() && el->getIntegerBitWidth() != 32) v = E.op(k.sampled == 'i' ? "OpSConvert" : "OpUConvert", type(valT), {v});
        std::string r = E.op("OpCompositeConstruct", type(RT), {v, E.constant(E.tInt(8), "0")});
        bind(C, r);
    };
    // Coordinates with the array layer appended (as float for sampling).
    auto coordWithLayer = [&](Value *coord, Value *layer, bool asFloat, std::string c = "") {
        if (c.empty()) {
            // Image coordinates are 32-bit (ushort coordinates and half
            // coordinates are widened).
            c = val(coord);
            Type *CT = coord->getType();
            if (CT->getScalarType()->isIntegerTy() && CT->getScalarSizeInBits() != 32) c = castInt(c, CT, 32, false);
            else if (CT->getScalarType()->isHalfTy()) c = E.op("OpFConvert", E.tVec(f32, numElements(CT)), {c});
        }
        if (!layer) return c;
        unsigned n = coord ? numElements(coord->getType()) : 2;
        std::string l = castInt(val(layer), layer->getType(), 32, false);
        std::string et = asFloat ? f32 : u32;
        if (asFloat) l = E.op("OpConvertUToF", f32, {l});
        if (n == 1) return E.op("OpCompositeConstruct", E.tVec(et, 2), {c, l});
        std::vector<std::string> parts;
        for (unsigned i = 0; i < n; i++) parts.push_back(E.op("OpCompositeExtract", et, {c, std::to_string(i)}));
        parts.push_back(l);
        return E.op("OpCompositeConstruct", E.tVec(et, n + 1), parts);
    };
    // Offset image operand: ConstOffset when constant non-zero, Offset otherwise.
    auto offsetOperand = [&](Value *off, std::string &ops, std::vector<std::string> &opv) {
        if (!off) return;
        std::string o;
        if (auto *Cst = dyn_cast<Constant>(off)) {
            if (Cst->isNullValue()) return;
            ops += ops.empty() ? "ConstOffset" : "|ConstOffset";
            // Offsets are 32-bit signed integers (ushort forms carry i16).
            Type *OT = off->getType();
            if (OT->getScalarSizeInBits() != 32) {
                Type *I32 = Type::getInt32Ty(C->getContext());
                if (auto *VT = dyn_cast<FixedVectorType>(OT)) {
                    std::vector<Constant *> el;
                    for (unsigned j = 0; j < VT->getNumElements(); j++) {
                        auto *CI = dyn_cast<ConstantInt>(Cst->getAggregateElement(j));
                        el.push_back(ConstantInt::get(I32, CI ? (uint64_t)CI->getSExtValue() : 0, true));
                    }
                    o = constant(ConstantVector::get(el));
                } else {
                    o = constant(ConstantInt::get(I32, (uint64_t)cast<ConstantInt>(Cst)->getSExtValue(), true));
                }
            } else {
                o = val(off);
            }
        } else {
            E.caps.insert("ImageGatherExtended");
            ops += ops.empty() ? "Offset" : "|Offset";
            o = castInt(val(off), off->getType(), 32, true);
        }
        opv.push_back(o);
    };
    auto imageOps = [&](const std::string &ops, const std::vector<std::string> &opv) {
        std::string s;
        if (ops.empty()) return s;
        s = " " + ops;
        for (auto &x : opv) s += " " + x;
        return s;
    };

    if (t.op == "sample" || t.op == "sample_compare" || t.op == "gather" || t.op == "gather_compare") {
        // Operands are recognized by type, so forms with or without the
        // observed i1 flags, offsets and trailing i32 all parse:
        // texture, sampler, [depth: i32], coordinate (float), [layer],
        // [reference], then in order: [grad: dPdx, dPdy, min-LOD], [i1],
        // [offset (int)], [i1 explicit-LOD, float LOD/bias, float min-LOD],
        // [gather: i32 component], [i32].
        std::vector<Value *> operands(C->arg_begin(), C->arg_end());
        size_t i = 0;
        auto need = [&](bool ok, const char *what) {
            if (!ok) fail("unsupported-intrinsic", name.str() + " (operand form: " + what + ")");
        };
        need(operands.size() >= 3, "too few operands");
        Value *tex = operands[i++];
        need(operands[i]->getType()->isPointerTy(), "sampler");
        Value *smp = operands[i++];
        if (t.depth && i < operands.size() && operands[i]->getType()->isIntegerTy(32) && i + 1 < operands.size() &&
            operands[i + 1]->getType()->getScalarType()->isFloatingPointTy())
            i++;  // i32 1 (as observed)
        need(i < operands.size() && operands[i]->getType()->getScalarType()->isFloatingPointTy(), "coordinate");
        Value *coord = operands[i++];
        Value *layer = nullptr;
        if (k.arrayed) { need(i < operands.size() && operands[i]->getType()->isIntegerTy(), "layer"); layer = operands[i++]; }
        Value *ref = nullptr;
        if (t.op == "sample_compare" || t.op == "gather_compare") { need(i < operands.size() && operands[i]->getType()->isFloatingPointTy(), "reference"); ref = operands[i++]; }
        Value *dPdx = nullptr, *dPdy = nullptr, *minLod = nullptr, *offset = nullptr, *lodOrBias = nullptr, *component = nullptr;
        bool explicitLod = false;
        if (t.grad) {
            need(i + 2 < operands.size(), "gradients");
            dPdx = operands[i++];
            dPdy = operands[i++];
            minLod = operands[i++];
        }
        // The rest: i1 flags, an integer offset (vector, or scalar for 1D),
        // floats (LOD or bias, then min-LOD), integers (gather component,
        // trailing i32).
        std::vector<Value *> flags, floats, ints;
        for (; i < operands.size(); i++) {
            Type *T = operands[i]->getType();
            if (T->isIntegerTy(1)) flags.push_back(operands[i]);
            else if (T->getScalarType()->isFloatingPointTy()) floats.push_back(operands[i]);
            else if (T->isVectorTy() && T->getScalarType()->isIntegerTy()) { need(!offset, "two offsets"); offset = operands[i]; }
            else if (T->isIntegerTy()) ints.push_back(operands[i]);
            else need(false, "unexpected operand type");
        }
        if (!offset && !cube && k.dim == "1D" && !ints.empty() && ints.size() >= 2) {
            offset = ints.front();  // 1D: scalar offset before the trailing i32
            ints.erase(ints.begin());
        }
        if (t.op == "sample" || t.op == "sample_compare") {
            if (!t.grad) {
                if (!flags.empty()) {
                    auto *E1 = dyn_cast<ConstantInt>(flags.back());
                    if (!E1) fail("unsupported-feature", "non-constant explicit-LOD flag in " + name.str());
                    explicitLod = E1->isOne();
                }
                if (!floats.empty()) lodOrBias = floats[0];
                if (floats.size() > 1) minLod = floats[1];
                if (!lodOrBias) lodOrBias = ConstantFP::get(Type::getFloatTy(C->getContext()), 0.0);
            }
        } else if (t.op == "gather") {
            if (!ints.empty()) component = ints.front();
            if (!component) component = ConstantInt::get(Type::getInt32Ty(C->getContext()), 0);
        }
        std::string img = heapImage(val(tex), k, false);
        std::string si = E.op("OpSampledImage", E.global("si" + imageType(k, false), "OpTypeSampledImage " + imageType(k, false)), {img, heapSampler(val(smp))});
        E.decorate(si, "NonUniform");
        std::string coords = coordWithLayer(coord, layer, true);
        std::string ops;
        std::vector<std::string> opv;
        bool fragment = EI.stage == Stage::Fragment;
        if (t.op == "gather" || t.op == "gather_compare") {
            offsetOperand(offset, ops, opv);
            std::string r;
            if (t.op == "gather") {
                r = E.fresh();
                E.body << r << " = OpImageGather " << v4 << " " << si << " " << coords << " " << val(component) << imageOps(ops, opv) << "\n";
            } else {
                r = E.fresh();
                E.body << r << " = OpImageDrefGather " << v4 << " " << si << " " << coords << " " << val(ref) << imageOps(ops, opv) << "\n";
            }
            finish(r);
            return true;
        }
        // Sampling.
        bool useExplicit = explicitLod || !fragment || t.grad;
        if (t.grad) {
            ops = "Grad";
            opv = {val(dPdx), val(dPdy)};
        } else if (explicitLod) {
            ops = "Lod";
            opv = {val(lodOrBias)};
        } else if (!fragment) {
            ops = "Lod";
            opv = {E.constant(f32, "0x0p+0")};
        } else if (!(isa<ConstantFP>(lodOrBias) && cast<ConstantFP>(lodOrBias)->isZero())) {
            ops = "Bias";
            opv = {val(lodOrBias)};
        }
        if (offset && !isa<Constant>(offset)) {
            // Vulkan allows non-constant offsets only for gathers: move the
            // offset into the coordinates (texel size of level 0).
            E.caps.insert("ImageQuery");
            unsigned n = numElements(coord->getType());
            std::string it = E.tVec(u32, n + (k.arrayed ? 1 : 0));
            std::string size = E.op("OpImageQuerySizeLod", it, {img, E.u32(0)});
            if (k.arrayed) {
                std::vector<std::string> a = {size, size};
                for (unsigned j = 0; j < n; j++) a.push_back(std::to_string(j));
                size = n == 1 ? E.op("OpCompositeExtract", u32, {size, "0"}) : E.op("OpVectorShuffle", E.tVec(u32, n), a);
            }
            std::string ft = E.tVec(f32, n);
            std::string fo = E.op("OpConvertSToF", ft, {val(offset)});
            std::string fs = E.op("OpConvertUToF", ft, {size});
            std::string d = E.op("OpFDiv", ft, {fo, fs});
            std::string c = val(coord);
            c = E.op("OpFAdd", ft, {c, d});
            coords = k.arrayed ? coordWithLayer(coord, layer, true, c) : c;
            offset = nullptr;
        }
        offsetOperand(offset, ops, opv);
        if (minLod && !(isa<ConstantFP>(minLod) && cast<ConstantFP>(minLod)->isZero()) && (fragment && !explicitLod)) {
            E.caps.insert("MinLod");
            ops += ops.empty() ? "MinLod" : "|MinLod";
            opv.push_back(val(minLod));
        }
        if (fragment && !useExplicit) uses.insert("implicit_lod");
        std::string r = E.fresh();
        if (t.op == "sample_compare") {
            E.body << r << " = " << (useExplicit ? "OpImageSampleDrefExplicitLod " : "OpImageSampleDrefImplicitLod ") << f32 << " " << si
                   << " " << coords << " " << val(ref) << imageOps(ops, opv) << "\n";
            std::string v = r;
            if (valT->isHalfTy()) v = E.op("OpFConvert", type(valT), {v});
            bind(C, E.op("OpCompositeConstruct", type(RT), {v, E.constant(E.tInt(8), "0")}));
            return true;
        }
        E.body << r << " = " << (useExplicit ? "OpImageSampleExplicitLod " : "OpImageSampleImplicitLod ") << v4 << " " << si << " "
               << coords << imageOps(ops, opv) << "\n";
        finish(r);
        return true;
    }

    if (t.op == "read") {
        // By type: texture, [read sampler], [depth: i32 1], coordinate
        // (integer), [layer or face], then [sample] (MS) or [offset
        // (vector)] [LOD], and a trailing access i32 when present.
        std::vector<Value *> operands(C->arg_begin(), C->arg_end());
        auto need = [&](bool ok, const char *what) {
            if (!ok) fail("unsupported-intrinsic", name.str() + " (operand form: " + what + ")");
        };
        size_t i = 0;
        Value *tex = operands[i++];
        if (i < operands.size() && operands[i]->getType()->isPointerTy()) i++;  // read sampler
        unsigned cdim = (k.dim == "1D" ? 1 : k.dim == "3D" ? 3 : 2);
        if (t.depth && i + 1 < operands.size() && operands[i]->getType()->isIntegerTy(32) && numElements(operands[i + 1]->getType()) == cdim &&
            cdim > 1)
            i++;  // i32 1 (as observed)
        need(i < operands.size() && operands[i]->getType()->getScalarType()->isIntegerTy(), "coordinate");
        Value *coord = operands[i++];
        Value *layer = (k.arrayed || cube) ? (need(i < operands.size(), "layer"), operands[i++]) : nullptr;
        Value *sample = nullptr, *lod = nullptr, *offset = nullptr;
        std::vector<Value *> rest(operands.begin() + (long)i, operands.end());
        unsigned access = 0;
        if (rest.size() >= 2 || (k.ms && rest.size() == 2)) {
            // The last operand is the access qualifier.
            if (auto *A = dyn_cast<ConstantInt>(rest.back())) { access = (unsigned)A->getZExtValue(); rest.pop_back(); }
        }
        for (Value *v : rest) {
            if (v->getType()->isVectorTy()) { need(!offset, "two offsets"); offset = v; }
            else if (k.ms && !sample) sample = v;
            else if (!lod) lod = v;
            else need(false, "extra operands");
        }
        if (k.ms) need(sample != nullptr, "sample index");
        if (!k.ms && !lod) lod = ConstantInt::get(Type::getInt32Ty(C->getContext()), 0);
        if (lod && !lod->getType()->isIntegerTy(32)) {
            // i16 LODs (ushort forms) widen in the image operands below.
        }
        // Cube faces cannot be fetched from a sampled image: cube reads use
        // the storage view (coordinates x, y, face).
        bool storage = access == 3 || access == 2 || cube;
        if (cube && k.arrayed) fail("unsupported-feature", "read from a cube array texture");
        std::string handle = val(tex);
        if (storage && lod && !(isa<ConstantInt>(lod) && cast<ConstantInt>(lod)->isZero())) {
            handle = E.op("OpIAdd", E.tInt(64), {handle, E.op("OpUConvert", E.tInt(64), {castInt(val(lod), lod->getType(), 32, false)})});
            uses.insert("storage_mip_levels");
        }
        std::string img = heapImage(handle, k, storage);
        std::string coords = coordWithLayer(coord, layer, false);
        std::string ops;
        std::vector<std::string> opv;
        std::string r = E.fresh();
        if (storage) {
            if (sample) { ops = "Sample"; opv = {castInt(val(sample), sample->getType(), 32, false)}; }
            E.body << r << " = OpImageRead " << v4 << " " << img << " " << coords << imageOps(ops, opv) << "\n";
        } else {
            if (sample) { ops = "Sample"; opv = {castInt(val(sample), sample->getType(), 32, false)}; }
            else { ops = "Lod"; opv = {castInt(val(lod), lod->getType(), 32, false)}; }
            offsetOperand(offset, ops, opv);
            E.body << r << " = OpImageFetch " << v4 << " " << img << " " << coords << imageOps(ops, opv) << "\n";
        }
        finish(r);
        return true;
    }

    if (t.op == "write") {
        // By type: texture, coordinate, [layer or face], value (the 4-element
        // vector), then [LOD] and a trailing access i32 when present.
        std::vector<Value *> operands(C->arg_begin(), C->arg_end());
        auto need = [&](bool ok, const char *what) {
            if (!ok) fail("unsupported-intrinsic", name.str() + " (operand form: " + what + ")");
        };
        size_t i = 0;
        need(operands.size() >= 3, "too few operands");
        Value *tex = operands[i++];
        Value *coord = operands[i++];
        Value *layer = nullptr;
        if (k.arrayed || cube) { need(i < operands.size() && !operands[i]->getType()->isVectorTy(), "layer"); layer = operands[i++]; }
        if (cube && k.arrayed) fail("unsupported-feature", "write to a cube array texture");
        need(i < operands.size() && operands[i]->getType()->isVectorTy(), "value");
        Value *value = operands[i++];
        std::vector<Value *> rest(operands.begin() + (long)i, operands.end());
        if (rest.size() >= 2 || (k.ms && !rest.empty())) rest.pop_back();  // access
        Value *lod = (!k.ms && !rest.empty()) ? rest[0] : nullptr;
        // Storage views are per mip level: level L of the texture whose
        // handle is h is storage-heap index h + L (abi.h).
        std::string handle = val(tex);
        if (lod && !(isa<ConstantInt>(lod) && cast<ConstantInt>(lod)->isZero())) {
            handle = E.op("OpIAdd", E.tInt(64), {handle, E.op("OpUConvert", E.tInt(64), {castInt(val(lod), lod->getType(), 32, false)})});
            uses.insert("storage_mip_levels");
        }
        std::string img = heapImage(handle, k, true);
        std::string coords = coordWithLayer(coord, layer, false);
        Type *VT = value->getType();
        std::string v = val(value);
        unsigned n = numElements(VT);
        Type *el = VT->getScalarType();
        if (el->isHalfTy()) v = E.op("OpFConvert", E.tVec(f32, n), {v});
        else if (el->isIntegerTy() && el->getIntegerBitWidth() != 32) v = E.op(k.sampled == 'i' ? "OpSConvert" : "OpUConvert", E.tVec(u32, n), {v});
        if (n != 4) fail("unsupported-feature", "texture write of " + printType(VT));
        if (k.sampled == 'i') v = E.op("OpBitcast", v4, {v});
        E.stmt("OpImageWrite " + img + " " + coords + " " + v);
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// SIMD-group and quad-group operations (section 4.6)

bool Translator::callSimd(CallInst *C, StringRef name) {
    StringRef n = name;
    if (!n.consume_front("air.")) return false;
    bool quad = false;
    if (n.consume_front("simd_")) quad = false;
    else if (n.consume_front("quad_")) quad = true;
    else return false;
    StringRef op = n.take_until([](char c) { return c == '.'; });
    StringRef rest = n.drop_front(op.size());
    bool isSigned = rest.starts_with(".s."), isUnsigned = rest.starts_with(".u.");
    (void)isUnsigned;
    E.caps.insert("GroupNonUniform");
    uses.insert("subgroup");
    Type *RT = C->getType();
    std::string t = RT->isVoidTy() ? "" : type(RT);
    std::string u32 = E.tInt(32);
    std::string scope = E.u32(3);  // Subgroup
    Type *ET = RT->getScalarType();
    bool isFloat = ET->isFloatingPointTy();
    bool isBool = ET->isIntegerTy(1);
    auto arg = [&](unsigned i) { return val(C->getArgOperand(i)); };
    auto lane = [&]() { return E.op("OpLoad", u32, {builtin("SubgroupLocalInvocationId", u32)}); };
    auto toLane = [&](unsigned i) {
        Value *V = C->getArgOperand(i);
        return castInt(val(V), V->getType(), 32, false);
    };
    auto shuffle = [&](const std::string &v, const std::string &idx) {
        E.caps.insert("GroupNonUniformShuffle");
        return E.op("OpGroupNonUniformShuffle", t, {scope, v, idx});
    };
    if (ET->getScalarSizeInBits() < 32 && !isBool) uses.insert("subgroup_extended_types");
    static const std::map<std::string, std::pair<const char *, const char *>> arith = {
        // op -> (integer, float) opcode suffix
        {"sum", {"IAdd", "FAdd"}}, {"product", {"IMul", "FMul"}}, {"and", {"BitwiseAnd", nullptr}},
        {"or", {"BitwiseOr", nullptr}}, {"xor", {"BitwiseXor", nullptr}}};
    std::string o = op.str();
    std::string group = "Reduce";
    if (o.rfind("prefix_inclusive_", 0) == 0) { group = "InclusiveScan"; o = o.substr(17); }
    else if (o.rfind("prefix_exclusive_", 0) == 0) { group = "ExclusiveScan"; o = o.substr(17); }
    std::string clustered;
    if (quad && group == "Reduce") { group = "ClusteredReduce"; clustered = " " + E.u32(4); }
    if (quad && group != "ClusteredReduce") {
        // Quad prefix scans: two shuffle-up steps inside the quad
        // (Hillis-Steele), then a shift for the exclusive form.
        static const std::map<std::string, std::pair<const char *, const char *>> bin = {
            {"sum", {"OpIAdd", "OpFAdd"}}, {"product", {"OpIMul", "OpFMul"}}};
        auto b = bin.find(o);
        if (b == bin.end()) fail("unsupported-intrinsic", name.str());
        const char *opc = isFloat ? b->second.second : b->second.first;
        std::string l = lane(), within = E.op("OpBitwiseAnd", u32, {lane(), E.u32(3)});
        Constant *idc = isFloat ? ConstantFP::get(RT, o == "sum" ? 0.0 : 1.0) : ConstantInt::get(RT, o == "sum" ? 0 : 1);
        std::string identity = constant(idc);
        std::string v = arg(0);
        for (unsigned d : {1u, 2u}) {
            std::string ok = E.op("OpUGreaterThanEqual", E.tBool(), {within, E.u32(d)});
            std::string src = E.op("OpSelect", u32, {ok, E.op("OpISub", u32, {l, E.u32(d)}), l});
            std::string s2 = E.op("OpSelect", t, {ok, shuffle(v, src), identity});
            v = E.op(opc, t, {v, s2});
        }
        if (group == "ExclusiveScan") {
            std::string ok = E.op("OpUGreaterThanEqual", E.tBool(), {within, E.u32(1)});
            std::string src = E.op("OpSelect", u32, {ok, E.op("OpISub", u32, {l, E.u32(1)}), l});
            v = E.op("OpSelect", t, {ok, shuffle(v, src), identity});
        }
        bind(C, v);
        return true;
    }
    auto arithOp = [&](const std::string &opc) {
        E.caps.insert(quad ? "GroupNonUniformClustered" : "GroupNonUniformArithmetic");
        std::string r = E.fresh();
        E.body << r << " = OpGroupNonUniform" << opc << " " << t << " " << scope << " " << group << " " << arg(0) << clustered << "\n";
        bind(C, r);
        return true;
    };
    auto a = arith.find(o);
    if (a != arith.end()) {
        if (isBool) return arithOp(o == "and" ? "LogicalAnd" : o == "or" ? "LogicalOr" : "LogicalXor");
        const char *opc = isFloat ? a->second.second : a->second.first;
        if (!opc) fail("unsupported-intrinsic", name.str());
        return arithOp(opc);
    }
    if (o == "min" || o == "max") {
        std::string k = isFloat ? "F" : isSigned ? "S" : "U";
        return arithOp(k + (o == "min" ? "Min" : "Max"));
    }
    if (o == "shuffle" || o == "broadcast") {
        std::string idx = toLane(1);
        if (quad) idx = E.op("OpBitwiseOr", u32, {E.op("OpBitwiseAnd", u32, {lane(), E.u32(~3u)}), E.op("OpBitwiseAnd", u32, {idx, E.u32(3)})});
        bind(C, shuffle(arg(0), idx));
        return true;
    }
    if (o == "shuffle_xor") {
        std::string idx = E.op("OpBitwiseXor", u32, {lane(), toLane(1)});
        bind(C, shuffle(arg(0), idx));
        return true;
    }
    if (o == "shuffle_up" || o == "shuffle_down") {
        // Lanes whose source is outside the group (quad) keep their own value (Metal).
        unsigned width = quad ? 4 : 32;
        std::string l = lane();
        std::string within = quad ? E.op("OpBitwiseAnd", u32, {l, E.u32(3)}) : l;
        std::string d = toLane(1);
        std::string src, ok;
        if (o == "shuffle_down") {
            std::string j = E.op("OpIAdd", u32, {within, d});
            ok = E.op("OpULessThan", E.tBool(), {j, E.u32(width)});
            src = E.op("OpIAdd", u32, {l, d});
        } else {
            ok = E.op("OpUGreaterThanEqual", E.tBool(), {within, d});
            src = E.op("OpISub", u32, {l, d});
        }
        src = E.op("OpSelect", u32, {ok, src, l});
        std::string s = shuffle(arg(0), src);
        bind(C, E.op("OpSelect", t, {ok, s, arg(0)}));
        return true;
    }
    if (o == "shuffle_rotate_up" || o == "shuffle_rotate_down") {
        unsigned width = quad ? 4 : 32;
        std::string l = lane();
        std::string base = E.op("OpBitwiseAnd", u32, {l, E.u32(~(width - 1))});
        std::string within = E.op("OpBitwiseAnd", u32, {l, E.u32(width - 1)});
        std::string j = E.op(o == "shuffle_rotate_down" ? "OpIAdd" : "OpISub", u32, {within, toLane(1)});
        j = E.op("OpBitwiseAnd", u32, {j, E.u32(width - 1)});
        bind(C, shuffle(arg(0), E.op("OpBitwiseOr", u32, {base, j})));
        return true;
    }
    if (o == "shuffle_and_fill_down" || o == "shuffle_and_fill_up") {
        // (data, fill, delta, modulo): lane i of each modulo-sized block takes
        // data[i + delta] when inside the block, else fill[i + delta - modulo]
        // (up: data[i - delta], else fill[i - delta + modulo]).
        std::string l = lane();
        std::string m = C->arg_size() > 3 ? toLane(3) : E.u32(quad ? 4 : 32);
        std::string d = toLane(2);
        std::string within = E.op("OpUMod", u32, {l, m});
        std::string base = E.op("OpISub", u32, {l, within});
        std::string inside, fromData, fromFill;
        if (o == "shuffle_and_fill_down") {
            std::string j = E.op("OpIAdd", u32, {within, d});
            inside = E.op("OpULessThan", E.tBool(), {j, m});
            fromData = E.op("OpIAdd", u32, {base, j});
            fromFill = E.op("OpIAdd", u32, {base, E.op("OpISub", u32, {j, m})});
        } else {
            inside = E.op("OpUGreaterThanEqual", E.tBool(), {within, d});
            fromData = E.op("OpISub", u32, {l, d});
            fromFill = E.op("OpISub", u32, {E.op("OpIAdd", u32, {l, m}), d});
        }
        std::string sd = shuffle(arg(0), E.op("OpSelect", u32, {inside, fromData, l}));
        std::string sf = shuffle(arg(1), E.op("OpSelect", u32, {inside, l, fromFill}));
        bind(C, E.op("OpSelect", t, {inside, sd, sf}));
        return true;
    }
    if (o == "broadcast_first") {
        E.caps.insert("GroupNonUniformBallot");
        bind(C, E.op("OpGroupNonUniformBroadcastFirst", t, {scope, arg(0)}));
        return true;
    }
    if (o == "is_first") {
        bind(C, E.op("OpGroupNonUniformElect", E.tBool(), {scope}));
        return true;
    }
    if (o == "all" || o == "any") {
        E.caps.insert("GroupNonUniformVote");
        if (quad) {
            E.caps.insert("GroupNonUniformClustered");
            std::string iv = E.op("OpSelect", u32, {arg(0), E.u32(1), E.u32(0)});
            std::string r = E.fresh();
            E.body << r << " = OpGroupNonUniform" << (o == "all" ? "UMin" : "UMax") << " " << u32 << " " << scope << " ClusteredReduce " << iv << " " << E.u32(4) << "\n";
            bind(C, E.op("OpINotEqual", E.tBool(), {r, E.u32(0)}));
            return true;
        }
        bind(C, E.op(o == "all" ? "OpGroupNonUniformAll" : "OpGroupNonUniformAny", E.tBool(), {scope, arg(0)}));
        return true;
    }
    if (o == "ballot" || o == "active_threads_mask") {
        E.caps.insert("GroupNonUniformBallot");
        std::string pred = o == "ballot" ? arg(0) : E.boolean(true);
        std::string b = E.op("OpGroupNonUniformBallot", E.tVec(u32, 4), {scope, pred});
        std::string x = E.op("OpCompositeExtract", u32, {b, "0"});
        if (quad) x = E.op("OpBitwiseAnd", u32, {E.op("OpShiftRightLogical", u32, {x, E.op("OpBitwiseAnd", u32, {lane(), E.u32(~3u)})}), E.u32(15)});
        bind(C, castInt(x, Type::getInt32Ty(C->getContext()), RT->getScalarSizeInBits(), false));
        return true;
    }
    fail("unsupported-intrinsic", name.str());
}

// ---------------------------------------------------------------------------
// Atomics: air.atomic.<global|local>.<op>[.s|.u].<T>(ptr, [value], order, scope, i32, i1)

bool Translator::callAtomic(CallInst *C, StringRef name) {
    StringRef n = name;
    if (!n.consume_front("air.atomic.")) return false;
    bool local;
    if (n.consume_front("global.")) local = false;
    else if (n.consume_front("local.")) local = true;
    else if (n.starts_with("fence") || n.starts_with("thread_fence")) {
        E.stmt("OpMemoryBarrier " + E.u32(1) + " " + E.u32(0x8 | 0x40 | 0x100 | 0x800));
        return true;
    } else fail("unsupported-intrinsic", name.str());
    StringRef op = n.take_until([](char c) { return c == '.'; });
    StringRef rest = n.drop_front(op.size());
    bool isSigned = rest.starts_with(".s.");
    Value *P = C->getArgOperand(0);
    Type *VT = op == "store" ? C->getArgOperand(1)->getType() : C->getType();
    if (op.starts_with("cmpxchg")) fail("unsupported-intrinsic", name.str());
    unsigned bits = VT->getScalarSizeInBits();
    if (VT->isVectorTy() || (bits != 32 && bits != 64)) fail("unsupported-intrinsic", name.str());
    if (bits == 64) E.caps.insert("Int64Atomics");
    std::string it = E.tInt(bits);
    std::string t = type(VT);
    std::string ptr;
    if (local) ptr = workgroupElement(val(P), bits);
    else ptr = psbPointer(val(P), it, bits);
    std::string scope = E.u32(local ? 2 : 1);  // Workgroup : Device
    std::string sem = E.u32(0);                  // relaxed (Metal's only order for most atomics)
    uses.insert("atomics");
    bool fl = VT->isFloatingPointTy();
    auto toInt = [&](Value *V) {
        std::string v = val(V);
        if (V->getType()->isFloatingPointTy() && !(op == "add" || op == "sub")) v = E.op("OpBitcast", it, {v});
        return v;
    };
    if (op == "load") {
        std::string r = E.op("OpAtomicLoad", fl ? it : t, {ptr, scope, sem});
        bind(C, fl ? E.op("OpBitcast", t, {r}) : r);
        return true;
    }
    if (op == "store") {
        E.stmt("OpAtomicStore " + ptr + " " + scope + " " + sem + " " + toInt(C->getArgOperand(1)));
        return true;
    }
    if (fl) {
        if (op != "add" && op != "sub" && op != "xchg") fail("unsupported-intrinsic", name.str());
        if (op == "xchg") {
            std::string r = E.op("OpAtomicExchange", it, {ptr, scope, sem, toInt(C->getArgOperand(1))});
            bind(C, E.op("OpBitcast", t, {r}));
            return true;
        }
        E.caps.insert("AtomicFloat32AddEXT");
        E.exts.insert("SPV_EXT_shader_atomic_float_add");
        if (local) fail("unsupported-intrinsic", name.str());
        std::string fptr = psbPointer(val(P), t, bits);
        std::string v = val(C->getArgOperand(1));
        if (op == "sub") v = E.op("OpFNegate", t, {v});
        bind(C, E.op("OpAtomicFAddEXT", t, {fptr, scope, sem, v}));
        return true;
    }
    static const std::map<std::string, std::string> ops = {
        {"add", "OpAtomicIAdd"}, {"sub", "OpAtomicISub"}, {"and", "OpAtomicAnd"}, {"or", "OpAtomicOr"},
        {"xor", "OpAtomicXor"}, {"xchg", "OpAtomicExchange"}};
    std::string opc;
    auto it2 = ops.find(op.str());
    if (it2 != ops.end()) opc = it2->second;
    else if (op == "min") opc = isSigned ? "OpAtomicSMin" : "OpAtomicUMin";
    else if (op == "max") opc = isSigned ? "OpAtomicSMax" : "OpAtomicUMax";
    else fail("unsupported-intrinsic", name.str());
    bind(C, E.op(opc, t, {ptr, scope, sem, val(C->getArgOperand(1))}));
    return true;
}

// ---------------------------------------------------------------------------
// Math (GLSL.std.450) and integer helpers

bool Translator::callMath(CallInst *C, StringRef name) {
    StringRef n = name;
    bool isLLVM = n.consume_front("llvm.");
    if (!isLLVM && !n.consume_front("air.")) return false;
    bool fast = n.consume_front("fast_");
    bool precise = n.consume_front("precise_");
    (void)fast;
    (void)precise;
    StringRef op = n.take_until([](char c) { return c == '.'; });
    StringRef rest = n.drop_front(op.size());
    bool qs = rest.starts_with(".s."), qu = rest.starts_with(".u.");
    Type *RT = C->getType();
    if (RT->isVoidTy() || RT->isStructTy()) {
        if (!(op == "sincos")) return false;
    }
    std::string t = RT->isVoidTy() ? "" : type(RT);
    Type *ST = RT->getScalarType();
    bool isFloat = ST->isFloatingPointTy();
    std::vector<std::string> a;
    for (unsigned i = 0; i < C->arg_size(); i++) a.push_back(val(C->getArgOperand(i)));
    auto glsl = [&](const char *inst, std::vector<std::string> args) {
        bind(C, E.ext(t, inst, std::move(args)));
        return true;
    };
    auto splat = [&](Type *T, double v) { return constant(ConstantFP::get(T, v)); };
    auto splatI = [&](Type *T, uint64_t v) { return constant(ConstantInt::get(T, v)); };
    std::string o = op.str();

    if (isLLVM) {
        if (o == "expect") { bind(C, a[0]); return true; }
        if (o == "fmuladd" || o == "fma") return glsl("Fma", a);
        if (o == "smax") return glsl("SMax", a);
        if (o == "smin") return glsl("SMin", a);
        if (o == "umax") return glsl("UMax", a);
        if (o == "umin") return glsl("UMin", a);
        if (o == "fabs") return glsl("FAbs", a);
        if (o == "abs") return glsl("SAbs", {a[0]});
        if (o == "minnum") return glsl("NMin", a);
        if (o == "maxnum") return glsl("NMax", a);
        if (o == "minimum") return glsl("FMin", a);
        if (o == "maximum") return glsl("FMax", a);
        static const std::map<std::string, const char *> unary = {
            {"floor", "Floor"}, {"ceil", "Ceil"}, {"trunc", "Trunc"}, {"round", "Round"}, {"rint", "RoundEven"},
            {"nearbyint", "RoundEven"}, {"roundeven", "RoundEven"}, {"sqrt", "Sqrt"}, {"exp", "Exp"}, {"exp2", "Exp2"},
            {"log", "Log"}, {"log2", "Log2"}, {"sin", "Sin"}, {"cos", "Cos"}};
        auto u = unary.find(o);
        if (u != unary.end()) return glsl(u->second, {a[0]});
        if (o == "pow") return glsl("Pow", a);
        if (o == "copysign") {
            Type *IT = RT->getWithNewType(Type::getIntNTy(C->getContext(), ST->getPrimitiveSizeInBits()));
            unsigned w = ST->getPrimitiveSizeInBits();
            std::string ia = E.op("OpBitcast", type(IT), {a[0]}), ib = E.op("OpBitcast", type(IT), {a[1]});
            std::string sign = splatI(IT, 1ull << (w - 1));
            std::string mag = E.op("OpBitwiseAnd", type(IT), {ia, E.op("OpNot", type(IT), {sign})});
            std::string sg = E.op("OpBitwiseAnd", type(IT), {ib, sign});
            bind(C, E.op("OpBitcast", t, {E.op("OpBitwiseOr", type(IT), {mag, sg})}));
            return true;
        }
        if (o == "ctpop" || o == "ctlz" || o == "cttz" || o == "bitreverse" || o == "bswap" || o == "fshl" || o == "fshr" ||
            o == "uadd" || o == "usub" || o == "sadd" || o == "ssub") {
            // handled by the integer section below with the AIR names
            if (o == "ctpop") o = "popcount";
            else if (o == "ctlz") o = "clz";
            else if (o == "cttz") o = "ctz";
            else if (o == "bitreverse") o = "reverse_bits";
            else if (o == "uadd" || o == "usub" || o == "sadd" || o == "ssub") {
                if (rest.starts_with(".sat")) { qs = o[0] == 's'; qu = !qs; o = o.substr(1) + "_sat"; }
                else return false;
            }
        } else {
            return false;
        }
    }

    // Float math.
    if (isFloat) {
        static const std::map<std::string, const char *> unary = {
            {"fabs", "FAbs"}, {"abs", "FAbs"}, {"ceil", "Ceil"}, {"floor", "Floor"}, {"trunc", "Trunc"}, {"fract", "Fract"},
            {"round", "Round"}, {"rint", "RoundEven"}, {"sqrt", "Sqrt"}, {"rsqrt", "InverseSqrt"}, {"exp", "Exp"},
            {"exp2", "Exp2"}, {"log", "Log"}, {"log2", "Log2"}, {"sin", "Sin"}, {"cos", "Cos"}, {"tan", "Tan"},
            {"asin", "Asin"}, {"acos", "Acos"}, {"atan", "Atan"}, {"sinh", "Sinh"}, {"cosh", "Cosh"}, {"tanh", "Tanh"},
            {"asinh", "Asinh"}, {"acosh", "Acosh"}, {"atanh", "Atanh"}, {"sign", "FSign"}, {"normalize", "Normalize"},
            {"length", "Length"}};
        auto u = unary.find(o);
        if (u != unary.end()) {
            if (o == "length") return glsl("Length", {a[0]});
            return glsl(u->second, {a[0]});
        }
        if (o == "fmax" || o == "fmin") return glsl(o == "fmax" ? (fast ? "FMax" : "NMax") : (fast ? "FMin" : "NMin"), a);
        if (o == "max" || o == "min") return glsl(o == "max" ? "FMax" : "FMin", a);
        if (o == "fmax3" || o == "fmin3" || o == "max3" || o == "min3") {
            const char *g = (o == "fmax3" || o == "max3") ? "FMax" : "FMin";
            std::string m = E.ext(t, g, {a[0], a[1]});
            return glsl(g, {m, a[2]});
        }
        if (o == "fmedian3" || o == "median3") {
            std::string mn = E.ext(t, "FMin", {a[0], a[1]}), mx = E.ext(t, "FMax", {a[0], a[1]});
            return glsl("FMax", {mn, E.ext(t, "FMin", {mx, a[2]})});
        }
        if (o == "atan2") return glsl("Atan2", a);
        if (o == "pow" || o == "powr") return glsl("Pow", a);
        if (o == "fma" || o == "mad") return glsl("Fma", a);
        if (o == "mix") return glsl("FMix", a);
        if (o == "clamp") return glsl("FClamp", a);
        if (o == "saturate") return glsl("FClamp", {a[0], splat(RT, 0.0), splat(RT, 1.0)});
        if (o == "step") return glsl("Step", a);
        if (o == "smoothstep") return glsl("SmoothStep", a);
        if (o == "distance") return glsl("Distance", a);
        if (o == "cross") return glsl("Cross", a);
        if (o == "reflect") return glsl("Reflect", a);
        if (o == "refract") return glsl("Refract", a);
        if (o == "faceforward") return glsl("FaceForward", a);
        if (o == "ldexp") return glsl("Ldexp", a);
        if (o == "fmod") { bind(C, E.op("OpFRem", t, a)); return true; }
        if (o == "fdim") { bind(C, E.ext(t, "FMax", {E.op("OpFSub", t, a), splat(RT, 0.0)})); return true; }
        if (o == "divide") { bind(C, E.op("OpFDiv", t, a)); return true; }
        if (o == "exp10") return glsl("Exp2", {E.op("OpFMul", t, {a[0], splat(RT, 3.321928094887362)})});
        if (o == "log10") { bind(C, E.op("OpFMul", t, {E.ext(t, "Log2", {a[0]}), splat(RT, 0.30102999566398120)})); return true; }
        if (o == "sinpi" || o == "cospi" || o == "tanpi") {
            std::string x = E.op("OpFMul", t, {a[0], splat(RT, 3.14159265358979323846)});
            return glsl(o == "sinpi" ? "Sin" : o == "cospi" ? "Cos" : "Tan", {x});
        }
        if (o == "copysign") {
            Type *IT = RT->getWithNewType(Type::getIntNTy(C->getContext(), ST->getPrimitiveSizeInBits()));
            unsigned w = ST->getPrimitiveSizeInBits();
            std::string ia = E.op("OpBitcast", type(IT), {a[0]}), ib = E.op("OpBitcast", type(IT), {a[1]});
            std::string sign = splatI(IT, 1ull << (w - 1));
            std::string mag = E.op("OpBitwiseAnd", type(IT), {ia, E.op("OpNot", type(IT), {sign})});
            std::string sg = E.op("OpBitwiseAnd", type(IT), {ib, sign});
            bind(C, E.op("OpBitcast", t, {E.op("OpBitwiseOr", type(IT), {mag, sg})}));
            return true;
        }
        if (o == "dot") {
            bind(C, E.op("OpDot", t, a));
            return true;
        }
    } else if (o == "dot") {
        fail("unsupported-intrinsic", name.str());
    }
    if (o == "sincos" && C->arg_size() == 2) {
        // sincos(x, cos out-pointer) -> sin
        Value *P = C->getArgOperand(1);
        Type *XT = C->getArgOperand(0)->getType();
        std::string xt = type(XT);
        std::string s = E.ext(xt, "Sin", {a[0]}), c = E.ext(xt, "Cos", {a[0]});
        store(a[1], P->getType()->getPointerAddressSpace(), XT, c, DL.getABITypeAlign(XT).value());
        bind(C, s);
        return true;
    }
    if (isFloat) return false;

    // Integer helpers.
    if (!ST->isIntegerTy()) return false;
    unsigned w = ST->getIntegerBitWidth();
    Type *I32 = RT->getWithNewType(Type::getInt32Ty(C->getContext()));
    std::string t32 = type(I32);
    auto widen = [&](const std::string &v, bool sign) { return w == 32 ? v : E.op(sign ? "OpSConvert" : "OpUConvert", t32, {v}); };
    auto narrow = [&](const std::string &v) { return w == 32 ? v : E.op("OpUConvert", t, {v}); };
    if (o == "abs") return qu ? (bind(C, a[0]), true) : glsl("SAbs", {a[0]});
    if (o == "max") return glsl(qu ? "UMax" : "SMax", a);
    if (o == "min") return glsl(qu ? "UMin" : "SMin", a);
    if (o == "clamp") return glsl(qu ? "UClamp" : "SClamp", a);
    if (o == "max3" || o == "min3") {
        const char *g = o == "max3" ? (qu ? "UMax" : "SMax") : (qu ? "UMin" : "SMin");
        return glsl(g, {E.ext(t, g, {a[0], a[1]}), a[2]});
    }
    if (w == 64 && (o == "popcount" || o == "clz" || o == "ctz")) {
        // On the 32-bit halves.
        Type *I64 = RT;
        std::string lo = E.op("OpUConvert", t32, {a[0]});
        std::string hi = E.op("OpUConvert", t32, {E.op("OpShiftRightLogical", t, {a[0], splatI(I64, 32)})});
        Type *BT = RT->getWithNewType(Type::getInt1Ty(C->getContext()));
        std::string r;
        if (o == "popcount") r = E.op("OpIAdd", t32, {E.op("OpBitCount", t32, {lo}), E.op("OpBitCount", t32, {hi})});
        else if (o == "clz") {
            auto clz32 = [&](const std::string &x) { return E.op("OpISub", t32, {splatI(I32, 31), E.ext(t32, "FindUMsb", {x})}); };
            std::string hiZero = E.op("OpIEqual", type(BT), {hi, splatI(I32, 0)});
            r = E.op("OpSelect", t32, {hiZero, E.op("OpIAdd", t32, {clz32(lo), splatI(I32, 32)}), clz32(hi)});
        } else {
            auto ctz32 = [&](const std::string &x) {
                std::string z = E.op("OpIEqual", type(BT), {x, splatI(I32, 0)});
                return E.op("OpSelect", t32, {z, splatI(I32, 32), E.ext(t32, "FindILsb", {x})});
            };
            std::string loZero = E.op("OpIEqual", type(BT), {lo, splatI(I32, 0)});
            r = E.op("OpSelect", t32, {loZero, E.op("OpIAdd", t32, {ctz32(hi), splatI(I32, 32)}), ctz32(lo)});
        }
        bind(C, E.op("OpUConvert", t, {r}));
        return true;
    }
    if (w == 64 && o == "reverse_bits") fail("unsupported-intrinsic", name.str() + " (64-bit)");
    if (o == "popcount") {
        bind(C, narrow(E.op("OpBitCount", t32, {widen(a[0], false)})));
        return true;
    }
    if (o == "reverse_bits") {
        std::string r = E.op("OpBitReverse", t32, {widen(a[0], false)});
        if (w != 32) r = E.op("OpShiftRightLogical", t32, {r, splatI(I32, 32 - w)});
        bind(C, narrow(r));
        return true;
    }
    if (o == "clz") {
        std::string msb = E.ext(t32, "FindUMsb", {widen(a[0], false)});  // -1 for 0
        std::string r = E.op("OpISub", t32, {splatI(I32, 31), msb});
        if (w != 32) r = E.op("OpISub", t32, {r, splatI(I32, 32 - w)});
        bind(C, narrow(r));
        return true;
    }
    if (o == "ctz") {
        std::string x = widen(a[0], false);
        std::string lsb = E.ext(t32, "FindILsb", {x});
        Type *BT = RT->getWithNewType(Type::getInt1Ty(C->getContext()));
        std::string zero = E.op("OpIEqual", type(BT), {x, splatI(I32, 0)});
        bind(C, narrow(E.op("OpSelect", t32, {zero, splatI(I32, w), lsb})));
        return true;
    }
    if (o == "bswap") {
        if (w == 16) {
            std::string r = E.op("OpBitwiseOr", t, {E.op("OpShiftLeftLogical", t, {a[0], splatI(RT, 8)}), E.op("OpShiftRightLogical", t, {a[0], splatI(RT, 8)})});
            bind(C, r);
            return true;
        }
        if (w != 32) fail("unsupported-intrinsic", name.str());
        std::string b0 = E.op("OpShiftLeftLogical", t, {a[0], splatI(RT, 24)});
        std::string b1 = E.op("OpShiftLeftLogical", t, {E.op("OpBitwiseAnd", t, {a[0], splatI(RT, 0xFF00)}), splatI(RT, 8)});
        std::string b2 = E.op("OpBitwiseAnd", t, {E.op("OpShiftRightLogical", t, {a[0], splatI(RT, 8)}), splatI(RT, 0xFF00)});
        std::string b3 = E.op("OpShiftRightLogical", t, {a[0], splatI(RT, 24)});
        bind(C, E.op("OpBitwiseOr", t, {E.op("OpBitwiseOr", t, {b0, b1}), E.op("OpBitwiseOr", t, {b2, b3})}));
        return true;
    }
    if (o == "rotate" || o == "fshl" || o == "fshr") {
        // rotate(x, n) == fshl(x, x, n)
        std::string x = a[0], y = o == "rotate" ? a[0] : a[1], s = o == "rotate" ? a[1] : a[2];
        std::string m = E.op("OpBitwiseAnd", t, {s, splatI(RT, w - 1)});
        std::string inv = E.op("OpBitwiseAnd", t, {E.op("OpISub", t, {splatI(RT, w), m}), splatI(RT, w - 1)});
        Type *BT = RT->getWithNewType(Type::getInt1Ty(C->getContext()));
        std::string isZero = E.op("OpIEqual", type(BT), {m, splatI(RT, 0)});
        std::string r;
        if (o == "fshr") r = E.op("OpBitwiseOr", t, {E.op("OpShiftRightLogical", t, {y, m}), E.op("OpShiftLeftLogical", t, {x, inv})});
        else r = E.op("OpBitwiseOr", t, {E.op("OpShiftLeftLogical", t, {x, m}), E.op("OpShiftRightLogical", t, {y, inv})});
        bind(C, E.op("OpSelect", t, {isZero, o == "fshr" ? y : x, r}));
        return true;
    }
    if (o == "mul_hi") {
        std::string st = E.global("mulx" + t, "OpTypeStruct " + t + " " + t);
        std::string r = E.op(qs ? "OpSMulExtended" : "OpUMulExtended", st, a);
        bind(C, E.op("OpCompositeExtract", t, {r, "1"}));
        return true;
    }
    if (o == "add_sat" || o == "sub_sat") {
        Type *BT = RT->getWithNewType(Type::getInt1Ty(C->getContext()));
        if (!qs) {
            if (o == "add_sat") {
                std::string r = E.op("OpIAdd", t, a);
                std::string ov = E.op("OpULessThan", type(BT), {r, a[0]});
                bind(C, E.op("OpSelect", t, {ov, constant(Constant::getAllOnesValue(RT)), r}));
            } else {
                std::string lt = E.op("OpULessThan", type(BT), {a[0], a[1]});
                bind(C, E.op("OpSelect", t, {lt, splatI(RT, 0), E.op("OpISub", t, a)}));
            }
            return true;
        }
        if (w == 64) fail("unsupported-intrinsic", name.str());
        Type *WT = RT->getWithNewType(Type::getIntNTy(C->getContext(), w * 2));
        std::string wt = type(WT);
        std::string x = E.op("OpSConvert", wt, {a[0]}), y = E.op("OpSConvert", wt, {a[1]});
        std::string r = E.op(o == "add_sat" ? "OpIAdd" : "OpISub", wt, {x, y});
        int64_t hi = (int64_t)((1ull << (w - 1)) - 1), lo = -(int64_t)(1ull << (w - 1));
        r = E.ext(wt, "SClamp", {r, constant(ConstantInt::get(WT, (uint64_t)lo, true)), constant(ConstantInt::get(WT, (uint64_t)hi, true))});
        bind(C, E.op("OpSConvert", t, {r}));
        return true;
    }
    if (o == "mad24" || o == "mul24") {
        std::string m = E.op("OpIMul", t, {a[0], a[1]});
        bind(C, o == "mad24" ? E.op("OpIAdd", t, {m, a[2]}) : m);
        return true;
    }
    if (o == "extract_bits" && w == 32) {
        bind(C, E.op(qs ? "OpBitFieldSExtract" : "OpBitFieldUExtract", t, a));
        return true;
    }
    if (o == "insert_bits" && w == 32) {
        bind(C, E.op("OpBitFieldInsert", t, a));
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Dispatcher

static std::string fmtHex(uint64_t v) {
    char b[24];
    snprintf(b, sizeof b, "%llu", (unsigned long long)v);
    return b;
}

void Translator::call(CallInst *C) {
    Function *Fn = C->getCalledFunction();
    if (!Fn) fail("unsupported-feature", "indirect call (visible function or function pointer)");
    auto helper = fnIds.find(Fn);
    if (helper != fnIds.end()) {
        std::vector<std::string> a;
        for (unsigned i = 0; i < C->arg_size(); i++) a.push_back(val(C->getArgOperand(i)));
        std::string r = E.fresh();
        E.body << r << " = OpFunctionCall " << type(C->getType()) << " " << helper->second;
        for (auto &x : a) E.body << " " << x;
        E.body << "\n";
        if (!C->getType()->isVoidTy()) bind(C, r);
        return;
    }
    StringRef n = Fn->getName();
    if (n.starts_with("llvm.lifetime") || n.starts_with("llvm.assume") || n.starts_with("llvm.experimental.noalias.scope.decl") ||
        n.starts_with("llvm.dbg") || n.starts_with("llvm.invariant") || n.starts_with("llvm.var.annotation") ||
        n.starts_with("llvm.donothing") || n.starts_with("llvm.sideeffect"))
        return;
    Type *RT = C->getType();
    std::string t = RT->isVoidTy() ? "" : type(RT);
    std::string u32 = E.tInt(32), f32 = E.tFloat(32);
    auto arg = [&](unsigned i) { return val(C->getArgOperand(i)); };

    if (n == "airc.grid_oob") {
        std::string v3 = E.tVec(u32, 3);
        std::string gid = E.op("OpLoad", v3, {builtin("GlobalInvocationId", v3)});
        std::string p = E.op("OpAccessChain", E.tPtr("PushConstant", v3), {pcVar, E.u32(2)});
        std::string grid = E.op("OpLoad", v3, {p});
        std::string ge = E.op("OpUGreaterThanEqual", E.tVec(E.tBool(), 3), {gid, grid});
        bind(C, E.op("OpAny", E.tBool(), {ge}));
        return;
    }
    if (n.starts_with("air.convert.")) {
        SmallVector<StringRef, 8> p;
        n.split(p, '.');
        if (p.size() < 6) fail("unsupported-intrinsic", n.str());
        char dk = p[2][0], sk = p[4][0];
        Value *S = C->getArgOperand(0);
        std::string s = arg(0);
        Type *ST = S->getType();
        if (p.size() > 6) {
            // Rounding or saturation qualifiers are not lowered yet.
            fail("unsupported-intrinsic", n.str());
        }
        if (ST->isIntOrIntVectorTy(1)) {
            // bool -> number
            Constant *one = dk == 'f' ? ConstantFP::get(RT, 1.0) : ConstantInt::get(RT, 1);
            bind(C, E.op("OpSelect", t, {s, constant(one), constant(Constant::getNullValue(RT))}));
            return;
        }
        if (RT->isIntOrIntVectorTy(1)) {
            if (sk == 'f') bind(C, E.op("OpFUnordNotEqual", t, {s, constant(Constant::getNullValue(ST))}));
            else bind(C, E.op("OpINotEqual", t, {s, constant(Constant::getNullValue(ST))}));
            return;
        }
        const char *op;
        if (dk == 'f' && sk == 'f') op = ST->getScalarSizeInBits() == RT->getScalarSizeInBits() ? nullptr : "OpFConvert";
        else if (dk == 'f') op = sk == 'u' ? "OpConvertUToF" : "OpConvertSToF";
        else if (sk == 'f') op = dk == 'u' ? "OpConvertFToU" : "OpConvertFToS";
        else op = ST->getScalarSizeInBits() == RT->getScalarSizeInBits() ? nullptr : (sk == 's' ? "OpSConvert" : "OpUConvert");
        if (!op) { bind(C, s); return; }
        bind(C, E.op(op, t, {s}));
        return;
    }
    if (n == "air.get_read_sampler") { bind(C, E.u64(0)); return; }
    if (n.starts_with("airc.table_entry.")) {
        Value *e = C->getArgOperand(0);
        if (auto *CI = dyn_cast<ConstantInt>(e)) { bind(C, tableEntry((unsigned)CI->getZExtValue())); return; }
        std::string off = E.op("OpIMul", E.tInt(64), {E.op("OpUConvert", E.tInt(64), {arg(0)}), E.u64(8)});
        std::string p = psbPointer(E.op("OpIAdd", E.tInt(64), {tableAddr, off}), E.tInt(64), 64);
        std::string r = E.fresh();
        E.body << r << " = OpLoad " << E.tInt(64) << " " << p << " Aligned 8\n";
        bind(C, r);
        return;
    }
    if (n == "air.discard_fragment") {
        if (EI.stage == Stage::Kernel) {
            // Metal accepts a kernel whose code calls discard_fragment only
            // when specialization removes the call (observed on the Mac: the
            // function with the call still reachable fails with "uses illegal
            // function"). Here the call sits on a path guarded by a function
            // constant, so it is never executed: no operation.
            uses.insert("discard_in_kernel_ignored");
            return;
        }
        if (EI.stage != Stage::Fragment) fail("unsupported-feature", "discard_fragment outside a fragment function");
        E.caps.insert("DemoteToHelperInvocation");
        E.stmt("OpDemoteToHelperInvocation");
        uses.insert("discard");
        return;
    }
    if (n.starts_with("air.dfdx") || n.starts_with("air.dfdy") || n.starts_with("air.fwidth")) {
        if (EI.stage == Stage::Vertex) fail("unsupported-feature", "derivatives in a vertex function");
        if (EI.stage == Stage::Kernel) {
            // Quad-group derivatives in kernels: quads of consecutive
            // thread indices (VK_KHR_compute_shader_derivatives, linear).
            E.caps.insert("ComputeDerivativeGroupLinearKHR");
            E.exts.insert("SPV_KHR_compute_shader_derivatives");
            uses.insert("compute_derivatives_linear");
        }
        const char *op = n.starts_with("air.dfdx") ? "OpDPdx" : n.starts_with("air.dfdy") ? "OpDPdy" : "OpFwidth";
        std::string x = arg(0);
        Type *XT = C->getArgOperand(0)->getType();
        bool half = XT->getScalarType()->isHalfTy();
        std::string ft = E.tVec(f32, numElements(XT));
        if (half) x = E.op("OpFConvert", ft, {x});
        std::string r = E.op(op, ft, {x});
        if (half) r = E.op("OpFConvert", t, {r});
        uses.insert("derivatives");
        bind(C, r);
        return;
    }
    if (n == "air.get_num_samples") {
        std::string spec = E.global("specsamples", "OpSpecConstant " + u32 + " 1");
        E.decorate(spec, "SpecId " + std::to_string(abi::kSpecRasterSampleCount));
        uses.insert("raster_sample_count");
        bind(C, castInt(spec, Type::getInt32Ty(C->getContext()), RT->getScalarSizeInBits(), false));
        return;
    }
    if (n == "air.wg.barrier" || n == "air.simdgroup.barrier" || n == "air.mem.barrier") {
        auto *Fl = dyn_cast<ConstantInt>(C->getArgOperand(0));
        unsigned flags = Fl ? (unsigned)Fl->getZExtValue() : 7;
        unsigned sem = 0x8;  // AcquireRelease
        if (flags & 1) sem |= 0x40;   // UniformMemory: device buffers
        if (flags & 2) sem |= 0x100;  // WorkgroupMemory
        if (flags & 4) sem |= 0x800;  // ImageMemory
        if (flags & 8) sem |= 0x100;  // imageblock memory (threadgroup memory here)
        if (flags == 0) sem = 0;
        bool sg = n == "air.simdgroup.barrier";
        std::string exec = E.u32(sg ? 3 : 2);
        std::string mem = E.u32((flags & 5) ? 1 : sg ? 3 : 2);
        if (n == "air.mem.barrier") E.stmt("OpMemoryBarrier " + mem + " " + E.u32(sem));
        else E.stmt("OpControlBarrier " + exec + " " + mem + " " + E.u32(sem));
        uses.insert("barrier");
        return;
    }
    {
        // Built-ins as functions: air.get_<name>[.<type>]([i32 dimension]).
        static const std::map<std::string, std::pair<std::string, unsigned>> fb = {
            {"thread_index_in_simdgroup", {"SubgroupLocalInvocationId", 1}}, {"simdgroup_index_in_threadgroup", {"SubgroupId", 1}},
            {"simdgroups_per_threadgroup", {"NumSubgroups", 1}}, {"dispatch_simdgroups_per_threadgroup", {"NumSubgroups", 1}},
            {"global_id", {"GlobalInvocationId", 3}}, {"local_id", {"LocalInvocationId", 3}}, {"group_id", {"WorkgroupId", 3}},
            {"num_groups", {"NumWorkgroups", 3}}, {"thread_index_in_threadgroup", {"LocalInvocationIndex", 1}}};
        StringRef nm = n;
        if (nm.consume_front("air.get_")) {
            StringRef base = nm.take_until([](char c) { return c == '.'; });
            auto b = fb.find(base.str());
            if (b != fb.end() || base == "local_size" || base == "global_size") {
                std::string v3 = E.tVec(u32, 3);
                std::string v;
                unsigned n3 = 3;
                if (base == "local_size") v = wgSizeId;
                else if (base == "global_size") v = E.op("OpLoad", v3, {E.op("OpAccessChain", E.tPtr("PushConstant", v3), {pcVar, E.u32(2)})});
                else {
                    n3 = b->second.second;
                    std::string bt = n3 == 3 ? v3 : u32;
                    v = E.op("OpLoad", bt, {builtin(b->second.first, bt)});
                }
                if (base == "local_size" && wgSizeId.empty()) fail("unsupported-feature", "threadgroup size outside a kernel");
                if (n3 == 3) {
                    if (C->arg_size() < 1) fail("unsupported-intrinsic", n.str());
                    std::string d = castInt(arg(0), C->getArgOperand(0)->getType(), 32, false);
                    v = E.op("OpVectorExtractDynamic", u32, {v, d});
                }
                bind(C, castInt(v, Type::getInt32Ty(C->getContext()), RT->getScalarSizeInBits(), false));
                return;
            }
        }
    }
    if (n == "air.get_simdgroup_size.i16" || n.starts_with("air.get_simdgroup_size")) {
        std::string s = E.op("OpLoad", u32, {builtin("SubgroupSize", u32)});
        bind(C, castInt(s, Type::getInt32Ty(C->getContext()), RT->getScalarSizeInBits(), false));
        return;
    }
    if (n.starts_with("air.unpack.") || n.starts_with("air.pack.")) {
        bool pack = n.starts_with("air.pack.");
        StringRef kind = n.drop_front(pack ? 9 : 11);
        if (kind.starts_with("unorm.rgb565")) kind = kind.take_front(12);
        else if (kind.starts_with("unorm.rgb9e5") || kind.starts_with("unorm.rgb10a2")) kind = kind.take_front(kind.starts_with("unorm.rgb9e5") ? 12 : 13);
        else if (kind.starts_with("unorm.rg11b10f")) kind = kind.take_front(14);
        else kind = kind.take_until([](char c) { return c == '.'; });
        std::string k = kind.str();
        if ((k == "unorm.rg11b10f" || k == "unorm.rgb10a2") && !pack) {
            std::string x = castInt(arg(0), C->getArgOperand(0)->getType(), 32, false);
            auto field = [&](unsigned sh, unsigned bits) {
                return E.op("OpBitwiseAnd", u32, {E.op("OpShiftRightLogical", u32, {x, E.u32(sh)}), E.u32((1u << bits) - 1)});
            };
            std::vector<std::string> comps;
            if (k == "unorm.rgb10a2") {
                // Red in bits 0-9 (the RGB10A2 layout).
                for (auto f : {std::pair<unsigned, unsigned>{0, 10}, {10, 10}, {20, 10}, {30, 2}})
                    comps.push_back(E.op("OpFDiv", f32, {E.op("OpConvertUToF", f32, {field(f.first, f.second)}),
                                                       E.constant(f32, f.second == 10 ? "0x1.ff8p+9" : "0x1.8p+1")}));
            } else {
                // Unsigned small floats: 6/6/5-bit mantissas, 5-bit exponents, red in bits 0-10.
                auto small = [&](unsigned sh, unsigned mbits) {
                    std::string m = E.op("OpConvertUToF", f32, {field(sh, mbits)});
                    std::string e = field(sh + mbits, 5);
                    std::string ef = E.op("OpConvertUToF", f32, {e});
                    std::string frac = E.op("OpFDiv", f32, {m, E.op("OpConvertUToF", f32, {E.u32(1u << mbits)})});
                    std::string normal = E.op("OpFMul", f32, {E.ext(f32, "Exp2", {E.op("OpFSub", f32, {ef, E.constant(f32, "0x1.ep+3")})}),
                                                              E.op("OpFAdd", f32, {frac, E.constant(f32, "0x1p+0")})});
                    std::string denorm = E.op("OpFMul", f32, {frac, E.constant(f32, "0x1p-14")});
                    std::string isZero = E.op("OpIEqual", E.tBool(), {e, E.u32(0)});
                    return E.op("OpSelect", f32, {isZero, denorm, normal});
                };
                comps = {small(0, 6), small(11, 6), small(22, 5)};
            }
            std::string res = E.op("OpCompositeConstruct", E.tVec(f32, (unsigned)comps.size()), comps);
            if (RT->getScalarType()->isHalfTy()) res = E.op("OpFConvert", t, {res});
            bind(C, res);
            return;
        }
        if (k == "unorm.rgb9e5" && !pack) {
            // Shared-exponent RGB (the E5B9G9R9 layout: red in bits 0-8).
            std::string x = castInt(arg(0), C->getArgOperand(0)->getType(), 32, false);
            std::string e = E.op("OpBitwiseAnd", u32, {E.op("OpShiftRightLogical", u32, {x, E.u32(27)}), E.u32(31)});
            std::string ef = E.op("OpConvertUToF", f32, {e});
            std::string scale = E.ext(f32, "Exp2", {E.op("OpFSub", f32, {ef, E.constant(f32, "0x1.8p+4")})});  // 2^(e - 24)
            std::vector<std::string> c3;
            for (unsigned sh : {0u, 9u, 18u})
                c3.push_back(E.op("OpFMul", f32, {E.op("OpConvertUToF", f32, {E.op("OpBitwiseAnd", u32, {E.op("OpShiftRightLogical", u32, {x, E.u32(sh)}), E.u32(511)})}), scale}));
            std::string res = E.op("OpCompositeConstruct", E.tVec(f32, 3), c3);
            if (RT->getScalarType()->isHalfTy()) res = E.op("OpFConvert", t, {res});
            bind(C, res);
            return;
        }
        if (k == "unorm.rgb565") {
            if (pack) {
                // (r, g, b) in [0, 1] -> r in bits 0-4, g 5-10, b 11-15 (checked against Metal on the Mac).
                Type *XT = C->getArgOperand(0)->getType();
                std::string x = arg(0);
                std::string v3f = E.tVec(f32, 3);
                if (XT->getScalarType()->isHalfTy()) x = E.op("OpFConvert", v3f, {x});
                std::string c = E.ext(v3f, "FClamp", {x, E.composite(v3f, {E.constant(f32, "0x0p+0"), E.constant(f32, "0x0p+0"), E.constant(f32, "0x0p+0")}),
                                                      E.composite(v3f, {E.constant(f32, "0x1p+0"), E.constant(f32, "0x1p+0"), E.constant(f32, "0x1p+0")})});
                std::string sc = E.op("OpFMul", v3f, {c, E.composite(v3f, {E.constant(f32, "0x1.fp+4"), E.constant(f32, "0x1.f8p+5"), E.constant(f32, "0x1.fp+4")})});
                std::string rd = E.ext(v3f, "RoundEven", {sc});
                std::string iv = E.op("OpConvertFToU", E.tVec(u32, 3), {rd});
                std::string r = E.op("OpCompositeExtract", u32, {iv, "0"});
                std::string g = E.op("OpShiftLeftLogical", u32, {E.op("OpCompositeExtract", u32, {iv, "1"}), E.u32(5)});
                std::string b = E.op("OpShiftLeftLogical", u32, {E.op("OpCompositeExtract", u32, {iv, "2"}), E.u32(11)});
                std::string w = E.op("OpBitwiseOr", u32, {E.op("OpBitwiseOr", u32, {r, g}), b});
                bind(C, castInt(w, Type::getInt32Ty(C->getContext()), RT->getScalarSizeInBits(), false));
                return;
            }
            std::string x = castInt(arg(0), C->getArgOperand(0)->getType(), 32, false);
            std::string r = E.op("OpBitwiseAnd", u32, {x, E.u32(31)});
            std::string g = E.op("OpBitwiseAnd", u32, {E.op("OpShiftRightLogical", u32, {x, E.u32(5)}), E.u32(63)});
            std::string b = E.op("OpBitwiseAnd", u32, {E.op("OpShiftRightLogical", u32, {x, E.u32(11)}), E.u32(31)});
            std::string v3f = E.tVec(f32, 3);
            std::string fv = E.op("OpConvertUToF", v3f, {E.op("OpCompositeConstruct", E.tVec(u32, 3), {r, g, b})});
            std::string res = E.op("OpFDiv", v3f, {fv, E.composite(v3f, {E.constant(f32, "0x1.fp+4"), E.constant(f32, "0x1.f8p+5"), E.constant(f32, "0x1.fp+4")})});
            if (RT->getScalarType()->isHalfTy()) res = E.op("OpFConvert", t, {res});
            bind(C, res);
            return;
        }
        static const std::map<std::string, std::pair<const char *, unsigned>> g = {
            {"unorm4x8", {"Unorm4x8", 4}}, {"snorm4x8", {"Snorm4x8", 4}}, {"unorm2x16", {"Unorm2x16", 2}}, {"snorm2x16", {"Snorm2x16", 2}}};
        auto it = g.find(k);
        if (it == g.end()) fail("unsupported-intrinsic", n.str());
        std::string fv = E.tVec(f32, it->second.second);
        if (pack) {
            std::string x = arg(0);
            if (C->getArgOperand(0)->getType()->getScalarType()->isHalfTy()) x = E.op("OpFConvert", fv, {x});
            std::string r = E.ext(u32, (std::string("Pack") + it->second.first).c_str(), {x});
            bind(C, castInt(r, Type::getInt32Ty(C->getContext()), RT->getScalarSizeInBits(), false));
            return;
        }
        std::string x = castInt(arg(0), C->getArgOperand(0)->getType(), 32, false);
        std::string r = E.ext(fv, (std::string("Unpack") + it->second.first).c_str(), {x});
        if (RT->getScalarType()->isHalfTy()) r = E.op("OpFConvert", t, {r});
        bind(C, r);
        return;
    }
    if ((n.starts_with("air.any.") || n.starts_with("air.all.")) && C->getArgOperand(0)->getType()->isIntOrIntVectorTy(1)) {
        Value *V = C->getArgOperand(0);
        if (!V->getType()->isVectorTy()) bind(C, arg(0));
        else bind(C, E.op(n.starts_with("air.any.") ? "OpAny" : "OpAll", E.tBool(), {arg(0)}));
        return;
    }
    if (n == "air.imageblock_data" || n.starts_with("air.load.implicit_imageblock") || n.starts_with("air.store.implicit_imageblock") ||
        n == "airc.imageblock_base") {
        if (!hasImageblock) fail("unsupported-feature", "imageblock access without an imageblock argument");
        if (n == "airc.imageblock_base") { bind(C, E.u64(imageblockBase())); return; }
        bool store = n.starts_with("air.store.");
        unsigned ci = n == "air.imageblock_data" ? 0 : store ? 2 : 1;
        Value *coord = C->getArgOperand(ci);
        std::string c32 = castInt(val(coord), coord->getType(), 32, false);
        std::string x = E.op("OpCompositeExtract", u32, {c32, "0"}), y = E.op("OpCompositeExtract", u32, {c32, "1"});
        std::string pix = E.op("OpIAdd", u32, {E.op("OpIMul", u32, {y, specX}), x});
        std::string off = E.op("OpIMul", u32, {pix, E.u32(ibStride)});
        std::string addr = E.op("OpIAdd", E.tInt(64), {E.op("OpUConvert", E.tInt(64), {off}), E.u64(imageblockBase())});
        if (n == "air.imageblock_data") { bind(C, addr); return; }
        auto *Fi = dyn_cast<ConstantInt>(C->getArgOperand(store ? 1 : 0));
        if (!Fi || Fi->getZExtValue() >= ibFieldOffsets.size()) fail("unsupported-feature", "implicit imageblock field");
        addr = addConst(addr, (int64_t)ibFieldOffsets[Fi->getZExtValue()]);
        if (store) {
            Value *V = C->getArgOperand(0);
            this->store(addr, kThreadgroup, V->getType(), val(V), 2);
        } else {
            bind(C, load(addr, kThreadgroup, RT, 2));
        }
        return;
    }
    if (n == "air.get_imageblock_width" || n == "air.get_imageblock_height") {
        if (!hasImageblock) fail("unsupported-feature", "imageblock size without an imageblock argument");
        bind(C, castInt(n == "air.get_imageblock_width" ? specX : specY, Type::getInt32Ty(C->getContext()), RT->getScalarSizeInBits(), false));
        return;
    }
    if (n.starts_with("air.is_uniform")) {
        // Whether the value is the same in every active thread of the SIMD
        // group (a dynamically uniform value is; the reverse is a safe
        // approximation for code that only uses it to pick a fast path).
        E.caps.insert("GroupNonUniformVote");
        bind(C, E.op("OpGroupNonUniformAllEqual", E.tBool(), {E.u32(3), arg(0)}));
        return;
    }
    if (n.starts_with("air.interpolate_")) {
        auto ip = interpolants.find(C->getArgOperand(0));
        if (ip == interpolants.end()) fail("unsupported-feature", "interpolant that is not a fragment input argument");
        const Interpolant &in = ip->second;
        std::string r;
        if (n.starts_with("air.interpolate_center_")) r = E.op("OpLoad", in.ioType, {in.var});
        else if (n.starts_with("air.interpolate_centroid_")) r = E.ext(in.ioType, "InterpolateAtCentroid", {in.var});
        else if (n.starts_with("air.interpolate_sample_")) r = E.ext(in.ioType, "InterpolateAtSample", {in.var, castInt(arg(1), C->getArgOperand(1)->getType(), 32, false)});
        else if (n.starts_with("air.interpolate_offset_")) {
            std::string off = arg(1);
            if (C->getArgOperand(1)->getType()->getScalarType()->isHalfTy()) off = E.op("OpFConvert", E.tVec(f32, 2), {off});
            r = E.ext(in.ioType, "InterpolateAtOffset", {in.var, off});
        } else fail("unsupported-intrinsic", n.str());
        if (in.half) r = E.op("OpFConvert", t, {r});
        bind(C, r);
        return;
    }
    if (n.starts_with("air.normalize_function_constant_predicate")) {
        Value *V = C->getArgOperand(0);
        std::string nz = V->getType()->isIntegerTy(1) ? arg(0) : E.op("OpINotEqual", E.tBool(), {arg(0), constant(Constant::getNullValue(V->getType()))});
        if (RT->isIntegerTy(1)) bind(C, nz);
        else bind(C, E.op("OpSelect", t, {nz, constant(ConstantInt::get(RT, 1)), constant(ConstantInt::get(RT, 0))}));
        return;
    }
    if (n.starts_with("air.is_function_constant_defined")) {
        // The guest resolves function constants; a host translation treats
        // every constant as defined.
        bind(C, E.boolean(true));
        return;
    }
    if (callTexture(C, n)) return;
    if (callSimd(C, n)) return;
    if (callAtomic(C, n)) return;
    if (callMath(C, n)) return;
    (void)fmtHex;
    if (!n.starts_with("air.") && !n.starts_with("llvm."))
        fail("unsupported-feature", "call to the external function " + n.str() + " (visible or linked function)");
    fail("unsupported-intrinsic", n.str());
}

}  // namespace airc
