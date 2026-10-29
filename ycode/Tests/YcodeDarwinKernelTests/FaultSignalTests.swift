import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// `processes.md` §2.3.1: the signal a fatal hardware exception ends the
/// process with (what launchd reports as "exited due to SIG…").
struct FaultSignalTests {
    typealias S = DarwinKernel.Signal

    func frame(ec: UInt8, iss: UInt32 = 0) -> TrapFrame {
        TrapFrame(esr: ExceptionSyndrome(ec: ec, iss: iss).raw, kind: TrapFrame.Kind.el0Synchronous.rawValue)
    }

    @Test func mapping() {
        #expect(DarwinKernel.faultSignal(frame(ec: 0x3C, iss: 1)) == S.sigtrap)     // BRK (Swift fatalError, __builtin_trap)
        #expect(DarwinKernel.faultSignal(frame(ec: 0x34)) == S.sigtrap)             // watchpoint
        #expect(DarwinKernel.faultSignal(frame(ec: 0x00)) == S.sigill)              // undefined instruction
        #expect(DarwinKernel.faultSignal(frame(ec: 0x18)) == S.sigill)              // trapped system instruction (CFP RCTX)
        #expect(DarwinKernel.faultSignal(frame(ec: 0x19)) == S.sigill)              // SVE, not enabled
        #expect(DarwinKernel.faultSignal(frame(ec: 0x1D)) == S.sigill)              // SME, not enabled
        #expect(DarwinKernel.faultSignal(frame(ec: 0x2C)) == S.sigfpe)
        #expect(DarwinKernel.faultSignal(frame(ec: 0x24, iss: 0x07)) == S.sigsegv)  // translation fault, level 3
        #expect(DarwinKernel.faultSignal(frame(ec: 0x24, iss: 0x4F)) == S.sigbus)   // permission fault (write)
        #expect(DarwinKernel.faultSignal(frame(ec: 0x24, iss: 0x21)) == S.sigbus)   // alignment fault
        #expect(DarwinKernel.faultSignal(frame(ec: 0x20, iss: 0x06)) == S.sigsegv)  // instruction abort, unmapped
        #expect(DarwinKernel.faultSignal(frame(ec: 0x22)) == S.sigbus)              // PC alignment
        #expect(DarwinKernel.faultSignal(frame(ec: 0x2F)) == S.sigsegv)             // anything else
    }
}
