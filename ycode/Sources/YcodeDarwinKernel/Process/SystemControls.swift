import YcodeDarwinABI

// Small system controls of stage 6. The simulator's processes run
// unprivileged under the host kernel, so Ycode answers as an unprivileged
// caller without entitlements would be answered. Call numbers and op codes
// are xnu's (level 1); the answers are marked with their evidence:
// - memorystatus_control (440): every command is EPERM (no entitlement,
//   not root). Level 3 for the commands runningboardd uses
//   (app-install-launch.md §3.3: "Memorystatus failed" with EPERM on the
//   Mac). The freezer queries SET/GET_PROCESS_IS_FREEZABLE and
//   GET_PROCESS_IS_FROZEN (18, 19, 24) are EINVAL (no freezer): Ycode
//   decision (unverified; a level-3 probe can confirm).
// - quotactl (165): ENOTSUP (no quotas on the volume). Ycode decision
//   (unverified; a level-3 probe can confirm).
// - csrctl (483, csr_check / csr_get_active_config): CSR_SYSCALL_CHECK (0)
//   is EPERM for every mask (configuration protection on); CSR_SYSCALL_GET_
//   ACTIVE_CONFIG (1) writes config 0. Ycode decision (unverified; a
//   level-3 probe can confirm).
// - __persona (494, `kpersona_*`; ops from xnu `sys/persona.h`): no
//   personas exist: GET, INFO, PIDINFO and GETPATH are ESRCH; FIND and
//   FIND_BY_TYPE find none (*idlen = 0); ALLOC, PALLOC, DEALLOC are EPERM.
//   Ycode decision (unverified; a level-3 probe can confirm).

enum SystemControlBSD {
    static let quotactl = 165, memorystatusControl = 440, csrctl = 483, persona = 494
    static let all: Set<Int> = [quotactl, memorystatusControl, csrctl, persona]
}

extension DarwinKernel {
    func systemControlCall(_ n: Int, _ a: [UInt64], _ call: inout String, _ mem: any KernelGuestMemory) throws -> BSDResult {
        func int(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }
        switch n {
        case SystemControlBSD.memorystatusControl:
            call = "memorystatus_control(command=\(int(0)), pid=\(int(1)), flags=\(hx(UInt32(bitPattern: int(2)))), "
                + "buffer=\(hx(a[3])), size=\(a[4]))"
            throw Failure(errno: [18, 19, 24].contains(int(0)) ? Errno.EINVAL : Errno.EPERM)
        case SystemControlBSD.quotactl:
            call = "quotactl(\(hx(a[0])), cmd=\(hx(UInt32(bitPattern: int(1)))), id=\(int(2)))"
            throw Failure(errno: Errno.ENOTSUP)
        case SystemControlBSD.csrctl:
            call = "csrctl(op=\(int(0)), \(hx(a[1])), size=\(a[2]))"
            switch int(0) {
            case 0: throw Failure(errno: Errno.EPERM)
            case 1:
                guard a[2] == 4 else { throw Failure(errno: Errno.EINVAL) }
                try mem.write(va: a[1], bytes: [0, 0, 0, 0])
                return .value(0)
            default: throw Failure(errno: Errno.EINVAL)
            }
        default:  // __persona(op, flags, info, id, idlen, path)
            let op = int(0)
            call = "__persona(op=\(op), flags=\(hx(a[1])), info=\(hx(a[2])), id=\(hx(a[3])), idlen=\(hx(a[4])))"
            switch op {
            case 1, 2, 3: throw Failure(errno: Errno.EPERM)
            case 4, 5, 6, 8: throw Failure(errno: Errno.ESRCH)
            case 7, 9:
                if a[4] != 0 { try mem.write(va: a[4], bytes: [UInt8](repeating: 0, count: 8)) }
                return .value(0)
            default: throw Failure(errno: Errno.EINVAL)
            }
        }
    }
}
