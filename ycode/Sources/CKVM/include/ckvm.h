// CKVM: a thin C layer over the Linux KVM ioctl interface for arm64 hosts.
//
// Swift cannot call the variadic ioctl(2) directly, so every KVM request the
// Ycode hypervisor needs is wrapped here as a plain C function. Functions that
// can fail return a negative errno value (-errno) on failure and a value >= 0
// on success.
//
// Everything except ckvm_available() exists only on Linux. On other hosts the
// module compiles to (almost) nothing, so the package still builds on macOS.
#ifndef CKVM_H
#define CKVM_H

#include <stddef.h>
#include <stdint.h>

/// 1 when the KVM bindings are compiled in (arm64 Linux), 0 otherwise.
int ckvm_available(void);

#if defined(__linux__) && defined(__aarch64__)

// ---- System, VM, and memory -------------------------------------------------

/// Opens /dev/kvm (read/write, close-on-exec). Returns the fd or -errno.
int ckvm_open(void);
/// Closes any fd. Returns 0 or -errno.
int ckvm_close(int fd);
/// KVM_GET_API_VERSION (12 on every supported kernel).
int ckvm_get_api_version(int kvm_fd);
/// KVM_CHECK_EXTENSION. Returns the extension value (0 = unsupported) or -errno.
int ckvm_check_extension(int kvm_fd, long extension);
/// KVM_CREATE_VM with the given machine type (0 = default IPA size). Returns the VM fd.
int ckvm_create_vm(int kvm_fd, unsigned long machine_type);
/// KVM_SET_USER_MEMORY_REGION.
int ckvm_set_user_memory_region(int vm_fd, uint32_t slot, uint32_t flags,
                                uint64_t guest_phys_addr, uint64_t memory_size,
                                uint64_t userspace_addr);

/// Anonymous, private, read/write mapping of `size` bytes (zero-filled).
/// Returns NULL on failure (errno is set).
void *ckvm_alloc_anonymous(size_t size);
/// munmap. Returns 0 or -errno.
int ckvm_free_anonymous(void *address, size_t size);
/// madvise(MADV_DONTNEED) on part of an anonymous private mapping: the host
/// pages are dropped and read back as zeros. Returns 0 or -errno.
int ckvm_discard_anonymous(void *address, size_t size);

/// A private, copy-on-write host mapping of a file, for a file-backed
/// memslot. Reserves `total_size` bytes of anonymous zero-filled read/write
/// memory, then maps `file_bytes` bytes of `fd` starting at `offset` over its
/// start with MAP_PRIVATE | MAP_FIXED and PROT_READ | PROT_WRITE. The file is
/// never modified. `file_bytes` must not reach past the host page holding the
/// end of the file (the caller clamps it to the file size); the rest of the
/// range stays anonymous zeros, so no access can raise SIGBUS. `offset` must
/// be a multiple of the host page size. Returns NULL on failure (errno set).
void *ckvm_map_file_private(int fd, uint64_t offset, size_t file_bytes, size_t total_size);

/// The host page size (sysconf(_SC_PAGESIZE)).
size_t ckvm_host_page_size(void);

/// Capability numbers for ckvm_check_extension.
enum {
    CKVM_CAP_NR_VCPUS = 9,
    CKVM_CAP_NR_MEMSLOTS = 10,
    CKVM_CAP_ARM_VM_IPA_SIZE = 165,
    CKVM_CAP_MAX_VCPUS = 66,
    CKVM_CAP_IMMEDIATE_EXIT = 136,
};

// ---- vCPU -------------------------------------------------------------------

/// KVM_CREATE_VCPU. Returns the vCPU fd.
int ckvm_create_vcpu(int vm_fd, unsigned long vcpu_id);
/// KVM_GET_VCPU_MMAP_SIZE (size of the shared struct kvm_run area).
int ckvm_get_vcpu_mmap_size(int kvm_fd);
/// Maps the vCPU's struct kvm_run. Returns NULL on failure (errno is set).
void *ckvm_map_run(int vcpu_fd, size_t mmap_size);

/// KVM_ARM_PREFERRED_TARGET on the VM, then KVM_ARM_VCPU_INIT on the vCPU
/// with that target and features[0] = `features0` (a bit mask of
/// KVM_ARM_VCPU_* feature numbers, see CKVM_ARM_VCPU_FEATURE_*).
int ckvm_arm_vcpu_init_preferred(int vm_fd, int vcpu_fd, uint32_t features0);
/// Feature bit numbers for ckvm_arm_vcpu_init_preferred.
enum {
    CKVM_ARM_VCPU_FEATURE_POWER_OFF = 0,
    CKVM_ARM_VCPU_FEATURE_EL1_32BIT = 1,
    CKVM_ARM_VCPU_FEATURE_PSCI_0_2 = 2,
    CKVM_ARM_VCPU_FEATURE_PMU_V3 = 3,
};

/// KVM_GET_ONE_REG / KVM_SET_ONE_REG for 64-bit registers.
int ckvm_get_one_reg_u64(int vcpu_fd, uint64_t reg_id, uint64_t *value);
int ckvm_set_one_reg_u64(int vcpu_fd, uint64_t reg_id, uint64_t value);

/// KVM_RUN. Returns 0 when the vCPU exited to user space (inspect the run
/// area), or -errno (-EINTR when a signal interrupted the run).
int ckvm_run(int vcpu_fd);
/// Diagnostics (`YCODE_DEBUG_RUNCHECK=1`, read at load): `ckvm_run` checks
/// SP, x29, x30, x18, NZCV and the caller's stack frames across KVM_RUN and
/// aborts on a change. `ckvm_debug_run_checks` counts the checked calls.
extern int ckvm_debug_run_check;
unsigned long ckvm_debug_run_checks(void);

// ---- Register IDs -------------------------------------------------------------

/// Core register x0...x30 (n in 0...30).
uint64_t ckvm_reg_x(unsigned n);
/// SP_EL0 (the "sp" of the user register set).
uint64_t ckvm_reg_sp_el0(void);
uint64_t ckvm_reg_pc(void);
uint64_t ckvm_reg_pstate(void);
uint64_t ckvm_reg_sp_el1(void);
uint64_t ckvm_reg_elr_el1(void);
uint64_t ckvm_reg_spsr_el1(void);
/// A system register by its MRS/MSR encoding.
uint64_t ckvm_reg_sysreg(unsigned op0, unsigned op1, unsigned crn, unsigned crm, unsigned op2);
/// The guest's virtual counter (CNTVCT_EL0) as KVM exposes it. The uapi
/// constant KVM_REG_ARM_TIMER_CNT is used as-is: its encoding is
/// deliberately not the architectural one.
uint64_t ckvm_reg_timer_cnt(void);
/// The guest's virtual timer control register (KVM_REG_ARM_TIMER_CTL).
uint64_t ckvm_reg_timer_ctl(void);

/// CNTFRQ_EL0 and CNTVCT_EL0 read on the host (both are readable at EL0 on
/// Linux). Used when KVM does not expose a value through ONE_REG.
uint64_t ckvm_host_cntfrq(void);
uint64_t ckvm_host_cntvct(void);

// ---- struct kvm_run accessors ------------------------------------------------

/// Exit reason numbers (the KVM_EXIT_* values used by the hypervisor).
enum {
    CKVM_EXIT_UNKNOWN = 0,
    CKVM_EXIT_EXCEPTION = 1,
    CKVM_EXIT_HYPERCALL = 3,
    CKVM_EXIT_DEBUG = 4,
    CKVM_EXIT_HLT = 5,
    CKVM_EXIT_MMIO = 6,
    CKVM_EXIT_SHUTDOWN = 8,
    CKVM_EXIT_FAIL_ENTRY = 9,
    CKVM_EXIT_INTR = 10,
    CKVM_EXIT_INTERNAL_ERROR = 17,
    CKVM_EXIT_SYSTEM_EVENT = 24,
    CKVM_EXIT_ARM_NISV = 28,
};

uint32_t ckvm_run_exit_reason(const void *run);
/// Sets or clears kvm_run.immediate_exit.
void ckvm_run_set_immediate_exit(void *run, uint8_t value);

uint64_t ckvm_run_mmio_phys_addr(const void *run);
uint32_t ckvm_run_mmio_len(const void *run);
uint8_t ckvm_run_mmio_is_write(const void *run);
/// Copies min(len, 8) bytes of the MMIO data buffer into `out`.
void ckvm_run_mmio_get_data(const void *run, uint8_t *out, uint32_t len);
/// Fills the MMIO data buffer (for completing a guest read on the next KVM_RUN).
void ckvm_run_mmio_set_data(void *run, const uint8_t *data, uint32_t len);

uint64_t ckvm_run_fail_entry_reason(const void *run);
uint32_t ckvm_run_fail_entry_cpu(const void *run);

uint32_t ckvm_run_internal_suberror(const void *run);
uint32_t ckvm_run_internal_ndata(const void *run);
uint64_t ckvm_run_internal_data(const void *run, uint32_t index);

uint32_t ckvm_run_system_event_type(const void *run);
uint32_t ckvm_run_system_event_ndata(const void *run);
uint64_t ckvm_run_system_event_data(const void *run, uint32_t index);

/// KVM_EXIT_ARM_NISV: ESR_EL2 bits and the faulting IPA.
uint64_t ckvm_run_arm_nisv_esr_iss(const void *run);
uint64_t ckvm_run_arm_nisv_fault_ipa(const void *run);

// ---- Kicking a vCPU thread and cache maintenance ------------------------------

/// Installs an empty handler for `signo` without SA_RESTART, so a KVM_RUN on
/// a thread that receives the signal returns -EINTR. Returns 0 or -errno.
int ckvm_kick_install(int signo);
/// Sends `signo` to the host thread `thread` (a pthread_t). Returns 0 or -errno.
int ckvm_kick_thread(unsigned long thread, int signo);
/// The calling thread's Linux thread id (diagnostics).
long ckvm_gettid(void);
/// Blocks `signo` on the calling thread, and has KVM unblock it only while
/// this thread is inside KVM_RUN on `vcpu_fd` (KVM_SET_SIGNAL_MASK): a kick
/// is then delivered only in KVM_RUN, never in the middle of host code.
int ckvm_kick_mask_outside_run(int vcpu_fd, int signo);
/// Diagnostics: up to `count` return addresses of the caller (frame-pointer
/// walk); returns how many.
int ckvm_capture_frames(uintptr_t *out, int count);

/// Cleans and invalidates [address, address+size) to the point of coherency
/// (DC CIVAC on every data-cache line, then DSB SY). Used for guest memory the
/// VMM wrote through its cacheable mapping and that a vCPU reads with its MMU
/// off (non-cacheable): the boot-info block, the trap frame, the shim image.
void ckvm_clean_dcache_range(const void *address, size_t size);

/// ID_AA64MMFR2_EL1 as Linux exposes it to user space (MRS emulation; fields
/// the kernel hides read as 0), or 0 when HWCAP_CPUID is absent.
uint64_t ckvm_host_id_aa64mmfr2(void);

// ---- Watchdog ---------------------------------------------------------------

/// Arms a one-shot per-thread timer that interrupts the calling thread after
/// `milliseconds`, so a KVM_RUN on this thread returns -EINTR. Pass 0 to
/// disarm. Returns 0 or -errno.
int ckvm_watchdog_arm(uint64_t milliseconds);
/// 1 once the watchdog timer has fired.
int ckvm_watchdog_fired(void);

// ---- Diagnostics: hardware write watchpoints --------------------------------

/// Watches the 8 bytes at `address` (8-byte aligned) for writes in every
/// current thread of this process (and threads they create later): a write
/// raises SIGTRAP in the writing thread. Replaces any earlier watch. Returns
/// the number of threads watched, or -errno.
int ckvm_hwwatch_arm(uint64_t address);
/// Removes the watch.
void ckvm_hwwatch_disarm(void);
/// The same for one of 4 independent watches (`slot` 0...3).
int ckvm_hwwatch_arm_slot(int slot, uint64_t address);
/// Diagnostics: `threads` threads that write and verify a stack and a heap
/// buffer forever, reporting any word that does not read back (stderr).
int ckvm_memcheck_start(int threads);
void ckvm_hwwatch_disarm_slot(int slot);

#endif // __linux__ && __aarch64__

#endif // CKVM_H
