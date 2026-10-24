// CKVM snapshot helpers (specs/simulator/snapshot.md §2.1, §2.2): FP/SIMD
// register access, a thread kick by Linux thread id, and host page residency.
// Linux arm64 only, like the rest of CKVM.
#ifndef CKVM_SNAPSHOT_H
#define CKVM_SNAPSHOT_H

#include <stddef.h>
#include <stdint.h>

#if defined(__linux__) && defined(__aarch64__)

/// KVM_GET_ONE_REG / KVM_SET_ONE_REG of any size (the size is in the id).
int ckvm_get_one_reg_bytes(int vcpu_fd, uint64_t reg_id, void *buffer);
int ckvm_set_one_reg_bytes(int vcpu_fd, uint64_t reg_id, const void *buffer);

/// Register ids: V0…V31 (128-bit), FPSR and FPCR (32-bit).
uint64_t ckvm_reg_fp_v(unsigned n);
uint64_t ckvm_reg_fpsr(void);
uint64_t ckvm_reg_fpcr(void);

/// The FP/SIMD state as 32 × 16 bytes of V registers, then FPSR and FPCR
/// (u32 each): 520 bytes. Returns 0 or -errno.
enum { CKVM_FP_STATE_SIZE = 32 * 16 + 8 };
int ckvm_get_fp_state(int vcpu_fd, uint8_t *out);
int ckvm_set_fp_state(int vcpu_fd, const uint8_t *in);

/// tgkill(getpid(), tid, signo). Returns 0 or -errno.
int ckvm_kick_tid(long tid, int signo);

/// mincore over [address, address+size) (address host-page aligned): one byte
/// per host page in `vec`, bit 0 = resident. Returns 0 or -errno.
int ckvm_mincore(const void *address, size_t size, uint8_t *vec);

/// /proc/self/pagemap entries for the host pages of [address, address+size):
/// `count` u64 entries (bit 63 present, bit 62 swapped, bit 61 file-page or
/// shared-anonymous). Returns the number of entries read or -errno.
long ckvm_pagemap(const void *address, size_t count, uint64_t *out);

/// Lazy restore (snapshot.md §6.3): maps `size` bytes of `fd` at `offset`
/// over [address, address+size) as a private, writable, copy-on-write
/// mapping (MAP_PRIVATE | MAP_FIXED). The pages are read from the file when
/// first touched. Returns 0 or -errno.
int ckvm_map_overlay(void *address, size_t size, int fd, uint64_t offset);

/// Replaces [address, address+size) with fresh anonymous zero memory
/// (MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_FIXED): the discard of
/// memory that may hold an overlay, where MADV_DONTNEED would bring the
/// file's bytes back instead of zeros. Returns 0 or -errno.
int ckvm_reset_anonymous(void *address, size_t size);

/// posix_fadvise(fd, offset, length, POSIX_FADV_WILLNEED). Returns 0 or an errno.
int ckvm_prefetch_file(int fd, uint64_t offset, uint64_t length);

#endif
#endif
