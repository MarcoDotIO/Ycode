// ctype.c - character classes for the C locale and the rune-locale table
// the SDK's inline <ctype.h> functions read (specs/macos/libsystem.md §12).
// Clean-room Ycode code. `_RuneLocale` and the `_CTYPE_*` masks are the
// public <runetype.h> and <_ctype.h> layouts (interoperability facts);
// classification follows the C standard's "C" locale.
#include "ycl.h"

enum {
    CT_A = 0x100, CT_C = 0x200, CT_D = 0x400, CT_G = 0x800, CT_L = 0x1000, CT_P = 0x2000, CT_S = 0x4000,
    CT_U = 0x8000, CT_X = 0x10000, CT_B = 0x20000, CT_R = 0x40000, CT_SW1 = 0x40000000,
};

struct ycl_rune_range {
    int nranges;
    void *ranges;
};

struct ycl_rune_locale {
    char magic[8];
    char encoding[32];
    int (*sgetrune)(const char *, size_t, char const **);
    int (*sputrune)(int, char *, size_t, char **);
    int invalid_rune;
    uint32_t runetype[256];
    int maplower[256];
    int mapupper[256];
    struct ycl_rune_range runetype_ext, maplower_ext, mapupper_ext;
    void *variable;
    int variable_len;
    int ncharclasses;
    void *charclasses;
};

YCL_EXPORT struct ycl_rune_locale _DefaultRuneLocale = {
    .magic = {'R', 'u', 'n', 'e', 'M', 'a', 'g', 'A'},
    .encoding = {'N', 'O', 'N', 'E'},
    .invalid_rune = 0xFFFD,
};
YCL_EXPORT struct ycl_rune_locale *_CurrentRuneLocale = &_DefaultRuneLocale;

static uint32_t class_of(int c) {
    uint32_t t = 0;
    if (c < 0x20 || c == 0x7F) t |= CT_C;
    if (c == ' ' || c == '\t') t |= CT_B;
    if (c == ' ' || (c >= '\t' && c <= '\r')) t |= CT_S;
    if (c >= '0' && c <= '9') t |= CT_D | CT_X;
    if ((c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) t |= CT_X;
    if (c >= 'a' && c <= 'z') t |= CT_L | CT_A;
    if (c >= 'A' && c <= 'Z') t |= CT_U | CT_A;
    if (c > 0x20 && c < 0x7F) {
        t |= CT_G | CT_R | CT_SW1;
        if (!(t & (CT_A | CT_D))) t |= CT_P;
    }
    if (c == ' ') t |= CT_R | CT_SW1;
    return t;
}

void ycl_ctype_init(void) {
    for (int c = 0; c < 256; c++) {
        _DefaultRuneLocale.runetype[c] = c < 128 ? class_of(c) : 0;
        _DefaultRuneLocale.maplower[c] = (c >= 'A' && c <= 'Z') ? c + 32 : c;
        _DefaultRuneLocale.mapupper[c] = (c >= 'a' && c <= 'z') ? c - 32 : c;
    }
}

YCL_EXPORT unsigned long ___runetype(int c) { return (c >= 0 && c < 256) ? _DefaultRuneLocale.runetype[c] : 0; }
YCL_EXPORT int ___tolower(int c) { return (c >= 0 && c < 256) ? _DefaultRuneLocale.maplower[c] : c; }
YCL_EXPORT int ___toupper(int c) { return (c >= 0 && c < 256) ? _DefaultRuneLocale.mapupper[c] : c; }
YCL_EXPORT int __maskrune(int c, unsigned long mask) { return (int)(___runetype(c) & mask); }
YCL_EXPORT int __toupper(int c) { return ___toupper(c); }
YCL_EXPORT int __tolower(int c) { return ___tolower(c); }
YCL_EXPORT int ___mb_cur_max(void) { return 1; }
YCL_EXPORT int __mb_cur_max = 1;

#define CLASSIFIER(name, mask) \
    YCL_EXPORT int name(int c) { return (c >= 0 && c < 128) ? !!(_DefaultRuneLocale.runetype[c] & (mask)) : 0; }
CLASSIFIER(isalnum, CT_A | CT_D)
CLASSIFIER(isalpha, CT_A)
CLASSIFIER(isblank, CT_B)
CLASSIFIER(iscntrl, CT_C)
CLASSIFIER(isdigit, CT_D)
CLASSIFIER(isgraph, CT_G)
CLASSIFIER(islower, CT_L)
CLASSIFIER(isprint, CT_R)
CLASSIFIER(ispunct, CT_P)
CLASSIFIER(isspace, CT_S)
CLASSIFIER(isupper, CT_U)
CLASSIFIER(isxdigit, CT_X)
YCL_EXPORT int isascii(int c) { return (c & ~0x7F) == 0; }
YCL_EXPORT int toascii(int c) { return c & 0x7F; }
YCL_EXPORT int tolower(int c) { return ___tolower(c); }
YCL_EXPORT int toupper(int c) { return ___toupper(c); }
YCL_EXPORT int digittoint(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return 0;
}

// Wide-character classes: the C locale classifies only ASCII; other code
// points are letters if they are not ASCII (enough for identifiers and
// whitespace splitting), print and graph.
static int wide_class(int c, uint32_t mask) {
    if (c >= 0 && c < 128) return !!(_DefaultRuneLocale.runetype[c] & mask);
    if (c < 0xA0 || c > 0x10FFFF) return 0;
    return !!(mask & (CT_A | CT_G | CT_R));
}

#define WCLASSIFIER(name, mask) \
    YCL_EXPORT int name(int c) { return wide_class(c, mask); }
WCLASSIFIER(iswalnum, CT_A | CT_D)
WCLASSIFIER(iswalpha, CT_A)
WCLASSIFIER(iswblank, CT_B)
WCLASSIFIER(iswcntrl, CT_C)
WCLASSIFIER(iswdigit, CT_D)
WCLASSIFIER(iswgraph, CT_G)
WCLASSIFIER(iswlower, CT_L)
WCLASSIFIER(iswprint, CT_R)
WCLASSIFIER(iswpunct, CT_P)
WCLASSIFIER(iswspace, CT_S)
WCLASSIFIER(iswupper, CT_U)
WCLASSIFIER(iswxdigit, CT_X)
YCL_EXPORT int towlower(int c) { return (c >= 0 && c < 128) ? ___tolower(c) : c; }
YCL_EXPORT int towupper(int c) { return (c >= 0 && c < 128) ? ___toupper(c) : c; }
YCL_EXPORT int iswctype(int c, unsigned long mask) { return wide_class(c, (uint32_t)mask); }
