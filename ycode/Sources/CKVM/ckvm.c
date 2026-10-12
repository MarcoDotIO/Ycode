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

int ckvm_run(int vcpu_fd) { return result_or_errno(ioctl(vcpu_fd, KVM_RUN, 0)); }

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

int ckvm_kick_install(int signo) {
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = kick_handler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0; // no SA_RESTART: KVM_RUN must return -EINTR
    return result_or_errno(sigaction(signo, &action, NULL));
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

#endif // __linux__ && __aarch64__

/* The calling thread's Linux thread id (diagnostics). */
#if defined(__linux__) && defined(__aarch64__)
long ckvm_gettid(void) { return (long)syscall(SYS_gettid); }
#else
long ckvm_gettid(void) { return 0; }
#endif
