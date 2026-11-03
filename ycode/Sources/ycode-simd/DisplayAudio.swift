// The device's sound on the display stream (display-stream.md §15): the
// audio service's output blocks (`AudioHostService.deliver`: 512 frames of
// 48 kHz Float32 stereo with their host play time) are cut into 5 ms
// packets, encoded with Opus (low delay, in-band FEC; libopus loaded at run
// time) or sent as 16-bit PCM, and sent with their play time on the
// server's monotonic clock, the clock of the frame timings. Silent packets
// are not sent. The audio service's thread only queues; encoding and
// sending happen on this pipe's thread.

#if os(Linux) && arch(arm64)
import CYcodeCodec
import Foundation
import YcodeDisplayStream

final class DisplayAudioPipe: @unchecked Sendable {
    static let rate = 48_000, channels = 2, packetFrames = 240  // 5 ms
    let codec: DisplayAudio.Codec
    private let send: (DisplayMessage) -> Bool
    private let cond = NSCondition()
    private var queue: [([Float], UInt64)] = []
    private var stopped = false
    private var encoder: UnsafeMutableRawPointer?
    // Statistics.
    private(set) var packetsSent = 0, silentSkipped = 0, bytesSent = 0, dropped = 0

    /// Opus when both sides have it and the client lists it first, else PCM.
    static func choose(client: [String]?) -> DisplayAudio.Codec? {
        guard let client, !client.isEmpty else { return nil }
        for c in client {
            if c == "opus", ycodec_opus_available() != 0 { return .opus }
            if c == "pcm" { return .pcm16 }
        }
        return nil
    }

    static var serverCodecs: [String] { (ycodec_opus_available() != 0 ? ["opus"] : []) + ["pcm"] }

    init(codec: DisplayAudio.Codec, bitrate: Int = 96_000, send: @escaping (DisplayMessage) -> Bool) {
        self.codec = codec
        self.send = send
        if codec == .opus { encoder = ycodec_opus_encoder_new(Int32(Self.rate), Int32(Self.channels), Int32(bitrate)) }
        let t = Thread { [weak self] in self?.run() }
        t.name = "display-audio"
        t.qualityOfService = .userInteractive
        t.start()
    }

    deinit { ycodec_opus_encoder_free(encoder) }

    /// From the audio service's thread: never blocks on the network.
    func push(_ samples: [Float], at: UInt64) {
        cond.withLock {
            // A stalled connection must not grow the queue: keep at most 200 ms.
            if queue.count > 20 { queue.removeFirst(); dropped += 1 }
            queue.append((samples, at))
            cond.signal()
        }
    }

    func stop() { cond.withLock { stopped = true; cond.signal() } }

    private func run() {
        var pending: [Float] = []
        var pendingAt: UInt64 = 0   // play time of pending[0]
        let frameNs = { (frames: Int) -> UInt64 in UInt64(frames) * 1_000_000_000 / UInt64(Self.rate) }
        var out = [UInt8](repeating: 0, count: 4000)
        while true {
            let batch = cond.withLock { () -> [([Float], UInt64)]? in
                while queue.isEmpty && !stopped { cond.wait() }
                if stopped { return nil }
                defer { queue.removeAll() }
                return queue
            }
            guard let batch else { return }
            for (samples, at) in batch {
                // A block that does not continue the pending audio (a gap, a restart) starts afresh.
                let expected = pendingAt &+ frameNs(pending.count / Self.channels)
                if pending.isEmpty || at > expected &+ 1_000_000 || expected > at &+ 1_000_000 {
                    pending.removeAll(keepingCapacity: true)
                    pendingAt = at
                }
                pending += samples
                while pending.count >= Self.packetFrames * Self.channels {
                    let n = Self.packetFrames * Self.channels
                    let at = pendingAt
                    let packet = pending.withUnsafeBufferPointer { Array($0[0..<n]) }
                    pending.removeFirst(n)
                    pendingAt &+= frameNs(Self.packetFrames)
                    if !packet.contains(where: { $0 != 0 }) { silentSkipped += 1; continue }
                    let data: [UInt8]
                    switch codec {
                    case .opus:
                        let k = packet.withUnsafeBufferPointer { ycodec_opus_encode(encoder, $0.baseAddress, Int32(Self.packetFrames), &out, Int32(out.count)) }
                        guard k > 0 else { continue }
                        data = Array(out[0..<Int(k)])
                    case .pcm16:
                        var d = [UInt8](repeating: 0, count: n * 2)
                        for i in 0..<n {
                            let v = Int16(max(-32768, min(32767, (packet[i] * 32767).rounded())))
                            d[2 * i] = UInt8(truncatingIfNeeded: v)
                            d[2 * i + 1] = UInt8(truncatingIfNeeded: v >> 8)
                        }
                        data = d
                    }
                    guard send(.audio(DisplayAudio(playTime: at, codec: codec, channels: Self.channels, frames: Self.packetFrames, data: data))) else {
                        return
                    }
                    packetsSent += 1
                    bytesSent += data.count
                }
            }
        }
    }
}
#endif
