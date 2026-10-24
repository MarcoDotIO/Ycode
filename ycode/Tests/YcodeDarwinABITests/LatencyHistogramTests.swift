import Testing
@testable import YcodeDarwinABI

@Suite struct LatencyHistogramTests {
    @Test func bucketsArePowerOfTwoQuarters() {
        #expect(LatencyHistogram.bucket(1024) == 40)
        #expect(LatencyHistogram.bucket(1280) == 41)
        #expect(LatencyHistogram.bucket(2047) == 43)
        #expect(LatencyHistogram.lowerBound(41) == 1280)
        for ns: UInt64 in [3, 17, 1000, 123_456, 9_999_999_999] {
            let b = LatencyHistogram.bucket(ns)
            #expect(LatencyHistogram.lowerBound(b) <= Double(ns))
            #expect(LatencyHistogram.lowerBound(b + 1) > Double(ns))
        }
    }

    @Test func percentilesAndSummary() {
        let h = LatencyHistogram("t")
        for i in 1...100 { h.add(UInt64(i) * 1000) }
        #expect(h.count == 100)
        #expect(h.maxNanoseconds == 100_000)
        let p50 = h.percentile(0.5)
        #expect(p50 >= 40_000 && p50 <= 50_000)
        #expect(h.percentile(0.99) <= 99_000)
        #expect(h.summary.hasPrefix("t: n 100"))
    }
}
