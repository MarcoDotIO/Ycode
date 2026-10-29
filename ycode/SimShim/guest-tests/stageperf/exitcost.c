/* exitcost: what one guest exit costs on this host, layer by layer (Linux
 * arm64 host tool for specs/simulator/guest-cpu.md §5). Original Ycode code,
 * written from the Linux KVM API documentation (Documentation/virt/kvm/
 * api.rst, devices/vm.rst, devices/arm-vgic-v3.rst), the Arm SMC Calling
 * Convention and PSCI specifications, and the Arm Architecture Reference
 * Manual. It runs a tiny guest of its own (EL1, MMU off) in a one-vCPU VM
 * and times one round trip per mode:
 *
 *   kern      HVC that KVM answers itself (PSCI_VERSION): the exception to
 *             the host kernel and back, no return to user space
 *   user      HVC forwarded to user space (SMCCC filter, KVM_EXIT_HYPERCALL):
 *             Ycode's doorbell; the VMM loop does nothing but KVM_RUN again
 *   user-fp   the same, and the guest touches FP/SIMD after each exit (the
 *             lazy FP/SIMD switch after every return to user space; Ycode's
 *             shim does this on every resume, YCODE_SHIM_FP_TOUCH)
 *   user-sig  the same as user, with KVM_SET_SIGNAL_MASK (Ycode's vCPUs set one)
 *   user-gic  the same as user, in a VM with an in-kernel vGICv3
 *   mmio      a store to a GPA with no memslot (KVM_EXIT_MMIO)
 *   ioctl     no guest: KVM_CHECK_EXTENSION on the VM fd (system call cost)
 *   syscall   no guest: getppid() on the host
 *
 *   cc -O2 -o exitcost exitcost.c
 *   exitcost [-n iterations] [-r rounds] [mode ...]   (default: all modes)
 * Prints "exitcost <mode> <median ns> ns (min .. max, n rounds)". Pin it with
 * taskset for stable numbers. */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define RAM_GPA 0x40000000ull
#define RAM_SIZE (2u << 20)
#define MMIO_GPA 0x09000000ull
#define FN_FORWARD 0xC6005943u   /* vendor hypervisor service, fast SMC64: forwarded to user space */
#define FN_PSCI_VERSION 0x84000000u

/* Guest code, copied into guest RAM at RAM_GPA (position independent). The
 * host selects the loop with x19: 0 = forwarded HVC, 1 = forwarded HVC + FP
 * touch, 2 = MMIO store, 3 = x20 PSCI_VERSION HVCs then one forwarded HVC. */
extern const char guest_begin[], guest_end[];
__asm__(
    ".text\n.balign 4\n.globl guest_begin\nguest_begin:\n"
    "  mov x2, #(3 << 20)\n  msr cpacr_el1, x2\n  isb\n"
    "  movz w5, #0x5943\n  movk w5, #0xC600, lsl #16\n"   /* FN_FORWARD */
    "  movz w6, #0x0000\n  movk w6, #0x8400, lsl #16\n"   /* FN_PSCI_VERSION */
    "  movz x7, #0x0900, lsl #16\n"                        /* MMIO_GPA */
    "  cmp x19, #1\n  b.eq 20f\n  cmp x19, #2\n  b.eq 30f\n  cmp x19, #3\n  b.eq 40f\n"
    "10: mov w0, w5\n  hvc #0\n  b 10b\n"
    "20: mov w0, w5\n  hvc #0\n  fmov d0, x1\n  b 20b\n"
    "30: str x1, [x7]\n  b 30b\n"
    "40: mov x21, x20\n"
    "41: mov w0, w6\n  hvc #0\n  subs x21, x21, #1\n  b.ne 41b\n"
    "  mov w0, w5\n  hvc #0\n  b 40b\n"
    ".globl guest_end\nguest_end:\n");

static int kvm_fd;

static void die(const char *what)
{
    fprintf(stderr, "exitcost: %s: %s\n", what, strerror(errno));
    exit(1);
}

static double now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1e9 + (double)t.tv_nsec;
}

static uint64_t core_reg(uint64_t index) { return KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM_CORE | index; }
#define CORE(field) core_reg(offsetof(struct kvm_regs, field) / sizeof(uint32_t))

static void set_reg(int vcpu, uint64_t id, uint64_t value)
{
    struct kvm_one_reg r = {.id = id, .addr = (uint64_t)(uintptr_t)&value};
    if (ioctl(vcpu, KVM_SET_ONE_REG, &r) < 0) die("KVM_SET_ONE_REG");
}

struct vm { int fd, vcpu; struct kvm_run *run; };

static struct vm make_vm(int x19, uint64_t x20, int gic, int sigmask)
{
    struct vm v;
    v.fd = ioctl(kvm_fd, KVM_CREATE_VM, 0);
    if (v.fd < 0) die("KVM_CREATE_VM");
    void *ram = mmap(NULL, RAM_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (ram == MAP_FAILED) die("mmap");
    memcpy(ram, guest_begin, (size_t)(guest_end - guest_begin));
    struct kvm_userspace_memory_region region = {
        .slot = 0, .guest_phys_addr = RAM_GPA, .memory_size = RAM_SIZE, .userspace_addr = (uint64_t)(uintptr_t)ram};
    if (ioctl(v.fd, KVM_SET_USER_MEMORY_REGION, &region) < 0) die("KVM_SET_USER_MEMORY_REGION");
    struct { uint32_t base, nr; uint8_t action, pad[15]; } filter = {FN_FORWARD, 1, 2 /* FWD_TO_USER */, {0}};
    struct kvm_device_attr fa = {.group = 0 /* KVM_ARM_VM_SMCCC_CTRL */, .attr = 0 /* KVM_ARM_VM_SMCCC_FILTER */,
                                 .addr = (uint64_t)(uintptr_t)&filter};
    if (ioctl(v.fd, KVM_SET_DEVICE_ATTR, &fa) < 0) die("SMCCC filter");
    v.vcpu = ioctl(v.fd, KVM_CREATE_VCPU, 0);
    if (v.vcpu < 0) die("KVM_CREATE_VCPU");
    struct kvm_vcpu_init init;
    if (ioctl(v.fd, KVM_ARM_PREFERRED_TARGET, &init) < 0) die("KVM_ARM_PREFERRED_TARGET");
    init.features[0] |= 1u << KVM_ARM_VCPU_PSCI_0_2;
    if (ioctl(v.vcpu, KVM_ARM_VCPU_INIT, &init) < 0) die("KVM_ARM_VCPU_INIT");
    if (gic) {
        struct kvm_create_device dev = {.type = KVM_DEV_TYPE_ARM_VGIC_V3};
        if (ioctl(v.fd, KVM_CREATE_DEVICE, &dev) < 0) die("KVM_CREATE_DEVICE vGICv3");
        uint64_t dist = 0x08000000, redist = 0x080A0000;
        struct kvm_device_attr a1 = {.group = KVM_DEV_ARM_VGIC_GRP_ADDR, .attr = KVM_VGIC_V3_ADDR_TYPE_DIST,
                                     .addr = (uint64_t)(uintptr_t)&dist};
        struct kvm_device_attr a2 = {.group = KVM_DEV_ARM_VGIC_GRP_ADDR, .attr = KVM_VGIC_V3_ADDR_TYPE_REDIST,
                                     .addr = (uint64_t)(uintptr_t)&redist};
        struct kvm_device_attr a3 = {.group = KVM_DEV_ARM_VGIC_GRP_CTRL, .attr = KVM_DEV_ARM_VGIC_CTRL_INIT};
        if (ioctl(dev.fd, KVM_SET_DEVICE_ATTR, &a1) < 0 || ioctl(dev.fd, KVM_SET_DEVICE_ATTR, &a2) < 0 ||
            ioctl(dev.fd, KVM_SET_DEVICE_ATTR, &a3) < 0) die("vGICv3 setup");
    }
    if (sigmask) {
        sigset_t s;
        pthread_sigmask(SIG_BLOCK, NULL, &s);
        struct { struct kvm_signal_mask h; uint64_t bits; } m = {{.len = 8}, 0};
        memcpy(&m.bits, &s, 8);
        if (ioctl(v.vcpu, KVM_SET_SIGNAL_MASK, &m) < 0) die("KVM_SET_SIGNAL_MASK");
    }
    int size = ioctl(kvm_fd, KVM_GET_VCPU_MMAP_SIZE, 0);
    v.run = mmap(NULL, (size_t)size, PROT_READ | PROT_WRITE, MAP_SHARED, v.vcpu, 0);
    if (v.run == MAP_FAILED) die("mmap kvm_run");
    set_reg(v.vcpu, CORE(regs.pc), RAM_GPA);
    set_reg(v.vcpu, CORE(regs.pstate), 0x3c5); /* EL1h, DAIF masked */
    set_reg(v.vcpu, CORE(regs.regs[19]), (uint64_t)x19);
    set_reg(v.vcpu, CORE(regs.regs[20]), x20);
    return v;
}

static void run_expect(struct vm *v, uint32_t reason)
{
    int r;
    do r = ioctl(v->vcpu, KVM_RUN, 0); while (r < 0 && (errno == EINTR || errno == EAGAIN));
    if (r < 0) die("KVM_RUN");
    if (v->run->exit_reason != reason) {
        fprintf(stderr, "exitcost: exit reason %u, expected %u\n", v->run->exit_reason, reason);
        exit(1);
    }
}

static int cmp(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static long iterations = 200000;
static int rounds = 7;

/* ns per round trip of one mode, one round. */
static double one_round(const char *mode)
{
    long n = iterations;
    if (!strcmp(mode, "syscall")) {
        double t0 = now_ns();
        volatile long s = 0;
        for (long i = 0; i < n; i++) s += getppid();
        return (now_ns() - t0) / (double)n;
    }
    if (!strcmp(mode, "ioctl")) {
        static int vmfd = -1;
        if (vmfd < 0) vmfd = ioctl(kvm_fd, KVM_CREATE_VM, 0);
        double t0 = now_ns();
        for (long i = 0; i < n; i++) (void)ioctl(vmfd, KVM_CHECK_EXTENSION, KVM_CAP_ARM_VM_IPA_SIZE);
        return (now_ns() - t0) / (double)n;
    }
    int kern = !strcmp(mode, "kern");
    int x19 = kern ? 3 : !strcmp(mode, "user-fp") ? 1 : !strcmp(mode, "mmio") ? 2 : 0;
    struct vm v = make_vm(x19, (uint64_t)n, !strcmp(mode, "user-gic"), !strcmp(mode, "user-sig"));
    uint32_t reason = x19 == 2 ? KVM_EXIT_MMIO : KVM_EXIT_HYPERCALL;
    /* Warm up: the first exits fault in the guest page and load state. */
    if (kern) run_expect(&v, reason);
    else for (int i = 0; i < 1000; i++) run_expect(&v, reason);
    double t0 = now_ns();
    if (kern) run_expect(&v, reason);   /* n in-kernel round trips, then one user exit */
    else for (long i = 0; i < n; i++) run_expect(&v, reason);
    double ns = (now_ns() - t0) / (double)n;
    munmap(v.run, (size_t)ioctl(kvm_fd, KVM_GET_VCPU_MMAP_SIZE, 0));
    close(v.vcpu);
    close(v.fd);
    return ns;
}

int main(int argc, char **argv)
{
    static const char *all[] = {"kern", "user", "user-fp", "user-sig", "user-gic", "mmio", "ioctl", "syscall"};
    int c;
    while ((c = getopt(argc, argv, "n:r:")) != -1) {
        if (c == 'n') iterations = atol(optarg);
        else if (c == 'r') rounds = atoi(optarg);
        else return 64;
    }
    if (rounds < 1 || rounds > 64 || iterations < 1) return 64;
    kvm_fd = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    if (kvm_fd < 0) die("/dev/kvm");
    const char **modes = optind < argc ? (const char **)&argv[optind] : all;
    int count = optind < argc ? argc - optind : (int)(sizeof all / sizeof *all);
    for (int m = 0; m < count; m++) {
        double v[64];
        for (int r = 0; r < rounds; r++) v[r] = one_round(modes[m]);
        qsort(v, (size_t)rounds, sizeof *v, cmp);
        printf("exitcost %-9s %8.1f ns (min %.1f max %.1f, n %d)\n", modes[m], v[rounds / 2], v[0], v[rounds - 1], rounds);
        fflush(stdout);
    }
    return 0;
}
