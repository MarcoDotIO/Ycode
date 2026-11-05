// llvm_libc.cpp - libSystem's math library and decimal-to-binary
// conversions, taken from LLVM's libc (Apache-2.0 WITH LLVM-exception;
// specs/macos/libsystem.md §13). LLVM libc implements each function in its
// own namespace (LIBC_NAMESPACE, set by build.sh); this file gives them
// their C names. Darwin's libm does not set errno (math_errhandling is
// MATH_ERREXCEPT), so build.sh compiles LLVM libc with LIBC_MATH_NO_ERRNO.
//
// The few double-precision functions LLVM libc does not have yet (the
// hyperbolic functions, erf, the gamma functions) are written here from
// their textbook identities; they are accurate to a few ulps, not
// correctly rounded.

#include "src/math/acos.h"
#include "src/math/acosf.h"
#include "src/math/acoshf.h"
#include "src/math/asin.h"
#include "src/math/asinf.h"
#include "src/math/asinhf.h"
#include "src/math/atan.h"
#include "src/math/atan2.h"
#include "src/math/atan2f.h"
#include "src/math/atanf.h"
#include "src/math/atanhf.h"
#include "src/math/cbrt.h"
#include "src/math/cbrtf.h"
#include "src/math/ceil.h"
#include "src/math/ceilf.h"
#include "src/math/copysign.h"
#include "src/math/copysignf.h"
#include "src/math/cos.h"
#include "src/math/cosf.h"
#include "src/math/coshf.h"
#include "src/math/erff.h"
#include "src/math/exp.h"
#include "src/math/exp10.h"
#include "src/math/exp10f.h"
#include "src/math/exp2.h"
#include "src/math/exp2f.h"
#include "src/math/expf.h"
#include "src/math/expm1.h"
#include "src/math/expm1f.h"
#include "src/math/fabs.h"
#include "src/math/fabsf.h"
#include "src/math/fdim.h"
#include "src/math/fdimf.h"
#include "src/math/floor.h"
#include "src/math/floorf.h"
#include "src/math/fma.h"
#include "src/math/fmaf.h"
#include "src/math/fmax.h"
#include "src/math/fmaxf.h"
#include "src/math/fmin.h"
#include "src/math/fminf.h"
#include "src/math/fmod.h"
#include "src/math/fmodf.h"
#include "src/math/frexp.h"
#include "src/math/frexpf.h"
#include "src/math/hypot.h"
#include "src/math/hypotf.h"
#include "src/math/ilogb.h"
#include "src/math/ilogbf.h"
#include "src/math/ldexp.h"
#include "src/math/ldexpf.h"
#include "src/math/llrint.h"
#include "src/math/llrintf.h"
#include "src/math/llround.h"
#include "src/math/llroundf.h"
#include "src/math/log.h"
#include "src/math/log10.h"
#include "src/math/log10f.h"
#include "src/math/log1p.h"
#include "src/math/log1pf.h"
#include "src/math/log2.h"
#include "src/math/log2f.h"
#include "src/math/logb.h"
#include "src/math/logbf.h"
#include "src/math/logf.h"
#include "src/math/lrint.h"
#include "src/math/lrintf.h"
#include "src/math/lround.h"
#include "src/math/lroundf.h"
#include "src/math/modf.h"
#include "src/math/nan.h"
#include "src/math/nanf.h"
#include "src/math/modff.h"
#include "src/math/nearbyint.h"
#include "src/math/nearbyintf.h"
#include "src/math/nextafter.h"
#include "src/math/nextafterf.h"
#include "src/math/pow.h"
#include "src/math/powf.h"
#include "src/math/remainder.h"
#include "src/math/remainderf.h"
#include "src/math/remquo.h"
#include "src/math/remquof.h"
#include "src/math/rint.h"
#include "src/math/rintf.h"
#include "src/math/round.h"
#include "src/math/roundf.h"
#include "src/math/scalbln.h"
#include "src/math/scalblnf.h"
#include "src/math/scalbn.h"
#include "src/math/scalbnf.h"
#include "src/math/sin.h"
#include "src/math/sincos.h"
#include "src/math/sincosf.h"
#include "src/math/sinf.h"
#include "src/math/sinhf.h"
#include "src/math/sqrt.h"
#include "src/math/sqrtf.h"
#include "src/math/tan.h"
#include "src/math/tanf.h"
#include "src/math/tanhf.h"
#include "src/math/trunc.h"
#include "src/math/truncf.h"
#include "src/stdlib/strtod.h"
#include "src/stdlib/strtof.h"
#include "src/stdlib/strtold.h"

#define L LIBC_NAMESPACE

extern "C" int *__error(void);
extern "C" __attribute__((visibility("default"))) int *__llvm_libc_errno(void) noexcept { return __error(); }

#define EXPORT extern "C" __attribute__((visibility("default")))

#define F1(name) \
    EXPORT double name(double x) { return L::name(x); } \
    EXPORT float name##f(float x) { return L::name##f(x); }
#define F2(name) \
    EXPORT double name(double x, double y) { return L::name(x, y); } \
    EXPORT float name##f(float x, float y) { return L::name##f(x, y); }

F1(acos) F1(asin) F1(atan) F1(cos) F1(sin) F1(tan) F1(exp) F1(exp2) F1(exp10) F1(expm1) F1(log) F1(log10)
F1(log1p) F1(log2) F1(logb) F1(cbrt) F1(sqrt) F1(fabs) F1(floor) F1(ceil) F1(round) F1(trunc) F1(rint)
F1(nearbyint)
F2(atan2) F2(pow) F2(hypot) F2(fmod) F2(remainder) F2(copysign) F2(fmin) F2(fmax) F2(fdim) F2(nextafter)

EXPORT float acoshf(float x) { return L::acoshf(x); }
EXPORT float asinhf(float x) { return L::asinhf(x); }
EXPORT float atanhf(float x) { return L::atanhf(x); }
EXPORT float coshf(float x) { return L::coshf(x); }
EXPORT float sinhf(float x) { return L::sinhf(x); }
EXPORT float tanhf(float x) { return L::tanhf(x); }
EXPORT float erff(float x) { return L::erff(x); }
EXPORT double fma(double x, double y, double z) { return L::fma(x, y, z); }
EXPORT float fmaf(float x, float y, float z) { return L::fmaf(x, y, z); }
EXPORT double frexp(double x, int *e) { return L::frexp(x, e); }
EXPORT float frexpf(float x, int *e) { return L::frexpf(x, e); }
EXPORT double ldexp(double x, int e) { return L::ldexp(x, e); }
EXPORT float ldexpf(float x, int e) { return L::ldexpf(x, e); }
EXPORT double scalbn(double x, int e) { return L::scalbn(x, e); }
EXPORT float scalbnf(float x, int e) { return L::scalbnf(x, e); }
EXPORT double scalbln(double x, long e) { return L::scalbln(x, e); }
EXPORT float scalblnf(float x, long e) { return L::scalblnf(x, e); }
EXPORT double modf(double x, double *i) { return L::modf(x, i); }
EXPORT float modff(float x, float *i) { return L::modff(x, i); }
EXPORT double remquo(double x, double y, int *q) { return L::remquo(x, y, q); }
EXPORT float remquof(float x, float y, int *q) { return L::remquof(x, y, q); }
EXPORT int ilogb(double x) { return L::ilogb(x); }
EXPORT int ilogbf(float x) { return L::ilogbf(x); }
EXPORT long lround(double x) { return L::lround(x); }
EXPORT long lroundf(float x) { return L::lroundf(x); }
EXPORT long long llround(double x) { return L::llround(x); }
EXPORT long long llroundf(float x) { return L::llroundf(x); }
EXPORT long lrint(double x) { return L::lrint(x); }
EXPORT long lrintf(float x) { return L::lrintf(x); }
EXPORT long long llrint(double x) { return L::llrint(x); }
EXPORT long long llrintf(float x) { return L::llrintf(x); }
EXPORT void sincos(double x, double *s, double *c) { L::sincos(x, s, c); }
EXPORT void sincosf(float x, float *s, float *c) { L::sincosf(x, s, c); }

// long double is double on arm64 Darwin.
EXPORT long double fabsl(long double x) { return L::fabs((double)x); }
EXPORT long double floorl(long double x) { return L::floor((double)x); }
EXPORT long double ceill(long double x) { return L::ceil((double)x); }
EXPORT long double sqrtl(long double x) { return L::sqrt((double)x); }
EXPORT long double powl(long double x, long double y) { return L::pow((double)x, (double)y); }
EXPORT long double logl(long double x) { return L::log((double)x); }
EXPORT long double expl(long double x) { return L::exp((double)x); }
EXPORT long double fmodl(long double x, long double y) { return L::fmod((double)x, (double)y); }
EXPORT long double roundl(long double x) { return L::round((double)x); }
EXPORT long double truncl(long double x) { return L::trunc((double)x); }
EXPORT long double ldexpl(long double x, int e) { return L::ldexp((double)x, e); }
EXPORT long double frexpl(long double x, int *e) { return L::frexp((double)x, e); }

// The Darwin entry points clang emits for a sin/cos pair and for exp10:
// the two results come back in d0/d1 (s0/s1).
struct ycl_sincos {
    double s, c;
};
struct ycl_sincosf {
    float s, c;
};
EXPORT ycl_sincos __sincos_stret(double x) {
    ycl_sincos r;
    L::sincos(x, &r.s, &r.c);
    return r;
}
EXPORT ycl_sincosf __sincosf_stret(float x) {
    ycl_sincosf r;
    L::sincosf(x, &r.s, &r.c);
    return r;
}
EXPORT ycl_sincos __sincospi_stret(double x) {
    ycl_sincos r;
    L::sincos(x * 3.141592653589793238462643383279502884, &r.s, &r.c);
    return r;
}
EXPORT double __exp10(double x) { return L::exp10(x); }
EXPORT float __exp10f(float x) { return L::exp10f(x); }

// --- double-precision functions LLVM libc does not provide yet ---

EXPORT double sinh(double x) {
    double ax = L::fabs(x);
    if (ax < 22.0) {
        double t = L::expm1(ax);
        double r = ax < 1.0 ? 0.5 * (2.0 * t - t * t / (t + 1.0)) : 0.5 * (t + t / (t + 1.0));
        return L::copysign(r, x);
    }
    return L::copysign(L::exp(ax - 0.6931471805599453), x);
}

EXPORT double cosh(double x) {
    double ax = L::fabs(x);
    if (ax < 22.0) {
        double t = L::exp(ax);
        return 0.5 * (t + 1.0 / t);
    }
    return L::exp(ax - 0.6931471805599453);
}

EXPORT double tanh(double x) {
    double ax = L::fabs(x);
    if (ax > 22.0) return L::copysign(1.0, x);
    double t = L::expm1(2.0 * ax);
    return L::copysign(t / (t + 2.0), x);
}

EXPORT double asinh(double x) {
    double ax = L::fabs(x);
    double r = ax > 1e8 ? L::log(ax) + 0.6931471805599453 : L::log1p(ax + ax * ax / (1.0 + L::sqrt(1.0 + ax * ax)));
    return L::copysign(r, x);
}

EXPORT double acosh(double x) {
    if (x > 1e8) return L::log(x) + 0.6931471805599453;
    double t = x - 1.0;
    return L::log1p(t + L::sqrt(2.0 * t + t * t));
}

EXPORT double atanh(double x) { return 0.5 * L::log1p(2.0 * x / (1.0 - x)); }

// erf: the Maclaurin series near zero, else 1 - erfc from erfc's
// continued fraction.
EXPORT double erf(double x) {
    double ax = L::fabs(x);
    if (ax < 0.5) {
        double x2 = x * x, term = x, sum = x;
        for (int n = 1; n < 30; n++) {
            term *= -x2 / n;
            double add = term / (2 * n + 1);
            sum += add;
            if (L::fabs(add) < 1e-17 * L::fabs(sum)) break;
        }
        return 1.1283791670955126 * sum;
    }
    if (ax > 6.0) return L::copysign(1.0, x);
    // Continued fraction for erfc, then 1 - erfc.
    double t = 0.0;
    for (int n = 60; n >= 1; n--) t = (n / 2.0) / (ax + t);
    double erfc_ax = L::exp(-ax * ax) / (ax + t) * 0.5641895835477563;
    return L::copysign(1.0 - erfc_ax, x);
}

EXPORT double erfc(double x) {
    if (x < 0.5) return 1.0 - erf(x);
    if (x > 27.0) return 0.0;
    double t = 0.0;
    for (int n = 60; n >= 1; n--) t = (n / 2.0) / (x + t);
    return L::exp(-x * x) / (x + t) * 0.5641895835477563;
}

EXPORT float erfcf(float x) { return (float)erfc(x); }

// Lanczos approximation (g = 7, n = 9).
static double lanczos_sum(double z) {
    static const double c[9] = {0.99999999999980993,  676.5203681218851,     -1259.1392167224028,
                                771.32342877765313,   -176.61502916214059,   12.507343278686905,
                                -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7};
    double a = c[0];
    for (int i = 1; i < 9; i++) a += c[i] / (z + i);
    return a;
}

EXPORT double lgamma(double x) {
    if (x < 0.5) return L::log(3.141592653589793 / L::fabs(L::sin(3.141592653589793 * x))) - lgamma(1.0 - x);
    double z = x - 1.0, t = z + 7.5;
    return 0.9189385332046727 + (z + 0.5) * L::log(t) - t + L::log(lanczos_sum(z));
}

EXPORT double tgamma(double x) {
    if (x < 0.5) return 3.141592653589793 / (L::sin(3.141592653589793 * x) * tgamma(1.0 - x));
    double z = x - 1.0, t = z + 7.5;
    return 2.5066282746310002 * L::pow(t, z + 0.5) * L::exp(-t) * lanczos_sum(z);
}

EXPORT float lgammaf(float x) { return (float)lgamma(x); }

// The reentrant forms also report the sign of Gamma(x).
static int gamma_sign(double x) {
    if (x > 0.0) return 1;
    double f = L::floor(x);
    if (f == x) return 1;  // a pole
    return ((long long)f & 1) ? -1 : 1;
}
EXPORT double lgamma_r(double x, int *sign) {
    if (sign) *sign = gamma_sign(x);
    return lgamma(x);
}
EXPORT float lgammaf_r(float x, int *sign) {
    if (sign) *sign = gamma_sign(x);
    return (float)lgamma(x);
}

EXPORT double nan(const char *tag) { return L::nan(tag); }
EXPORT float nanf(const char *tag) { return L::nanf(tag); }
EXPORT long double nanl(const char *tag) { return L::nan(tag); }

// --- Bessel functions of the first and second kind (<math.h> j0 ... yn):
//     power series below |x| = 8, Hankel's asymptotic expansion above,
//     recurrences in the order. Accurate to about 1e-10, not correctly
//     rounded. ---

static const double kPi = 3.141592653589793238462643383279502884;
static const double kEulerGamma = 0.577215664901532860606512090082402431;

// J_n(x) by its power series (n = 0 or 1, |x| < 8).
static double bessel_j_series(int n, double x) {
    double q = -0.25 * x * x, term = n ? 0.5 * x : 1.0, sum = term;
    for (int k = 1; k < 60; k++) {
        term *= q / (k * (double)(k + n));
        sum += term;
        if (L::fabs(term) < 1e-17 * L::fabs(sum)) break;
    }
    return sum;
}

// Hankel's asymptotic P and Q for order n (0 or 1), |x| >= 8.
static void hankel_pq(int n, double x, double *p, double *q) {
    double mu = 4.0 * n * n, z = 8.0 * x, t = 1.0, ps = 1.0, qs = 0.0;
    for (int k = 1; k < 30; k++) {
        double a = (2 * k - 1), before = L::fabs(t);
        t *= (mu - a * a) / (k * z);
        if (L::fabs(t) > before) break;  // the asymptotic series started to diverge
        if (k & 1) {
            qs += (k & 2) ? -t : t;
        } else {
            ps += (k & 2) ? -t : t;
        }
        if (L::fabs(t) < 1e-17) break;
    }
    *p = ps;
    *q = qs;
}

static double bessel_j_large(int n, double x) {
    double p, q;
    hankel_pq(n, x, &p, &q);
    double chi = x - (0.5 * n + 0.25) * kPi;
    return L::sqrt(2.0 / (kPi * x)) * (p * L::cos(chi) - q * L::sin(chi));
}

static double bessel_y_large(int n, double x) {
    double p, q;
    hankel_pq(n, x, &p, &q);
    double chi = x - (0.5 * n + 0.25) * kPi;
    return L::sqrt(2.0 / (kPi * x)) * (p * L::sin(chi) + q * L::cos(chi));
}

EXPORT double j0(double x) {
    double ax = L::fabs(x);
    return ax < 8.0 ? bessel_j_series(0, ax) : bessel_j_large(0, ax);
}

EXPORT double j1(double x) {
    double ax = L::fabs(x);
    double r = ax < 8.0 ? bessel_j_series(1, ax) : bessel_j_large(1, ax);
    return x < 0 ? -r : r;
}

EXPORT double y0(double x) {
    if (x < 0.0) return L::nan("");
    if (x == 0.0) return -__builtin_inf();
    if (x >= 8.0) return bessel_y_large(0, x);
    // Y0 = (2/pi)(ln(x/2) + gamma) J0 + (2/pi) sum (-1)^(k+1) H_k (x^2/4)^k / (k!)^2
    double q = 0.25 * x * x, term = 1.0, h = 0.0, sum = 0.0;
    for (int k = 1; k < 60; k++) {
        term *= q / ((double)k * k);
        h += 1.0 / k;
        double add = ((k & 1) ? 1.0 : -1.0) * h * term;
        sum += add;
        if (L::fabs(add) < 1e-17 * L::fabs(sum)) break;
    }
    return (2.0 / kPi) * ((L::log(0.5 * x) + kEulerGamma) * j0(x) + sum);
}

EXPORT double y1(double x) {
    if (x < 0.0) return L::nan("");
    if (x == 0.0) return -__builtin_inf();
    if (x >= 8.0) return bessel_y_large(1, x);
    // Y1 = (2/pi)(ln(x/2) + gamma) J1 - 2/(pi x)
    //      - (1/pi) sum_k (-1)^k (H_k + H_{k+1} - 2 H_0 ...) form:
    // Y1 = (2/pi) ln(x/2) J1 - 2/(pi x)
    //      - (1/pi) sum_{k>=0} (-1)^k (psi(k+1) + psi(k+2)) (x/2)^(2k+1) / (k! (k+1)!)
    double half = 0.5 * x, q = half * half, term = half, sum = 0.0;
    double psi1 = -kEulerGamma, psi2 = 1.0 - kEulerGamma;  // psi(k+1), psi(k+2) at k = 0
    for (int k = 0; k < 60; k++) {
        if (k > 0) {
            term *= -q / ((double)k * (k + 1));
            psi1 += 1.0 / k;
            psi2 += 1.0 / (k + 1);
        }
        double add = (psi1 + psi2) * term;
        sum += add;
        if (k > 2 && L::fabs(add) < 1e-17 * L::fabs(sum)) break;
    }
    return (2.0 / kPi) * L::log(half) * j1(x) - 2.0 / (kPi * x) - sum / kPi;
}

EXPORT double jn(int n, double x) {
    if (n < 0) return (n & 1) ? -jn(-n, x) : jn(-n, x);
    if (n == 0) return j0(x);
    if (n == 1) return j1(x);
    if (x == 0.0) return 0.0;
    double ax = L::fabs(x), r;
    if (ax > n) {
        // Forward recurrence is stable above the order.
        double a = j0(ax), b = j1(ax);
        for (int k = 1; k < n; k++) {
            double c = (2.0 * k / ax) * b - a;
            a = b;
            b = c;
        }
        r = b;
    } else {
        // Miller's backward recurrence, normalized with J0.
        int start = 2 * ((n + (int)L::sqrt(40.0 * n)) / 2) + 2;
        double next = 0.0, cur = 1e-300, at_n = 0.0, sum = 0.0;
        for (int k = start; k > 0; k--) {
            double prev = (2.0 * k / ax) * cur - next;
            next = cur;
            cur = prev;
            if (L::fabs(cur) > 1e250) {
                cur *= 1e-250;
                next *= 1e-250;
                at_n *= 1e-250;
                sum *= 1e-250;
            }
            if (k - 1 == n) at_n = cur;
            if (((k - 1) & 1) == 0 && k - 1 > 0) sum += cur;
        }
        double norm = cur + 2.0 * sum;  // J0 + 2 (J2 + J4 + ...) = 1
        r = at_n / norm;
    }
    return (x < 0 && (n & 1)) ? -r : r;
}

EXPORT double yn(int n, double x) {
    if (n < 0) return (n & 1) ? -yn(-n, x) : yn(-n, x);
    if (n == 0) return y0(x);
    if (n == 1) return y1(x);
    if (x < 0.0) return L::nan("");
    if (x == 0.0) return -__builtin_inf();
    double a = y0(x), b = y1(x);
    for (int k = 1; k < n && !__builtin_isinf(b); k++) {
        double c = (2.0 * k / x) * b - a;
        a = b;
        b = c;
    }
    return b;
}

EXPORT float j0f(float x) { return (float)j0(x); }
EXPORT float j1f(float x) { return (float)j1(x); }
EXPORT float jnf(int n, float x) { return (float)jn(n, x); }
EXPORT float y0f(float x) { return (float)y0(x); }
EXPORT float y1f(float x) { return (float)y1(x); }
EXPORT float ynf(int n, float x) { return (float)yn(n, x); }
EXPORT float tgammaf(float x) { return (float)tgamma(x); }

// --- decimal and hexadecimal strings to floating point ---

EXPORT double strtod(const char *s, char **end) { return L::strtod(s, end); }
EXPORT float strtof(const char *s, char **end) { return L::strtof(s, end); }
EXPORT long double strtold(const char *s, char **end) { return L::strtold(s, end); }
EXPORT double atof(const char *s) { return L::strtod(s, nullptr); }
// The C locale is the only one Ycode's libSystem has (locale.c).
EXPORT double strtod_l(const char *s, char **end, void *) { return L::strtod(s, end); }
EXPORT float strtof_l(const char *s, char **end, void *) { return L::strtof(s, end); }
EXPORT long double strtold_l(const char *s, char **end, void *) { return L::strtold(s, end); }
