// time.c - calendar time for Ycode's libSystem (specs/macos/libsystem.md
// §12). Clean-room Ycode code from the C standard and POSIX descriptions
// of gmtime, localtime, mktime, strftime and tzset; struct tm is the public
// Darwin layout (nine ints, then tm_gmtoff and tm_zone).
//
// Time zones: Ycode's libSystem knows UTC, fixed offsets written as POSIX
// TZ strings without rules ("UTC", "GMT", "UTC0", "EST5", "<+03>-3", ...),
// and nothing else; any other zone is treated as UTC. Foundation computes
// its own time zones (FoundationInternationalization, ICU).
#include "ycl.h"

struct tm {
    int tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday, tm_isdst;
    long tm_gmtoff;
    char *tm_zone;
};

char *getenv(const char *);

YCL_EXPORT char *tzname[2] = {"UTC", "UTC"};
YCL_EXPORT long timezone;
YCL_EXPORT int daylight;

static char zone_name[16] = "UTC";
static long zone_offset;  // seconds east of UTC
static os_unfair_lock tz_lock;

// Parses "NAME[+-]hh[:mm[:ss]]" (POSIX: the offset is west-positive).
static void parse_tz(const char *tz) {
    zone_offset = 0;
    strlcpy(zone_name, "UTC", sizeof zone_name);
    if (!tz || !*tz || *tz == ':') return;
    const char *p = tz;
    char name[16];
    size_t n = 0;
    if (*p == '<') {
        p++;
        while (*p && *p != '>' && n < sizeof name - 1) name[n++] = *p++;
        if (*p == '>') p++;
    } else {
        while (*p && ((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z')) && n < sizeof name - 1) name[n++] = *p++;
    }
    name[n] = 0;
    if (n < 3) return;
    int sign = 1;
    if (*p == '+' || *p == '-') sign = *p++ == '-' ? -1 : 1;
    if (*p < '0' || *p > '9') {
        if (!*p) strlcpy(zone_name, name, sizeof zone_name);  // a name alone: UTC with that name
        return;
    }
    long h = 0, m = 0, s = 0;
    while (*p >= '0' && *p <= '9') h = h * 10 + (*p++ - '0');
    if (*p == ':') {
        p++;
        while (*p >= '0' && *p <= '9') m = m * 10 + (*p++ - '0');
        if (*p == ':') {
            p++;
            while (*p >= '0' && *p <= '9') s = s * 10 + (*p++ - '0');
        }
    }
    if (*p) return;  // daylight-saving rules: not supported, stay UTC
    zone_offset = -sign * (h * 3600 + m * 60 + s);
    strlcpy(zone_name, name, sizeof zone_name);
}

YCL_EXPORT void tzset(void) {
    os_unfair_lock_lock(&tz_lock);
    parse_tz(getenv("TZ"));
    tzname[0] = tzname[1] = zone_name;
    timezone = -zone_offset;
    daylight = 0;
    os_unfair_lock_unlock(&tz_lock);
}

// --- conversions between seconds and civil dates (proleptic Gregorian) ---

static long long days_from_civil(long long y, unsigned m, unsigned d) {
    y -= m <= 2;
    long long era = (y >= 0 ? y : y - 399) / 400;
    unsigned yoe = (unsigned)(y - era * 400);
    unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + (long long)doe - 719468;
}

static void civil_from_days(long long z, long long *y, unsigned *m, unsigned *d) {
    z += 719468;
    long long era = (z >= 0 ? z : z - 146096) / 146097;
    unsigned doe = (unsigned)(z - era * 146097);
    unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    unsigned mp = (5 * doy + 2) / 153;
    *d = doy - (153 * mp + 2) / 5 + 1;
    *m = mp < 10 ? mp + 3 : mp - 9;
    *y = (long long)yoe + era * 400 + (*m <= 2);
}

static int is_leap(long long y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0; }

static struct tm *fill(long long t, long offset, const char *zone, struct tm *out) {
    long long local = t + offset;
    long long days = local >= 0 ? local / 86400 : -((-local + 86399) / 86400);
    long long secs = local - days * 86400;
    long long y;
    unsigned m, d;
    civil_from_days(days, &y, &m, &d);
    if (y - 1900 > 0x7FFFFFFF || y - 1900 < -0x7FFFFFFF - 1) {
        ycl_errno = YCL_EOVERFLOW;
        return 0;
    }
    out->tm_year = (int)(y - 1900);
    out->tm_mon = (int)m - 1;
    out->tm_mday = (int)d;
    out->tm_hour = (int)(secs / 3600);
    out->tm_min = (int)(secs / 60 % 60);
    out->tm_sec = (int)(secs % 60);
    out->tm_wday = (int)((days % 7 + 11) % 7);  // 1970-01-01 was a Thursday
    out->tm_yday = (int)(days - days_from_civil(y, 1, 1));
    out->tm_isdst = 0;
    out->tm_gmtoff = offset;
    out->tm_zone = (char *)zone;
    return out;
}

YCL_EXPORT struct tm *gmtime_r(const long *t, struct tm *out) { return fill(*t, 0, "UTC", out); }

YCL_EXPORT struct tm *localtime_r(const long *t, struct tm *out) {
    tzset();
    return fill(*t, zone_offset, zone_name, out);
}

static struct tm shared_tm;
YCL_EXPORT struct tm *gmtime(const long *t) { return gmtime_r(t, &shared_tm); }
YCL_EXPORT struct tm *localtime(const long *t) { return localtime_r(t, &shared_tm); }

static long long seconds_of(struct tm *tm) {
    // Normalize month first, then let days carry everything else.
    long long y = (long long)tm->tm_year + 1900, mon = tm->tm_mon;
    y += mon >= 0 ? mon / 12 : -((-mon + 11) / 12);
    mon = ((mon % 12) + 12) % 12;
    long long days = days_from_civil(y, (unsigned)mon + 1, 1) + tm->tm_mday - 1;
    return days * 86400 + (long long)tm->tm_hour * 3600 + (long long)tm->tm_min * 60 + tm->tm_sec;
}

YCL_EXPORT long timegm(struct tm *tm) {
    long long t = seconds_of(tm);
    fill(t, 0, "UTC", tm);
    return (long)t;
}

YCL_EXPORT long mktime(struct tm *tm) {
    tzset();
    long long t = seconds_of(tm) - zone_offset;
    fill(t, zone_offset, zone_name, tm);
    return (long)t;
}

YCL_EXPORT double difftime(long a, long b) { return (double)a - (double)b; }

// --- formatting ---

static const char *const day_names[7] = {"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"};
static const char *const month_names[12] = {"January", "February", "March",     "April",   "May",      "June",
                                            "July",    "August",   "September", "October", "November", "December"};

struct out {
    char *s;
    size_t max, n;
    int overflow;
};

static void put(struct out *o, const char *s, size_t len) {
    for (size_t i = 0; i < len; i++) {
        if (o->n + 1 >= o->max) {
            o->overflow = 1;
            return;
        }
        o->s[o->n++] = s[i];
    }
}

static void puts_(struct out *o, const char *s) { put(o, s, strlen(s)); }

static void num(struct out *o, long long v, int width, char pad) {
    char buf[24];
    int n = 0, neg = v < 0;
    unsigned long long u = neg ? 0 - (unsigned long long)v : (unsigned long long)v;
    do buf[n++] = (char)('0' + u % 10); while ((u /= 10) && n < 22);
    while (pad && n < width) buf[n++] = pad;
    if (neg) put(o, "-", 1);
    for (int i = n - 1; i >= 0; i--) put(o, &buf[i], 1);
}

// The ISO 8601 week-based year and week number.
static void iso_week(const struct tm *tm, long long *year, int *week) {
    long long y = (long long)tm->tm_year + 1900;
    int wday = (tm->tm_wday + 6) % 7;  // Monday 0
    int w = (tm->tm_yday - wday + 10) / 7;
    if (w < 1) {
        y--;
        int days_prev = is_leap(y) ? 366 : 365;
        w = (tm->tm_yday + days_prev - wday + 10) / 7;
    } else if (w == 53) {
        int days_year = is_leap(y) ? 366 : 365;
        if (tm->tm_yday - wday + 3 >= days_year) {
            w = 1;
            y++;
        }
    }
    *year = y;
    *week = w;
}

static void format(struct out *o, const char *fmt, const struct tm *tm) {
    for (; *fmt && !o->overflow; fmt++) {
        if (*fmt != '%') {
            put(o, fmt, 1);
            continue;
        }
        fmt++;
        while (*fmt == 'E' || *fmt == 'O') fmt++;
        long long year = (long long)tm->tm_year + 1900;
        switch (*fmt) {
        case 'a': put(o, day_names[tm->tm_wday % 7], 3); break;
        case 'A': puts_(o, day_names[tm->tm_wday % 7]); break;
        case 'b':
        case 'h': put(o, month_names[tm->tm_mon % 12], 3); break;
        case 'B': puts_(o, month_names[tm->tm_mon % 12]); break;
        case 'c': format(o, "%a %b %e %H:%M:%S %Y", tm); break;
        case 'C': num(o, year / 100, 2, '0'); break;
        case 'd': num(o, tm->tm_mday, 2, '0'); break;
        case 'D': format(o, "%m/%d/%y", tm); break;
        case 'e': num(o, tm->tm_mday, 2, ' '); break;
        case 'F': format(o, "%Y-%m-%d", tm); break;
        case 'g': {
            long long y;
            int w;
            iso_week(tm, &y, &w);
            num(o, y % 100, 2, '0');
            break;
        }
        case 'G': {
            long long y;
            int w;
            iso_week(tm, &y, &w);
            num(o, y, 1, 0);
            break;
        }
        case 'H': num(o, tm->tm_hour, 2, '0'); break;
        case 'I': num(o, tm->tm_hour % 12 ? tm->tm_hour % 12 : 12, 2, '0'); break;
        case 'j': num(o, tm->tm_yday + 1, 3, '0'); break;
        case 'k': num(o, tm->tm_hour, 2, ' '); break;
        case 'l': num(o, tm->tm_hour % 12 ? tm->tm_hour % 12 : 12, 2, ' '); break;
        case 'm': num(o, tm->tm_mon + 1, 2, '0'); break;
        case 'M': num(o, tm->tm_min, 2, '0'); break;
        case 'n': put(o, "\n", 1); break;
        case 'p': puts_(o, tm->tm_hour < 12 ? "AM" : "PM"); break;
        case 'r': format(o, "%I:%M:%S %p", tm); break;
        case 'R': format(o, "%H:%M", tm); break;
        case 's': {
            struct tm copy = *tm;
            num(o, seconds_of(&copy) - tm->tm_gmtoff, 1, 0);
            break;
        }
        case 'S': num(o, tm->tm_sec, 2, '0'); break;
        case 't': put(o, "\t", 1); break;
        case 'T': format(o, "%H:%M:%S", tm); break;
        case 'u': num(o, tm->tm_wday ? tm->tm_wday : 7, 1, 0); break;
        case 'U': num(o, (tm->tm_yday + 7 - tm->tm_wday) / 7, 2, '0'); break;
        case 'V': {
            long long y;
            int w;
            iso_week(tm, &y, &w);
            num(o, w, 2, '0');
            break;
        }
        case 'w': num(o, tm->tm_wday, 1, 0); break;
        case 'W': num(o, (tm->tm_yday + 7 - (tm->tm_wday + 6) % 7) / 7, 2, '0'); break;
        case 'x': format(o, "%m/%d/%y", tm); break;
        case 'X': format(o, "%H:%M:%S", tm); break;
        case 'y': num(o, ((year % 100) + 100) % 100, 2, '0'); break;
        case 'Y': num(o, year, 1, 0); break;
        case 'z': {
            long off = tm->tm_gmtoff;
            put(o, off < 0 ? "-" : "+", 1);
            if (off < 0) off = -off;
            num(o, off / 3600 * 100 + off / 60 % 60, 4, '0');
            break;
        }
        case 'Z': puts_(o, tm->tm_zone ? tm->tm_zone : "UTC"); break;
        case '%': put(o, "%", 1); break;
        case 0: return;
        default:
            put(o, "%", 1);
            put(o, fmt, 1);
            break;
        }
    }
}

YCL_EXPORT size_t strftime(char *s, size_t max, const char *fmt, const struct tm *tm) {
    struct out o = {s, max, 0, 0};
    if (!max) return 0;
    format(&o, fmt, tm);
    if (o.overflow) {
        s[0] = 0;
        return 0;
    }
    s[o.n] = 0;
    return o.n;
}

YCL_EXPORT size_t strftime_l(char *s, size_t max, const char *fmt, const struct tm *tm, void *locale) {
    (void)locale;
    return strftime(s, max, fmt, tm);
}

YCL_EXPORT char *asctime_r(const struct tm *tm, char *buf) {
    strftime(buf, 26, "%a %b %e %H:%M:%S %Y\n", tm);
    return buf;
}

YCL_EXPORT char *ctime_r(const long *t, char *buf) {
    struct tm tm;
    return localtime_r(t, &tm) ? asctime_r(&tm, buf) : 0;
}

static char shared_text[32];
YCL_EXPORT char *asctime(const struct tm *tm) { return asctime_r(tm, shared_text); }
YCL_EXPORT char *ctime(const long *t) { return ctime_r(t, shared_text); }

// --- clocks ---

int clock_gettime(int, struct ycl_timespec *);

YCL_EXPORT int clock_getres(int clock, struct ycl_timespec *res) {
    (void)clock;
    if (res) {
        res->tv_sec = 0;
        res->tv_nsec = 1000;  // microsecond resolution, as Darwin reports
    }
    return 0;
}

YCL_EXPORT uint64_t clock_gettime_nsec_np(int clock) {
    struct ycl_timespec t;
    if (clock_gettime(clock, &t)) return 0;
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}
