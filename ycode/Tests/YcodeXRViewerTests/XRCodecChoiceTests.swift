// The stream's encoding: what the viewer asks for with each capability set,
// what the server picks, and that a fallback is never silent (display-stream.md §14).

import Testing
import YcodeDisplayStream
@testable import YcodeXRViewer

@Suite struct XRCodecChoiceTests {
    static func options(_ args: [String] = []) throws -> XRViewerOptions {
        guard case .run(let o) = XRViewerOptions.parse(["--connect", "unix:/x"] + args) else { throw XRCodecTestError.parse }
        return o
    }
    enum XRCodecTestError: Error { case parse }

    /// A decoder with what `have` names; the others say why not.
    static func problem(_ have: Set<String>) -> (String) -> String? { { have.contains($0) ? nil : "no \($0) here" } }

    static let cases: [(have: Set<String>, offered: [String], chosen: String)] = [
        (["hevc444", "hevc", "h264", "jpeg", "zlib"], ["jpeg", "zlib", "hevc444", "hevc", "h264"], "hevc444"),
        (["hevc", "h264", "jpeg", "zlib"], ["jpeg", "zlib", "hevc444", "hevc", "h264"], "hevc"),
        (["hevc444", "hevc", "h264", "zlib"], ["jpeg", "zlib", "hevc", "h264"], "hevc"),            // the server's NVENC has no 4:4:4
        (["hevc444", "hevc", "h264", "zlib"], ["jpeg", "zlib", "h264"], "h264"),                    // an older server
        (["jpeg", "zlib"], ["jpeg", "zlib", "hevc444", "hevc", "h264"], "jpeg"),                    // no NVDEC
        (["zlib"], ["jpeg", "zlib", "h264"], "zlib"),                                               // run 7's x86 without NVDEC
    ]

    @Test(arguments: 0..<cases.count)
    func theBestCommonEncodingIsChosen(index: Int) throws {
        let c = Self.cases[index]
        let o = try Self.options()
        let hello = o.hello(problem: Self.problem(c.have))
        #expect(DisplayCodecChoice.serverPick(hello: hello, offered: c.offered) == c.chosen)
    }

    @Test(arguments: 0..<cases.count)
    func everyFallbackWarnsAndNamesWhy(index: Int) throws {
        let c = Self.cases[index]
        let o = try Self.options()
        let plan = o.encodingPlan(problem: Self.problem(c.have))
        let w = DisplayCodecChoice.warning(viewer: "v", wishes: plan.wishes, missing: plan.missing, offered: c.offered, chosen: c.chosen)
        if c.chosen == "hevc444" {
            #expect(w == nil)
        } else {
            let text = try #require(w)
            #expect(text.contains("WARNING"))
            #expect(text.contains(c.chosen))
            #expect(text.contains("expect "))
            #expect(text.contains("--encoding"))
            for better in plan.wishes.prefix(while: { $0 != c.chosen }) { #expect(text.contains("\(better):"), "\(better) missing from \(text)") }
        }
    }

    @Test func zlibSaysHowSlowItIs() {
        let w = DisplayCodecChoice.warning(viewer: "v", wishes: ["h264", "zlib"], missing: [("h264", "no NVDEC")], offered: ["zlib"], chosen: "zlib")
        #expect(w?.contains("pictures a second") == true)
        #expect(w?.contains("no NVDEC") == true)
    }

    @Test func aNamedEncodingIsTheFirstWishAndWhatFollowsTheFallback() throws {
        let o = try Self.options(["--encoding", "h264"])
        let plan = o.encodingPlan(problem: Self.problem(["jpeg", "zlib", "h264"]))
        #expect(plan.wishes == ["h264", "jpeg", "zlib"])
        #expect(o.hello(problem: Self.problem(["jpeg", "zlib", "h264"])).encoding == "h264")
        #expect(try Self.options(["--encoding", "auto"]).encoding == nil)
        if case .run = XRViewerOptions.parse(["--connect", "unix:/x", "--encoding", "vp9"]) { Issue.record("vp9 parsed") }
    }

    @Test func foveationStartsFromTiles() throws {
        let o = try Self.options(["--foveate"])
        #expect(o.encodingPlan(problem: Self.problem(["hevc", "jpeg", "zlib"])).usable == ["jpeg", "zlib"])
    }

    @Test func videoRateControlGoesInTheHello() throws {
        let qp = try Self.options(["--video-qp", "20"]).hello(problem: Self.problem(["hevc"]))
        #expect(qp.videoQP == 20 && qp.videoBitrate == nil && qp.videoFPS == nil)
        let cbr = try Self.options(["--video-bitrate", "50000", "--video-fps", "24"]).hello(problem: Self.problem(["hevc"]))
        #expect(cbr.videoQP == nil && cbr.videoBitrate == 50000 && cbr.videoFPS == 24)
    }

    @Test func helloRoundTripsTheNewFields() throws {
        var h = DisplayClientHello(client: "c", encoding: "hevc444")
        h.encodings = ["hevc444", "hevc"]
        h.videoQP = 24
        h.videoFPS = 30
        let bytes = DisplayMessage.clientHello(h).encoded()
        var parser = DisplayMessageParser()
        parser.append(bytes)
        guard case .clientHello(let back)? = try parser.next() else { Issue.record("no hello"); return }
        #expect(back == h)
        #expect(DisplayEncoding(name: "hevc444")?.isVideo == true && DisplayEncoding(name: "hevc")?.rawValue == 4 && DisplayEncoding(name: "jpeg")?.isVideo == false)
    }

    /// An older client (no list) keeps its encoding, or the server's first.
    @Test func olderClientsAreServedAsBefore() {
        var h = DisplayClientHello(client: "old", encoding: "jpeg")
        #expect(DisplayCodecChoice.serverPick(hello: h, offered: ["jpeg", "zlib", "h264"]) == "jpeg")
        h.encoding = "vp9"
        #expect(DisplayCodecChoice.serverPick(hello: h, offered: ["jpeg", "zlib", "h264"]) == "jpeg")
    }
}
