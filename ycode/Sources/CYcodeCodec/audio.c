/* CYcodeCodec audio (see include/CYcodeCodec.h): Opus (libopus, BSD,
 * xiph.org; the constants below are those of its public opus_defines.h,
 * v1.5.2) and PulseAudio's simple API (libpulse-simple, served by PipeWire's
 * pulse server on current desktops; values from its public documentation),
 * both opened at run time with dlopen. Nothing is linked. */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include "CYcodeCodec.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

/* ---- Opus ---- */

#define Y_OPUS_OK 0
#define Y_OPUS_APPLICATION_RESTRICTED_LOWDELAY 2051
#define Y_OPUS_SET_BITRATE_REQUEST 4002
#define Y_OPUS_SET_COMPLEXITY_REQUEST 4010
#define Y_OPUS_SET_INBAND_FEC_REQUEST 4012
#define Y_OPUS_SET_PACKET_LOSS_PERC_REQUEST 4014

static struct {
    void *(*enc_create)(int32_t, int, int, int *);
    int (*enc_ctl)(void *, int, ...);
    int32_t (*encode_float)(void *, const float *, int, unsigned char *, int32_t);
    void (*enc_destroy)(void *);
    void *(*dec_create)(int32_t, int, int *);
    int (*decode_float)(void *, const unsigned char *, int32_t, float *, int, int);
    void (*dec_destroy)(void *);
    int ok;
} OP;
static pthread_once_t opOnce = PTHREAD_ONCE_INIT;

static void op_load(void) {
    const char *names[] = {"libopus.so.0", "libopus.so", "libopus.0.dylib", "/opt/homebrew/lib/libopus.0.dylib", NULL};
    void *h = NULL;
    for (int i = 0; names[i] && !h; i++) h = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
    if (!h) return;
#define S(f, n) *(void **)&OP.f = dlsym(h, n); if (!OP.f) return;
    S(enc_create, "opus_encoder_create") S(enc_ctl, "opus_encoder_ctl") S(encode_float, "opus_encode_float")
    S(enc_destroy, "opus_encoder_destroy") S(dec_create, "opus_decoder_create") S(decode_float, "opus_decode_float")
    S(dec_destroy, "opus_decoder_destroy")
#undef S
    OP.ok = 1;
}

int ycodec_opus_available(void) {
    pthread_once(&opOnce, op_load);
    return OP.ok;
}

void *ycodec_opus_encoder_new(int sampleRate, int channels, int bitrate) {
    if (!ycodec_opus_available()) return NULL;
    int err = 0;
    void *e = OP.enc_create(sampleRate, channels, Y_OPUS_APPLICATION_RESTRICTED_LOWDELAY, &err);
    if (!e || err != Y_OPUS_OK) return NULL;
    OP.enc_ctl(e, Y_OPUS_SET_BITRATE_REQUEST, (int32_t)bitrate);
    OP.enc_ctl(e, Y_OPUS_SET_COMPLEXITY_REQUEST, (int32_t)5);
    OP.enc_ctl(e, Y_OPUS_SET_INBAND_FEC_REQUEST, (int32_t)1);
    OP.enc_ctl(e, Y_OPUS_SET_PACKET_LOSS_PERC_REQUEST, (int32_t)5);
    return e;
}

int ycodec_opus_encode(void *e, const float *pcm, int frames, uint8_t *out, int maxBytes) {
    if (!e) return -1;
    return (int)OP.encode_float(e, pcm, frames, out, maxBytes);
}

void ycodec_opus_encoder_free(void *e) { if (e) OP.enc_destroy(e); }

void *ycodec_opus_decoder_new(int sampleRate, int channels) {
    if (!ycodec_opus_available()) return NULL;
    int err = 0;
    void *d = OP.dec_create(sampleRate, channels, &err);
    return err == Y_OPUS_OK ? d : NULL;
}

int ycodec_opus_decode(void *d, const uint8_t *data, int size, float *pcm, int maxFrames, int fec) {
    if (!d) return -1;
    return OP.decode_float(d, data, data ? size : 0, pcm, maxFrames, fec);
}

void ycodec_opus_decoder_free(void *d) { if (d) OP.dec_destroy(d); }

/* ---- PulseAudio simple API ---- */

typedef struct { int format; uint32_t rate; uint8_t channels; } y_pa_sample_spec;   /* pa_sample_spec */
typedef struct { uint32_t maxlength, tlength, prebuf, minreq, fragsize; } y_pa_buffer_attr;  /* pa_buffer_attr */
#define Y_PA_SAMPLE_FLOAT32LE 5
#define Y_PA_STREAM_PLAYBACK 1

static struct {
    void *(*open)(const char *, const char *, int, const char *, const char *, const y_pa_sample_spec *, const void *,
                  const y_pa_buffer_attr *, int *);
    int (*write)(void *, const void *, size_t, int *);
    uint64_t (*latency)(void *, int *);
    void (*free_)(void *);
    int ok;
} PA;
static pthread_once_t paOnce = PTHREAD_ONCE_INIT;

static void pa_load(void) {
    void *h = dlopen("libpulse-simple.so.0", RTLD_NOW | RTLD_LOCAL);
    if (!h) return;
#define S(f, n) *(void **)&PA.f = dlsym(h, n); if (!PA.f) return;
    S(open, "pa_simple_new") S(write, "pa_simple_write") S(latency, "pa_simple_get_latency") S(free_, "pa_simple_free")
#undef S
    PA.ok = 1;
}

void *ycodec_pulse_open(const char *app, const char *stream, int sampleRate, int channels, int targetMs) {
    pthread_once(&paOnce, pa_load);
    if (!PA.ok) return NULL;
    y_pa_sample_spec ss = {Y_PA_SAMPLE_FLOAT32LE, (uint32_t)sampleRate, (uint8_t)channels};
    uint32_t bytesPerMs = (uint32_t)(sampleRate / 1000 * channels * 4);
    y_pa_buffer_attr attr = {(uint32_t)-1, bytesPerMs * (uint32_t)targetMs, 0, bytesPerMs * 2, (uint32_t)-1};
    int err = 0;
    return PA.open(NULL, app, Y_PA_STREAM_PLAYBACK, NULL, stream, &ss, NULL, &attr, &err);
}

int ycodec_pulse_write(void *s, const float *pcm, int frames, int channels) {
    if (!s) return -1;
    int err = 0;
    return PA.write(s, pcm, (size_t)frames * (size_t)channels * 4, &err);
}

int64_t ycodec_pulse_latency_us(void *s) {
    if (!s) return -1;
    int err = 0;
    uint64_t l = PA.latency(s, &err);
    return err ? -1 : (int64_t)l;
}

void ycodec_pulse_close(void *s) { if (s) PA.free_(s); }
