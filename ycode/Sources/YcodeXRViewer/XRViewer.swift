// `ycode-xr-viewer` (specs/simulator/xr-viewer.md): a visionOS device of a
// simulator host, viewed in an OpenXR headset. The stream client and the
// link are the remote viewer's (display-stream.md, sim-link.md); the
// headset's tracking becomes visionOS input through `XRInputMapper`; the
// guest's pictures go to the headset as one projection layer, each eye's
// image with the pose and field of view the guest rendered it for, so the
// runtime's reprojection corrects the head motion since.
//
// Modes: live (OpenXR), `--replay <script>` (the OpenXR-free stand-in: a
// recorded or written tracking script drives the same mapping and stream),
// `--probe` (phase 1: what the runtime and headset offer).

import CYcodeCodec
import Foundation
import YcodeDisplayStream
import YcodeRemoteViewer

public struct XRViewerOptions: Sendable {
    public var connect: String?
    public var linkDevice: String?
    public var linkHost: String?
    /// Frames by UDP on the link (`--media udp`). TCP by default: a video keyframe is
    /// hundreds of datagrams, and one lost costs a whole new keyframe (xr-viewer.md §7).
    public var media = false
    public var stereo = false
    /// "synth" (the default with re-projection), "adaptive", "alternate" or "mono" (xr-viewer.md §4, xr-depth.md §6).
    public var stereoMode = "synth"
    public var latch: Int?
    public var settleMs: Int?
    public var pointer = XRInputMapper.Pointer.auto
    public var palmOrientation = false
    /// The wearer's hands drawn over the picture (§5.1): "rendered" or "off".
    public var hands = "rendered"
    /// The thumbstick turns the immersion (§5); `--no-immersion` turns it
    /// off (it hung Ycode's GPU translation before GPU-SIRI's fix, §9.2).
    public var immersion = true
    /// Foveated streaming (§4.5): the full-resolution inset's share of each side (0: off).
    public var foveaFraction = 0.0
    /// Eye pictures turned outwards (degrees, §4.6).
    public var eyeYaw = 0.0
    private var downscaleGiven = false
    private var stereoGiven = false
    /// The stream's encoding (display-stream.md §14): nil is auto, the best
    /// both ends have; a name is the first wish, what comes after it the fallback.
    public var encoding: String?
    /// Video: constant QP (the default), or by bit rate with `--video-bitrate` (§14).
    public var videoQP = 20
    public var videoBitrate: Int?
    public var videoFPS = 30
    public var quality = 80
    public var downscale = 1
    public var fps = 120
    public var seconds: Double?
    public var replay: String?
    /// The headset's session with a script's tracking instead of the
    /// headset's (the whole display path without a wearer, §9).
    public var drive: String?
    /// The tracking as a script (`--record-tracking`).
    public var recordTracking: String?
    /// What the left eye sees, as an MP4 (`--record`, §7.1), and whether the gaze cursor is drawn into it.
    public var recordVideo: String?
    public var recordCursor = false
    public var recordFPS = 30
    public var recordKbps = 1000
    public var probe = false
    public var probeSession = false
    public var measure: String?
    /// Per received frame: its tag and a grey thumbnail of its view's canvas
    /// (tests of the latch depth, xr-viewer.md §6).
    public var dump: String?
    public var verbose = false
    /// Switching's control file (§7.2, XRControl).
    public var stateFile: String?
    /// Depth re-projection (xr-depth.md §7): nil = on when the server sends depth.
    public var reproject: Bool?
    /// The depth's downscale against the picture (2, 4, 8).
    public var depthDownscale = 4
    /// Depth texels per grid cell of the re-projection mesh.
    public var depthGridStep = 1
    /// The world cache's face size (0: none).
    public var cacheFaceSize = 2048
    /// The cache takes every picture (`--cache-all`), not only those of a settled pose.
    public var cacheAll = false
    /// How long the head must have held a picture's pose before the cache takes it (ms).
    public var settleWindowMs = 300
    /// …and the head must have held still from this long before the picture arrived (ms).
    public var holdMs = 800
    /// Replay with --reproject on: a PNG of the right eye every 2 s into this folder.
    public var reprojectShots: String?
    /// Replay with --reproject on: the offscreen eye size (the Quest Pro's recommended 2700 × 2970 for timing).
    public var offscreenSize = (1350, 1485)
    /// The environment's turn about +Y (degrees) when the server does not know it, and its exposure.
    public var environmentYaw: Double?
    public var environmentGain: Double?
    /// Ask the server for the room's environment (`--environment off`: no backdrop).
    public var environment = true
    /// The camera sweep over the whole sphere at the start and after a recentre (xr-depth.md §5.5).
    public var sweep = true
    /// A sweep stop's longest wait for its picture (ms).
    public var sweepStopMs = 2500
    /// The gaze path (`XRGazeSettings`, xr-viewer.md §13) and the pinch.
    public var gaze = XRGazeSettings()
    public var pinchOnCentimetres = 2.0, pinchOffCentimetres = 3.5, pinchSlopMillimetres = 12.0
    public var handHoldMs = 200
    /// An extended index finger is a direct touch (`allowDirect`).
    public var poke = true
    /// A reticle at the point the viewer sends (`--gaze-dot`), and the bias targets (`--gaze-calibrate`).
    public var gazeDot = false, gazeCalibrate = false
    /// The gaze at the frame's predicted display time (the default) or at the present (`--gaze-time now`).
    public var gazeAtPresent = false
    /// The camera holds within this much of the head (xr-depth.md §5.5).
    public var holdBandDegrees = 3.0, holdBandCentimetres = 2.0
    /// A picture goes on top this long after the camera came to rest, before it is final (ms, 0: only once final).
    public var freshTopMs = 350
    /// …and while the camera moves slower than this (degrees per second; the same in dm/s; 0: only at rest).
    public var freshTopSpeed = 20.0
    /// Replay: per picture, its tag's yaw and a row of it (how far the tag is from what the picture shows, offline).
    public var tagProbe: String?
    /// At most this many frames unacknowledged (display-stream.md §4.2; 0: no window).
    public var frameWindow = 3
    /// `--upload bgrx`: the picture through a BGRX copy on one thread, the path of run 8 (comparison).
    public var uploadViaBGRX = false
    /// Diagnostic: the stream's thread sleeps this long after each picture (a consumer slower than the guest, §13.2).
    public var slowConsumerMs = 0
    /// Replay: per dwell of a written script, where the guest's picture changed against where the ray points.
    public var hoverProbe: String?
    /// `--stereo synth`: both eyes made from one view by re-projection.
    public var synthStereo: Bool { stereoMode == "synth" }

    public init() {}

    public static let usage = """
        usage: ycode-xr-viewer [--connect <address> | --link <device> [--host <name>] [--media udp|tcp]]
                               [--stereo synth|adaptive|alternate|mono] [--latch N] [--settle MS] [--pointer auto|eyes|controller|head] [--palm] [--hands rendered|light|off] [--no-immersion] [--foveate [fraction]] [--eye-yaw deg]
                               [--encoding auto|hevc444|hevc|h264|jpeg|zlib] [--video-qp N] [--video-bitrate kbps] [--video-fps N] [--quality Q] [--downscale N] [--fps N] [--seconds S]
                               [--replay <script.jsonl>] [--record <file.mp4> [--record-cursor] [--record-fps N] [--record-bitrate kbps]] [--record-tracking <script.jsonl>] [--measure <file.tsv>] [--dump <file>] [--state-file <file>] [--verbose]
                               [--gaze-dot] [--gaze-calibrate] [--gaze-filter fixation|oneeuro|raw] [--gaze-cutoff Hz] [--gaze-snap deg] [--gaze-deadband deg] [--gaze-hold ms] [--gaze-time display|now]
                               [--pinch-rewind ms] [--pinch-freeze on|off] [--pinch-on cm] [--pinch-off cm] [--pinch-slop mm] [--hand-hold ms] [--poke on|off]
                               [--hold-band deg[,cm]] [--fresh-top ms] [--fresh-top-speed deg/s] [--frame-window N] [--upload planes|bgrx] [--hover-probe <file.tsv>]
               ycode-xr-viewer --probe [--session]
          A visionOS device in an OpenXR headset (Linux; the Khronos loader and the active runtime, e.g. WiVRn).
          --encoding   the stream: auto (default) takes the best both ends have, hevc444 > hevc > h264 > jpeg > zlib; a fallback always warns
          --video-qp   video at this constant QP (default 20; lower is sharper)   --video-bitrate kbit/s  CBR instead, one picture of VBV at --video-fps (30)
          --stereo     synth (the default when the server sends depth; without depth it is mono): both eyes re-projected from one
                       view at the headset's rate, xr-depth.md §6; adaptive (the default with --reproject off): one view while
                       the head moves, the left and right eye in turn while it is still; alternate: always the eyes in turn;
                       mono: one view for both eyes
          --latch      mono: pictures between a pose and the picture that shows it (the server's default, 1)
          --settle     alternate stereo: the least ms a pose has before its picture is taken (the server's default, 170)
          --reproject  on|off: re-project every headset frame with the stream's depth (default: on when the server sends depth),
                       the room's environment and a world cache filling everything around the guest's 90° view
          --depth N    depth at 1/N of the picture (2, 4 default, 8)   --grid N  depth texels per mesh cell (1)
          --cache N    world cache face size (2048; 0: none)   --env-yaw D, --env-gain G  the environment's turn and exposure
          --sweep      on (default with one view): at the start and after a recentre the guest's camera visits the whole sphere
                       once, a few seconds, so the world cache holds the room everywhere; off: it fills only where the wearer looks
          --pointer    what selects: the eyes when the headset tracks them (auto), a controller's ray, or the head
          --palm       send the palm's orientation for the hands (default: the head's)
          --hands      draw the wearer's tracked hands over the picture (rendered, the default) or not (off)
          --no-immersion  the thumbstick does not turn the immersion
          --eye-yaw    eye pictures turned outwards by deg (about 7 for the Quest Pro's per-eye frustum; only for adaptive and
                       alternate: with one view, as in synth, the camera is never turned)
          --foveate    the whole picture at half resolution plus a full-resolution inset around the gaze
                       (fraction of each side, default 0.35; the gaze point goes only to the server, never to a log)
          --replay     no headset: drive the stream with a tracking script (JSON lines of XRTrackingSample)
          --drive      the headset's session, but the tracking from a script (looped): the display path without a wearer
          --gaze-dot   a small ring at the point the viewer sends to the guest, on the surface it meets: cyan tracking, orange a dropout's held ray, green a pinch's ray
          --gaze-calibrate  after the sweep, five white rings to look at (a moment each): the tracker's constant error is taken off (the log gives only its size)
          --gaze-filter  fixation (default: steady on a fixation, none on a saccade, in the frame the eyes hold), oneeuro (runs 5-8), raw
          --gaze-cutoff  the fixation filter's smoothing (3 Hz)   --gaze-snap deg  a larger error for two samples is a saccade (1.0)   --gaze-deadband deg  (0.1)
          --gaze-hold  a dropout holds the last ray this long (350 ms)   --gaze-time now  locate the gaze at the present, not ahead at the display time
          --pinch-rewind  a pinch this soon after a saccade selects what the eyes left (70 ms; 0 off)   --pinch-freeze  the ray stays at the pinch's place until the release (on)
          --pinch-on, --pinch-off  thumb to index, cm (2.0, 3.5)   --pinch-slop  dead zone of a pinch's hand, mm (12)   --hand-hold  a lost hand stays this long (200 ms)
          --poke       an extended index finger is a direct touch (on)
          --hold-band  the camera stays while the head is within deg[,cm] of it (3,2; runs up to 8: 1.5,1.5)
          --fresh-top  a picture goes on top this long after the camera rests, before it is final (350 ms; 0: only once final, as run 8)
          --fresh-top-speed  …and while the camera moves slower than this (20 deg/s, and as many cm/s; 0: only at rest; above it the picture is under the cache)
          --frame-window  at most N frames unacknowledged, so no queue forms behind a slow viewer (3; 0 off)
          --upload     planes (default) or bgrx (the path of run 8: one thread, the decoder locked out; for comparison)
          --record     what the left eye sees (picture and hands) as a 1920x1080 H.264 MP4 while the headset is worn
                       (--record-fps, default 30; --record-bitrate kbit/s, default 1000: about 7.5 MB a minute)
          --record-cursor  draw the gaze cursor into the recording (off by default: no eye data is recorded)
          --record-tracking  write the tracking as a script (the eye gaze is never written)
          --dump       each received frame's tag and a grey thumbnail of its view (latch tests)
          --state-file JSON state for switching (waitingForHeadset, streaming, stopped); SIGTERM ends the viewer
          --probe      what the runtime and headset offer (--session: also start a session for 3 s)
        """

    public enum Parsed { case run(XRViewerOptions), exit(Int32, String) }

    public static func parse(_ args: [String]) -> Parsed {
        var o = XRViewerOptions()
        var i = 0
        func value() -> String? { i + 1 < args.count ? { i += 1; return args[i] }() : nil }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--connect": guard let v = value() else { return .exit(64, "--connect <address>") }; o.connect = v
            case "--link": guard let v = value() else { return .exit(64, "--link <device>") }; o.linkDevice = v
            case "--host": guard let v = value() else { return .exit(64, "--host <name>") }; o.linkHost = v
            case "--media":
                guard let v = value(), v == "udp" || v == "tcp" else { return .exit(64, "--media udp|tcp") }
                o.media = v == "udp"
            case "--stereo":
                guard let v = value(), ["adaptive", "alternate", "mono", "synth"].contains(v) else { return .exit(64, "--stereo adaptive|alternate|mono|synth") }
                o.stereoMode = v
                o.stereo = v != "mono" && v != "synth"
                o.stereoGiven = true
            case "--settle": guard let v = value().flatMap(Int.init), v >= 0, v <= 2000 else { return .exit(64, "--settle 0…2000 (ms)") }; o.settleMs = v
            case "--latch": guard let v = value().flatMap(Int.init), v >= 0, v <= 8 else { return .exit(64, "--latch 0…8") }; o.latch = v
            case "--pointer":
                guard let v = value().flatMap(XRInputMapper.Pointer.init(rawValue:)) else { return .exit(64, "--pointer auto|eyes|controller|head") }
                o.pointer = v
            case "--palm": o.palmOrientation = true
            case "--immersion": o.immersion = true
            case "--no-immersion": o.immersion = false
            case "--eye-yaw": guard let v = value().flatMap(Double.init), abs(v) <= 20 else { return .exit(64, "--eye-yaw <degrees, 0…20>") }; o.eyeYaw = v
            case "--foveate":
                o.foveaFraction = 0.35
                if i + 1 < args.count, let f = Double(args[i + 1]), f > 0, f < 1 { o.foveaFraction = f; i += 1 }
            case "--hands":
                guard let v = value(), ["rendered", "light", "off"].contains(v) else { return .exit(64, "--hands rendered|light|off") }
                o.hands = v
            case "--encoding":
                guard let v = value(), v == "auto" || DisplayCodecChoice.preference.contains(v) else { return .exit(64, "--encoding auto|hevc444|hevc|h264|jpeg|zlib") }
                o.encoding = v == "auto" ? nil : v
            case "--video-qp": guard let v = value().flatMap(Int.init), (1...51).contains(v) else { return .exit(64, "--video-qp 1…51") }; o.videoQP = v
            case "--video-bitrate": guard let v = value().flatMap(Int.init), (500...500_000).contains(v) else { return .exit(64, "--video-bitrate 500…500000 (kbit/s)") }; o.videoBitrate = v
            case "--video-fps": guard let v = value().flatMap(Int.init), (1...120).contains(v) else { return .exit(64, "--video-fps 1…120") }; o.videoFPS = v
            case "--quality": guard let v = value().flatMap(Int.init) else { return .exit(64, "--quality 1…100") }; o.quality = v
            case "--downscale": guard let v = value().flatMap(Int.init), (1...4).contains(v) else { return .exit(64, "--downscale 1…4") }; o.downscale = v; o.downscaleGiven = true
            case "--fps": guard let v = value().flatMap(Int.init), (1...120).contains(v) else { return .exit(64, "--fps 1…120") }; o.fps = v
            case "--seconds": guard let v = value().flatMap(Double.init), v > 0 else { return .exit(64, "--seconds S") }; o.seconds = v
            case "--replay": guard let v = value() else { return .exit(64, "--replay <script>") }; o.replay = v
            case "--drive": guard let v = value() else { return .exit(64, "--drive <script>") }; o.drive = v
            case "--record": guard let v = value() else { return .exit(64, "--record <file.mp4>") }; o.recordVideo = v
            case "--record-tracking": guard let v = value() else { return .exit(64, "--record-tracking <script>") }; o.recordTracking = v
            case "--record-cursor": o.recordCursor = true
            case "--record-fps": guard let v = value().flatMap(Int.init), (1...60).contains(v) else { return .exit(64, "--record-fps 1…60") }; o.recordFPS = v
            case "--record-bitrate": guard let v = value().flatMap(Int.init), (200...50_000).contains(v) else { return .exit(64, "--record-bitrate <kbit/s>") }; o.recordKbps = v
            case "--measure": guard let v = value() else { return .exit(64, "--measure <file>") }; o.measure = v
            case "--dump": guard let v = value() else { return .exit(64, "--dump <file>") }; o.dump = v
            case "--state-file": guard let v = value() else { return .exit(64, "--state-file <file>") }; o.stateFile = v
            case "--probe": o.probe = true
            case "--reproject":
                guard let v = value(), ["on", "off"].contains(v) else { return .exit(64, "--reproject on|off") }
                o.reproject = v == "on"
            case "--depth": guard let v = value().flatMap(Int.init), [2, 4, 8].contains(v) else { return .exit(64, "--depth 2|4|8") }; o.depthDownscale = v
            case "--grid": guard let v = value().flatMap(Int.init), (1...8).contains(v) else { return .exit(64, "--grid 1…8") }; o.depthGridStep = v
            case "--cache": guard let v = value().flatMap(Int.init), v == 0 || (256...2048).contains(v) else { return .exit(64, "--cache 0|256…2048") }; o.cacheFaceSize = v
            case "--offscreen":
                let parts = value()?.split(separator: "x").compactMap { Int($0) } ?? []
                guard parts.count == 2, parts.allSatisfy({ (64...8192).contains($0) }) else { return .exit(64, "--offscreen WxH") }
                o.offscreenSize = (parts[0], parts[1])
            case "--cache-all": o.cacheAll = true
            case "--cache-hold": guard let v = value().flatMap(Int.init), (0...5000).contains(v) else { return .exit(64, "--cache-hold ms") }; o.holdMs = v
            case "--cache-settle": guard let v = value().flatMap(Int.init), (0...5000).contains(v) else { return .exit(64, "--cache-settle ms") }; o.settleWindowMs = v
            case "--reproject-shots": guard let v = value() else { return .exit(64, "--reproject-shots <dir>") }; o.reprojectShots = v
            case "--environment":
                guard let v = value(), ["on", "off"].contains(v) else { return .exit(64, "--environment on|off") }
                o.environment = v == "on"
            case "--sweep":
                guard let v = value(), ["on", "off"].contains(v) else { return .exit(64, "--sweep on|off") }
                o.sweep = v == "on"
            case "--env-yaw": guard let v = value().flatMap(Double.init) else { return .exit(64, "--env-yaw degrees") }; o.environmentYaw = v
            case "--env-gain": guard let v = value().flatMap(Double.init), v > 0 else { return .exit(64, "--env-gain g") }; o.environmentGain = v
            case "--session": o.probeSession = true
            case "--gaze-dot": o.gazeDot = true
            case "--gaze-calibrate": o.gazeCalibrate = true
            case "--gaze-filter":
                guard let v = value().flatMap(XRGazeSettings.Filter.init(rawValue:)) else { return .exit(64, "--gaze-filter fixation|oneeuro|raw") }
                o.gaze.filter = v
            case "--gaze-cutoff": guard let v = value().flatMap(Double.init), v > 0, v <= 45 else { return .exit(64, "--gaze-cutoff <Hz>") }; o.gaze.cutoffHz = v
            case "--gaze-snap": guard let v = value().flatMap(Double.init), v > 0, v <= 20 else { return .exit(64, "--gaze-snap <degrees>") }; o.gaze.snapDegrees = v
            case "--gaze-deadband": guard let v = value().flatMap(Double.init), v >= 0, v <= 2 else { return .exit(64, "--gaze-deadband <degrees>") }; o.gaze.deadbandDegrees = v
            case "--gaze-hold": guard let v = value().flatMap(Int.init), (0...5000).contains(v) else { return .exit(64, "--gaze-hold <ms>") }; o.gaze.holdSeconds = Double(v) / 1000
            case "--gaze-time":
                guard let v = value(), v == "display" || v == "now" else { return .exit(64, "--gaze-time display|now") }
                o.gazeAtPresent = v == "now"
            case "--pinch-rewind": guard let v = value().flatMap(Int.init), (0...500).contains(v) else { return .exit(64, "--pinch-rewind <ms>") }; o.gaze.pinchRewindSeconds = Double(v) / 1000
            case "--pinch-freeze":
                guard let v = value(), ["on", "off"].contains(v) else { return .exit(64, "--pinch-freeze on|off") }
                o.gaze.freezeDuringPinch = v == "on"
            case "--pinch-on": guard let v = value().flatMap(Double.init), v > 0, v < 10 else { return .exit(64, "--pinch-on <cm>") }; o.pinchOnCentimetres = v
            case "--pinch-off": guard let v = value().flatMap(Double.init), v > 0, v < 15 else { return .exit(64, "--pinch-off <cm>") }; o.pinchOffCentimetres = v
            case "--pinch-slop": guard let v = value().flatMap(Double.init), v >= 0, v <= 100 else { return .exit(64, "--pinch-slop <mm>") }; o.pinchSlopMillimetres = v
            case "--hand-hold": guard let v = value().flatMap(Int.init), (0...2000).contains(v) else { return .exit(64, "--hand-hold <ms>") }; o.handHoldMs = v
            case "--poke":
                guard let v = value(), ["on", "off"].contains(v) else { return .exit(64, "--poke on|off") }
                o.poke = v == "on"
            case "--hold-band":
                let parts = value()?.split(separator: ",").compactMap { Double($0) } ?? []
                guard (1...2).contains(parts.count), parts[0] >= 0, parts[0] <= 45 else { return .exit(64, "--hold-band <deg>[,<cm>]") }
                o.holdBandDegrees = parts[0]
                if parts.count == 2 { o.holdBandCentimetres = parts[1] }
            case "--fresh-top": guard let v = value().flatMap(Int.init), (0...5000).contains(v) else { return .exit(64, "--fresh-top <ms>") }; o.freshTopMs = v
            case "--fresh-top-speed": guard let v = value().flatMap(Double.init), v >= 0, v <= 360 else { return .exit(64, "--fresh-top-speed <deg/s>") }; o.freshTopSpeed = v
            case "--tag-probe": guard let v = value() else { return .exit(64, "--tag-probe <file>") }; o.tagProbe = v
            case "--frame-window": guard let v = value().flatMap(Int.init), (0...64).contains(v) else { return .exit(64, "--frame-window 0…64") }; o.frameWindow = v
            case "--upload":
                guard let v = value(), v == "planes" || v == "bgrx" else { return .exit(64, "--upload planes|bgrx") }
                o.uploadViaBGRX = v == "bgrx"
            case "--slow-consumer": guard let v = value().flatMap(Int.init), (0...2000).contains(v) else { return .exit(64, "--slow-consumer <ms>") }; o.slowConsumerMs = v
            case "--hover-probe": guard let v = value() else { return .exit(64, "--hover-probe <file>") }; o.hoverProbe = v
            case "--verbose", "-v": o.verbose = true
            case "-h", "--help": return .exit(0, usage)
            default: return .exit(64, "unknown option \(a)\n" + usage)
            }
            i += 1
        }
        if !o.probe && o.connect == nil && o.linkDevice == nil { return .exit(64, "--connect or --link is needed\n" + usage) }
        // Without re-projection there is nothing to make both eyes from one view: adaptive.
        if o.reproject == false && !o.stereoGiven { o.stereoMode = "adaptive"; o.stereo = true }
        // Foveated: the whole picture at half resolution unless asked otherwise.
        if o.foveaFraction > 0 && !o.downscaleGiven { o.downscale = 2 }
        return .run(o)
    }

    /// The encodings to ask for (display-stream.md §14). The foveated inset is
    /// JPEG over a tile picture (§4.5), so `--foveate` starts there unless told otherwise.
    public func encodingPlan(problem: (String) -> String?) -> (wishes: [String], usable: [String], missing: [(name: String, why: String)]) {
        let wishes = DisplayCodecChoice.wishes(first: encoding ?? (foveaFraction > 0 ? "jpeg" : nil))
        let (usable, missing) = DisplayCodecChoice.decodable(wishes: wishes, problem: problem)
        return (wishes, usable, missing)
    }

    /// Why this host cannot decode an encoding (nil: it can).
    static func decodeProblem(_ name: String) -> String? {
        guard let e = DisplayEncoding(name: name) else { return "unknown encoding" }
        return StreamCanvas.decodeProblem(e)
    }

    /// The client hello this viewer sends.
    public var hello: DisplayClientHello { hello(problem: Self.decodeProblem) }

    public func hello(problem: (String) -> String?) -> DisplayClientHello {
        let usableList = encodingPlan(problem: problem).usable
        let usable = usableList.first ?? "zlib"
        var h = DisplayClientHello(client: "ycode-xr-viewer", maxFPS: fps, encoding: usable, quality: quality, downscale: downscale)
        h.encodings = usableList
        h.timing = true
        if let videoBitrate {
            h.videoBitrate = videoBitrate
            h.videoFPS = videoFPS
        } else {
            h.videoQP = videoQP
        }
        // Synthesised stereo asks the guest for the head every picture (mono).
        h.xr = XRClientRequest(stereo: synthStereo ? "mono" : stereoMode, latch: latch, settleMs: settleMs)
        if reproject != false {
            h.xr?.depthDownscale = depthDownscale
            h.xr?.environment = environment
        }
        if foveaFraction > 0 { h.xr?.foveaFraction = foveaFraction }
        if eyeYaw != 0 { h.xr?.eyeYawDegrees = eyeYaw }
        if frameWindow > 0 { h.frameWindow = frameWindow }
        return h
    }
}

/// The newest decoded picture of each view, as the stream delivers them.
final class XRPictureBoard: @unchecked Sendable {
    struct Entry { var sequence: UInt64; var guestFrame: UInt64 = 0; var tag: XRFrameView?; var receivedAt: UInt64; var decodedAt: UInt64 }
    private let lock = NSLock()
    private var latest: [XRView: Entry] = [:]
    func put(_ view: XRView, _ e: Entry) { lock.withLock { latest[view] = e } }
    func get(_ view: XRView) -> Entry? { lock.withLock { latest[view] } }
}

/// The stages of one shown picture (xr-viewer.md §6), viewer ns.
struct XRLatencySample {
    /// Viewer ns: the tag's pose left the viewer (0 untagged); the server's
    /// stages (display-stream.md §12.1, mapped to this clock; 0 unknown):
    /// the frame record seen, capture start, encode end, send end; then
    /// here: received, decoded, uploaded, the predicted display time.
    var poseSent: UInt64 = 0
    var recordSeen: UInt64 = 0, captureStart: UInt64 = 0, encodeEnd: UInt64 = 0, sendEnd: UInt64 = 0
    var received: UInt64 = 0, decoded: UInt64 = 0, uploaded: UInt64 = 0, display: UInt64 = 0
}

public final class XRViewer: @unchecked Sendable {
    let options: XRViewerOptions
    let client: DisplayStreamClient
    let board = XRPictureBoard()
    /// Foveated streaming: the newest decoded inset per view (alpha-feathered BGRA).
    struct DecodedInset { var inset: XRInset; var pixels: [UInt8]; var serial: Int }
    private var insets: [XRView: DecodedInset] = [:]
    private var insetSerial = 0
    func inset(_ v: XRView) -> DecodedInset? { lock.withLock { insets[v] } }
    private var lastFovea: (Float, Float, UInt64)?
    private let lock = NSLock()
    private var serverXR = false, serverSpatial = false
    private var hello: DisplayServerHello?
    private var poseSentAt: [UInt32: UInt64] = [:]
    private var latencies: [XRLatencySample] = []
    /// The stream's own stages per frame (headset or not): frames waiting
    /// for their timing message, and the joined stages.
    private var pendingFrames: [UInt64: (UInt64, UInt64)] = [:]
    private var streamStages: [XRLatencySample] = []
    private var counts = (frames: 0, tags: 0, left: 0, right: 0, mono: 0)
    private var firstFrameAt: UInt64 = 0, lastFrameAt: UInt64 = 0
    let log: (String) -> Void
    private let dumpFile: FileHandle?

    /// The depth re-projection (XRDepthView.swift), once the session exists.
    var depthView: XRDepthView? {
        get { lock.withLock { depthViewStorage } }
        set { lock.withLock { depthViewStorage = newValue } }
    }
    private var depthViewStorage: XRDepthView?
    /// The server sends depth (its hello's `xrDepth`).
    var serverDepth: Bool { lock.withLock { hello?.xrDepth == true } }

    public init(options: XRViewerOptions, connect: @escaping @Sendable () throws -> DisplayTransport, log: @escaping (String) -> Void) {
        self.options = options
        self.log = log
        if let d = options.dump {
            FileManager.default.createFile(atPath: d, contents: nil)
            dumpFile = FileHandle(forWritingAtPath: d)
        } else {
            dumpFile = nil
        }
        client = DisplayStreamClient(settings: options.hello, connect: connect)
        client.onEvent = { [weak self] e in self?.event(e) }
        client.onDepth = { [weak self] d, _ in self?.depthView?.depthArrived(d) }
        client.onEnvironment = { [weak self] e in self?.depthView?.environmentArrived(e) }
    }

    private func event(_ e: DisplayClientEvent) {
        switch e {
        case .hello(let h):
            lock.withLock { hello = h; serverSpatial = h.spatial == true; serverXR = h.xr == true }
            log("ycode-xr-viewer: \(h.deviceName) (\(h.model)), \(h.pixelWidth)x\(h.pixelHeight)"
                + (h.spatial == true ? "" : "; not a visionOS device: no spatial input")
                + (h.xr == true ? "" : "; the server has no headset support (mono, untagged)"))
            let plan = options.encodingPlan(problem: XRViewerOptions.decodeProblem)
            let chosen = plan.usable.first(where: h.encodings.contains) ?? h.encodings.first ?? "zlib"
            log("ycode-xr-viewer: stream encoding \(chosen) (the server offers \(h.encodings.joined(separator: ", ")))")
            if let w = DisplayCodecChoice.warning(viewer: "ycode-xr-viewer", wishes: plan.wishes, missing: plan.missing, offered: h.encodings, chosen: chosen) { log(w) }
            if options.foveaFraction > 0, DisplayEncoding(name: chosen)?.isVideo == true {
                log("ycode-xr-viewer: WARNING: --foveate has no effect with \(chosen): video is sent whole at full resolution")
            }
            if options.foveaFraction > 0, ycodec_jpeg_decode_available() == 0 {
                log("ycode-xr-viewer: WARNING: --foveate needs JPEG for its inset, which this viewer cannot decode (\(XRViewerOptions.decodeProblem("jpeg") ?? "")): no inset will show")
            }
        case .frame(let f):
            XRControl.shared.streaming()
            if options.slowConsumerMs > 0 { Thread.sleep(forTimeInterval: Double(options.slowConsumerMs) / 1000) }
            let view = f.view?.view ?? .mono
            board.put(view, .init(sequence: f.frame.sequence, guestFrame: f.frame.guestFrame, tag: f.view, receivedAt: f.receivedAt, decodedAt: f.decodedAt))
            if let dumpFile, let canvas = client.canvas(for: view) {
                let grey = canvas.greySamples(rows: 18, columns: 32).map { String(format: "%02x", $0) }.joined()
                let line = "\(f.frame.sequence)\t\(f.frame.guestFrame)\t\(view.rawValue)\t\(f.view?.poseSequence ?? 0)\t\(f.view?.estimated == true ? 1 : 0)\t\(f.decodedAt)\t\(grey)\t\(poseSent(f.view?.poseSequence ?? 0) ?? 0)\n"
                dumpFile.write(Data(line.utf8))
            }
            lock.withLock {
                if firstFrameAt == 0 { firstFrameAt = f.receivedAt }
                lastFrameAt = f.receivedAt
                pendingFrames[f.frame.sequence] = (f.receivedAt, f.decodedAt)
                if pendingFrames.count > 512 { pendingFrames.removeAll() }
                counts.frames += 1
                if f.view != nil { counts.tags += 1 }
                switch view {
                case .left: counts.left += 1
                case .right: counts.right += 1
                case .mono: counts.mono += 1
                }
            }
        case .timing(let t):
            let clock = client.clock
            lock.withLock {
                guard let (rx, dec) = pendingFrames.removeValue(forKey: t.sequence) else { return }
                func map(_ ns: UInt64) -> UInt64 { ns == 0 ? 0 : clock.clientTime(server: ns) ?? 0 }
                streamStages.append(XRLatencySample(recordSeen: map(t.recordSeen), captureStart: map(t.captureStart), encodeEnd: map(t.encodeEnd),
                                                    sendEnd: map(t.sendEnd), received: rx, decoded: dec))
                if streamStages.count > 100_000 { streamStages.removeFirst(50_000) }
            }
        case .inset(let i):
            guard i.encoding == .jpeg, i.width > 0, i.height > 0 else { break }
            var px = [UInt8](repeating: 0, count: i.width * i.height * 4)
            let ok = i.data.withUnsafeBufferPointer { b in
                px.withUnsafeMutableBytes { ycodec_jpeg_decode_bgra(b.baseAddress, b.count, Int32(i.width), Int32(i.height), $0.baseAddress!.assumingMemoryBound(to: UInt8.self), i.width * 4) }
            }
            guard ok == 0 else { break }
            XRViewer.feather(&px, width: i.width, height: i.height)
            lock.withLock { insetSerial += 1; insets[i.view] = DecodedInset(inset: i, pixels: px, serial: insetSerial) }
        case .phase(let p, let d):
            log("ycode-xr-viewer: \(p)\(d.map { " (\($0))" } ?? "")")
            if p == DisplayNotice.takenOverPhase { XRControl.shared.requestStop("another viewer took over") }
        case .notice(let n): log("ycode-xr-viewer: notice: \(n)")
        default: break
        }
    }

    /// A soft edge: alpha ramps from 0 to 255 over the outer 8 % of the
    /// inset (the half-resolution picture shows through at its border).
    static func feather(_ px: inout [UInt8], width w: Int, height h: Int) {
        let band = max(4, min(w, h) * 8 / 100)
        px.withUnsafeMutableBufferPointer { p in
            for y in 0..<h {
                let dy = min(y, h - 1 - y)
                for x in 0..<w {
                    let d = min(dy, min(x, w - 1 - x))
                    if d >= band { continue }
                    p[(y * w + x) * 4 + 3] = UInt8(255 * d / band)
                }
            }
        }
    }

    /// Foveated streaming: where the eyes look in the guest's view, to the
    /// server only (at most 90 times a second, when it moved).
    func sendFovea(u: Double, v: Double) {
        guard options.foveaFraction > 0, xrServer else { return }
        let now = viewerNanoseconds()
        if let l = lastFovea, abs(Double(l.0) - u) < 0.004, abs(Double(l.1) - v) < 0.004 { return }
        lastFovea = (Float(u), Float(v), now)
        client.sendInput { .fovea(sequence: $0, u: Float(u), v: Float(v)) }
    }

    var spatial: Bool { lock.withLock { serverSpatial } }
    var xrServer: Bool { lock.withLock { serverXR } }
    var guestSize: (Int, Int) { lock.withLock { hello.map { ($0.pixelWidth, $0.pixelHeight) } ?? (3840, 2160) } }

    // MARK: Sending input

    private var lastSelection: (time: UInt64, pinch: (Bool, Bool))?
    private var lastImmersionSend: UInt64 = 0
    private var lastPing: UInt64 = 0
    private var pendingImmersion: Double?
    private var crownRelease: UInt64?

    /// One mapped sample → messages (latest-wins state on the server).
    func send(_ out: XRInputOutput) {
        let now = viewerNanoseconds()
        guard spatial else { return }
        // The clock against the server's (stage times), kept fresh once a second.
        if now &- lastPing >= 1_000_000_000 { client.ping(); lastPing = now }
        if xrServer {
            let seq = client.sendInput { .views(sequence: $0, views: XRViews(sequence: $0, stereo: out.views.stereo, head: out.views.head,
                                                                             left: out.views.left, right: out.views.right)) }
            if seq != 0 { lock.withLock { poseSentAt[seq] = now; if poseSentAt.count > 512 { poseSentAt = poseSentAt.filter { now &- $0.value < 2_000_000_000 } } } }
        } else {
            client.sendInput { .pose(sequence: $0, pose: out.views.head) }
        }
        // Selections: about 60 per second, pinch changes at once.
        let pinch = (out.selection.left?.pinching ?? false, out.selection.right?.pinching ?? false)
        if lastSelection == nil || lastSelection!.pinch != pinch || now &- lastSelection!.time >= 16_000_000 {
            client.sendInput { .selection(sequence: $0, selection: out.selection) }
            lastSelection = (now, pinch)
        }
        if let down = out.crown { client.sendInput { .button(sequence: $0, button: .home, down: down) } }
        if out.recentred {
            // The guest recentres on a held crown (≥ 0.5 s, visionos.md §5.5.9).
            client.sendInput { .button(sequence: $0, button: .home, down: true) }
            crownRelease = now + 700_000_000
        }
        if let r = crownRelease, now >= r {
            client.sendInput { .button(sequence: $0, button: .home, down: false) }
            crownRelease = nil
        }
        if let a = out.immersion, options.immersion { pendingImmersion = a }
        if let a = pendingImmersion, now &- lastImmersionSend >= 100_000_000 {
            client.send(.command(token: client.token(), text: String(format: "vision immersion %.3f", a)))
            lastImmersionSend = now
            pendingImmersion = nil
        }
    }

    func poseSent(_ seq: UInt32) -> UInt64? { lock.withLock { poseSentAt[seq] } }

    // MARK: Gaps (xr-viewer.md §13.1)

    private var gapRecorder = XRGapRecorder()
    private var gapLines = 0
    /// Pictures that came with the camera at rest and no pinch: bursts of them (a hover's highlight or an animation).
    private var contentBursts = 0, lastPictureAt: UInt64 = 0, cameraMovedAt: UInt64 = 0, firstTick: UInt64 = 0

    /// One headset frame (or a replay's sample).
    func tick(tracked: Bool, head: SpatialPose?, waited: UInt64, work: UInt64, cameraMoved: Bool, pinchChanged: Bool, saccade: Bool, hidden: Bool) {
        let now = viewerNanoseconds()
        lock.withLock {
            if firstTick == 0 { firstTick = now }
            if cameraMoved || pinchChanged { cameraMovedAt = now }
            gapRecorder.frame(at: now, tracked: tracked, head: head, waited: waited, work: work, cameraMoved: cameraMoved,
                              pinchChanged: pinchChanged, saccade: saccade, pictureHidden: hidden)
        }
    }

    /// A new picture reached the eyes.
    func pictureShown(_ entry: XRPictureBoard.Entry, _ s: XRLatencySample) {
        let gap = lock.withLock { () -> XRGapRecorder.Gap? in
            if s.uploaded &- lastPictureAt > 150_000_000, s.uploaded &- cameraMovedAt > 300_000_000 { contentBursts += 1 }
            lastPictureAt = s.uploaded
            let g = gapRecorder.picture(.init(sequence: entry.sequence, guestFrame: entry.guestFrame, captureStart: s.captureStart, sendEnd: s.sendEnd,
                                              received: s.received, decoded: s.decoded, uploaded: s.uploaded))
            if g != nil { gapLines += 1 }
            return gapLines <= 400 ? g : nil
        }
        if let gap, gap.cause != .idle { log("ycode-xr-viewer: " + gap.description) }
    }

    /// The gaps and the content bursts of the session.
    var gapSummary: String {
        lock.withLock {
            let seconds = firstTick > 0 ? max(0.001, Double(viewerNanoseconds() - firstTick) / 1e9) : 0.001
            return gapRecorder.summary + String(format: "; picture bursts with the camera still and no pinch %d (%.2f per second: hover changes and animations; the server's log has them by place)", contentBursts, Double(contentBursts) / seconds)
        }
    }

    func addLatency(_ l: XRLatencySample) { lock.withLock { latencies.append(l); if latencies.count > 100_000 { latencies.removeFirst(50_000) } } }

    // MARK: Summary

    func summary() -> String {
        let (c, lat, st) = lock.withLock { (counts, latencies, streamStages) }
        var s = "frames \(c.frames) (left \(c.left), right \(c.right), mono \(c.mono); tagged \(c.tags))"
        // What the stream carried since the first picture: its rate and its bytes per second.
        let stats = client.statistics
        let (firstAt, lastAt) = lock.withLock { (firstFrameAt, lastFrameAt) }
        if c.frames > 1, lastAt > firstAt {
            let seconds = Double(lastAt - firstAt) / 1e9
            s += String(format: "; %.1f pictures/s, %.1f MB/s", Double(c.frames - 1) / seconds, Double(stats.bytes) / 1e6 / seconds)
        }
        func pct(_ v: [Double], _ p: Double) -> Double { v.isEmpty ? 0 : v.sorted()[min(v.count - 1, Int(Double(v.count) * p))] }
        func stage(_ f: (XRLatencySample) -> (UInt64, UInt64)) -> [Double] {
            lat.compactMap { l in let (a, b) = f(l); return a > 0 && b >= a ? Double(b - a) / 1e6 : nil }
        }
        func sstage(_ f: (XRLatencySample) -> (UInt64, UInt64)) -> [Double] {
            st.compactMap { l in let (a, b) = f(l); return a > 0 && b >= a ? Double(b - a) / 1e6 : nil }
        }
        let streamTotal = sstage { ($0.recordSeen, $0.decoded) }
        if !streamTotal.isEmpty {
            s += String(format: "; stream (frame seen → decoded) p50 %.1f / p90 %.1f ms: seen→capture %.1f, encode %.1f, send %.1f, network %.1f, decode %.1f",
                        pct(streamTotal, 0.5), pct(streamTotal, 0.9), pct(sstage { ($0.recordSeen, $0.captureStart) }, 0.5),
                        pct(sstage { ($0.captureStart, $0.encodeEnd) }, 0.5), pct(sstage { ($0.encodeEnd, $0.sendEnd) }, 0.5),
                        pct(sstage { ($0.sendEnd, $0.received) }, 0.5), pct(sstage { ($0.received, $0.decoded) }, 0.5))
        }
        let tagged = stage { ($0.poseSent, $0.display) }
        if !tagged.isEmpty {
            s += String(format: "; tagged pose sent → shown p50 %.0f / p90 %.0f ms", pct(tagged, 0.5), pct(tagged, 0.9))
        }
        let ours = stage { ($0.recordSeen, $0.display) }
        if !ours.isEmpty {
            let parts: [(String, [Double])] = [
                ("seen→capture", stage { ($0.recordSeen, $0.captureStart) }), ("encode", stage { ($0.captureStart, $0.encodeEnd) }),
                ("send", stage { ($0.encodeEnd, $0.sendEnd) }), ("network", stage { ($0.sendEnd, $0.received) }),
                ("decode", stage { ($0.received, $0.decoded) }), ("→upload", stage { ($0.decoded, $0.uploaded) }),
                ("→display", stage { ($0.uploaded, $0.display) })]
            s += String(format: "; ours (guest frame seen → display) p50 %.1f / p90 %.1f ms: ", pct(ours, 0.5), pct(ours, 0.9))
                + parts.map { "\($0.0) " + String(format: "%.1f", pct($0.1, 0.5)) }.joined(separator: ", ")
        }
        return s
    }

    func writeMeasure(_ path: String) {
        let lat = lock.withLock { latencies }
        var text = "pose_sent_ns\trecord_seen_ns\tcapture_ns\tencode_end_ns\tsend_end_ns\treceived_ns\tdecoded_ns\tuploaded_ns\tdisplay_ns\n"
        for l in lat {
            text += [l.poseSent, l.recordSeen, l.captureStart, l.encodeEnd, l.sendEnd, l.received, l.decoded, l.uploaded, l.display]
                .map { String($0) }.joined(separator: "\t") + "\n"
        }
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// The viewer's monotonic clock (ns).
func viewerNanoseconds() -> UInt64 {
    var t = timespec()
    clock_gettime(CLOCK_MONOTONIC, &t)
    return UInt64(t.tv_sec) * 1_000_000_000 + UInt64(t.tv_nsec)
}

// MARK: - The modes

public enum XRViewerMain {
    static func say(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    public static func main(_ arguments: [String], connect: (@Sendable () throws -> DisplayTransport)?) -> Int32 {
        let o: XRViewerOptions
        switch XRViewerOptions.parse(arguments) {
        case .exit(let code, let text):
            if code == 0 { print(text) } else { say(text) }
            return code
        case .run(let v): o = v
        }
        if o.probe { return probe(o) }
        guard let connect else { say("ycode-xr-viewer: no connection"); return 64 }
        let viewer = XRViewer(options: o, connect: connect, log: say)
        XRControl.shared.configure(stateFile: o.stateFile)
        let status = o.replay.map { replay(viewer, script: $0) } ?? live(viewer)
        XRControl.shared.stopped(status == 0 ? nil : "exit status \(status)")
        return status
    }

    /// Phase 1: what the runtime offers (and, with --session, a short session).
    static func probe(_ o: XRViewerOptions) -> Int32 {
        let (ok, why) = XRSession.available()
        guard ok else { say("ycode-xr-viewer: \(why)"); return 69 }
        do {
            let s = try XRSession(session: o.probeSession)
            print(s.info.description)
            print("extensions: " + s.info.extensions.joined(separator: " "))
            guard o.probeSession else { return 0 }
            let t0 = Date()
            var frames = 0, gaze = 0, hands = [0, 0]
            while Date().timeIntervalSince(t0) < 3.5 {
                if let e = s.poll() { if e == .exit || e == .lost { break } }
                guard s.running else { Thread.sleep(forTimeInterval: 0.01); continue }
                let f = try s.beginFrame(time: Date().timeIntervalSince(t0))
                frames += 1
                if f.sample?.gaze != nil { gaze += 1 }
                for h in 0..<2 where f.sample?.hands[h] != nil { hands[h] += 1 }
                if frames == 1 { print("fields of view: " + f.fov.map { String(format: "%.1f…%.1f° × %.1f…%.1f°", $0.left * 180 / .pi, $0.right * 180 / .pi, $0.down * 180 / .pi, $0.up * 180 / .pi) }.joined(separator: ", ")) }
                try s.endFrameEmpty()
                if Date().timeIntervalSince(t0) > 3 { s.requestExit() }
            }
            print("session: \(frames) frames, eye gaze in \(gaze), hands in \(hands[0])/\(hands[1])")
            return 0
        } catch {
            say("ycode-xr-viewer: \(error)")
            return 1
        }
    }

    /// The OpenXR-free stand-in: a script drives the mapping and the stream.
    static func replay(_ viewer: XRViewer, script path: String) -> Int32 {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { say("ycode-xr-viewer: cannot read \(path)"); return 66 }
        let samples: [XRTrackingSample]
        do { samples = try XRSampleScript.decode(text) } catch { say("ycode-xr-viewer: \(path): \(error)"); return 65 }
        guard let first = samples.first else { say("ycode-xr-viewer: \(path) is empty"); return 65 }
        // Re-projection without a headset: offscreen eyes (the GPU time, the
        // disocclusion, and PNGs of the right eye with --reproject-shots).
        if viewer.options.reproject == true {
            do {
                let dv = try XRDepthView(session: nil, options: viewer.options, log: say)
                dv.shotDirectory = viewer.options.reprojectShots
                dv.offscreenSize = viewer.options.offscreenSize
                viewer.depthView = dv
                say("ycode-xr-viewer: offscreen re-projection on \(dv.reprojector.deviceName)")
            } catch { say("ycode-xr-viewer: no re-projection: \(error)") }
        }
        viewer.client.start()
        let deadline = Date().addingTimeInterval(10)
        while !viewer.spatial && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        var mapper = XRInputMapper(options: viewer.options)
        var video: XRVideoRecorder?
        if let path = viewer.options.recordVideo {
            let v = XRVideoRecorder(path: path, fps: viewer.options.recordFPS, bitrateKbps: viewer.options.recordKbps, log: say)
            if v.start() { video = v }
        }
        // Without re-projection: the plain path, as a headset's frames run it.
        let plain = viewer.options.reproject == false ? XRPlainPath() : nil
        let sink = plain != nil ? XROffscreenSink() : nil
        let hoverProbe = viewer.options.hoverProbe.map { XRHoverProbe(path: $0) }
        let tagFile: FileHandle? = viewer.options.tagProbe.flatMap { p in
            FileManager.default.createFile(atPath: p, contents: nil)
            return FileHandle(forWritingAtPath: p)
        }
        var tagSequence: UInt64 = 0
        var lastCamera: SpatialPose?
        var lastPinching = false
        let start = viewerNanoseconds()
        var previousEnd = start
        for s in samples {
            if XRControl.shared.stopRequested { break }
            let due = start + UInt64(max(0, s.time - first.time) * 1e9)
            let now = viewerNanoseconds()
            if due > now { Thread.sleep(forTimeInterval: Double(due - now) / 1e9) }
            var out = mapper.map(s)
            if !viewer.options.stereo, let dv = viewer.depthView, let anchor = mapper.anchor {
                out.views.head = dv.camera(out.views.head, anchor: anchor, recentred: out.recentred)
            }
            viewer.send(out)
            for e in mapper.takePinchEvents() { say("ycode-xr-viewer: " + e.description) }
            if let hoverProbe { hoverProbe.sample(viewer, s, out, mapper: mapper) }
            if let tagFile, let entry = viewer.board.get(.mono), entry.sequence != tagSequence, let tag = entry.tag, let canvas = viewer.client.canvas(for: .mono) {
                tagSequence = entry.sequence
                let f = tag.pose.forward
                let row = canvas.greySamples(rows: 1, columns: 1080).map { String(format: "%02x", $0) }.joined()
                let line = String(format: "%llu\t%.3f\t%.3f\t", entry.sequence, atan2(-f.x, -f.z) * 180 / .pi, s.time) + row + "\n"
                tagFile.write(Data(line.utf8))
            }
            if viewer.options.foveaFraction > 0 {
                let d = s.gaze.map { s.head.rotation.conjugate.rotate($0.forward) } ?? SpatialVector(0, 0, -1)
                let (w, h) = viewer.guestSize
                if let p = XRInset.point(gaze: d, fov: .guest(width: w, height: h)) { viewer.sendFovea(u: p.u, v: p.v) }
            }
            if let dv = viewer.depthView, let anchor = mapper.anchor {
                // The Quest Pro's fields of view (xr-viewer.md §2).
                let d = Double.pi / 180
                dv.offscreen(viewer, s, fovs: [XRFieldOfView(left: -54 * d, right: 40 * d, up: 48 * d, down: -48 * d),
                                               XRFieldOfView(left: -40 * d, right: 54 * d, up: 48 * d, down: -48 * d)], anchor: anchor)
            }
            if let plain, let sink, let anchor = mapper.anchor {
                plain.update(viewer, into: sink, anchor: anchor, head: s.head, ahead: 0, log: say)
            }
            let tickNow = viewerNanoseconds()
            let moved = lastCamera.map { XRCameraHold.differs($0, out.views.head, metres: 0.0005, radians: 0.0009) } ?? false
            lastCamera = out.views.head
            let pinching = (out.selection.left?.pinching ?? false) || (out.selection.right?.pinching ?? false)
            viewer.tick(tracked: true, head: s.head, waited: 0, work: tickNow &- previousEnd, cameraMoved: moved, pinchChanged: pinching != lastPinching,
                        saccade: mapper.saccadeNow, hidden: viewer.depthView?.pictureHidden ?? false)
            lastPinching = pinching
            previousEnd = viewerNanoseconds()
            // Recording without a headset: the newest left (or mono) picture at its tag's pose.
            if let video, let anchor = mapper.anchor {
                let l = viewer.board.get(.left), m = viewer.board.get(.mono)
                let (view, entry) = (l?.sequence ?? 0) > (m?.sequence ?? 0) ? (XRView.left, l) : (XRView.mono, m)
                if let entry, let canvas = viewer.client.canvas(for: view) {
                    let (w, h) = viewer.guestSize
                    video.submit(XRRecordJob(canvas: canvas, rendered: entry.tag.map { anchor.fromStage($0.pose) } ?? s.head,
                                             fov: entry.tag?.fov ?? .guest(width: w, height: h), hands: s.hands,
                                             pinching: [out.selection.left?.pinching ?? false, out.selection.right?.pinching ?? false],
                                             gaze: nil, time: viewerNanoseconds()))
                }
            }
        }
        Thread.sleep(forTimeInterval: 1)
        if let video { say("ycode-xr-viewer: " + video.stop()) }
        say("ycode-xr-viewer: replayed \(samples.count) samples; " + viewer.summary())
        if let dv = viewer.depthView { say("ycode-xr-viewer: " + dv.summary) }
        if let sink { say("ycode-xr-viewer: " + sink.summary) }
        say("ycode-xr-viewer: " + viewer.gapSummary)
        say("ycode-xr-viewer: " + mapper.gazeStats.description)
        say("ycode-xr-viewer: " + mapper.handsDescription)
        if let m = viewer.options.measure { viewer.writeMeasure(m) }
        viewer.client.stop()
        return 0
    }

    /// The headset.
    static func live(_ viewer: XRViewer) -> Int32 {
        let o = viewer.options
        let (ok, why) = XRSession.available()
        guard ok else { say("ycode-xr-viewer: \(why)"); return 69 }
        say("ycode-xr-viewer: waiting for the OpenXR runtime (a headset must be connected to it)…")
        let session: XRSession
        do { session = try XRSession(session: true) } catch { say("ycode-xr-viewer: \(error)"); return 1 }
        say("ycode-xr-viewer: " + session.info.description)
        if o.reproject != false {
            do { viewer.depthView = try XRDepthView(session: session, options: o, log: say); say("ycode-xr-viewer: re-projection on \(viewer.depthView!.reprojector.deviceName)") }
            catch { say("ycode-xr-viewer: no re-projection: \(error)") }
        }
        viewer.client.start()
        var mapper = XRInputMapper(options: o)
        if o.gazeAtPresent { session.locateGazeAtPresent(true) }
        let overlay = o.gazeDot || o.gazeCalibrate ? XRGazeOverlay(showDot: o.gazeDot, calibrate: o.gazeCalibrate, log: say) : nil
        var noDepthSaid = false
        var recorder: FileHandle?
        if let path = o.recordTracking {
            FileManager.default.createFile(atPath: path, contents: nil)
            recorder = FileHandle(forWritingAtPath: path)
        }
        let t0 = viewerNanoseconds()
        let path = XRPlainPath()
        var poses = [SpatialPose.identity, .identity], fovs = [XRFieldOfView.guest(width: 3840, height: 2160), .guest(width: 3840, height: 2160)]
        var images = [-1, -1]
        var recenter = false, exiting = false
        var xrFrames = 0, tracked = 0, nextReport = viewerNanoseconds() + 5_000_000_000
        var baseFrame: [UInt64] = [0, 0]
        let gpu = XRGPUSampler()
        gpu.start()
        var driveSamples: [XRTrackingSample] = []
        if let d = o.drive, let text = try? String(contentsOfFile: d, encoding: .utf8), let samples = try? XRSampleScript.decode(text), !samples.isEmpty {
            driveSamples = samples
            say("ycode-xr-viewer: tracking from \(d) (\(samples.count) samples, looped)")
        }
        var insetMissing = 0, layoutChanges = 0, lastLayout = ""
        var insetShown: [Int: Int] = [:]
        var video: XRVideoRecorder?
        if let path = o.recordVideo {
            let v = XRVideoRecorder(path: path, fps: o.recordFPS, bitrateKbps: o.recordKbps, log: say)
            if v.start() { video = v; say("ycode-xr-viewer: recording the left eye to \(path)") }
        }
        var loopNs: [UInt64] = []
        var previousWork: UInt64 = 0
        var lastCamera: SpatialPose?
        var lastPinching = false
        var gazeAges: [Double] = []
        var stale = XRStaleTracking()
        var stop = false
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT)
        let stopFlag = XRFlag()
        sigint.setEventHandler { stopFlag.set() }
        sigint.resume()
        while !stop {
            while let e = session.poll() {
                switch e {
                case .recenter: recenter = true
                case .exit, .lost: stop = true
                case .state(let s) where o.verbose: say("ycode-xr-viewer: session state \(s)")
                default: break
                }
            }
            if stop { break }
            if (stopFlag.isSet || XRControl.shared.stopRequested || (o.seconds.map { Double(viewerNanoseconds() - t0) / 1e9 > $0 } ?? false)) && !exiting {
                session.requestExit()
                exiting = true
            }
            guard session.running else { Thread.sleep(forTimeInterval: 0.01); continue }
            let now = Double(viewerNanoseconds() - t0) / 1e9
            let frame: XRFrameState
            let waitStart = viewerNanoseconds()
            do { frame = try session.beginFrame(time: now) } catch { say("ycode-xr-viewer: \(error)"); break }
            let loopStart = viewerNanoseconds()
            let waited = loopStart &- waitStart
            xrFrames += 1
            if frame.gazeSampleAge != 0 {
                if gazeAges.count < 200_000 { gazeAges.append(Double(frame.gazeSampleAge) / 1e6) }
                // Samples this old: the headset's tracking is not arriving (the runtime's link, xr-viewer.md §13.1).
                if stale.note(age: frame.gazeSampleAge, at: loopStart) { say("ycode-xr-viewer: \(stale.lastDescription)") }
            }
            if frame.sample != nil { tracked += 1 }
            if !noDepthSaid, !o.stereo, o.reproject == nil, viewer.spatial, !viewer.serverDepth {
                noDepthSaid = true
                say("ycode-xr-viewer: the server sends no depth: one view for both eyes, without re-projection (--stereo adaptive for stereo at rest)")
            }
            if o.verbose || viewerNanoseconds() >= nextReport {
                nextReport = viewerNanoseconds() + 5_000_000_000
                // Off the headset's loop: the summary sorts every sample so far, which grew to tens of ms.
                let (f, tr) = (xrFrames, tracked)
                DispatchQueue.global(qos: .utility).async { say("ycode-xr-viewer: \(f) headset frames, \(tr) tracked (head and views); " + viewer.summary()) }
            }
            var sprites: [XRHandSprite] = []
            var pinches = [false, false]
            var driven: XRTrackingSample?
            if !driveSamples.isEmpty {
                let t = now.truncatingRemainder(dividingBy: driveSamples.last!.time - driveSamples.first!.time + 0.011)
                driven = driveSamples[min(driveSamples.count - 1, max(0, Int(t / 0.011111)))]
                driven!.time = now
            }
            if (driven ?? frame.sample) == nil { viewer.tick(tracked: false, head: nil, waited: waited, work: previousWork, cameraMoved: false, pinchChanged: false, saccade: false, hidden: false) }
            if var s = driven ?? frame.sample {
                s.recenter = recenter
                recenter = false
                if let recorder { recorder.write(Data((XRSampleScript.encode(s) + "\n").utf8)) }
                var out = mapper.map(s)
                if !o.stereo, let dv = viewer.depthView, o.reproject == true || viewer.serverDepth, let anchor = mapper.anchor {
                    out.views.head = dv.camera(out.views.head, anchor: anchor, recentred: out.recentred)
                }
                viewer.send(out)
                for e in mapper.takePinchEvents() { say("ycode-xr-viewer: " + e.description) }
                let moved = lastCamera.map { XRCameraHold.differs($0, out.views.head, metres: 0.0005, radians: 0.0009) } ?? false
                lastCamera = out.views.head
                let pinching = (out.selection.left?.pinching ?? false) || (out.selection.right?.pinching ?? false)
                viewer.tick(tracked: true, head: s.head, waited: waited, work: previousWork, cameraMoved: moved, pinchChanged: pinching != lastPinching,
                            saccade: mapper.saccadeNow, hidden: viewer.depthView?.pictureHidden ?? false)
                lastPinching = pinching
                if o.foveaFraction > 0 {
                    // The gaze (else the head's forward) in head space → the guest's view.
                    let d = mapper.lastGaze.map { s.head.rotation.conjugate.rotate($0.forward) } ?? SpatialVector(0, 0, -1)
                    let (w, h) = viewer.guestSize
                    if let p = XRInset.point(gaze: d, fov: .guest(width: w, height: h)) { viewer.sendFovea(u: p.u, v: p.v) }
                }
                pinches = [out.selection.left?.pinching ?? false, out.selection.right?.pinching ?? false]
                if let overlay, let anchor = mapper.anchor {
                    sprites += overlay.sprites(session: session, mapper: &mapper, sample: s, out: out, anchor: anchor, waiting: viewer.depthView?.sweeping ?? false) { origin, direction in
                        viewer.depthView?.surfaceDistance(origin: origin, direction: direction)
                    }
                }
                if o.hands != "off" {
                    // One layer per hand: its discs drawn into a 256² image on the CPU
                    // and uploaded every frame into slot 2 (left) or 3 (right).
                    let pinchState = [out.selection.left?.pinching ?? false, out.selection.right?.pinching ?? false]
                    for h in 0..<2 {
                        guard h < s.hands.count, let j = s.hands[h],
                              let ov = XRHandModel.overlay(hand: j, pinching: pinchState[h], eye: s.head.position, n: o.hands == "light" ? 160 : 256) else { continue }
                        let n = o.hands == "light" ? 160 : 256
                        let ok = (try? ov.pixels.withUnsafeBytes { try session.upload(eye: 2 + h, pixels: $0.baseAddress!, width: n, height: n, bytesPerRow: n * 4) }) != nil
                        if ok { sprites.append(XRHandSprite(pose: ov.pose, size: ov.size, highlight: h == 1)) }
                    }
                }
            }
            // Depth re-projection: both eyes drawn every frame at their current
            // poses into the rendered swapchains (xr-depth.md §5).
            if let dv = viewer.depthView, o.reproject == true || viewer.serverDepth, let anchor = mapper.anchor,
               let r = dv.frame(viewer, frame, anchor: anchor) {
                previousWork = viewerNanoseconds() - loopStart
                loopNs.append(previousWork)
                do { try session.endFrame(images: [0, 1], poses: r.poses, fovs: r.fovs, sprites: sprites, render: [true, true]) }
                catch { say("ycode-xr-viewer: \(error)"); break }
                continue
            }
            if let anchor = mapper.anchor {
                let ahead = frame.displayTime > 0 ? UInt64(max(0, frame.displayTime - session.xrNow)) : 0
                path.update(viewer, into: session, anchor: anchor, head: frame.sample?.head, ahead: ahead, log: say)
            }
            images = [-1, -1]
            var shownViews: [XRView] = []
            if let layout = path.plan.layout() {
                images = layout.map(\.slot)
                poses = layout.map(\.shown.pose)
                fovs = layout.map(\.shown.fov)
                shownViews = layout.map(\.view)
                baseFrame = layout.map(\.shown.sequence)
                let signature = images.map(String.init).joined(separator: ",")
                if signature != lastLayout { layoutChanges += 1; lastLayout = signature }
            }
            // Foveated: each view's inset for the picture it shows (a newer gaze on the same picture too).
            var insetImages: [Int]?, insetFovs: [XRFieldOfView]?
            if o.foveaFraction > 0, images[0] >= 0, images[1] >= 0 {
                var ok = true
                var imgs = [-1, -1], ifovs = fovs
                for e in 0..<2 {
                    let view = shownViews[e]
                    guard let d = viewer.inset(view), d.inset.frameSequence == baseFrame[e] else { ok = false; break }
                    let slot = XRLayerPlan.insetSlot(for: view)
                    if insetShown[slot] != d.serial {
                        let failure: Error? = d.pixels.withUnsafeBytes { b in
                            do { try session.upload(eye: slot, pixels: b.baseAddress!, width: d.inset.width, height: d.inset.height, bytesPerRow: d.inset.width * 4); return nil }
                            catch { return error }
                        }
                        if failure != nil { ok = false; break }
                        insetShown[slot] = d.serial
                    }
                    imgs[e] = slot
                    ifovs[e] = XRInset.fov(of: (d.inset.x, d.inset.y, d.inset.width, d.inset.height), in: fovs[e], width: d.inset.fullWidth, height: d.inset.fullHeight)
                }
                if ok { (insetImages, insetFovs) = (imgs, ifovs) } else { insetMissing += 1 }
            }
            if let video, let canvas = path.leftCanvas, images[0] >= 0, let s = frame.sample {
                video.submit(XRRecordJob(canvas: canvas, rendered: poses[0], fov: fovs[0], hands: s.hands,
                                         pinching: pinches,
                                         gaze: o.recordCursor ? s.gaze : nil, time: viewerNanoseconds()))
            }
            previousWork = viewerNanoseconds() - loopStart
            loopNs.append(previousWork)
            do {
                if images[0] >= 0 && images[1] >= 0 { try session.endFrame(images: images, poses: poses, fovs: fovs, insets: insetImages, insetFovs: insetFovs, sprites: sprites) }
                else { try session.endFrameEmpty(sprites: sprites) }
            } catch { say("ycode-xr-viewer: \(error)"); break }
        }
        sigint.cancel()
        if let video { say("ycode-xr-viewer: " + video.stop()) }
        if let g = gpu.stop() { say("ycode-xr-viewer: " + g) }
        say("ycode-xr-viewer: " + mapper.gazeStats.description)
        say("ycode-xr-viewer: layer layout changes \(layoutChanges); foveal inset missing in \(insetMissing) headset frames, new pictures held for their inset \(path.insetWaits) times")
        say("ycode-xr-viewer: " + viewer.gapSummary)
        say("ycode-xr-viewer: " + mapper.handsDescription)
        if !gazeAges.isEmpty {
            let a = gazeAges.sorted()
            say(String(format: "ycode-xr-viewer: gaze sample against the frame's display time: p50 %.0f / p90 %.0f ms (positive: older); samples without the tracked bit %d", a[a.count / 2], a[a.count * 9 / 10], session.untrackedGaze) + "; " + stale.summary)
        }
        if !loopNs.isEmpty {
            let s = loopNs.sorted()
            say(String(format: "ycode-xr-viewer: headset loop work per frame (after the wait) p50 %.2f / p99 %.2f / max %.2f ms", Double(s[s.count / 2]) / 1e6,
                       Double(s[min(s.count - 1, s.count * 99 / 100)]) / 1e6, Double(s.last!) / 1e6))
        }
        say("ycode-xr-viewer: " + viewer.summary())
        if let dv = viewer.depthView { say("ycode-xr-viewer: " + dv.summary) }
        if let m = o.measure { viewer.writeMeasure(m) }
        try? recorder?.close()
        viewer.client.stop()
        return 0
    }
}

extension XRInputMapper {
    /// A mapper with the viewer's options.
    init(options o: XRViewerOptions) {
        self.init(pointer: o.pointer, stereo: o.stereo)
        palmOrientation = o.palmOrientation
        gazeSettings = o.gaze
        pinchOn = o.pinchOnCentimetres / 100
        pinchOff = o.pinchOffCentimetres / 100
        pinchSlop = o.pinchSlopMillimetres / 1000
        handHoldSeconds = Double(o.handHoldMs) / 1000
        poke = o.poke
    }
}

/// `--hover-probe`: a written script's gaze (never a wearer's: replay only) rests
/// on a place at a time. Where the guest's picture changed during the dwell, and how
/// long after the ray arrived it first did, against where the ray points in the
/// picture: one line per dwell. It says whether what the guest highlights is what
/// the ray points at, and how late.
final class XRHoverProbe {
    private let file: FileHandle?
    private var lastRay: SpatialVector?
    private var rayAt: UInt64 = 0
    private var rayPlace: (u: Double, v: Double)?
    private var baseline: [UInt8]?
    private var lastSequence: UInt64 = 0
    private var first: Double?
    private var bounds: (x0: Int, y0: Int, x1: Int, y1: Int, n: Int)?
    private var pictures = 0
    private var dwell = 0
    static let rows = 512, columns = 288

    init(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        file = FileHandle(forWritingAtPath: path)
        file?.write(Data("dwell\tray_u\tray_v\tchanged_u\tchanged_v\tchanged_w\tchanged_h\tcells\tpictures\tfirst_ms\n".utf8))
    }

    private func report() {
        guard dwell > 0, let place = rayPlace else { return }
        var line = String(format: "%d\t%.3f\t%.3f", dwell, place.u, place.v)
        if let b = bounds {
            let (c, r) = (Double(Self.columns), Double(Self.rows))
            line += String(format: "\t%.3f\t%.3f\t%.3f\t%.3f\t%d", Double(b.x0 + b.x1 + 1) / 2 / c, Double(b.y0 + b.y1 + 1) / 2 / r, Double(b.x1 - b.x0 + 1) / c, Double(b.y1 - b.y0 + 1) / r, b.n)
        } else {
            line += "\t\t\t\t\t0"
        }
        line += String(format: "\t%d\t%@\n", pictures, first.map { String(format: "%.0f", $0) } ?? "")
        file?.write(Data(line.utf8))
    }

    func sample(_ viewer: XRViewer, _ s: XRTrackingSample, _ out: XRInputOutput, mapper: XRInputMapper) {
        guard let anchor = mapper.anchor else { return }
        let now = viewerNanoseconds()
        let d = out.selection.rayDirection
        let stageHead = anchor.toStage(s.head)
        if lastRay == nil || xrAngleDegrees(lastRay!, d) > 1 {
            report()
            lastRay = d
            rayAt = now
            let (w, h) = viewer.guestSize
            rayPlace = XRInset.point(gaze: stageHead.rotation.conjugate.rotate(d), fov: .guest(width: w, height: h))
            dwell += 1
            first = nil
            bounds = nil
            pictures = 0
            baseline = viewer.client.canvas(for: .mono)?.greySamples(rows: Self.rows, columns: Self.columns)
        }
        guard let entry = viewer.board.get(.mono), entry.sequence != lastSequence, let canvas = viewer.client.canvas(for: .mono),
              let base = baseline, entry.decodedAt > rayAt else { return }
        lastSequence = entry.sequence
        pictures += 1
        let g = canvas.greySamples(rows: Self.rows, columns: Self.columns)
        guard g.count == base.count else { return }
        var b = bounds ?? (Self.columns, Self.rows, -1, -1, 0)
        var any = false
        for r in 0..<Self.rows {
            for c in 0..<Self.columns where abs(Int(g[r * Self.columns + c]) - Int(base[r * Self.columns + c])) > 5 {
                (b.x0, b.y0, b.x1, b.y1, b.n) = (min(b.x0, c), min(b.y0, r), max(b.x1, c), max(b.y1, r), b.n + 1)
                any = true
            }
        }
        if any {
            bounds = b
            if first == nil { first = Double(entry.decodedAt - rayAt) / 1e6 }
        }
    }
}

final class XRFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// The GPU's utilisation during a session (nvidia-smi once a second, when
/// it exists): the runtime composites on the same GPU, so a saturated GPU
/// shows up here before it shows in the headset (§9.2).
final class XRGPUSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Int] = []
    private var process: Process?

    func start() {
        let candidates = ["/usr/bin/nvidia-smi", "/usr/local/bin/nvidia-smi"]
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["--query-gpu=utilization.gpu", "--format=csv,noheader,nounits", "-lms", "1000"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            let values = text.split(whereSeparator: \.isNewline).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            self?.lock.withLock { self?.samples += values }
        }
        do { try p.run(); process = p } catch {}
    }

    func stop() -> String? {
        process?.terminate()
        let s = lock.withLock { samples }
        guard !s.isEmpty else { return nil }
        let sorted = s.sorted()
        return "GPU utilisation p50 \(sorted[sorted.count / 2]) %, p90 \(sorted[sorted.count * 9 / 10]) %, max \(sorted.last!) % (\(s.count) s)"
    }
}
