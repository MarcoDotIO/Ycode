import Foundation
import Testing
@testable import YcodeSimFeatures

/// FEAT (specs/simulator/simulator-features.md §4, "Ycode implementation"):
/// the per-feature preference writes and setter notifications, the getters,
/// the location sequences and files, the audio files, the channel's frames,
/// the command grammar and the environment overrides.
struct SimFeatureMappingTests {
    func keys(_ p: SettingsPlan) -> [String] { p.writes.map { "\($0.domain) \($0.key)=\($0.value?.description ?? "-")" } }

    @Test func appearanceWritesTheStyleMode() {
        let dark = SimFeatureMapping.plan(for: .appearance(.dark))
        #expect(keys(dark) == ["com.apple.uikitservices.userInterfaceStyleMode UserInterfaceStyleMode=2"])
        #expect(dark.notifications.isEmpty)  // SpringBoard announces the change (Q8)
        #expect(SimFeatureMapping.plan(for: .appearance(.light)).writes[0].value == .int(1))
    }

    @Test func liquidGlassWritesOpacityAndLook() {
        let p = SimFeatureMapping.plan(for: .liquidGlass(opacity: 0.4, look: .tinted))
        #expect(keys(p) == ["com.apple.UIKit UIViewGlassTintAmount=0.4", "com.apple.UIKit UIViewGlassLegibilitySetting=1"])
        #expect(p.notifications == ["UIViewGlassTintAmountUpdateNotification", "UIViewGlassLegibilityUpdateNotification"])
        // clear is the absent key; an opacity alone posts one notification.
        #expect(SimFeatureMapping.plan(for: .liquidGlass(opacity: nil, look: .clear)).writes[0].value == nil)
        #expect(SimFeatureMapping.plan(for: .liquidGlass(opacity: 2, look: nil)).writes == [PreferenceWrite("com.apple.UIKit", "UIViewGlassTintAmount", .real(1))])
    }

    @Test func colorFiltersWriteMediaAccessibility() {
        let p = SimFeatureMapping.plan(for: .colorFilter(.protanopia, intensity: 0.5))
        #expect(keys(p) == ["com.apple.mediaaccessibility __Color__.MADisplayFilterCategoryEnabled=1",
                            "com.apple.mediaaccessibility __Color__.MADisplayFilterType=2",
                            "com.apple.mediaaccessibility MADisplayFilterRedColorCorrectionIntensity=0.5",
                            "com.apple.Accessibility GrayscaleDisplay=0",
                            "com.apple.Accessibility DidCheckGrayscaleValue-v2=1"])
        #expect(p.notifications == ["com.apple.mediaaccessibility.displayFilterSettingsChanged",
                                    "com.apple.accessibility.displayFilterForceUpdate",
                                    "com.apple.accessibility.red-color-filter"])
        let g = SimFeatureMapping.plan(for: .colorFilter(.grayscale, intensity: nil))
        #expect(g.writes.contains(PreferenceWrite("com.apple.Accessibility", "GrayscaleDisplay", .int(1))))
        #expect(g.writes.contains(PreferenceWrite("com.apple.mediaaccessibility", "__Color__.MADisplayFilterType", .int(1))))
        #expect(!g.writes.contains { $0.key.hasSuffix("Intensity") })
        // Intensity is clamped to 0.25…1 and defaults to 1.
        #expect(SimFeatureMapping.plan(for: .colorFilter(.tritanopia, intensity: 0.1)).writes[2] ==
                PreferenceWrite("com.apple.mediaaccessibility", "MADisplayFilterBlueColorCorrectionIntensity", .real(0.25)))
        #expect(SimFeatureMapping.plan(for: .colorFilter(.deuteranopia, intensity: nil)).writes[2].value == .real(1))
        let off = SimFeatureMapping.plan(for: .colorFilter(.none, intensity: nil))
        #expect(off.writes.first == PreferenceWrite("com.apple.mediaaccessibility", "__Color__.MADisplayFilterCategoryEnabled", .int(0)))
        #expect(off.notifications.count == 5)
        #expect(!SimFeatureMapping.persists(.colorFilter(.grayscale, intensity: nil)))
        #expect(SimFeatureMapping.persists(.appearance(.dark)))
    }

    @Test func textSizeWritesTheCategoryAndExtendedRange() {
        let p = SimFeatureMapping.plan(for: .contentSize(.accessibilityExtraLarge))
        #expect(keys(p) == ["com.apple.UIKit UIPreferredContentSizeCategoryName=\"UICTContentSizeCategoryAccessibilityXL\"",
                            "com.apple.preferences-framework largeTextUsesExtendedRange=true"])
        #expect(p.notifications == ["ApplePreferredContentSizeCategoryChangedNotification"])
        #expect(SimFeatureMapping.plan(for: .contentSize(.small)).writes.count == 1)
        #expect(ContentSize.allCases.map(\.categoryName).last == "UICTContentSizeCategoryAccessibilityXXXL")
        #expect(ContentSize.large.stepped(by: 1) == .extraLarge)
        #expect(ContentSize.extraSmall.stepped(by: -1) == .extraSmall)
        #expect(ContentSize.accessibilityExtraExtraExtraLarge.stepped(by: 1) == .accessibilityExtraExtraExtraLarge)
        #expect(ContentSize(categoryName: "UICTContentSizeCategoryXXL") == .extraExtraLarge)
    }

    @Test func accessibilitySwitches() {
        #expect(keys(SimFeatureMapping.plan(for: .accessibility(.reduceMotion, true))) ==
                ["com.apple.Accessibility ReduceMotionEnabled=1", "com.apple.Accessibility PointerEffectScalingEnabled=0"])
        #expect(SimFeatureMapping.plan(for: .accessibility(.reduceMotion, false)).writes[1].value == nil)
        #expect(SimFeatureMapping.plan(for: .accessibility(.reduceMotion, true)).notifications ==
                ["com.apple.accessibility.cache.ax", "com.apple.accessibility.reduce.motion.status"])
        #expect(keys(SimFeatureMapping.plan(for: .accessibility(.increaseContrast, false))) ==
                ["com.apple.Accessibility DarkenSystemColors=0", "com.apple.Accessibility PointerIncreasedContrastEnabled=0"])
        #expect(SimFeatureMapping.plan(for: .accessibility(.increaseContrast, true)).notifications ==
                ["com.apple.accessibility.cache.ax", "com.apple.accessibility.status", "com.apple.accessibility.darken.system.colors"])
        #expect(keys(SimFeatureMapping.plan(for: .accessibility(.showBorders, true))) == ["com.apple.Accessibility ButtonShapesEnabled=1"])
        #expect(SimFeatureMapping.plan(for: .accessibility(.showBorders, true)).notifications == ["com.apple.accessibility.button.shapes"])
        #expect(keys(SimFeatureMapping.plan(for: .accessibility(.reduceTransparency, true))) ==
                ["com.apple.Accessibility EnhancedBackgroundContrastEnabled=1"])
        let vo = SimFeatureMapping.plan(for: .accessibility(.voiceOver, true))
        #expect(keys(vo) == ["com.apple.Accessibility VoiceOverTouchEnabled=1", "com.apple.Accessibility AccessibilityEnabled=true",
                             "com.apple.Accessibility ApplicationAccessibilityEnabled=1"])
        #expect(vo.waitForVoiceOver == true && vo.startServices == ["com.apple.VoiceOverTouch"])
        #expect(SimFeatureMapping.plan(for: .accessibility(.voiceOver, false)).startServices.isEmpty)
        #expect(SettingsChannel.apply(vo)["startServices"] as? [String] == ["com.apple.VoiceOverTouch"])
        // After a boot: start the screen reader only when enabled and not running.
        var state = SimSettingsState()
        #expect(SimFeatureMapping.bootPlan(state) == nil)
        state.switches[.voiceOver] = true
        #expect(SimFeatureMapping.bootPlan(state)?.startServices == ["com.apple.VoiceOverTouch"])
        state.voiceOverRunning = true   // a key left over from a killed reader
        #expect(SimFeatureMapping.bootPlan(state)?.startServices == ["com.apple.VoiceOverTouch"])
        state.switches[.voiceOver] = false
        let clean = SimFeatureMapping.bootPlan(state)
        #expect(clean?.startServices == [] && clean.map(keys) == ["com.apple.Accessibility VOTIsRunningKey=-",
                                                                 "com.apple.VoiceOverTouch VOTIsRunningKey=-"])
        #expect(vo.notifications == ["com.apple.accessibility.cache.ax", "com.apple.accessibility.cache.app.ax",
                                     "com.apple.accessibility.application.status"])
    }

    @Test func stateReadsBackFromValues() {
        var v: [String: PrefValue] = [:]
        v[PreferenceRead(SimPrefs.styleDomain, SimPrefs.styleKey).tag] = .int(2)
        v[PreferenceRead(SimPrefs.uikit, SimPrefs.contentSize).tag] = .string("UICTContentSizeCategoryXL")
        v[PreferenceRead(SimPrefs.mediaAccessibility, SimPrefs.filterEnabled).tag] = .int(1)
        v[PreferenceRead(SimPrefs.mediaAccessibility, SimPrefs.filterType).tag] = .int(4)
        v[PreferenceRead(SimPrefs.mediaAccessibility, "MADisplayFilterGreenColorCorrectionIntensity").tag] = .real(0.5)
        v[PreferenceRead(SimPrefs.accessibility, SimPrefs.reduceMotion).tag] = .int(1)
        v[PreferenceRead(SimPrefs.accessibility, SimPrefs.voiceOverRunning).tag] = .bool(true)
        let s = SimSettingsState(values: v)
        #expect(s.appearance == .dark && s.contentSize == .extraLarge && s.colorFilter == .deuteranopia)
        #expect(s.colorFilterIntensity == 0.5 && s.isOn(.reduceMotion) && !s.isOn(.showBorders) && s.voiceOverRunning)
        // Absent keys are the defaults; the lines round-trip.
        #expect(SimSettingsState(values: [:]) == SimSettingsState())
        #expect(SimSettingsState(lines: s.lines) == s)
        #expect(SimFeatureMapping.stateReads.count == Set(SimFeatureMapping.stateReads).count)
    }
}

struct SimLocationTests {
    @Test func requestSequencesFollowTheSpec() {
        let c = Coordinate(37.33, -122.03)
        #expect(SimLocation.steps(for: .set(c)) == [.clear, .stop, .append(c), .start])
        #expect(SimLocation.steps(for: .clear) == [.stop, .clear])
        let d = Coordinate(37.34, -122.02)
        #expect(SimLocation.steps(for: .route([c, d], speed: 15, spacing: .interval(2))) ==
                [.stop, .clear, .interval(2), .speed(15), .append(c), .append(d), .start])
        #expect(SimLocation.steps(for: .route([c, d], speed: 15, spacing: .distance(50)))[2] == .distance(50))
        #expect(SimLocation.steps(for: .scenario(name: "City Run")) ==
                [.stop, .clear, .loadScenario(SimLocation.scenarioDirectory + "/City Run.plist"), .start])
        let pts = [ScenarioPoint(c, time: 0)]
        #expect(SimLocation.steps(for: .points(pts, loop: true), ycodeScenarioPath: "/tmp/s.plist") ==
                [.stop, .clear, .writeScenario(path: "/tmp/s.plist", points: pts, repeatBehavior: 2), .loadScenario("/tmp/s.plist"), .start])
        #expect(LocationStep.append(c).dictionary["call"] as? String == "append")
    }

    @Test func coordinatesAndPresets() {
        #expect(Coordinate(argument: "37.33,-122.03") == Coordinate(37.33, -122.03))
        #expect(Coordinate(argument: " 1.5 , 2 ") == Coordinate(1.5, 2))
        #expect(Coordinate(argument: "91,0") == nil && Coordinate(argument: "0,181") == nil && Coordinate(argument: "1;2") == nil)
        #expect(SimLocation.presets.count == 14)
        #expect(SimLocation.preset(named: "tokyo") == Coordinate(35.6762, 139.6503))
        #expect(SimLocation.preset(named: "San Francisco, CA, USA") != nil)
        let a = Coordinate(0, 0), b = Coordinate(0, 1)
        #expect(abs(a.distance(to: b) - 111_195) < 50)
        #expect(abs(a.bearing(to: b) - 90) < 0.001 && abs(b.bearing(to: a) - 270) < 0.001)
    }

    @Test func gpxTrackWithTimesBecomesAScenario() throws {
        let gpx = """
        <?xml version="1.0"?><gpx version="1.1" creator="t"><trk><trkseg>
        <trkpt lat="37.0" lon="-122.0"><ele>10</ele><time>2026-01-01T00:00:00Z</time></trkpt>
        <trkpt lat='37.001' lon='-122.0'><time>2026-01-01T00:00:10Z</time></trkpt>
        <trkpt lat="37.002" lon="-122.0"><time>2026-01-01T00:00:20.5Z</time></trkpt>
        </trkseg></trk></gpx>
        """
        guard case .points(let p, let loop) = try SimLocation.parseFile(gpx) else { Issue.record("not points"); return }
        #expect(p.count == 3 && !loop)
        #expect(p[0].altitude == 10 && p[0].verticalAccuracy == 5 && p[1].verticalAccuracy == -1)
        #expect(p[2].time == 20.5 && abs(p[0].speed - 11.12) < 0.05 && abs(p[0].course) < 0.01)
    }

    @Test func gpxWithoutTimesIsARoute() throws {
        let gpx = "<gpx><rte><rtept lat=\"1\" lon=\"2\"/><rtept lat=\"1.1\" lon=\"2\"/></rte><wpt lat=\"9\" lon=\"9\"/></gpx>"
        #expect(try SimLocation.parseFile(gpx) == .route([Coordinate(1, 2), Coordinate(1.1, 2)], speed: 20, spacing: .interval(1)))
        #expect(try SimLocation.parseFile("<gpx><wpt lat=\"5\" lon=\"6\"></wpt></gpx>") == .set(Coordinate(5, 6)))
        #expect(throws: SimLocation.FileError.self) { try SimLocation.parseFile("<gpx></gpx>") }
        #expect(throws: SimLocation.FileError.self) { try SimLocation.parseFile("<gpx><trkpt lat=\"x\" lon=\"1\"/></gpx>") }
    }

    @Test func routeJSONAndCoordinateLists() throws {
        let json = #"{"mode":"distance","distance":25,"speed":3.5,"waypoints":[{"latitude":1,"longitude":2},{"latitude":1.01,"longitude":2.01}]}"#
        #expect(try SimLocation.parseFile(json) == .route([Coordinate(1, 2), Coordinate(1.01, 2.01)], speed: 3.5, spacing: .distance(25)))
        #expect(throws: SimLocation.FileError.self) { try SimLocation.parseFile(#"{"waypoints":[{"latitude":1,"longitude":2}]}"#) }
        #expect(throws: SimLocation.FileError.self) { try SimLocation.parseFile(#"{"mode":"x","waypoints":[{"latitude":1,"longitude":2},{"latitude":1,"longitude":3}]}"#) }
        #expect(try SimLocation.parseFile("# a walk\n1,2\n3,4\n") == .route([Coordinate(1, 2), Coordinate(3, 4)], speed: 20, spacing: .interval(1)))
        #expect(try SimLocation.parseFile("48.85,2.35") == .set(Coordinate(48.85, 2.35)))
        #expect(throws: SimLocation.FileError.self) { try SimLocation.parseFile("1,2\nnope") }
    }
}

struct SimAudioTests {
    @Test func filesForEachChoice() {
        let def = SimAudioSettings()
        #expect(SimAudio.hostFile(def)["useHostDefaultOutputDevice"] as? Bool == true)
        #expect(SimAudio.hostFile(def)["sim_output_device_uid"] as? String == SimAudio.ycodeOutputUID)
        #expect(SimAudio.settingsFile(def)["sim_volume"] as? Int == 60)
        let none = SimAudioSettings(volume: 130, output: .none, input: .none)
        #expect(SimAudio.hostFile(none)["sim_output_device_uid"] as? String == "")
        #expect(SimAudio.hostFile(none)["useHostDefaultOutputDevice"] as? Bool == false)
        #expect(SimAudio.settingsFile(none)["sim_volume"] as? Int == 100)
        let dev = SimAudioSettings(volume: 30, output: .device("X:output"), input: .system)
        #expect(SimAudio.settingsFile(dev)["sim_output_device_uid"] as? String == "X:output")
        // Read back.
        for s in [def, SimAudioSettings(volume: 30, output: .none, input: .none), dev] {
            #expect(SimAudio.settings(hostFile: SimAudio.hostFile(s), settingsFile: SimAudio.settingsFile(s)) == s)
        }
        #expect(SimAudio.settings(hostFile: nil, settingsFile: nil) == SimAudioSettings())
        #expect(AudioDeviceChoice(argument: "System") == .system && AudioDeviceChoice(argument: "none") == .none)
    }
}

struct SettingsChannelTests {
    @Test func framesRoundTrip() throws {
        let plan = SimFeatureMapping.plan(for: .liquidGlass(opacity: 0.5, look: .clear))
        var buffer = SettingsChannel.frame(["id": 7] .merging(SettingsChannel.apply(plan)) { a, _ in a })!
        let second = SettingsChannel.frame(SettingsChannel.read(SimFeatureMapping.stateReads))!
        buffer += second.prefix(3)   // a partial frame stays
        let frames = try SettingsChannel.takeFrames(&buffer)
        #expect(frames.count == 1 && buffer.count == 3)
        let m = frames[0]
        #expect(m["id"] as? Int == 7 && m["op"] as? String == "apply")
        let writes = m["writes"] as? [[String: Any]] ?? []
        #expect(writes.count == 2 && writes[0]["value"] as? Double == 0.5 && writes[1]["value"] == nil)
        buffer += second.dropFirst(3)
        let reads = try SettingsChannel.takeFrames(&buffer)
        #expect(reads.count == 1 && (reads[0]["reads"] as? [Any])?.count == SimFeatureMapping.stateReads.count && buffer.isEmpty)
    }

    @Test func badFramesAreRefused() {
        var big: [UInt8] = [0x7F, 0, 0, 0]
        #expect(throws: SettingsChannel.ChannelError.frameTooLarge(0x7F00_0000)) { try SettingsChannel.takeFrames(&big) }
        var junk: [UInt8] = [0, 0, 0, 3, 1, 2, 3]
        #expect(throws: SettingsChannel.ChannelError.notADictionary) { try SettingsChannel.takeFrames(&junk) }
    }

    @Test func replyValuesKeepTheirTypes() throws {
        var b = SettingsChannel.frame(["id": 1, "ok": true, "values": ["a|b": 2, "c|d": 0.5, "e|f": "s", "g|h": true]])!
        let reply = try SettingsChannel.takeFrames(&b)[0]
        let v = SettingsChannel.values(of: reply)
        #expect(v["a|b"]?.intValue == 2 && v["c|d"] == .real(0.5) && v["e|f"] == .string("s") && v["g|h"]?.intValue == 1)
    }
}

struct SimSettingsCommandTests {
    func p(_ s: String) throws -> SimSettingsCommand { try SimSettingsCommand.parse(s.split(separator: " ").map(String.init)) }

    @Test func uiCommands() throws {
        #expect(try p("ui appearance dark") == .set(.appearance(.dark)))
        #expect(try p("ui appearance") == .getAppearance)
        #expect(try p("ui appearance toggle") == .toggleAppearance)
        #expect(try p("ui content_size accessibility-large") == .set(.contentSize(.accessibilityLarge)))
        #expect(try p("ui content_size increment") == .stepContentSize(1))
        #expect(try p("ui content_size") == .getContentSize)
        #expect(try p("ui increase_contrast enabled") == .set(.accessibility(.increaseContrast, true)))
        #expect(try p("ui increase_contrast") == .getIncreaseContrast)
        #expect(try p("ui liquid-glass 0.3 tinted") == .set(.liquidGlass(opacity: 0.3, look: .tinted)))
        #expect(try p("ui color-filter protanopia 0.5") == .set(.colorFilter(.protanopia, intensity: 0.5)))
        #expect(try p("ui color-filter grayscale") == .set(.colorFilter(.grayscale, intensity: nil)))
        #expect(throws: SimSettingsCommand.ParseError.self) { try p("ui color-filter grayscale 0.5") }
        #expect(throws: SimSettingsCommand.ParseError.self) { try p("ui appearance purple") }
        #expect(throws: SimSettingsCommand.ParseError.self) { try p("ui liquid-glass 2") }
    }

    @Test func accessibilityLocationAudio() throws {
        #expect(try p("accessibility reduce-motion on") == .set(.accessibility(.reduceMotion, true)))
        #expect(try p("accessibility voiceover off") == .set(.accessibility(.voiceOver, false)))
        #expect(try p("accessibility show-borders") == .getSwitch(.showBorders))
        #expect(try p("location set 48.85,2.35") == .location(.set(Coordinate(48.85, 2.35))))
        #expect(try p("location preset Tokyo") == .location(.set(Coordinate(35.6762, 139.6503))))
        #expect(try p("location start --speed=5 --distance=10 1,2 3,4") ==
                .location(.route([Coordinate(1, 2), Coordinate(3, 4)], speed: 5, spacing: .distance(10))))
        #expect(throws: SimSettingsCommand.ParseError.self) { try p("location start 1,2") }
        #expect(try p("location run City Run") == .location(.scenario(name: "City Run")))
        #expect(try p("location run /tmp/a.gpx") == .locationFile("/tmp/a.gpx"))
        #expect(try p("location run /x/My Run.plist") == .location(.scenario(name: "/x/My Run.plist")))
        #expect(try p("location clear") == .location(.clear))
        #expect(try p("audio volume 30") == .volume(30))
        #expect(try p("audio volume up") == .stepVolume(10))
        #expect(try p("audio output none") == .output(.none))
        #expect(try p("audio input") == .getInput)
        #expect(throws: SimSettingsCommand.ParseError.self) { try p("audio volume 101") }
        #expect(try p("settings") == .state)
        let clear = try p("location clear"), dark = try p("ui appearance dark"), gray = try p("ui color-filter grayscale")
        #expect(!clear.worksOffline && dark.worksOffline && !gray.worksOffline)
    }

    @Test func environmentOverrides() throws {
        #expect(try p("overrides com.x.app appearance=dark reduce-motion=on") ==
                .overrides(bundleID: "com.x.app", .set([.appearance: "dark", .reduceMotion: "on"])))
        #expect(try p("overrides com.x.app") == .overrides(bundleID: "com.x.app", .show))
        #expect(throws: SimSettingsCommand.ParseError.self) { try p("overrides com.x.app appearance=blue") }
        var o = EnvironmentOverrides()
        o.apply(.set([.dynamicType: "accessibility-large", .boldText: "off", .appearance: "light"]))
        #expect(o.words == ["appearance=light", "dynamic-type=accessibility-large", "bold-text=off"])
        #expect(o.plist["dynamic-type"] as? String == "UICTContentSizeCategoryAccessibilityL")
        #expect(o.plist["bold-text"] as? Bool == false)
        #expect(EnvironmentOverrides(plist: o.plist) == o)
        o.apply(.set([.appearance: nil]))
        #expect(o.values[.appearance] == nil)
        o.apply(.clear)
        #expect(o.isEmpty)
        #expect(EnvironmentOverrides.Item.allCases.count == 11)
        #expect(EnvironmentOverrides.Item.dynamicType.choices.count == 12)
        #expect(EnvironmentOverrides.Item.reduceMotion.choices.map(\.title) == ["Reduced", "Default"])
    }

    @Test func environmentOverrideSections() throws {
        let s = EnvironmentOverrides.Sections(appearance: .dark, dynamicType: nil, accessibility: [.reduceMotion: true, .grayscale: true])
        let o = EnvironmentOverrides(sections: s)
        #expect(o.values[.appearance] == "dark" && o.values[.dynamicType] == nil)
        #expect(o.values[.reduceMotion] == "on" && o.values[.boldText] == "off" && o.values.count == 10)
        #expect(o.sections.appearance == .dark && o.sections.accessibility?[.grayscale] == true && o.sections.dynamicType == nil)
        let w = o.commandWords(bundleID: "a.b")
        #expect(w.prefix(3) == ["overrides", "a.b", "appearance=dark"] && w.contains("dynamic-type=none") && w.contains("smart-invert=off"))
        // The words parse back to the same overrides.
        var back = EnvironmentOverrides()
        guard case .overrides(_, let req) = try SimSettingsCommand.parse(w) else { Issue.record("not overrides"); return }
        back.apply(req)
        #expect(back == o)
        #expect(EnvironmentOverrides().commandWords(bundleID: "a.b") == ["overrides", "a.b", "clear"])
        #expect(EnvironmentOverrides.accessibilityItems.count == 9)
    }
}
