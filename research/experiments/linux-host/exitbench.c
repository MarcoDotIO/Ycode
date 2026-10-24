/*
 * exitbench: compare two ways a KVM arm64 guest can ring the host, measured
 * as nanoseconds per round trip (guest -> KVM_EXIT -> host -> KVM_RUN).
 * Ycode's own code; it runs a tiny hand-assembled guest loop, no Apple code.
 *
 *   mmio   the guest stores to an unbacked GPA. KVM returns KVM_EXIT_MMIO
 *          and advances the guest PC itself. This is Ycode's doorbell exit
 *          (specs/simulator/vm-shim-protocol.md section 5).
 *   hvc    the guest issues HVC with a vendor SMCCC function id, and an
 *          SMCCC filter range with action FWD_TO_USER makes KVM return
 *          KVM_EXIT_HYPERCALL (Documentation/virt/kvm/devices/vm.rst,
 *          KVM_ARM_VM_SMCCC_FILTER). PC is already past the HVC on exit.
 *
 * The question (native-mode feasibility, item 5): is a forwarded HVC exit
 * cheaper than our MMIO doorbell? Both leave EL1, trap to EL2, and return to
 * host userspace with one KVM_RUN per crossing; this measures the delta.
 *
 * Build (Thor, arm64):  cc -O2 -o exitbench exitbench.c
 * Run:   ./exitbench [iterations]      (default 300000; runs both modes)
 * Facts: the public Linux KVM API (api.rst, vm.rst) and the Arm ARM
 * (instruction encodings). The SMCCC-filter uapi constants are defined here
 * because this box's /usr/include/linux/kvm.h predates them.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

/* --- SMCCC filter uapi (arch/arm64/include/uapi/asm/kvm.h), redefined --- */
#define YC_KVM_ARM_VM_SMCCC_CTRL 0
#define YC_KVM_ARM_VM_SMCCC_FILTER 0
#define YC_KVM_SMCCC_FILTER_FWD_TO_USER 2
struct yc_kvm_smccc_filter {
    uint32_t base;
    uint32_t nr_functions;
    uint8_t action;
    uint8_t pad[15];
};

/* A vendor-specific hypervisor service function id (SMCCC): bit 31 = fast
 * call, owner field = vendor. It is outside the Arm Architecture range
 * (0x8000_0000..0x8000_FFFF) that the filter refuses. */
#define YC_HVC_FUNCTION 0x86000000u

/* GPAs. RAM holds the guest loop; the doorbell is deliberately unbacked. */
#define GUEST_RAM 0x40000000ull
#define GUEST_DOORBELL 0x09000000ull

#define CORE(field) \
    (KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM_CORE | (offsetof(struct kvm_regs, field) / sizeof(uint32_t)))

static void die(const char *m)
{
    fprintf(stderr, "exitbench: %s: %s\n", m, strerror(errno));
    exit(1);
}

static void set_reg(int vcpu, uint64_t id, uint64_t v)
{
    struct kvm_one_reg r = { .id = id, .addr = (uint64_t)&v };
    if (ioctl(vcpu, KVM_SET_ONE_REG, &r) < 0)
        die("KVM_SET_ONE_REG");
}

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* The two guest programs, hand-assembled (little-endian arm64). Each is an
 * endless loop that performs one host exit per iteration. */
static const uint32_t prog_mmio[] = {
    0xd2a12001, /* movz x1, #0x0900, lsl #16   ; x1 = GUEST_DOORBELL        */
    0xd2800000, /* mov  x0, #0                                              */
    0xf9000020, /* str  x0, [x1]               ; -> KVM_EXIT_MMIO           */
    0x17ffffff, /* b    .-4                     ; back to the store          */
};
static const uint32_t prog_hvc[] = {
    0x52b0c000, /* movz w0, #0x8600, lsl #16   ; w0 = YC_HVC_FUNCTION       */
    0xd4000002, /* hvc  #0                      ; -> KVM_EXIT_HYPERCALL      */
    0x17ffffff, /* b    .-4                     ; back to the hvc            */
};

static int vm_fd, kvm_fd;

static int make_vcpu(const uint32_t *prog, size_t prog_words, uint8_t *ram, int mmio_entry)
{
    memset(ram, 0, 0x4000);
    memcpy(ram, prog, prog_words * 4);
    int vcpu = ioctl(vm_fd, KVM_CREATE_VCPU, 0);
    if (vcpu < 0)
        die("KVM_CREATE_VCPU");
    struct kvm_vcpu_init init;
    memset(&init, 0, sizeof init);
    if (ioctl(vm_fd, KVM_ARM_PREFERRED_TARGET, &init) < 0)
        die("KVM_ARM_PREFERRED_TARGET");
    if (ioctl(vcpu, KVM_ARM_VCPU_INIT, &init) < 0)
        die("KVM_ARM_VCPU_INIT");
    /* EL1h, DAIF masked (0x3c5). MMU off: PC is a GPA. */
    set_reg(vcpu, CORE(regs.pc), GUEST_RAM + (uint64_t)(mmio_entry ? 0 : 0));
    set_reg(vcpu, CORE(regs.pstate), 0x3c5);
    return vcpu;
}

static double bench(const char *name, const uint32_t *prog, size_t prog_words, uint8_t *ram, long iters,
                    int want_hypercall)
{
    int vcpu = make_vcpu(prog, prog_words, ram, 1);
    int run_size = ioctl(kvm_fd, KVM_GET_VCPU_MMAP_SIZE, 0);
    struct kvm_run *run = mmap(NULL, run_size, PROT_READ | PROT_WRITE, MAP_SHARED, vcpu, 0);
    if (run == MAP_FAILED)
        die("mmap kvm_run");

    long got = 0;
    int warmup = 2000;
    uint64_t t0 = 0;
    for (long i = 0; i < iters + warmup; i++) {
        if (i == warmup)
            t0 = now_ns();
        if (ioctl(vcpu, KVM_RUN, 0) < 0) {
            if (errno == EINTR)
                continue;
            die("KVM_RUN");
        }
        if (want_hypercall) {
            if (run->exit_reason != KVM_EXIT_HYPERCALL) {
                fprintf(stderr, "exitbench: %s: unexpected exit_reason %u\n", name, run->exit_reason);
                exit(1);
            }
        } else {
            if (run->exit_reason != KVM_EXIT_MMIO) {
                fprintf(stderr, "exitbench: %s: unexpected exit_reason %u\n", name, run->exit_reason);
                exit(1);
            }
        }
        got++;
    }
    uint64_t t1 = now_ns();
    close(vcpu);
    munmap(run, run_size);
    double per = (double)(t1 - t0) / (double)iters;
    printf("  %-5s %9ld exits  %7.1f ns/round trip\n", name, got, per);
    return per;
}

int main(int argc, char **argv)
{
    long iters = argc > 1 ? atol(argv[1]) : 300000;

    kvm_fd = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    if (kvm_fd < 0)
        die("open /dev/kvm");
    vm_fd = ioctl(kvm_fd, KVM_CREATE_VM, 0);
    if (vm_fd < 0)
        die("KVM_CREATE_VM");

    uint8_t *ram;
    if (posix_memalign((void **)&ram, 0x10000, 0x10000) != 0)
        die("posix_memalign");
    struct kvm_userspace_memory_region region = {
        .slot = 0,
        .guest_phys_addr = GUEST_RAM,
        .memory_size = 0x10000,
        .userspace_addr = (uint64_t)ram,
    };
    if (ioctl(vm_fd, KVM_SET_USER_MEMORY_REGION, &region) < 0)
        die("KVM_SET_USER_MEMORY_REGION");

    printf("exitbench: %ld iterations each\n", iters);

    /* MMIO doorbell (no filter needed). */
    double mmio = bench("mmio", prog_mmio, sizeof prog_mmio / 4, ram, iters, 0);

    /* Install an SMCCC filter: forward the one vendor function id to
     * userspace. Must be set before any vCPU in the VM has run; this VM has
     * only had the MMIO vCPU, which was created and run, so KVM may refuse
     * with EBUSY. If so, redo on a fresh VM. */
    struct yc_kvm_smccc_filter filt = {
        .base = YC_HVC_FUNCTION,
        .nr_functions = 1,
        .action = YC_KVM_SMCCC_FILTER_FWD_TO_USER,
    };
    struct kvm_device_attr attr = {
        .group = YC_KVM_ARM_VM_SMCCC_CTRL,
        .attr = YC_KVM_ARM_VM_SMCCC_FILTER,
        .addr = (uint64_t)&filt,
    };
    int vm_for_hvc = vm_fd;
    if (ioctl(vm_fd, KVM_SET_DEVICE_ATTR, &attr) < 0) {
        if (errno != EBUSY && errno != ENXIO && errno != ENOTTY && errno != EINVAL)
            die("KVM_SET_DEVICE_ATTR(SMCCC_FILTER)");
        /* Fresh VM: install the filter before creating/running a vCPU. */
        int fresh = ioctl(kvm_fd, KVM_CREATE_VM, 0);
        if (fresh < 0)
            die("KVM_CREATE_VM (fresh)");
        struct kvm_userspace_memory_region r2 = region;
        if (ioctl(fresh, KVM_SET_USER_MEMORY_REGION, &r2) < 0)
            die("KVM_SET_USER_MEMORY_REGION (fresh)");
        if (ioctl(fresh, KVM_SET_DEVICE_ATTR, &attr) < 0) {
            fprintf(stderr, "exitbench: SMCCC filter unsupported on this kernel (errno %d: %s)\n", errno,
                    strerror(errno));
            fprintf(stderr, "exitbench: reporting MMIO only.\n");
            return 0;
        }
        vm_for_hvc = fresh;
    }

    int saved = vm_fd;
    vm_fd = vm_for_hvc;
    double hvc = bench("hvc", prog_hvc, sizeof prog_hvc / 4, ram, iters, 1);
    vm_fd = saved;

    printf("exitbench: hvc - mmio = %+.1f ns/round trip (%.1f%%)\n", hvc - mmio, 100.0 * (hvc - mmio) / mmio);
    return 0;
}
