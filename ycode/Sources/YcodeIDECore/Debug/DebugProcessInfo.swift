import Foundation

/// What the Debug navigator shows about the debugged process.
public struct DebugProcessInfo: Equatable {
    public var product: String
    public var pid: Int?
    public var gauges: ProcessGauges
    public init(product: String, pid: Int?, gauges: ProcessGauges = ProcessGauges()) {
        self.product = product
        self.pid = pid
        self.gauges = gauges
    }
}
