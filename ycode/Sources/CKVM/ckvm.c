// CKVM implementation. See include/ckvm.h. Written against the public Linux
// KVM API documentation and the kernel's uapi headers.
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif
#include "ckvm.h"

// The bindings use the arm64 KVM uapi (core-register IDs, vCPU init), so
// they are compiled only on arm64 Linux. Elsewhere only ckvm_available exists.
#if !(defined(__linux__) && defined(__aarch64__))

int ckvm_available(void) { return 0; }

#else

#include <errno.h>
#include <pthread.h>
#include <sys/auxv.h>
#include <asm/hwcap.h>
#include <fcntl.h>
#include <signal.h>
#include <stddef.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>
#include <linux/kvm.h>
#include <dirent.h>
#include <stdlib.h>
#include <stdio.h>
#include <linux/perf_event.h>
#include <linux/hw_breakpoint.h>

int ckvm_available(void) { return 1; }

static int result_or_errno(int result) { return result < 0 ? -errno : result; }

int ckvm_open(void) { return result_or_errno(open("/dev/kvm", O_RDWR | O_CLOEXEC)); }

int ckvm_close(int fd) { return result_or_errno(close(fd)); }

int ckvm_get_api_version(int kvm_fd) {
    return result_or_errno(ioctl(kvm_fd, KVM_GET_API_VERSION, 0));
}

int ckvm_check_extension(int kvm_fd, long extension) {
    return result_or_errno(ioctl(kvm_fd, KVM_CHECK_EXTENSION, extension));
}

int ckvm_create_vm(int kvm_fd, unsigned long machine_type) {
    int fd;
    do {
        fd = ioctl(kvm_fd, KVM_CREATE_VM, machine_type);
    } while (fd < 0 && errno == EINTR);
    return result_or_errno(fd);
}

int ckvm_set_user_memory_region(int vm_fd, uint32_t slot, uint32_t flags,
                                uint64_t guest_phys_addr, uint64_t memory_size,
                                uint64_t userspace_addr) {
    struct kvm_userspace_memory_region region;
    memset(&region, 0, sizeof region);
    region.slot = slot;
    region.flags = flags;
    region.guest_phys_addr = guest_phys_addr;
    region.memory_size = memory_size;
    region.userspace_addr = userspace_addr;
    return result_or_errno(ioctl(vm_fd, KVM_SET_USER_MEMORY_REGION, &region));
}

void *ckvm_alloc_anonymous(size_t size) {
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    return p == MAP_FAILED ? NULL : p;
}

int ckvm_free_anonymous(void *address, size_t size) { return result_or_errno(munmap(address, size)); }

int ckvm_discard_anonymous(void *address, size_t size) {
    return result_or_errno(madvise(address, size, MADV_DONTNEED));
}

void *ckvm_map_file_private(int fd, uint64_t offset, size_t file_bytes, size_t total_size) {
    if (file_bytes > total_size || total_size == 0) {
        errno = EINVAL;
        return NULL;
    }
    void *base = mmap(NULL, total_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (base == MAP_FAILED) return NULL;
    if (file_bytes > 0) {
        void *p = mmap(base, file_bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_FIXED, fd, (off_t)offset);
        if (p == MAP_FAILED) {
            int saved = errno;
            munmap(base, total_size);
            errno = saved;
            return NULL;
        }
    }
    return base;
}

size_t ckvm_host_page_size(void) {
    long size = sysconf(_SC_PAGESIZE);
    return size > 0 ? (size_t)size : 4096;
}

int ckvm_create_vcpu(int vm_fd, unsigned long vcpu_id) {
    return result_or_errno(ioctl(vm_fd, KVM_CREATE_VCPU, vcpu_id));
}

int ckvm_get_vcpu_mmap_size(int kvm_fd) {
    return result_or_errno(ioctl(kvm_fd, KVM_GET_VCPU_MMAP_SIZE, 0));
}

void *ckvm_map_run(int vcpu_fd, size_t mmap_size) {
    void *p = mmap(NULL, mmap_size, PROT_READ | PROT_WRITE, MAP_SHARED, vcpu_fd, 0);
    return p == MAP_FAILED ? NULL : p;
}

int ckvm_arm_vcpu_init_preferred(int vm_fd, int vcpu_fd, uint32_t features0) {
    struct kvm_vcpu_init init;
    memset(&init, 0, sizeof init);
    if (ioctl(vm_fd, KVM_ARM_PREFERRED_TARGET, &init) < 0) return -errno;
    init.features[0] |= features0;
    return result_or_errno(ioctl(vcpu_fd, KVM_ARM_VCPU_INIT, &init));
}

int ckvm_get_one_reg_u64(int vcpu_fd, uint64_t reg_id, uint64_t *value) {
    struct kvm_one_reg reg;
    reg.id = reg_id;
    reg.addr = (uint64_t)(uintptr_t)value;
    return result_or_errno(ioctl(vcpu_fd, KVM_GET_ONE_REG, &reg));
}

int ckvm_set_one_reg_u64(int vcpu_fd, uint64_t reg_id, uint64_t value) {
    struct kvm_one_reg reg;
    reg.id = reg_id;
    reg.addr = (uint64_t)(uintptr_t)&value;
    return result_or_errno(ioctl(vcpu_fd, KVM_SET_ONE_REG, &reg));
}

// Diagnostics (`ckvm_debug_run_check`, YCODE_DEBUG_RUNCHECK=1): KVM_RUN
// issued directly with SP, x29, x30, x18 and a known NZCV recorded just
// before and after the system call, and the caller's stack frames (4 KiB
// above this function's frame record) snapshotted and compared, so a change
// in any of them across KVM_RUN aborts with both values.
int ckvm_debug_run_check = 0;
static _Thread_local uint64_t run_regs_before[5], run_regs_after[5];
static _Thread_local unsigned char run_snapshot[4096];
static _Thread_local uintptr_t run_stack_top;
static _Atomic unsigned long run_checks;

__attribute__((noinline)) static int run_checked(int vcpu_fd) {
    if (!run_stack_top) {
        pthread_attr_t attr;
        void *lo; size_t size;
        if (pthread_getattr_np(pthread_self(), &attr) == 0) {
            if (pthread_attr_getstack(&attr, &lo, &size) == 0) run_stack_top = (uintptr_t)lo + size;
            pthread_attr_destroy(&attr);
        }
        if (!run_stack_top) run_stack_top = 1;
    }
    uintptr_t from = (uintptr_t)__builtin_frame_address(0) + 16;
    size_t span = sizeof run_snapshot;
    if (run_stack_top > from && run_stack_top - from < span) span = run_stack_top - from;
    if (run_stack_top <= from) span = 0;
    memcpy(run_snapshot, (const void *)from, span);
    register long x0 __asm__("x0") = vcpu_fd;
    register long x1 __asm__("x1") = KVM_RUN;
    register long x2 __asm__("x2") = 0;
    register long x8 __asm__("x8") = __NR_ioctl;
    uint64_t *b = run_regs_before, *a = run_regs_after;
    __asm__ volatile(
        "mov x9, #0xa0000000\n"
        "msr nzcv, x9\n"
        "mov x9, sp\n str x9, [%[b], #0]\n str x29, [%[b], #8]\n str x30, [%[b], #16]\n str x18, [%[b], #24]\n"
        "mrs x9, nzcv\n str x9, [%[b], #32]\n"
        "svc #0\n"
        "mrs x9, nzcv\n str x9, [%[a], #32]\n"
        "mov x9, sp\n str x9, [%[a], #0]\n str x29, [%[a], #8]\n str x30, [%[a], #16]\n str x18, [%[a], #24]\n"
        : "+r"(x0)
        : "r"(x1), "r"(x2), "r"(x8), [b] "r"(b), [a] "r"(a)
        : "x9", "memory", "cc");
    long result = x0;
    static const char *names[5] = {"sp", "x29", "x30", "x18", "nzcv"};
    int bad = 0;
    char line[512];
    for (int i = 0; i < 5; i++) {
        if (run_regs_before[i] == run_regs_after[i]) continue;
        int n = snprintf(line, sizeof line, "RUNCHECK: %s changed across KVM_RUN: before 0x%llx after 0x%llx (result %ld, check %lu)\n",
                         names[i], (unsigned long long)run_regs_before[i], (unsigned long long)run_regs_after[i], result,
                         (unsigned long)run_checks);
        (void)!write(2, line, n);
        bad = 1;
    }
    if (memcmp(run_snapshot, (const void *)from, span) != 0) {
        for (size_t i = 0; i < span; i += 8) {
            uint64_t was, now;
            memcpy(&was, run_snapshot + i, 8);
            memcpy(&now, (const unsigned char *)from + i, 8);
            if (was == now) continue;
            int n = snprintf(line, sizeof line, "RUNCHECK: caller stack word %p (frame+0x%zx) changed across KVM_RUN: 0x%llx -> 0x%llx (result %ld)\n",
                             (void *)(from + i), i + 16, (unsigned long long)was, (unsigned long long)now, result);
            (void)!write(2, line, n);
        }
        bad = 1;
    }
    run_checks++;
    if (bad) abort();
    if (result < 0) { errno = (int)-result; return (int)result; }
    return (int)result;
}

int ckvm_run(int vcpu_fd) {
    if (ckvm_debug_run_check) return run_checked(vcpu_fd);
    return result_or_errno(ioctl(vcpu_fd, KVM_RUN, 0));
}

unsigned long ckvm_debug_run_checks(void) { return run_checks; }

static void run_check_summary(void) {
    char line[128];
    int n = snprintf(line, sizeof line, "RUNCHECK: %lu checked KVM_RUN calls, no change\n", (unsigned long)run_checks);
    (void)!write(2, line, n);
}

__attribute__((constructor)) static void run_check_init(void) {
    const char *e = getenv("YCODE_DEBUG_RUNCHECK");
    ckvm_debug_run_check = e && e[0] == '1';
    if (ckvm_debug_run_check) {
        atexit(run_check_summary);
        static const char note[] = "RUNCHECK: enabled\n";
        (void)!write(2, note, sizeof note - 1);
    }
}

// ---- Register IDs -------------------------------------------------------------

#define CKVM_CORE_ID(field) \
    (KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM_CORE | KVM_REG_ARM_CORE_REG(field))

uint64_t ckvm_reg_x(unsigned n) {
    // regs.regs[n] is n 64-bit words (2n 32-bit words) into struct kvm_regs.
    return CKVM_CORE_ID(regs.regs[0]) + 2u * (uint64_t)n;
}
uint64_t ckvm_reg_sp_el0(void) { return CKVM_CORE_ID(regs.sp); }
uint64_t ckvm_reg_pc(void) { return CKVM_CORE_ID(regs.pc); }
uint64_t ckvm_reg_pstate(void) { return CKVM_CORE_ID(regs.pstate); }
uint64_t ckvm_reg_sp_el1(void) { return CKVM_CORE_ID(sp_el1); }
uint64_t ckvm_reg_elr_el1(void) { return CKVM_CORE_ID(elr_el1); }
uint64_t ckvm_reg_spsr_el1(void) { return CKVM_CORE_ID(spsr[KVM_SPSR_EL1]); }

uint64_t ckvm_reg_sysreg(unsigned op0, unsigned op1, unsigned crn, unsigned crm, unsigned op2) {
    return KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM64_SYSREG |
           (((uint64_t)op0 << KVM_REG_ARM64_SYSREG_OP0_SHIFT) & KVM_REG_ARM64_SYSREG_OP0_MASK) |
           (((uint64_t)op1 << KVM_REG_ARM64_SYSREG_OP1_SHIFT) & KVM_REG_ARM64_SYSREG_OP1_MASK) |
           (((uint64_t)crn << KVM_REG_ARM64_SYSREG_CRN_SHIFT) & KVM_REG_ARM64_SYSREG_CRN_MASK) |
           (((uint64_t)crm << KVM_REG_ARM64_SYSREG_CRM_SHIFT) & KVM_REG_ARM64_SYSREG_CRM_MASK) |
           (((uint64_t)op2 << KVM_REG_ARM64_SYSREG_OP2_SHIFT) & KVM_REG_ARM64_SYSREG_OP2_MASK);
}

uint64_t ckvm_reg_timer_cnt(void) { return KVM_REG_ARM_TIMER_CNT; }
uint64_t ckvm_reg_timer_ctl(void) { return KVM_REG_ARM_TIMER_CTL; }

uint64_t ckvm_host_cntfrq(void) {
    uint64_t value;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(value));
    return value;
}

uint64_t ckvm_host_cntvct(void) {
    uint64_t value;
    __asm__ volatile("isb; mrs %0, cntvct_el0" : "=r"(value) : : "memory");
    return value;
}

// ---- struct kvm_run accessors ------------------------------------------------

#define RUN(p) ((const struct kvm_run *)(p))

uint32_t ckvm_run_exit_reason(const void *run) { return RUN(run)->exit_reason; }
void ckvm_run_set_immediate_exit(void *run, uint8_t value) { ((struct kvm_run *)run)->immediate_exit = value; }

uint64_t ckvm_run_mmio_phys_addr(const void *run) { return RUN(run)->mmio.phys_addr; }
uint32_t ckvm_run_mmio_len(const void *run) { return RUN(run)->mmio.len; }
uint8_t ckvm_run_mmio_is_write(const void *run) { return RUN(run)->mmio.is_write; }

// The 8 data bytes of an MMIO exit as one little-endian word, read with a
// single load (no memcpy call): the doorbell's frame address must arrive
// intact even where the C library's copy routines are unreliable (see
// hostcopy.c and docs/postmortem-kvm-sve.md).
uint64_t ckvm_run_mmio_data_u64(const void *run) {
    return __atomic_load_n((const uint64_t *)(const void *)RUN(run)->mmio.data, __ATOMIC_RELAXED);
}

void ckvm_run_mmio_get_data(const void *run, uint8_t *out, uint32_t len) {
    if (len > sizeof RUN(run)->mmio.data) len = sizeof RUN(run)->mmio.data;
    memcpy(out, RUN(run)->mmio.data, len);
}

void ckvm_run_mmio_set_data(void *run, const uint8_t *data, uint32_t len) {
    struct kvm_run *r = (struct kvm_run *)run;
    if (len > sizeof r->mmio.data) len = sizeof r->mmio.data;
    memset(r->mmio.data, 0, sizeof r->mmio.data);
    memcpy(r->mmio.data, data, len);
}

uint64_t ckvm_run_fail_entry_reason(const void *run) { return RUN(run)->fail_entry.hardware_entry_failure_reason; }
uint32_t ckvm_run_fail_entry_cpu(const void *run) { return RUN(run)->fail_entry.cpu; }

uint32_t ckvm_run_internal_suberror(const void *run) { return RUN(run)->internal.suberror; }
uint32_t ckvm_run_internal_ndata(const void *run) { return RUN(run)->internal.ndata; }
uint64_t ckvm_run_internal_data(const void *run, uint32_t index) {
    const struct kvm_run *r = RUN(run);
    size_t cap = sizeof r->internal.data / sizeof r->internal.data[0];
    return index < cap ? r->internal.data[index] : 0;
}

uint32_t ckvm_run_system_event_type(const void *run) { return RUN(run)->system_event.type; }
uint32_t ckvm_run_system_event_ndata(const void *run) { return RUN(run)->system_event.ndata; }
uint64_t ckvm_run_system_event_data(const void *run, uint32_t index) {
    const struct kvm_run *r = RUN(run);
    size_t cap = sizeof r->system_event.data / sizeof r->system_event.data[0];
    return index < cap ? r->system_event.data[index] : 0;
}

uint64_t ckvm_run_arm_nisv_esr_iss(const void *run) { return RUN(run)->arm_nisv.esr_iss; }
uint64_t ckvm_run_arm_nisv_fault_ipa(const void *run) { return RUN(run)->arm_nisv.fault_ipa; }

// ---- Kicking a vCPU thread and cache maintenance ------------------------------

static void kick_handler(int signo) { (void)signo; }

// Diagnostics (YCODE_DEBUG_SIGLOG=1): every kick delivered while the thread
// was running user code (the interrupted instruction does not follow an
// `svc`) is reported with the interrupted pc, sp, x29 and x30, and pc's
// offset from `ckvm_run` (to symbolize against the binary). The kernel puts
// a frame record {x29, x30} and the signal frame just below sp.
static int siglog_enabled;
static _Atomic unsigned long siglog_user, siglog_syscall;

static void kick_handler_logging(int signo, siginfo_t *info, void *context) {
    (void)info;
    ucontext_t *uc = context;
    uint64_t pc = uc->uc_mcontext.pc, sp = uc->uc_mcontext.sp;
    uint64_t fp = uc->uc_mcontext.regs[29], lr = uc->uc_mcontext.regs[30];
    if (pc >= 4 && *(const uint32_t *)(uintptr_t)(pc - 4) == 0xd4000001u) { siglog_syscall++; return; }
    unsigned long n = ++siglog_user;
    if (n > 2000) return;
    int saved = errno;
    char line[256];
    int len = snprintf(line, sizeof line, "SIGLOG: signal %d in user code: tid %ld pc 0x%llx (ckvm_run%+lld) sp 0x%llx x29 0x%llx x30 0x%llx (ckvm_run%+lld)\n",
                       signo, (long)syscall(SYS_gettid), (unsigned long long)pc, (long long)(pc - (uint64_t)(uintptr_t)&ckvm_run),
                       (unsigned long long)sp, (unsigned long long)fp, (unsigned long long)lr,
                       (long long)(lr - (uint64_t)(uintptr_t)&ckvm_run));
    (void)!write(2, line, len);
    errno = saved;
}

static void siglog_summary(void) {
    char line[160];
    int n = snprintf(line, sizeof line, "SIGLOG: %lu kicks in user code, %lu in system calls\n",
                     (unsigned long)siglog_user, (unsigned long)siglog_syscall);
    (void)!write(2, line, n);
}

int ckvm_kick_install(int signo) {
    struct sigaction action;
    memset(&action, 0, sizeof action);
    const char *e = getenv("YCODE_DEBUG_SIGLOG");
    siglog_enabled = e && e[0] == '1';
    if (siglog_enabled) {
        action.sa_sigaction = kick_handler_logging;
        action.sa_flags = SA_SIGINFO; // no SA_RESTART: KVM_RUN must return -EINTR
        atexit(siglog_summary);
    } else {
        action.sa_handler = kick_handler;
        action.sa_flags = 0; // no SA_RESTART: KVM_RUN must return -EINTR
    }
    sigemptyset(&action.sa_mask);
    return result_or_errno(sigaction(signo, &action, NULL));
}

int ckvm_kick_mask_outside_run(int vcpu_fd, int signo) {
    sigset_t blocked;
    sigemptyset(&blocked);
    sigaddset(&blocked, signo);
    int r = pthread_sigmask(SIG_BLOCK, &blocked, NULL);
    if (r != 0) return -r;
    sigset_t during;
    if (pthread_sigmask(SIG_BLOCK, NULL, &during) != 0) return -EINVAL;
    sigdelset(&during, signo);
    struct { struct kvm_signal_mask header; uint64_t bits; } mask;
    memset(&mask, 0, sizeof mask);
    mask.header.len = 8; // the kernel's sigset_t on arm64
    memcpy(&mask.bits, &during, 8);
    return result_or_errno(ioctl(vcpu_fd, KVM_SET_SIGNAL_MASK, &mask));
}

int ckvm_kick_thread(unsigned long thread, int signo) {
    int result = pthread_kill((pthread_t)thread, signo);
    return result == 0 ? 0 : -result;
}

void ckvm_clean_dcache_range(const void *address, size_t size) {
    if (size == 0) return;
    uint64_t ctr;
    __asm__ volatile("mrs %0, ctr_el0" : "=r"(ctr));
    uintptr_t line = (uintptr_t)4 << ((ctr >> 16) & 0xF); // DminLine: log2 of words
    uintptr_t start = (uintptr_t)address & ~(line - 1);
    uintptr_t end = (uintptr_t)address + size;
    for (uintptr_t p = start; p < end; p += line) {
        __asm__ volatile("dc civac, %0" : : "r"(p) : "memory");
    }
    __asm__ volatile("dsb sy" : : : "memory");
}

uint64_t ckvm_host_id_aa64mmfr2(void) {
    unsigned long hwcap = getauxval(AT_HWCAP);
    if (!(hwcap & HWCAP_CPUID)) return 0;
    uint64_t value;
    __asm__ volatile("mrs %0, ID_AA64MMFR2_EL1" : "=r"(value));
    return value;
}

// ---- Watchdog ---------------------------------------------------------------

#ifndef sigev_notify_thread_id
#define sigev_notify_thread_id _sigev_un._tid
#endif

static volatile sig_atomic_t watchdog_fired_flag = 0;
static int watchdog_timer_created = 0;
static timer_t watchdog_timer;

static void watchdog_handler(int signo) {
    (void)signo;
    watchdog_fired_flag = 1;
}

int ckvm_watchdog_arm(uint64_t milliseconds) {
    if (!watchdog_timer_created) {
        struct sigaction action;
        memset(&action, 0, sizeof action);
        action.sa_handler = watchdog_handler;
        sigemptyset(&action.sa_mask);
        action.sa_flags = 0; // no SA_RESTART: KVM_RUN must return -EINTR
        if (sigaction(SIGALRM, &action, NULL) < 0) return -errno;

        struct sigevent event;
        memset(&event, 0, sizeof event);
        event.sigev_notify = SIGEV_THREAD_ID;
        event.sigev_signo = SIGALRM;
        event.sigev_notify_thread_id = (pid_t)syscall(SYS_gettid);
        if (timer_create(CLOCK_MONOTONIC, &event, &watchdog_timer) < 0) return -errno;
        watchdog_timer_created = 1;
    }
    watchdog_fired_flag = 0;
    struct itimerspec spec;
    memset(&spec, 0, sizeof spec);
    spec.it_value.tv_sec = (time_t)(milliseconds / 1000);
    spec.it_value.tv_nsec = (long)((milliseconds % 1000) * 1000000);
    return result_or_errno(timer_settime(watchdog_timer, 0, &spec, NULL));
}

int ckvm_watchdog_fired(void) { return watchdog_fired_flag ? 1 : 0; }


// ---- Diagnostics: hardware write watchpoints --------------------------------

#define HWWATCH_SLOTS 4
static int hwwatch_fds[HWWATCH_SLOTS][2048];
static int hwwatch_count[HWWATCH_SLOTS];
static pthread_mutex_t hwwatch_lock = PTHREAD_MUTEX_INITIALIZER;

static void hwwatch_close_locked(int slot) {
    for (int i = 0; i < hwwatch_count[slot]; i++) close(hwwatch_fds[slot][i]);
    hwwatch_count[slot] = 0;
}

int ckvm_hwwatch_arm_slot(int slot, uint64_t address) {
    if (slot < 0 || slot >= HWWATCH_SLOTS) return -EINVAL;
    pthread_mutex_lock(&hwwatch_lock);
    hwwatch_close_locked(slot);
    DIR *d = opendir("/proc/self/task");
    if (!d) { int e = errno; pthread_mutex_unlock(&hwwatch_lock); return -e; }
    struct dirent *ent;
    int lastError = 0;
    while ((ent = readdir(d)) && hwwatch_count[slot] < 2048) {
        if (ent->d_name[0] < '0' || ent->d_name[0] > '9') continue;
        pid_t tid = (pid_t)atoi(ent->d_name);
        struct perf_event_attr attr;
        memset(&attr, 0, sizeof attr);
        attr.type = PERF_TYPE_BREAKPOINT;
        attr.size = sizeof attr;
        attr.bp_type = HW_BREAKPOINT_W;
        attr.bp_addr = address;
        attr.bp_len = HW_BREAKPOINT_LEN_8;
        attr.sample_period = 1;
        attr.exclude_kernel = 1;
        attr.exclude_hv = 1;
        attr.inherit = 1;
        attr.remove_on_exec = 1;
        attr.sigtrap = 1;
        attr.sig_data = address;
        int fd = (int)syscall(SYS_perf_event_open, &attr, tid, -1, -1, PERF_FLAG_FD_CLOEXEC);
        if (fd >= 0) hwwatch_fds[slot][hwwatch_count[slot]++] = fd; else lastError = errno;
    }
    closedir(d);
    int n = hwwatch_count[slot];
    pthread_mutex_unlock(&hwwatch_lock);
    return n > 0 ? n : -lastError;
}

void ckvm_hwwatch_disarm_slot(int slot) {
    if (slot < 0 || slot >= HWWATCH_SLOTS) return;
    pthread_mutex_lock(&hwwatch_lock);
    hwwatch_close_locked(slot);
    pthread_mutex_unlock(&hwwatch_lock);
}


// ---- Diagnostics: lost-write checker ----------------------------------------

#include <stdio.h>
static void *memcheck_thread(void *arg) {
    long id = (long)arg;
    enum { WORDS = 8192 };                       // 64 KiB on this thread's stack
    volatile uint64_t buf[WORDS];
    uint64_t *heap = malloc(WORDS * sizeof(uint64_t));
    volatile uint64_t *hp = heap;
    unsigned long pass = 0, reported = 0;
    for (;;) {
        pass++;
        uint64_t key = ((uint64_t)id << 56) ^ (pass * 0x9E3779B97F4A7C15ull);
        for (int i = 0; i < WORDS; i++) { buf[i] = key ^ (uint64_t)i; hp[i] = ~(key ^ (uint64_t)i); }
        for (int i = 0; i < WORDS; i++) {
            uint64_t want = key ^ (uint64_t)i;
            uint64_t s1 = buf[i], h1 = hp[i];
            if ((s1 != want || h1 != ~want) && reported < 20) {
                reported++;
                uint64_t s2 = buf[i], h2 = hp[i];
                char line[400];
                int n = snprintf(line, sizeof line,
                    "ycode-simd: MEMCHECK thread %ld pass %lu word %d: stack %p want %016llx got %016llx (again %016llx); heap %p want %016llx got %016llx (again %016llx)\n",
                    id, pass, i, (void *)&buf[i], (unsigned long long)want, (unsigned long long)s1, (unsigned long long)s2,
                    (void *)&hp[i], (unsigned long long)~want, (unsigned long long)h1, (unsigned long long)h2);
                (void)!write(2, line, n);
            }
        }
        if ((pass & 0xff) == 0) usleep(100);
    }
    return NULL;
}

int ckvm_memcheck_start(int threads) {
    for (long i = 0; i < threads; i++) {
        pthread_t t;
        pthread_attr_t a;
        pthread_attr_init(&a);
        pthread_attr_setstacksize(&a, 1 << 20);
        if (pthread_create(&t, &a, memcheck_thread, (void *)i) != 0) return -1;
        pthread_attr_destroy(&a);
        pthread_detach(t);
    }
    return 0;
}

int ckvm_hwwatch_arm(uint64_t address) { return ckvm_hwwatch_arm_slot(0, address); }
void ckvm_hwwatch_disarm(void) { ckvm_hwwatch_disarm_slot(0); }

#endif // __linux__ && __aarch64__

/* Diagnostics: the calling thread's return addresses by frame-pointer walk
   (cheap enough for every map lookup), pointer-authentication bits dropped. */
int ckvm_capture_frames(uintptr_t *out, int count) {
    void **fp = (void **)__builtin_frame_address(0);
    int n = 0;
    while (out && n < count && fp && ((uintptr_t)fp & 7) == 0) {
        void **next = (void **)fp[0];
        out[n++] = (uintptr_t)fp[1] & 0x0000ffffffffffffull;
        if (next <= fp || (char *)next - (char *)fp > (1 << 24)) break;
        fp = next;
    }
    return n;
}

/* The calling thread's Linux thread id (diagnostics). */
#if defined(__linux__) && defined(__aarch64__)
long ckvm_gettid(void) { return (long)syscall(SYS_gettid); }
#else
long ckvm_gettid(void) { return 0; }
#endif
