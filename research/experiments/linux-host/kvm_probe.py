#!/usr/bin/env python3
"""Read the guest-visible arm64 ID registers through KVM, without running a guest.

Reports which translation granules (4K/16K/64K pages) and VA/PA sizes a KVM
guest can use, which decides whether Darwin's 16 KB-page layout can be
reproduced inside a VM. Usage: python3 -I kvm_probe.py
"""
import ctypes, fcntl, os, struct

KVM_CREATE_VM = 0xAE01
KVM_CREATE_VCPU = 0xAE41
KVM_ARM_PREFERRED_TARGET = 0x8020AEAF
KVM_ARM_VCPU_INIT = 0x4020AEAE
KVM_GET_ONE_REG = 0x4010AEAB


def sysreg(op0, op1, crn, crm, op2):
    return 0x6000000000000000 | 0x0030000000000000 | 0x0013_0000 | (op0 << 14) | (op1 << 11) | (crn << 7) | (crm << 3) | op2


def get(vcpu, reg):
    val = ctypes.c_uint64()
    arg = struct.pack("QQ", reg, ctypes.addressof(val))
    fcntl.ioctl(vcpu, KVM_GET_ONE_REG, arg)
    return val.value


kvm = os.open("/dev/kvm", os.O_RDWR)
vm = fcntl.ioctl(kvm, KVM_CREATE_VM, 0)
init = bytearray(32)
fcntl.ioctl(vm, KVM_ARM_PREFERRED_TARGET, init)
vcpu = fcntl.ioctl(vm, KVM_CREATE_VCPU, 0)
fcntl.ioctl(vcpu, KVM_ARM_VCPU_INIT, bytes(init))

mmfr0 = get(vcpu, sysreg(3, 0, 0, 7, 0))   # ID_AA64MMFR0_EL1
mmfr2 = get(vcpu, sysreg(3, 0, 0, 7, 2))   # ID_AA64MMFR2_EL1
pfr0 = get(vcpu, sysreg(3, 0, 0, 4, 0))    # ID_AA64PFR0_EL1
isar1 = get(vcpu, sysreg(3, 0, 0, 6, 1))   # ID_AA64ISAR1_EL1
f = lambda v, lo: (v >> lo) & 0xF
pa_bits = {0: 32, 1: 36, 2: 40, 3: 42, 4: 44, 5: 48, 6: 52}.get(f(mmfr0, 0), "?")
print(f"ID_AA64MMFR0_EL1 = {mmfr0:#018x}")
print(f"  PARange: {pa_bits}-bit physical")
print(f"  TGran4:  {'yes' if f(mmfr0, 28) in (0, 1) else 'no'}")
print(f"  TGran16: {'yes' if f(mmfr0, 20) in (1, 2) else 'no'}  (raw {f(mmfr0, 20)})")
print(f"  TGran64: {'yes' if f(mmfr0, 24) == 0 else 'no'}")
print(f"ID_AA64MMFR2_EL1 VARange: {'52-bit' if f(mmfr2, 16) else '48-bit'} virtual")
print(f"ID_AA64PFR0_EL1 EL0: {'AArch64+AArch32' if f(pfr0, 0) == 2 else 'AArch64 only'}")
print(f"ID_AA64ISAR1_EL1 pointer auth (APA/API): {f(isar1, 4)}/{f(isar1, 8)}")
for fd in (vcpu, vm, kvm):
    os.close(fd)
