// CKVM snapshot helpers (see include/ckvm_snapshot.h). Original Ycode code
// over the public Linux KVM, mincore and pagemap interfaces.
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include "ckvm_snapshot.h"

#if defined(__linux__) && defined(__aarch64__)

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <linux/kvm.h>

static int snap_result(int r) { return r < 0 ? -errno : r; }

int ckvm_get_one_reg_bytes(int vcpu_fd, uint64_t reg_id, void *buffer) {
    struct kvm_one_reg reg;
    reg.id = reg_id;
    reg.addr = (uint64_t)(uintptr_t)buffer;
    return snap_result(ioctl(vcpu_fd, KVM_GET_ONE_REG, &reg));
}

int ckvm_set_one_reg_bytes(int vcpu_fd, uint64_t reg_id, const void *buffer) {
    struct kvm_one_reg reg;
    reg.id = reg_id;
    reg.addr = (uint64_t)(uintptr_t)buffer;
    return snap_result(ioctl(vcpu_fd, KVM_SET_ONE_REG, &reg));
}

#define SNAP_CORE(field, size) \
    (KVM_REG_ARM64 | (size) | KVM_REG_ARM_CORE | KVM_REG_ARM_CORE_REG(field))

uint64_t ckvm_reg_fp_v(unsigned n) {
    // fp_regs.vregs[n] is a __uint128_t: 4 32-bit words per register.
    return SNAP_CORE(fp_regs.vregs[0], KVM_REG_SIZE_U128) + 4u * (uint64_t)n;
}
uint64_t ckvm_reg_fpsr(void) { return SNAP_CORE(fp_regs.fpsr, KVM_REG_SIZE_U32); }
uint64_t ckvm_reg_fpcr(void) { return SNAP_CORE(fp_regs.fpcr, KVM_REG_SIZE_U32); }

int ckvm_get_fp_state(int vcpu_fd, uint8_t *out) {
    for (unsigned n = 0; n < 32; n++) {
        int r = ckvm_get_one_reg_bytes(vcpu_fd, ckvm_reg_fp_v(n), out + 16 * n);
        if (r < 0) return r;
    }
    int r = ckvm_get_one_reg_bytes(vcpu_fd, ckvm_reg_fpsr(), out + 512);
    if (r < 0) return r;
    return ckvm_get_one_reg_bytes(vcpu_fd, ckvm_reg_fpcr(), out + 516);
}

int ckvm_set_fp_state(int vcpu_fd, const uint8_t *in) {
    for (unsigned n = 0; n < 32; n++) {
        int r = ckvm_set_one_reg_bytes(vcpu_fd, ckvm_reg_fp_v(n), in + 16 * n);
        if (r < 0) return r;
    }
    int r = ckvm_set_one_reg_bytes(vcpu_fd, ckvm_reg_fpsr(), in + 512);
    if (r < 0) return r;
    return ckvm_set_one_reg_bytes(vcpu_fd, ckvm_reg_fpcr(), in + 516);
}

int ckvm_kick_tid(long tid, int signo) {
    return snap_result((int)syscall(SYS_tgkill, (long)getpid(), tid, signo));
}

int ckvm_mincore(const void *address, size_t size, uint8_t *vec) {
    return snap_result(mincore((void *)address, size, (unsigned char *)vec));
}

static int pagemap_fd = -1;
static pthread_mutex_t pagemap_lock = PTHREAD_MUTEX_INITIALIZER;

long ckvm_pagemap(const void *address, size_t count, uint64_t *out) {
    pthread_mutex_lock(&pagemap_lock);
    if (pagemap_fd < 0) pagemap_fd = open("/proc/self/pagemap", O_RDONLY | O_CLOEXEC);
    int fd = pagemap_fd;
    pthread_mutex_unlock(&pagemap_lock);
    if (fd < 0) return -errno;
    long page = sysconf(_SC_PAGESIZE);
    off_t offset = (off_t)((uintptr_t)address / (uintptr_t)page) * 8;
    size_t want = count * 8, done = 0;
    while (done < want) {
        ssize_t n = pread(fd, (char *)out + done, want - done, offset + (off_t)done);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -errno;
        }
        if (n == 0) break;
        done += (size_t)n;
    }
    return (long)(done / 8);
}

int ckvm_map_overlay(void *address, size_t size, int fd, uint64_t offset) {
    void *p = mmap(address, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_FIXED, fd, (off_t)offset);
    return p == MAP_FAILED ? -errno : 0;
}

int ckvm_reset_anonymous(void *address, size_t size) {
    void *p = mmap(address, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_FIXED, -1, 0);
    return p == MAP_FAILED ? -errno : 0;
}

int ckvm_prefetch_file(int fd, uint64_t offset, uint64_t length) {
    return posix_fadvise(fd, (off_t)offset, (off_t)length, POSIX_FADV_WILLNEED);
}

#endif
