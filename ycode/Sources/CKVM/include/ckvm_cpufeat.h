// CKVM CPU-feature helpers (specs/simulator/cpu-features.md §4.1).
// Original Ycode code over the public Linux KVM API and the Arm
// architecture's EL0-readable registers.
#ifndef CKVM_CPUFEAT_H
#define CKVM_CPUFEAT_H

#include <stdint.h>

#if defined(__linux__) && defined(__aarch64__)

/// Creates a scratch VM with one vCPU initialized as Ycode initializes every
/// vCPU (preferred target, PSCI 0.2 only), reads `count` registers with
/// KVM_GET_ONE_REG (64-bit ids), and destroys the VM. `results[i]` is 0 or
/// the -errno of that read (its value is then 0). Returns 0, or -errno when
/// the VM or the vCPU could not be made.
int ckvm_probe_vcpu_registers(const uint64_t *ids, uint64_t *values, int32_t *results, int count);

/// CTR_EL0 as read at EL0 by this process (Linux lets EL0 read it, or
/// emulates the read).
uint64_t ckvm_host_ctr_el0(void);
/// DCZID_EL0 as read at EL0 (always readable at EL0).
uint64_t ckvm_host_dczid_el0(void);
/// The FPCR trap-enable probe (cpu-features.md §4.2, FP_SyncExceptions):
/// sets IOE, DZE, OFE, UFE, IXE and IDE, reads FPCR back, restores the old
/// value. Returns the trap-enable bits that read back as 1. Runs at EL0 of
/// the host, on the same cores the guest vCPUs run on (KVM does not trap
/// FPCR), with no floating-point operation between the write and the
/// restore.
uint64_t ckvm_host_fpcr_trap_probe(void);

#endif
#endif
