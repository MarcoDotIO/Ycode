// CKVM CPU-feature helpers (see include/ckvm_cpufeat.h). Original Ycode code
// over the public Linux KVM API (KVM_CREATE_VM, KVM_CREATE_VCPU,
// KVM_ARM_PREFERRED_TARGET, KVM_ARM_VCPU_INIT, KVM_GET_ONE_REG) and the Arm
// Architecture Reference Manual's register definitions.
#include "ckvm_cpufeat.h"

#if defined(__linux__) && defined(__aarch64__)

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <linux/kvm.h>

int ckvm_probe_vcpu_registers(const uint64_t *ids, uint64_t *values, int32_t *results, int count) {
    int kvm = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    if (kvm < 0) return -errno;
    int rc = 0, vm = -1, vcpu = -1;
    vm = ioctl(kvm, KVM_CREATE_VM, 0UL);
    if (vm < 0) { rc = -errno; goto out; }
    vcpu = ioctl(vm, KVM_CREATE_VCPU, 0UL);
    if (vcpu < 0) { rc = -errno; goto out; }
    struct kvm_vcpu_init init;
    memset(&init, 0, sizeof init);
    if (ioctl(vm, KVM_ARM_PREFERRED_TARGET, &init) < 0) { rc = -errno; goto out; }
    init.features[0] |= 1u << KVM_ARM_VCPU_PSCI_0_2;
    if (ioctl(vcpu, KVM_ARM_VCPU_INIT, &init) < 0) { rc = -errno; goto out; }
    for (int i = 0; i < count; i++) {
        uint64_t v = 0;
        struct kvm_one_reg reg;
        reg.id = ids[i];
        reg.addr = (uint64_t)(uintptr_t)&v;
        if (ioctl(vcpu, KVM_GET_ONE_REG, &reg) < 0) {
            results[i] = -errno;
            values[i] = 0;
        } else {
            results[i] = 0;
            values[i] = v;
        }
    }
out:
    if (vcpu >= 0) close(vcpu);
    if (vm >= 0) close(vm);
    close(kvm);
    return rc;
}

uint64_t ckvm_host_ctr_el0(void) {
    uint64_t value;
    __asm__ volatile("mrs %0, ctr_el0" : "=r"(value));
    return value;
}

uint64_t ckvm_host_dczid_el0(void) {
    uint64_t value;
    __asm__ volatile("mrs %0, dczid_el0" : "=r"(value));
    return value;
}

uint64_t ckvm_host_fpcr_trap_probe(void) {
    // IOE (8), DZE (9), OFE (10), UFE (11), IXE (12), IDE (15).
    const uint64_t traps = (1u << 8) | (1u << 9) | (1u << 10) | (1u << 11) | (1u << 12) | (1u << 15);
    uint64_t saved, readback;
    __asm__ volatile(
        "mrs %0, fpcr\n"
        "orr x9, %0, %2\n"
        "msr fpcr, x9\n"
        "isb\n"
        "mrs %1, fpcr\n"
        "msr fpcr, %0\n"
        "isb\n"
        : "=&r"(saved), "=&r"(readback)
        : "r"(traps)
        : "x9", "memory");
    return readback & traps;
}

#endif
