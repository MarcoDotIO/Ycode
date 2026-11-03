/* CYcodeVideo (see include/CYcodeVideo.h). NVENC and NVDEC through the
 * public Video Codec SDK interfaces (vendored headers, MIT), resolved with
 * dlopen/dlsym from the NVIDIA driver's libraries. */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include "CYcodeVideo.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void yvid_nv12_to_bgrx(const uint8_t *y, const uint8_t *uv, int pitch, int width, int height, uint8_t *dst, size_t dstStride) {
    /* BT.709 limited range: what NVENC's RGB→YUV conversion does (measured on flat
     * patches: red → Y 63, U 102, V 240), and what the encoder now signals in its VUI. */
    for (int j = 0; j < height; j++) {
        const uint8_t *yr = y + (size_t)j * pitch, *uvr = uv + (size_t)(j / 2) * pitch;
        uint8_t *o = dst + (size_t)j * dstStride;
        for (int i = 0; i < width; i++) {
            int c = (int)yr[i] - 16, d = (int)uvr[i & ~1] - 128, e = (int)uvr[(i & ~1) + 1] - 128;
            int r = (298 * c + 459 * e + 128) >> 8, g = (298 * c - 55 * d - 136 * e + 128) >> 8, b = (298 * c + 541 * d + 128) >> 8;
            o[i * 4 + 0] = (uint8_t)(b < 0 ? 0 : b > 255 ? 255 : b);
            o[i * 4 + 1] = (uint8_t)(g < 0 ? 0 : g > 255 ? 255 : g);
            o[i * 4 + 2] = (uint8_t)(r < 0 ? 0 : r > 255 ? 255 : r);
            o[i * 4 + 3] = 0xFF;
        }
    }
}

void yvid_yuv444_to_bgrx(const uint8_t *y, const uint8_t *u, const uint8_t *v, int pitch, int width, int height, uint8_t *dst, size_t dstStride) {
    /* The same matrix as yvid_nv12_to_bgrx, chroma at every pixel. */
    for (int j = 0; j < height; j++) {
        const uint8_t *yr = y + (size_t)j * pitch, *ur = u + (size_t)j * pitch, *vr = v + (size_t)j * pitch;
        uint8_t *o = dst + (size_t)j * dstStride;
        for (int i = 0; i < width; i++) {
            int c = (int)yr[i] - 16, d = (int)ur[i] - 128, e = (int)vr[i] - 128;
            int r = (298 * c + 459 * e + 128) >> 8, g = (298 * c - 55 * d - 136 * e + 128) >> 8, b = (298 * c + 541 * d + 128) >> 8;
            o[i * 4 + 0] = (uint8_t)(b < 0 ? 0 : b > 255 ? 255 : b);
            o[i * 4 + 1] = (uint8_t)(g < 0 ? 0 : g > 255 ? 255 : g);
            o[i * 4 + 2] = (uint8_t)(r < 0 ? 0 : r > 255 ? 255 : r);
            o[i * 4 + 3] = 0xFF;
        }
    }
}

#if defined(__linux__)
#include <dlfcn.h>
#include <pthread.h>

#include "ffnvcodec/dynlink_cuda.h"
#include "ffnvcodec/dynlink_cuviddec.h"
#include "ffnvcodec/dynlink_nvcuvid.h"
#include "ffnvcodec/nvEncodeAPI.h"

static void seterr(char *error, size_t n, const char *fmt, long v) {
    if (error && n) snprintf(error, n, fmt, v);
}

/* ---- CUDA (driver API) ---- */

static struct {
    tcuInit *Init;
    tcuDeviceGet *DeviceGet;
    tcuCtxCreate_v2 *CtxCreate;
    tcuCtxDestroy_v2 *CtxDestroy;
    tcuCtxPushCurrent_v2 *CtxPush;
    tcuCtxPopCurrent_v2 *CtxPop;
    tcuMemcpy2D_v2 *Memcpy2D;
    int ok;
} CU;
static pthread_once_t cuOnce = PTHREAD_ONCE_INIT;

static void cu_load(void) {
    void *h = dlopen("libcuda.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!h) return;
#define S(f, n) *(void **)&CU.f = dlsym(h, n); if (!CU.f) return;
    S(Init, "cuInit") S(DeviceGet, "cuDeviceGet") S(CtxCreate, "cuCtxCreate_v2") S(CtxDestroy, "cuCtxDestroy_v2")
    S(CtxPush, "cuCtxPushCurrent_v2") S(CtxPop, "cuCtxPopCurrent_v2") S(Memcpy2D, "cuMemcpy2D_v2")
#undef S
    if (CU.Init(0) != CUDA_SUCCESS) return;
    CU.ok = 1;
}

static CUcontext cu_context(void) {
    pthread_once(&cuOnce, cu_load);
    if (!CU.ok) return NULL;
    CUdevice dev;
    CUcontext ctx = NULL, popped;
    if (CU.DeviceGet(&dev, 0) != CUDA_SUCCESS || CU.CtxCreate(&ctx, 0, dev) != CUDA_SUCCESS) return NULL;
    CU.CtxPop(&popped);
    return ctx;
}

/* ---- NVENC ---- */

typedef NVENCSTATUS (NVENCAPI *createInstance_fn)(NV_ENCODE_API_FUNCTION_LIST *);
static NV_ENCODE_API_FUNCTION_LIST NV;
static int nvOK;
static pthread_once_t nvOnce = PTHREAD_ONCE_INIT;

static void nv_load(void) {
    void *h = dlopen("libnvidia-encode.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!h) return;
    createInstance_fn create = (createInstance_fn)dlsym(h, "NvEncodeAPICreateInstance");
    if (!create) return;
    memset(&NV, 0, sizeof NV);
    NV.version = NV_ENCODE_API_FUNCTION_LIST_VER;
    if (create(&NV) != NV_ENC_SUCCESS || !NV.nvEncOpenEncodeSessionEx) return;
    nvOK = 1;
}

struct yvid_enc {
    CUcontext ctx;
    void *session;
    NV_ENC_INPUT_PTR input;
    NV_ENC_OUTPUT_PTR bitstream;
    int width, height;
    uint8_t *out;
    size_t outCap;
    int first;
    int codec;
};

void yvid_enc_close(yvid_enc *e) {
    if (!e) return;
    if (e->session) {
        CU.CtxPush(e->ctx);
        if (e->input) NV.nvEncDestroyInputBuffer(e->session, e->input);
        if (e->bitstream) NV.nvEncDestroyBitstreamBuffer(e->session, e->bitstream);
        NV.nvEncDestroyEncoder(e->session);
        CUcontext p;
        CU.CtxPop(&p);
    }
    if (e->ctx) CU.CtxDestroy(e->ctx);
    free(e->out);
    free(e);
}

/* The VUI says what the pictures are: BT.709 limited range, as NVENC converts BGRA. */
#define SIGNAL_BT709(v) do { \
    (v).videoSignalTypePresentFlag = 1; (v).videoFormat = NV_ENC_VUI_VIDEO_FORMAT_UNSPECIFIED; (v).videoFullRangeFlag = 0; \
    (v).colourDescriptionPresentFlag = 1; (v).colourPrimaries = NV_ENC_VUI_COLOR_PRIMARIES_BT709; \
    (v).transferCharacteristics = NV_ENC_VUI_TRANSFER_CHARACTERISTIC_SRGB; (v).colourMatrix = NV_ENC_VUI_MATRIX_COEFFS_BT709; } while (0)

static const GUID *enc_guid(int codec) {
    switch (codec) {
    case YVID_H264: return &NV_ENC_CODEC_H264_GUID;
    case YVID_HEVC: return &NV_ENC_CODEC_HEVC_GUID;
    case YVID_AV1: return &NV_ENC_CODEC_AV1_GUID;
    default: return NULL;
    }
}

yvid_enc *yvid_enc_open(int width, int height, int fps, int bitrateKbps, char *error, size_t errorSize) {
    yvid_enc_params p = { YVID_H264, 0, fps, bitrateKbps, 0 };
    return yvid_enc_open2(width, height, &p, error, errorSize);
}

yvid_enc *yvid_enc_open2(int width, int height, const yvid_enc_params *params, char *error, size_t errorSize) {
    pthread_once(&nvOnce, nv_load);
    if (!nvOK) { seterr(error, errorSize, "libnvidia-encode.so.1 not available%ld", 0); return NULL; }
    if (width <= 0 || height <= 0 || (width & 1) || (height & 1)) { seterr(error, errorSize, "bad size (%ld)", width); return NULL; }
    const GUID *codec = enc_guid(params->codec);
    if (!codec) { seterr(error, errorSize, "unknown codec %ld", params->codec); return NULL; }
    if (params->yuv444 && params->codec != YVID_HEVC) { seterr(error, errorSize, "4:4:4 is only offered for HEVC (codec %ld)", params->codec); return NULL; }
    int fps = params->fps > 0 ? params->fps : 60, bitrateKbps = params->bitrateKbps;
    yvid_enc *e = calloc(1, sizeof *e);
    if (!e) return NULL;
    e->width = width;
    e->height = height;
    e->first = 1;
    e->codec = params->codec;
    e->ctx = cu_context();
    if (!e->ctx) { seterr(error, errorSize, "no CUDA context%ld", 0); free(e); return NULL; }
    CU.CtxPush(e->ctx);
    NVENCSTATUS st;
    NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS op = {0};
    op.version = NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER;
    op.deviceType = NV_ENC_DEVICE_TYPE_CUDA;
    op.device = e->ctx;
    op.apiVersion = NVENCAPI_VERSION;
    if ((st = NV.nvEncOpenEncodeSessionEx(&op, &e->session)) != NV_ENC_SUCCESS) {
        seterr(error, errorSize, "nvEncOpenEncodeSessionEx: %ld", st);
        e->session = NULL;
        goto fail;
    }
    NV_ENC_PRESET_CONFIG preset = {0};
    preset.version = NV_ENC_PRESET_CONFIG_VER;
    preset.presetCfg.version = NV_ENC_CONFIG_VER;
    if ((st = NV.nvEncGetEncodePresetConfigEx(e->session, *codec, NV_ENC_PRESET_P1_GUID,
                                              NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY, &preset)) != NV_ENC_SUCCESS) {
        seterr(error, errorSize, "nvEncGetEncodePresetConfigEx: %ld", st);
        goto fail;
    }
    NV_ENC_CONFIG cfg = preset.presetCfg;
    cfg.version = NV_ENC_CONFIG_VER;
    cfg.gopLength = NVENC_INFINITE_GOPLENGTH;
    cfg.frameIntervalP = 1;
    if (params->qp > 0) {
        /* Constant QP: every picture at one quality, whatever it costs (the
         * stream sends a picture only when it changes, so nothing would
         * refine a picture a rate limit had starved; display-stream.md §14). */
        cfg.rcParams.rateControlMode = NV_ENC_PARAMS_RC_CONSTQP;
        cfg.rcParams.constQP.qpInterP = cfg.rcParams.constQP.qpInterB = cfg.rcParams.constQP.qpIntra = (uint32_t)params->qp;
        cfg.rcParams.averageBitRate = 0;
        cfg.rcParams.maxBitRate = 0;
        cfg.rcParams.vbvBufferSize = 0;
        cfg.rcParams.vbvInitialDelay = 0;
    } else if (params->constantBitrate) {
        /* CBR with a VBV of one frame at the nominal rate. */
        cfg.rcParams.rateControlMode = NV_ENC_PARAMS_RC_CBR;
        cfg.rcParams.averageBitRate = (uint32_t)bitrateKbps * 1000u;
        cfg.rcParams.maxBitRate = (uint32_t)bitrateKbps * 1000u;
        cfg.rcParams.vbvBufferSize = (uint32_t)((uint64_t)bitrateKbps * 1000u / (uint32_t)fps);
        cfg.rcParams.vbvInitialDelay = cfg.rcParams.vbvBufferSize;
    } else {
        cfg.rcParams.rateControlMode = NV_ENC_PARAMS_RC_VBR;
        cfg.rcParams.averageBitRate = (uint32_t)bitrateKbps * 1000u;
        cfg.rcParams.maxBitRate = (uint32_t)bitrateKbps * 2000u;
        cfg.rcParams.vbvBufferSize = (uint32_t)((uint64_t)bitrateKbps * 2000u / (uint32_t)fps);
        cfg.rcParams.vbvInitialDelay = cfg.rcParams.vbvBufferSize;
    }
    cfg.rcParams.zeroReorderDelay = 1;
    switch (params->codec) {
    case YVID_H264:
        cfg.encodeCodecConfig.h264Config.idrPeriod = NVENC_INFINITE_GOPLENGTH;
        cfg.encodeCodecConfig.h264Config.repeatSPSPPS = 1;
        cfg.encodeCodecConfig.h264Config.maxNumRefFrames = 1;
        SIGNAL_BT709(cfg.encodeCodecConfig.h264Config.h264VUIParameters);
        break;
    case YVID_HEVC:
        cfg.encodeCodecConfig.hevcConfig.idrPeriod = NVENC_INFINITE_GOPLENGTH;
        cfg.encodeCodecConfig.hevcConfig.repeatSPSPPS = 1;
        cfg.encodeCodecConfig.hevcConfig.maxNumRefFramesInDPB = 1;
        cfg.encodeCodecConfig.hevcConfig.chromaFormatIDC = params->yuv444 ? 3 : 1;
        cfg.encodeCodecConfig.hevcConfig.inputBitDepth = NV_ENC_BIT_DEPTH_8;
        cfg.encodeCodecConfig.hevcConfig.outputBitDepth = NV_ENC_BIT_DEPTH_8;
        if (params->yuv444) cfg.profileGUID = NV_ENC_HEVC_PROFILE_FREXT_GUID;
        SIGNAL_BT709(cfg.encodeCodecConfig.hevcConfig.hevcVUIParameters);
        break;
    case YVID_AV1:
        cfg.encodeCodecConfig.av1Config.idrPeriod = NVENC_INFINITE_GOPLENGTH;
        cfg.encodeCodecConfig.av1Config.repeatSeqHdr = 1;
        cfg.encodeCodecConfig.av1Config.maxNumRefFramesInDPB = 1;
        cfg.encodeCodecConfig.av1Config.chromaFormatIDC = 1;
        cfg.encodeCodecConfig.av1Config.inputBitDepth = NV_ENC_BIT_DEPTH_8;
        cfg.encodeCodecConfig.av1Config.outputBitDepth = NV_ENC_BIT_DEPTH_8;
        break;
    }
    NV_ENC_INITIALIZE_PARAMS init = {0};
    init.version = NV_ENC_INITIALIZE_PARAMS_VER;
    init.encodeGUID = *codec;
    init.presetGUID = NV_ENC_PRESET_P1_GUID;
    init.tuningInfo = NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY;
    init.encodeWidth = init.darWidth = (uint32_t)width;
    init.encodeHeight = init.darHeight = (uint32_t)height;
    init.frameRateNum = (uint32_t)fps;
    init.frameRateDen = 1;
    init.enablePTD = 1;
    init.encodeConfig = &cfg;
    init.maxEncodeWidth = (uint32_t)width;
    init.maxEncodeHeight = (uint32_t)height;
    if ((st = NV.nvEncInitializeEncoder(e->session, &init)) != NV_ENC_SUCCESS) {
        seterr(error, errorSize, "nvEncInitializeEncoder: %ld", st);
        goto fail;
    }
    NV_ENC_CREATE_INPUT_BUFFER in = {0};
    in.version = NV_ENC_CREATE_INPUT_BUFFER_VER;
    in.width = (uint32_t)width;
    in.height = (uint32_t)height;
    in.bufferFmt = NV_ENC_BUFFER_FORMAT_ARGB;
    if ((st = NV.nvEncCreateInputBuffer(e->session, &in)) != NV_ENC_SUCCESS) {
        seterr(error, errorSize, "nvEncCreateInputBuffer: %ld", st);
        goto fail;
    }
    e->input = in.inputBuffer;
    NV_ENC_CREATE_BITSTREAM_BUFFER bs = {0};
    bs.version = NV_ENC_CREATE_BITSTREAM_BUFFER_VER;
    if ((st = NV.nvEncCreateBitstreamBuffer(e->session, &bs)) != NV_ENC_SUCCESS) {
        seterr(error, errorSize, "nvEncCreateBitstreamBuffer: %ld", st);
        goto fail;
    }
    e->bitstream = bs.bitstreamBuffer;
    CUcontext p;
    CU.CtxPop(&p);
    return e;
fail:
    CU.CtxPop(&(CUcontext){0});
    yvid_enc_close(e);
    return NULL;
}

int yvid_enc_encode(yvid_enc *e, const uint8_t *bgra, size_t stride, const int32_t *rects, int count, int forceIDR,
                    const uint8_t **out, size_t *outSize, int *isIDR) {
    if (!e) return -1;
    CU.CtxPush(e->ctx);
    int rc = -1;
    NV_ENC_LOCK_INPUT_BUFFER lk = {0};
    lk.version = NV_ENC_LOCK_INPUT_BUFFER_VER;
    lk.inputBuffer = e->input;
    NVENCSTATUS est = NV.nvEncLockInputBuffer(e->session, &lk);
    if (est != NV_ENC_SUCCESS) {
        if (getenv("YCODE_DISPLAY_VIDEO_DEBUG")) fprintf(stderr, "nvEncLockInputBuffer: %d: %s\n", (int)est, NV.nvEncGetLastErrorString ? NV.nvEncGetLastErrorString(e->session) : "");
        goto done;
    }
    {
        uint8_t *dst = lk.bufferDataPtr;
        size_t pitch = lk.pitch;
        if (count < 0 || e->first) {
            for (int y = 0; y < e->height; y++) memcpy(dst + (size_t)y * pitch, bgra + (size_t)y * stride, (size_t)e->width * 4);
        } else {
            for (int i = 0; i < count; i++) {
                int x = rects[i * 4], y0 = rects[i * 4 + 1], w = rects[i * 4 + 2], h = rects[i * 4 + 3];
                if (x < 0 || y0 < 0 || w <= 0 || h <= 0 || x + w > e->width || y0 + h > e->height) continue;
                for (int y = y0; y < y0 + h; y++)
                    memcpy(dst + (size_t)y * pitch + (size_t)x * 4, bgra + (size_t)y * stride + (size_t)x * 4, (size_t)w * 4);
            }
        }
    }
    NV.nvEncUnlockInputBuffer(e->session, e->input);
    NV_ENC_PIC_PARAMS pic = {0};
    pic.version = NV_ENC_PIC_PARAMS_VER;
    pic.inputWidth = (uint32_t)e->width;
    pic.inputHeight = (uint32_t)e->height;
    pic.inputPitch = (uint32_t)e->width;
    pic.inputBuffer = e->input;
    pic.outputBitstream = e->bitstream;
    pic.bufferFmt = NV_ENC_BUFFER_FORMAT_ARGB;
    pic.pictureStruct = NV_ENC_PIC_STRUCT_FRAME;
    /* AV1: repeatSeqHdr already puts the sequence header on every key frame. */
    if (forceIDR || e->first) pic.encodePicFlags = NV_ENC_PIC_FLAG_FORCEIDR | (e->codec == YVID_AV1 ? 0 : NV_ENC_PIC_FLAG_OUTPUT_SPSPPS);
    est = NV.nvEncEncodePicture(e->session, &pic);
    if (est != NV_ENC_SUCCESS) {
        if (getenv("YCODE_DISPLAY_VIDEO_DEBUG")) fprintf(stderr, "nvEncEncodePicture: %d: %s\n", (int)est, NV.nvEncGetLastErrorString ? NV.nvEncGetLastErrorString(e->session) : "");
        goto done;
    }
    NV_ENC_LOCK_BITSTREAM lb = {0};
    lb.version = NV_ENC_LOCK_BITSTREAM_VER;
    lb.outputBitstream = e->bitstream;
    if ((est = NV.nvEncLockBitstream(e->session, &lb)) != NV_ENC_SUCCESS) {
        if (getenv("YCODE_DISPLAY_VIDEO_DEBUG")) fprintf(stderr, "nvEncLockBitstream: %d: %s\n", (int)est, NV.nvEncGetLastErrorString ? NV.nvEncGetLastErrorString(e->session) : "");
        goto done;
    }
    if (lb.bitstreamSizeInBytes > e->outCap) {
        free(e->out);
        e->outCap = lb.bitstreamSizeInBytes * 2;
        e->out = malloc(e->outCap);
    }
    if (e->out) {
        memcpy(e->out, lb.bitstreamBufferPtr, lb.bitstreamSizeInBytes);
        *out = e->out;
        *outSize = lb.bitstreamSizeInBytes;
        /* AV1 reports a key frame as I; a forced IDR is a key frame whatever it reports. */
        *isIDR = lb.pictureType == NV_ENC_PIC_TYPE_IDR || forceIDR || e->first;
        rc = 0;
        e->first = 0;
    }
    NV.nvEncUnlockBitstream(e->session, e->bitstream);
done:;
    CUcontext p;
    CU.CtxPop(&p);
    return rc;
}

static int encChecked = -1;
static pthread_mutex_t encCheckLock = PTHREAD_MUTEX_INITIALIZER;

int yvid_enc_available(void) {
    pthread_mutex_lock(&encCheckLock);
    if (encChecked < 0) {
        char err[128];
        yvid_enc *e = yvid_enc_open(256, 256, 60, 1000, err, sizeof err);  /* NVENC has a minimum size (above 64 x 64) */
        encChecked = e != NULL;
        yvid_enc_close(e);
    }
    int r = encChecked;
    pthread_mutex_unlock(&encCheckLock);
    return r;
}

static int guid_equal(const GUID *a, const GUID *b) { return memcmp(a, b, sizeof *a) == 0; }

int yvid_enc_query(int codec, yvid_enc_caps *caps, char *error, size_t errorSize) {
    memset(caps, 0, sizeof *caps);
    pthread_once(&nvOnce, nv_load);
    if (!nvOK) { seterr(error, errorSize, "libnvidia-encode.so.1 not available%ld", 0); return -1; }
    const GUID *guid = enc_guid(codec);
    if (!guid) { seterr(error, errorSize, "unknown codec %ld", codec); return -1; }
    CUcontext ctx = cu_context();
    if (!ctx) { seterr(error, errorSize, "no CUDA context%ld", 0); return -1; }
    CU.CtxPush(ctx);
    void *session = NULL;
    NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS op = {0};
    op.version = NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER;
    op.deviceType = NV_ENC_DEVICE_TYPE_CUDA;
    op.device = ctx;
    op.apiVersion = NVENCAPI_VERSION;
    int rc = -1;
    NVENCSTATUS st = NV.nvEncOpenEncodeSessionEx(&op, &session);
    if (st != NV_ENC_SUCCESS) { seterr(error, errorSize, "nvEncOpenEncodeSessionEx: %ld", st); session = NULL; goto done; }
    uint32_t count = 0, got = 0;
    if ((st = NV.nvEncGetEncodeGUIDCount(session, &count)) != NV_ENC_SUCCESS) { seterr(error, errorSize, "nvEncGetEncodeGUIDCount: %ld", st); goto done; }
    GUID guids[16];
    if (count > 16) count = 16;
    if ((st = NV.nvEncGetEncodeGUIDs(session, guids, count, &got)) != NV_ENC_SUCCESS) { seterr(error, errorSize, "nvEncGetEncodeGUIDs: %ld", st); goto done; }
    rc = 0;
    for (uint32_t i = 0; i < got; i++) if (guid_equal(&guids[i], guid)) caps->supported = 1;
    if (caps->supported) {
#define CAP(field, which) { NV_ENC_CAPS_PARAM q = {0}; q.version = NV_ENC_CAPS_PARAM_VER; q.capsToQuery = which; int v = 0; \
        if (NV.nvEncGetEncodeCaps(session, *guid, &q, &v) == NV_ENC_SUCCESS) caps->field = v; }
        CAP(yuv444, NV_ENC_CAPS_SUPPORT_YUV444_ENCODE)
        CAP(tenBit, NV_ENC_CAPS_SUPPORT_10BIT_ENCODE)
        CAP(maxWidth, NV_ENC_CAPS_WIDTH_MAX)
        CAP(maxHeight, NV_ENC_CAPS_HEIGHT_MAX)
#undef CAP
    }
done:
    if (session) NV.nvEncDestroyEncoder(session);
    CUcontext popped;
    CU.CtxPop(&popped);
    CU.CtxDestroy(ctx);
    return rc;
}

/* ---- NVDEC ---- */

static struct {
    tcuvidCreateVideoParser *CreateParser;
    tcuvidParseVideoData *Parse;
    tcuvidDestroyVideoParser *DestroyParser;
    tcuvidCreateDecoder *CreateDecoder;
    tcuvidDestroyDecoder *DestroyDecoder;
    tcuvidDecodePicture *DecodePicture;
    tcuvidMapVideoFrame64 *Map;
    tcuvidUnmapVideoFrame64 *Unmap;
    tcuvidGetDecoderCaps *Caps;
    int ok;
} DV;
static pthread_once_t dvOnce = PTHREAD_ONCE_INIT;

static void dv_load(void) {
    void *h = dlopen("libnvcuvid.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!h) return;
#define S(f, n) *(void **)&DV.f = dlsym(h, n); if (!DV.f) return;
    S(CreateParser, "cuvidCreateVideoParser") S(Parse, "cuvidParseVideoData") S(DestroyParser, "cuvidDestroyVideoParser")
    S(CreateDecoder, "cuvidCreateDecoder") S(DestroyDecoder, "cuvidDestroyDecoder") S(DecodePicture, "cuvidDecodePicture")
    S(Map, "cuvidMapVideoFrame64") S(Unmap, "cuvidUnmapVideoFrame64")
#undef S
    *(void **)&DV.Caps = dlsym(h, "cuvidGetDecoderCaps");  /* optional: without it only H.264 4:2:0 is assumed */
    DV.ok = 1;
}

struct yvid_dec {
    CUcontext ctx;
    CUvideoparser parser;
    CUvideodecoder decoder;
    int width, height, codedW, codedH, cropTop, cropLeft;
    int format;                  /* YVID_NV12 or YVID_YUV444 */
    uint8_t *planes;
    size_t planesCap;
    int got, failed;
};

static cudaVideoCodec dec_codec(int codec) {
    switch (codec) {
    case YVID_HEVC: return cudaVideoCodec_HEVC;
    case YVID_AV1: return cudaVideoCodec_AV1;
    default: return cudaVideoCodec_H264;
    }
}

static int CUDAAPI on_sequence(void *user, CUVIDEOFORMAT *f) {
    yvid_dec *d = user;
    int w = f->display_area.right - f->display_area.left, h = f->display_area.bottom - f->display_area.top;
    int format = f->chroma_format == cudaVideoChromaFormat_444 ? YVID_YUV444 : YVID_NV12;
    if (d->decoder && w == d->width && h == d->height && (int)f->coded_width == d->codedW && (int)f->coded_height == d->codedH && format == d->format)
        return f->min_num_decode_surfaces > 2 ? f->min_num_decode_surfaces : 2;
    if (d->decoder) { DV.DestroyDecoder(d->decoder); d->decoder = NULL; }
    CUVIDDECODECREATEINFO ci = {0};
    ci.CodecType = f->codec;
    ci.ChromaFormat = f->chroma_format;
    ci.OutputFormat = format == YVID_YUV444 ? cudaVideoSurfaceFormat_YUV444 : cudaVideoSurfaceFormat_NV12;
    ci.bitDepthMinus8 = f->bit_depth_luma_minus8;
    ci.DeinterlaceMode = cudaVideoDeinterlaceMode_Weave;
    ci.ulWidth = f->coded_width;
    ci.ulHeight = f->coded_height;
    ci.ulMaxWidth = f->coded_width;
    ci.ulMaxHeight = f->coded_height;
    ci.display_area.left = (short)f->display_area.left;
    ci.display_area.top = (short)f->display_area.top;
    ci.display_area.right = (short)f->display_area.right;
    ci.display_area.bottom = (short)f->display_area.bottom;
    ci.ulTargetWidth = (unsigned long)w;
    ci.ulTargetHeight = (unsigned long)h;
    ci.ulNumDecodeSurfaces = f->min_num_decode_surfaces > 2 ? f->min_num_decode_surfaces : 2;
    ci.ulNumOutputSurfaces = 1;
    ci.ulCreationFlags = cudaVideoCreate_PreferCUVID;
    if (DV.CreateDecoder(&d->decoder, &ci) != CUDA_SUCCESS) { d->failed = 1; d->decoder = NULL; return 0; }
    d->width = w;
    d->height = h;
    d->codedW = (int)f->coded_width;
    d->codedH = (int)f->coded_height;
    d->format = format;
    return (int)ci.ulNumDecodeSurfaces;
}

static int CUDAAPI on_decode(void *user, CUVIDPICPARAMS *p) {
    yvid_dec *d = user;
    if (!d->decoder) return 0;
    if (DV.DecodePicture(d->decoder, p) != CUDA_SUCCESS) { d->failed = 1; return 0; }
    return 1;
}

static int CUDAAPI on_display(void *user, CUVIDPARSERDISPINFO *info) {
    yvid_dec *d = user;
    if (!d->decoder || !info) return 1;
    CUVIDPROCPARAMS pp = {0};
    pp.progressive_frame = info->progressive_frame;
    pp.top_field_first = info->top_field_first;
    unsigned long long dev = 0;
    unsigned int pitch = 0;
    if (DV.Map(d->decoder, info->picture_index, &dev, &pitch, &pp) != CUDA_SUCCESS) { d->failed = 1; return 0; }
    size_t luma = (size_t)d->width * (size_t)d->height;
    size_t need = d->format == YVID_YUV444 ? luma * 3 : luma * 3 / 2;
    if (need > d->planesCap) {
        free(d->planes);
        d->planes = malloc(need);
        d->planesCap = d->planes ? need : 0;
    }
    if (d->planes) {
        CUDA_MEMCPY2D c = {0};
        c.srcMemoryType = CU_MEMORYTYPE_DEVICE;
        c.srcDevice = (CUdeviceptr)dev;
        c.srcPitch = pitch;
        c.dstMemoryType = CU_MEMORYTYPE_HOST;
        c.dstHost = d->planes;
        c.dstPitch = (size_t)d->width;
        c.WidthInBytes = (size_t)d->width;
        c.Height = (size_t)d->height;
        int ok = CU.Memcpy2D(&c) == CUDA_SUCCESS;
        /* The chroma planes follow the output surface's luma rows (its height is the target height, rounded up to even). */
        unsigned long long rows = (unsigned long long)((d->height + 1) & ~1);
        c.srcDevice = (CUdeviceptr)(dev + (unsigned long long)pitch * rows);
        c.dstHost = d->planes + luma;
        if (d->format == YVID_YUV444) {
            ok = ok && CU.Memcpy2D(&c) == CUDA_SUCCESS;
            c.srcDevice = (CUdeviceptr)(dev + (unsigned long long)pitch * rows * 2);
            c.dstHost = d->planes + luma * 2;
            ok = ok && CU.Memcpy2D(&c) == CUDA_SUCCESS;
        } else {
            c.Height = (size_t)d->height / 2;
            ok = ok && CU.Memcpy2D(&c) == CUDA_SUCCESS;
        }
        if (ok) d->got = 1; else d->failed = 1;
    }
    DV.Unmap(d->decoder, dev);
    return 1;
}

yvid_dec *yvid_dec_open(char *error, size_t errorSize) { return yvid_dec_open2(YVID_H264, error, errorSize); }

yvid_dec *yvid_dec_open2(int codec, char *error, size_t errorSize) {
    pthread_once(&dvOnce, dv_load);
    if (!DV.ok) { seterr(error, errorSize, "libnvcuvid.so.1 not available%ld", 0); return NULL; }
    yvid_dec *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    d->ctx = cu_context();
    if (!d->ctx) { seterr(error, errorSize, "no CUDA context%ld", 0); free(d); return NULL; }
    CUVIDPARSERPARAMS pp = {0};
    pp.CodecType = dec_codec(codec);
    pp.ulMaxNumDecodeSurfaces = 4;
    pp.ulMaxDisplayDelay = 0;
    pp.pUserData = d;
    pp.pfnSequenceCallback = on_sequence;
    pp.pfnDecodePicture = on_decode;
    pp.pfnDisplayPicture = on_display;
    CU.CtxPush(d->ctx);
    CUresult r = DV.CreateParser(&d->parser, &pp);
    CUcontext p;
    CU.CtxPop(&p);
    if (r != CUDA_SUCCESS) { seterr(error, errorSize, "cuvidCreateVideoParser: %ld", r); CU.CtxDestroy(d->ctx); free(d); return NULL; }
    return d;
}

int yvid_dec_decode(yvid_dec *d, const uint8_t *au, size_t size, const uint8_t **y, const uint8_t **uv, int *width, int *height, int *pitch) {
    yvid_picture pic;
    int r = yvid_dec_decode2(d, au, size, &pic);
    if (r != 1) return r;
    if (pic.format != YVID_NV12) return -1;
    *y = pic.y;
    *uv = pic.u;
    *width = pic.width;
    *height = pic.height;
    *pitch = pic.pitch;
    return 1;
}

int yvid_dec_decode2(yvid_dec *d, const uint8_t *au, size_t size, yvid_picture *out) {
    if (!d) return -1;
    CU.CtxPush(d->ctx);
    d->got = 0;
    d->failed = 0;
    CUVIDSOURCEDATAPACKET pkt = {0};
    pkt.payload = au;
    pkt.payload_size = (unsigned long)size;
    pkt.flags = CUVID_PKT_ENDOFPICTURE;
    CUresult r = DV.Parse(d->parser, &pkt);
    CUcontext p;
    CU.CtxPop(&p);
    if (r != CUDA_SUCCESS || d->failed) return -1;
    if (!d->got) return 0;
    size_t luma = (size_t)d->width * (size_t)d->height;
    out->format = d->format;
    out->y = d->planes;
    out->u = d->planes + luma;
    out->v = d->format == YVID_YUV444 ? d->planes + luma * 2 : NULL;
    out->width = d->width;
    out->height = d->height;
    out->pitch = d->width;
    return 1;
}

void yvid_dec_close(yvid_dec *d) {
    if (!d) return;
    CU.CtxPush(d->ctx);
    if (d->parser) DV.DestroyParser(d->parser);
    if (d->decoder) DV.DestroyDecoder(d->decoder);
    CUcontext p;
    CU.CtxPop(&p);
    CU.CtxDestroy(d->ctx);
    free(d->planes);
    free(d);
}

static int decChecked = -1;

int yvid_dec_available(void) {
    pthread_mutex_lock(&encCheckLock);
    if (decChecked < 0) {
        yvid_dec *d = yvid_dec_open(NULL, 0);
        decChecked = d != NULL;
        yvid_dec_close(d);
    }
    int r = decChecked;
    pthread_mutex_unlock(&encCheckLock);
    return r;
}

int yvid_dec_query(int codec, int yuv444, int bitDepth, yvid_dec_caps *caps) {
    memset(caps, 0, sizeof *caps);
    pthread_once(&dvOnce, dv_load);
    if (!DV.ok) return -1;
    if (!DV.Caps) { caps->supported = codec == YVID_H264 && !yuv444 && bitDepth == 8; caps->maxWidth = caps->maxHeight = 4096; return 0; }
    CUcontext ctx = cu_context();
    if (!ctx) return -1;
    CU.CtxPush(ctx);
    CUVIDDECODECAPS q;
    memset(&q, 0, sizeof q);
    q.eCodecType = dec_codec(codec);
    q.eChromaFormat = yuv444 ? cudaVideoChromaFormat_444 : cudaVideoChromaFormat_420;
    q.nBitDepthMinus8 = (unsigned)(bitDepth - 8);
    CUresult r = DV.Caps(&q);
    CUcontext popped;
    CU.CtxPop(&popped);
    CU.CtxDestroy(ctx);
    if (r != CUDA_SUCCESS) return -1;
    caps->supported = q.bIsSupported != 0;
    caps->maxWidth = (int)q.nMaxWidth;
    caps->maxHeight = (int)q.nMaxHeight;
    return 0;
}

#else /* not Linux: no NVENC/NVDEC here */

int yvid_enc_available(void) { return 0; }
int yvid_enc_query(int codec, yvid_enc_caps *caps, char *error, size_t errorSize) {
    (void)codec;
    memset(caps, 0, sizeof *caps);
    if (error && errorSize) snprintf(error, errorSize, "video encoding needs Linux with an NVIDIA driver");
    return -1;
}
yvid_enc *yvid_enc_open2(int width, int height, const yvid_enc_params *params, char *error, size_t errorSize) {
    (void)width; (void)height; (void)params;
    if (error && errorSize) snprintf(error, errorSize, "video encoding needs Linux with an NVIDIA driver");
    return NULL;
}
yvid_enc *yvid_enc_open(int width, int height, int fps, int bitrateKbps, char *error, size_t errorSize) {
    (void)width; (void)height; (void)fps; (void)bitrateKbps;
    if (error && errorSize) snprintf(error, errorSize, "video encoding needs Linux with an NVIDIA driver");
    return NULL;
}
int yvid_enc_encode(yvid_enc *e, const uint8_t *bgra, size_t stride, const int32_t *rects, int count, int forceIDR,
                    const uint8_t **out, size_t *outSize, int *isIDR) {
    (void)e; (void)bgra; (void)stride; (void)rects; (void)count; (void)forceIDR; (void)out; (void)outSize; (void)isIDR;
    return -1;
}
void yvid_enc_close(yvid_enc *e) { (void)e; }
int yvid_dec_available(void) { return 0; }
yvid_dec *yvid_dec_open(char *error, size_t errorSize) {
    if (error && errorSize) snprintf(error, errorSize, "video decoding needs Linux with an NVIDIA driver");
    return NULL;
}
int yvid_dec_decode(yvid_dec *d, const uint8_t *au, size_t size, const uint8_t **y, const uint8_t **uv, int *width, int *height, int *pitch) {
    (void)d; (void)au; (void)size; (void)y; (void)uv; (void)width; (void)height; (void)pitch;
    return -1;
}
void yvid_dec_close(yvid_dec *d) { (void)d; }
int yvid_dec_query(int codec, int yuv444, int bitDepth, yvid_dec_caps *caps) {
    (void)codec; (void)yuv444; (void)bitDepth;
    memset(caps, 0, sizeof *caps);
    return -1;
}
yvid_dec *yvid_dec_open2(int codec, char *error, size_t errorSize) {
    (void)codec;
    if (error && errorSize) snprintf(error, errorSize, "video decoding needs Linux with an NVIDIA driver");
    return NULL;
}
int yvid_dec_decode2(yvid_dec *d, const uint8_t *au, size_t size, yvid_picture *out) {
    (void)d; (void)au; (void)size; (void)out;
    return -1;
}

#endif
