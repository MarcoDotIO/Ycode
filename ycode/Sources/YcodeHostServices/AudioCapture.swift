// `YCODE_AUDIO_CAPTURE=<path.wav>`: what the guest plays, written as a WAV
// file (16-bit PCM, the device's rate and channels) so tests and boots can
// check that audio really flows (audio-host.md, "Ycode implementation").
// Each IO cycle's output block is mixed in at its place on the host clock,
// so overlapping clients add up; a stretch with no IO longer than a second
// is left out rather than written as silence. The header is brought up to
// date about once a second, so a run that is killed still leaves a
// readable file.

import Foundation

/// Writes the guest's audio output to a WAV file as described above. Not
/// thread-safe: the audio service calls it from its IO path only.
public final class AudioCaptureWriter {
    /// The WAV file being written.
    public let path: String
    /// Frames per second of the file (the device's nominal rate).
    public let sampleRate: Int
    /// Interleaved channels per frame.
    public let channels: Int
    private let handle: FileHandle
    /// Host monotonic ns of capture frame 0 (moved forward over gaps).
    private var baseNs: UInt64?
    /// Frames already in the file.
    public private(set) var writtenFrames: Int64 = 0
    /// Mixed frames not yet written: they cover [writtenFrames, writtenFrames + count).
    private var pending: [Float] = []
    private var framesSinceHeader: Int64 = 0
    /// Statistics: blocks added, samples that were not zero, the peak magnitude.
    public private(set) var blocks = 0
    /// Samples added that were not zero.
    public private(set) var nonZeroSamples = 0
    /// The largest sample magnitude added (1.0 is full scale).
    public private(set) var peak: Float = 0
    /// How long pending audio waits for other clients' blocks before it is written.
    private let holdFrames: Int

    /// Creates (or truncates) the file at `path` and writes an empty header.
    /// Throws `CocoaError(.fileWriteUnknown)` when the file cannot be created
    /// or opened.
    public init(path: String, sampleRate: Int, channels: Int) throws {
        guard FileManager.default.createFile(atPath: path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        guard let h = FileHandle(forWritingAtPath: path) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        self.path = path
        self.sampleRate = sampleRate
        self.channels = channels
        handle = h
        holdFrames = sampleRate / 4
        h.write(Data(Self.header(dataBytes: 0, sampleRate: sampleRate, channels: channels)))
    }

    /// The 44-byte RIFF/WAVE header of a 16-bit PCM file.
    public static func header(dataBytes: UInt32, sampleRate: Int, channels: Int) -> [UInt8] {
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        let blockAlign = UInt16(channels * 2)
        return Array("RIFF".utf8) + le32(36 &+ dataBytes) + Array("WAVE".utf8) + Array("fmt ".utf8) + le32(16) + le16(1)
            + le16(UInt16(channels)) + le32(UInt32(sampleRate)) + le32(UInt32(sampleRate) * UInt32(blockAlign))
            + le16(blockAlign) + le16(16) + Array("data".utf8) + le32(dataBytes)
    }

    /// Adds one block of interleaved samples that the device plays from
    /// host monotonic time `ns`.
    public func add(_ samples: [Float], at ns: UInt64) {
        let frames = samples.count / channels
        guard frames > 0 else { return }
        blocks += 1
        for s in samples where s != 0 {
            nonZeroSamples += 1
            peak = max(peak, abs(s))
        }
        if baseNs == nil { baseNs = ns }
        let end = writtenFrames + Int64(pending.count / channels)
        var position = ns >= baseNs! ? Int64((Double(ns - baseNs!) * Double(sampleRate) / 1e9).rounded()) : 0
        if position > end + Int64(sampleRate) {
            // A gap of more than a second: close it up.
            baseNs! += UInt64(Double(position - end) * 1e9 / Double(sampleRate))
            position = end
        }
        var first = 0
        if position < writtenFrames {
            // Late for frames already written: those are dropped.
            first = Int(writtenFrames - position)
            if first >= frames { return }
            position = writtenFrames
        }
        let offset = Int(position - writtenFrames) * channels
        let needed = offset + (frames - first) * channels
        if pending.count < needed { pending += [Float](repeating: 0, count: needed - pending.count) }
        for i in 0..<((frames - first) * channels) { pending[offset + i] += samples[first * channels + i] }
        // Write what is older than the hold window.
        let pendingFrames = pending.count / channels
        if pendingFrames > holdFrames { write(frames: pendingFrames - holdFrames) }
    }

    private func write(frames: Int) {
        let n = min(frames, pending.count / channels)
        guard n > 0 else { return }
        var out = [UInt8]()
        out.reserveCapacity(n * channels * 2)
        for i in 0..<(n * channels) {
            let v = Int16(max(-1, min(1, pending[i])) * 32767)
            out.append(UInt8(truncatingIfNeeded: v))
            out.append(UInt8(truncatingIfNeeded: v >> 8))
        }
        pending.removeFirst(n * channels)
        handle.write(Data(out))
        writtenFrames += Int64(n)
        framesSinceHeader += Int64(n)
        if framesSinceHeader >= Int64(sampleRate) { updateHeader() }
    }

    private func updateHeader() {
        framesSinceHeader = 0
        let bytes = UInt32(clamping: writtenFrames * Int64(channels) * 2)
        let at = handle.offsetInFile
        handle.seek(toFileOffset: 0)
        handle.write(Data(Self.header(dataBytes: bytes, sampleRate: sampleRate, channels: channels)))
        handle.seek(toFileOffset: at)
    }

    /// Writes everything pending and the final header.
    public func flush() {
        write(frames: pending.count / channels)
        updateHeader()
        try? handle.synchronize()
    }

    /// Flushes and closes the file. The writer must not be used afterwards.
    public func close() {
        flush()
        try? handle.close()
    }
}
