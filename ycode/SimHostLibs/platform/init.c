/*
 * init.c - __libplatform_init of Ycode's libsystem_platform.
 *
 * Clean-room Ycode code, from host-library-init.md section 1.3 (platform
 * steps) and host-libraries.md section 7. Called by libSystem's
 * initializer as __libplatform_init(NULL, envp, apple, vars). Like every
 * Ycode init function it is safe to skip and safe to call twice: the
 * library works from static state, and repeated calls only refresh it.
 *
 * Steps:
 *  1. security_config=<hex> from apple[] is kept in a private global
 *     (Ycode's VMM passes 0x0);
 *  2. a pfz=... string in apple[] is erased (zero-filled, key included);
 *     libsystem_kernel has already read it;
 *  3. the simple-ASL context is set up (simple.c);
 *  4. __libkernel_platform_init receives the version-1 string table.
 */
#include "yc_platform.h"

YC_HIDDEN void __yc_simple_asl_init(const char **envp, const void *vars);

void *YC_FN(_platform_memmove)(void *, const void *, yc_size_t);
void *YC_FN(_platform_memccpy)(void *, const void *, int, yc_size_t);
void *YC_FN(_platform_memchr)(const void *, int, yc_size_t);
int YC_FN(_platform_memcmp)(const void *, const void *, yc_size_t);
void *YC_FN(_platform_memset)(void *, int, yc_size_t);
void YC_FN(_platform_bzero)(void *, yc_size_t);
yc_size_t YC_FN(_platform_strlen)(const char *);
yc_size_t YC_FN(_platform_strnlen)(const char *, yc_size_t);
char *YC_FN(_platform_strchr)(const char *, int);
int YC_FN(_platform_strcmp)(const char *, const char *);
int YC_FN(_platform_strncmp)(const char *, const char *, yc_size_t);
char *YC_FN(_platform_strcpy)(char *, const char *);
char *YC_FN(_platform_strncpy)(char *, const char *, yc_size_t);
yc_size_t YC_FN(_platform_strlcpy)(char *, const char *, yc_size_t);
yc_size_t YC_FN(_platform_strlcat)(char *, const char *, yc_size_t);
char *YC_FN(_platform_strstr)(const char *, const char *);
const char *YC_FN(_simple_getenv)(const char **, const char *);

static const struct yc_libkernel_string_functions string_functions = {
    .version = 1,
    .bzero = (void *)YC_FN(_platform_bzero),
    .memchr = (void *)YC_FN(_platform_memchr),
    .memcmp = (void *)YC_FN(_platform_memcmp),
    .memmove = (void *)YC_FN(_platform_memmove),
    .memccpy = (void *)YC_FN(_platform_memccpy),
    .memset = (void *)YC_FN(_platform_memset),
    .strchr = (void *)YC_FN(_platform_strchr),
    .strcmp = (void *)YC_FN(_platform_strcmp),
    .strcpy = (void *)YC_FN(_platform_strcpy),
    .strlcat = (void *)YC_FN(_platform_strlcat),
    .strlcpy = (void *)YC_FN(_platform_strlcpy),
    .strlen = (void *)YC_FN(_platform_strlen),
    .strncmp = (void *)YC_FN(_platform_strncmp),
    .strncpy = (void *)YC_FN(_platform_strncpy),
    .strnlen = (void *)YC_FN(_platform_strnlen),
    .strstr = (void *)YC_FN(_platform_strstr),
};

_Static_assert(sizeof(struct yc_libkernel_string_functions) == 136, "string table is 136 bytes");

static yc_u64 security_config;

/* Parses "0x<hex digits>" (either case). Returns 0 and leaves *out alone
 * on any malformed input. */
static int parse_hex(const char *s, yc_u64 *out)
{
    if (s == YC_NULL || s[0] != '0' || (s[1] != 'x' && s[1] != 'X'))
        return 0;
    yc_u64 v = 0;
    const char *p = s + 2;
    if (*p == 0)
        return 0;
    for (; *p; p++) {
        int d;
        if (*p >= '0' && *p <= '9') d = *p - '0';
        else if (*p >= 'a' && *p <= 'f') d = *p - 'a' + 10;
        else if (*p >= 'A' && *p <= 'F') d = *p - 'A' + 10;
        else return 0;
        v = (v << 4) | (yc_u64)d;
    }
    *out = v;
    return 1;
}

YC_HIDDEN yc_u64 __yc_security_config(void)
{
    return security_config;
}

YC_EXPORT void YC_FN(__libplatform_init)(void *future_use, const char **envp, const char **apple, const void *vars)
{
    (void)future_use;
    if (apple) {
        yc_u64 v;
        if (parse_hex(YC_FN(_simple_getenv)(apple, "security_config"), &v))
            security_config = v;
        for (const char **a = apple; *a; a++) {
            char *str = (char *)*a;
            if (str[0] == 'p' && str[1] == 'f' && str[2] == 'z' && str[3] == '=') {
                YC_FN(_platform_bzero)(str, __yc_strlen(str));
                break;
            }
        }
    }
    __yc_simple_asl_init(envp, vars);
    YC_KFN(__libkernel_platform_init)(&string_functions);
}
