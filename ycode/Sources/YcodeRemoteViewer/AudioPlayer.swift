// The viewer's side of the device's sound (display-stream.md §15): packets
// are decoded (Opus, with loss concealment and in-band FEC, or PCM) and
// placed on the output's sample timeline at their play time: the server's
// play time mapped to this machine's clock (ClockSync) plus a fixed target
// delay. The video is presented as soon as it is decoded; the audio keeps
// the device's own timing, delayed by the target, so the A/V offset is the
// target minus the video's capture → presented time (both measured).
//
// The output is PulseAudio's simple API (PipeWire's pulse server on current
// desktops), or a null output paced by the monotonic clock; either can also
// be written to a WAV file (what was sent to the speaker, for checks).
// Clock drift between the output device and the monotonic clock is taken up
// by placing each packet where its play time says, snapping it to the end
// of the previous packet when within 2 ms (no clicks), and re-placing it
// when the two have drifted further apart (a small jump; resampling is
// follow-up work).

import CYcodeCodec
import Foundation
import YcodeDisplayStream

public final class AudioPlayer: @unchecked Sendable {
    public static let rate = 48_000, channels = 2
    public enum Output: String, Sendable { case pulse, null }

    public let output: Output
    /// Added to each packet's play time (ms).
    public let targetMilliseconds: Double
    public var muted = false
    public var volume: Float = 1

    private let lock = NSLock()
    private var ring: [Float]
    private let ringFrames = 48_000 * 2
    /// The next frame index to be written to the output, and when it plays (client ns).
    private var writeIndex: Int64 = 0
    private var writeIndexPlaysAt: UInt64 = 0
    private var started = false
    private var stopped = false
    private var lastEnd: Int64?
    /// Delay added on top of the target when packets came too late for the
    /// output's own latency (ns; grows, never shrinks within a session).
    public private(set) var extraDelay: UInt64 = 0
    /// The output's latency last measured (ns).
    public private(set) var outputLatency: UInt64 = 0
    private var decoder: UnsafeMutableRawPointer?
    private var lastServerEnd: UInt64?
    private var pulse: UnsafeMutableRawPointer?
    private var wav: FileHandle?
    private var wavFrames = 0
    private let wavPath: String?
    public var log: @Sendable (String) -> Void = { _ in }

    // Statistics.
    public private(set) var packets = 0, lostPackets = 0, latePackets = 0, concealed = 0, recovered = 0, resyncs = 0, underrunChunks = 0
    /// Per packet: ms between its arrival and its (target) play time on this machine's clock.
    public private(set) var margins: [Double] = []
    /// Per packet: ms between the server's play time (mapped) and the arrival (negative: early).
    public private(set) var arrivals: [Double] = []
    /// The first audible frame: when it reached the speaker queue and when it plays.
    public private(set) var firstSound: (written: UInt64, plays: UInt64, serverPlay: UInt64)?
    /// When sound starts after at least 50 ms of silence: the time it plays (client ns).
    public var onsets: [UInt64] { lock.withLock { onsetTimes } }
    private var onsetTimes: [UInt64] = []

    public init(output: Output, targetMilliseconds: Double = 10, wavPath: String? = nil) {
        self.output = output
        self.targetMilliseconds = targetMilliseconds
        self.wavPath = wavPath
        ring = [Float](repeating: 0, count: 48_000 * 2 * 2)
    }

    deinit { ycodec_opus_decoder_free(decoder) }

    /// The codecs to ask the server for, best first.
    public static var codecs: [String] { (ycodec_opus_available() != 0 ? ["opus"] : []) + ["pcm"] }

    /// Opens the output and starts the writer thread; false when the pulse output cannot open.
    @discardableResult
    public func start() -> Bool {
        if output == .pulse {
            pulse = ycodec_pulse_open("Ycode Simulator", "device sound", Int32(Self.rate), Int32(Self.channels), 20)
            guard pulse != nil else { log("audio: no PulseAudio/PipeWire output; sound off"); return false }
        }
        if let wavPath {
            FileManager.default.createFile(atPath: wavPath, contents: Self.wavHeader(frames: 0))
            wav = FileHandle(forWritingAtPath: wavPath)
            wav?.seekToEndOfFile()
        }
        let t = Thread { [weak self] in self?.writer() }
        t.name = "audio-out"
        t.qualityOfService = .userInteractive
        t.start()
        return true
    }

    public func stop() {
        lock.withLock { stopped = true }
        finishWAV()
    }

    // MARK: Packets (connection thread)

    /// A packet that arrived at client time `arrival`; `clientPlay` is its
    /// play time on this machine's clock (nil before the clock is known: dropped).
    public func receive(_ a: DisplayAudio, arrival: UInt64, clientPlay: UInt64?) {
        guard a.channels == Self.channels, a.sampleRate == Self.rate, a.frames > 0, a.frames <= 5760 else { return }
        var pcm = [Float](repeating: 0, count: a.frames * Self.channels)
        var fecPCM: [Float]?
        switch a.codec {
        case .pcm16:
            guard a.data.count >= a.frames * Self.channels * 2 else { return }
            for i in 0..<(a.frames * Self.channels) { pcm[i] = Float(Int16(bitPattern: UInt16(a.data[2 * i]) | UInt16(a.data[2 * i + 1]) << 8)) / 32768 }
        case .opus:
            if decoder == nil { decoder = ycodec_opus_decoder_new(Int32(Self.rate), Int32(Self.channels)) }
            guard let decoder else { return }
            // One packet missing just before this one (by play time): recover it from this one's FEC.
            let frameNs = UInt64(a.frames) * 1_000_000_000 / UInt64(Self.rate)
            if let prev = lastServerEnd, a.playTime > prev + frameNs / 2, a.playTime < prev + frameNs * 3 / 2 {
                var f = [Float](repeating: 0, count: a.frames * Self.channels)
                let n = a.data.withUnsafeBufferPointer { ycodec_opus_decode(decoder, $0.baseAddress, Int32($0.count), &f, Int32(a.frames), 1) }
                if n > 0 { fecPCM = f; lock.withLock { recovered += 1 } }
            }
            let n = a.data.withUnsafeBufferPointer { ycodec_opus_decode(decoder, $0.baseAddress, Int32($0.count), &pcm, Int32(a.frames), 0) }
            guard n == Int32(a.frames) else { return }
        }
        lastServerEnd = a.playTime + UInt64(a.frames) * 1_000_000_000 / UInt64(Self.rate)
        guard let clientPlay else { return }
        lock.lock()
        defer { lock.unlock() }
        // The earliest a frame placed now can play is the output's latency
        // away: a packet that would be late moves the whole sound later
        // (an adaptive jitter buffer that only grows; at most 200 ms).
        var play = clientPlay + UInt64(targetMilliseconds * 1e6) + extraDelay
        if started, play < writeIndexPlaysAt + 2_000_000, extraDelay < 200_000_000 {
            extraDelay = min(200_000_000, extraDelay + (writeIndexPlaysAt + 2_000_000 - play))
            play = clientPlay + UInt64(targetMilliseconds * 1e6) + extraDelay
            log(String(format: "audio: the sound plays %.1f ms after its device time (target %.0f ms + %.1f ms for the output)",
                       Double(play - clientPlay) / 1e6, targetMilliseconds, Double(extraDelay) / 1e6))
        }
        packets += 1
        margins.append((Double(play) - Double(arrival)) / 1e6)
        arrivals.append((Double(arrival) - Double(clientPlay)) / 1e6)
        if margins.count > 100_000 { margins.removeFirst(50_000); arrivals.removeFirst(50_000) }
        guard started else { return }
        let frameNs = 1e9 / Double(Self.rate)
        var index = writeIndex + Int64(((Double(play) - Double(writeIndexPlaysAt)) / frameNs).rounded())
        if let end = lastEnd {
            let gap = index - end
            if abs(gap) <= Int64(Self.rate / 500) { index = end }          // within 2 ms: continuous
            else if abs(gap) < Int64(Self.rate / 50) { resyncs += 1 }       // 2–20 ms: drift, re-placed (a gap after silence is not counted)
        }
        if let f = fecPCM, index - Int64(a.frames) >= writeIndex { place(f, at: index - Int64(a.frames)) }
        if index < writeIndex {
            // Its time has passed (partly): keep what is still ahead.
            latePackets += 1
            let skip = Int(writeIndex - index)
            guard skip < a.frames else { lastEnd = index + Int64(a.frames); return }
            place(Array(pcm[(skip * Self.channels)...]), at: writeIndex)
        } else {
            place(pcm, at: index)
        }
        lastEnd = index + Int64(a.frames)
        if firstSound == nil, pcm.contains(where: { abs($0) > 1e-4 }) {
            firstSound = (arrival, play, clientPlay)
        }
    }

    /// Writes frames into the ring at a timeline index (under the lock).
    private func place(_ pcm: [Float], at index: Int64) {
        let frames = pcm.count / Self.channels
        guard index + Int64(frames) - writeIndex < Int64(ringFrames) else { return }  // too far ahead
        for f in 0..<frames {
            let slot = Int((index + Int64(f)) % Int64(ringFrames)) * Self.channels
            ring[slot] = pcm[f * 2]
            ring[slot + 1] = pcm[f * 2 + 1]
        }
    }

    // MARK: Output (writer thread)

    private func writer() {
        let chunk = 240  // 5 ms
        var buffer = [Float](repeating: 0, count: chunk * Self.channels)
        let started0 = viewerNanoseconds()
        var written: Int64 = 0
        var prevAudible = false
        var silentSince: UInt64 = 0
        while !lock.withLock({ stopped }) {
            let now = viewerNanoseconds()
            // When the next frame written will play.
            let latency: UInt64
            if let pulse {
                let l = ycodec_pulse_latency_us(pulse)
                latency = l > 0 ? UInt64(l) * 1000 : 0
            } else {
                latency = 0
            }
            var audible = false
            lock.withLock {
                if !started { started = true; writeIndex = 0 }
                writeIndexPlaysAt = now + latency
                outputLatency = latency
                for f in 0..<chunk {
                    let slot = Int((writeIndex + Int64(f)) % Int64(ringFrames)) * Self.channels
                    buffer[f * 2] = ring[slot]
                    buffer[f * 2 + 1] = ring[slot + 1]
                    ring[slot] = 0
                    ring[slot + 1] = 0
                }
                writeIndex += Int64(chunk)
                audible = buffer.contains { abs($0) > 0.01 }
                if audible, !prevAudible, writeIndexPlaysAt > silentSince + 50_000_000 {
                    // Where in the chunk the sound starts.
                    let first = (0..<chunk).first { abs(buffer[$0 * 2]) > 0.01 || abs(buffer[$0 * 2 + 1]) > 0.01 } ?? 0
                    onsetTimes.append(writeIndexPlaysAt + UInt64(first) * 1_000_000_000 / UInt64(Self.rate))
                }
                if audible { silentSince = writeIndexPlaysAt + UInt64(chunk) * 1_000_000_000 / UInt64(Self.rate) }
                // Sound stopped although later sound is already placed: a hole (late or lost packets).
                if !audible, prevAudible, let end = lastEnd, end > writeIndex { underrunChunks += 1 }
            }
            prevAudible = audible
            let gain: Float = muted ? 0 : volume
            if gain != 1 { for i in buffer.indices { buffer[i] *= gain } }
            if let wav {
                var d = [UInt8](repeating: 0, count: buffer.count * 2)
                for i in buffer.indices {
                    let v = Int16(max(-32768, min(32767, (buffer[i] * 32767).rounded())))
                    d[2 * i] = UInt8(truncatingIfNeeded: v)
                    d[2 * i + 1] = UInt8(truncatingIfNeeded: v >> 8)
                }
                wav.write(Data(d))
                wavFrames += chunk
            }
            if let pulse {
                _ = buffer.withUnsafeBufferPointer { ycodec_pulse_write(pulse, $0.baseAddress, Int32(chunk), Int32(Self.channels)) }
            } else {
                // Real time: the null output plays chunk k at started0 + k × 5 ms.
                written += Int64(chunk)
                let due = started0 + UInt64(written) * 1_000_000_000 / UInt64(Self.rate)
                let n = viewerNanoseconds()
                if due > n + 5_000_000 { usleep(UInt32((due - n - 5_000_000) / 1000)) }
            }
        }
        if let pulse { ycodec_pulse_close(pulse) }
    }

    // MARK: WAV

    static func wavHeader(frames: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(frames * channels * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(rate)); u32(UInt32(rate * channels * 2))
        u16(UInt16(channels * 2)); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        return d
    }

    private func finishWAV() {
        guard let wav else { return }
        wav.seek(toFileOffset: 0)
        wav.write(Self.wavHeader(frames: wavFrames))
        try? wav.close()
        self.wav = nil
    }

    /// One line of statistics.
    public var summary: String {
        lock.withLock {
            "audio: \(packets) packets, \(latePackets) late, \(recovered) recovered by FEC, \(resyncs) re-placed, \(underrunChunks) holes; "
                + String(format: "plays %.1f ms after device time (output latency %.1f ms); ", targetMilliseconds + Double(extraDelay) / 1e6, Double(outputLatency) / 1e6)
                + "arrival vs play time " + StageSummary.describe(arrivals) + "; margin to play " + StageSummary.describe(margins)
        }
    }
}
