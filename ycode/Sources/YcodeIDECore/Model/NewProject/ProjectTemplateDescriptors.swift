import Foundation

/// One project template: where the chooser lists it, its options and the
/// generator that writes it (`specs/ide/templates.md` § "Template
/// chooser", § "Template catalog"). Names, tabs, sections, sort keys and
/// option identifiers are the spec's; summaries, symbols and generated
/// file contents are Ycode's own.
public struct ProjectTemplateDescriptor: Equatable, Sendable, Identifiable {
    /// Stable identifier "<tab>.<name>" ("ios.app"); `ycode new --template`
    /// takes it, "<Tab>/<Name>" or the name.
    public var id: String
    public var platform: String
    /// "" for the Other tab's unnamed section.
    public var section: String
    public var title: String
    /// The sort key within the section (nil: after those with one).
    public var sortKey: Int?
    public var summary: String
    public var symbol: String
    public var fields: [TemplateOptionField]
    /// Which generator writes it (`ProjectGenerator`).
    public var generator: String
    /// When Ycode cannot create the template yet: why (Next is disabled
    /// and the sheet shows this line).
    public var unavailableReason: String?
    /// The save step's default name (package templates), else the product name.
    public var defaultSaveName: String?

    public init(id: String, platform: String, section: String, title: String, sortKey: Int?, summary: String, symbol: String,
                fields: [TemplateOptionField], generator: String, unavailableReason: String? = nil, defaultSaveName: String? = nil) {
        self.id = id
        self.platform = platform
        self.section = section
        self.title = title
        self.sortKey = sortKey
        self.summary = summary
        self.symbol = symbol
        self.fields = fields
        self.generator = generator
        self.unavailableReason = unavailableReason
        self.defaultSaveName = defaultSaveName
    }

    public var isAvailable: Bool { unavailableReason == nil }
    public var sdk: TemplateSDK { TemplateSDK.forTab(platform) }
    /// "<Section>/<Template>", the per-tab memory's value (§ Persistence).
    public var memoryKey: String { "\(section)/\(title)" }
    public var isPackage: Bool { generator.hasPrefix("package:") }

    /// A fresh options form: `values` where still allowed, else defaults.
    public func makeForm(_ values: [String: String] = [:]) -> TemplateOptionsForm { TemplateOptionsForm(fields: fields, values: values) }

    /// The grid cell for the sheet.
    public var entry: TemplateEntry {
        var e = TemplateEntry(title, defaultName: "", symbol: symbol)
        e.templateID = id
        e.summary = summary
        return e
    }
}

/// A chooser's catalog (New Project, or the Package… chooser).
public struct TemplateChooserCatalog: Sendable {
    public var tabs: [String]
    public var templates: [ProjectTemplateDescriptor]

    /// § Entries: sections alphabetical; within one, ascending key, keyless
    /// after, ties by name.
    public func templates(platform: String) -> [ProjectTemplateDescriptor] {
        templates.filter { $0.platform == platform }.sorted { a, b in
            if a.section != b.section { return a.section.localizedStandardCompare(b.section) == .orderedAscending }
            switch (a.sortKey, b.sortKey) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
    }

    /// The tab's sections, in order. The filter (Ycode's reading, OPEN) is
    /// a case- and diacritic-insensitive substring match on the name.
    public func sections(platform: String, filter: String = "") -> [TemplateSection] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        var order: [String] = []
        var bySection: [String: [TemplateEntry]] = [:]
        for t in templates(platform: platform) {
            if !f.isEmpty, t.title.range(of: f, options: [.caseInsensitive, .diacriticInsensitive]) == nil { continue }
            if bySection[t.section] == nil { order.append(t.section) }
            bySection[t.section, default: []].append(t.entry)
        }
        return order.map { TemplateSection(title: $0, entries: bySection[$0]!) }
    }

    /// A template by identifier, "<Tab>/<Name>", or name (first tab with it).
    public func find(_ key: String, platform: String? = nil) -> ProjectTemplateDescriptor? {
        let k = key.lowercased()
        if let d = templates.first(where: { $0.id == k }) { return d }
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2, tabs.contains(where: { $0.caseInsensitiveCompare(parts[0]) == .orderedSame }) {
            return find(parts[1], platform: parts[0])
        }
        let pool = platform.map { p in templates.filter { $0.platform.caseInsensitiveCompare(p) == .orderedSame } } ?? templates
        if let d = pool.first(where: { $0.id.hasSuffix("." + k) }) { return d }
        return pool.first { $0.title.caseInsensitiveCompare(key) == .orderedSame || ProjectTemplates.slug($0.title) == k }
    }
}

/// The New Project catalog (`templates.md` § "Tabs, sections and
/// templates") and the Package… chooser's.
public enum ProjectTemplates {
    typealias ID = TemplateOptionID
    static let appSection = "Application"
    static let lib = "Framework & Library"

    static func slug(_ s: String) -> String {
        var out = String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func d(_ tab: String, _ section: String, _ title: String, _ key: Int?, _ summary: String, _ symbol: String,
                  _ fields: [TemplateOptionField], _ generator: String, unavailable: String? = nil, save: String? = nil) -> ProjectTemplateDescriptor {
        let prefix = tab == "Multiplatform" ? "multiplatform" : tab.lowercased()
        return ProjectTemplateDescriptor(id: "\(prefix).\(slug(title))", platform: tab, section: section, title: title, sortKey: key,
                                         summary: summary, symbol: symbol, fields: fields, generator: generator,
                                         unavailableReason: unavailable, defaultSaveName: save)
    }

    static let id = TemplateFields.identity
    static let objcUnavailable = "Ycode writes this template in Swift only."
    static let metal4Unavailable = "Ycode has no Metal 4 renderer yet."

    /// Language: Swift, with Objective-C drawn disabled (Ycode writes Swift only).
    static let swiftOnlyLanguage = TemplateOptionField(ID.language, "Language", .popUp(["Swift", TemplateChoice("Objective-C", unavailable: objcUnavailable)]),
                                                       default: "Swift")

    static func gameType(_ values: [String], default def: String, swiftRealityKit: Bool = false) -> TemplateOptionField {
        let all: [String: TemplateChoice] = [
            "RealityKit": TemplateChoice("RealityKit", requires: swiftRealityKit ? [.is(ID.language, "Swift")] : []),
            "SceneKit": TemplateChoice("SceneKit", title: "SceneKit (Deprecated)"),
            "SpriteKit": "SpriteKit",
            "Metal 4": TemplateChoice("Metal 4", unavailable: metal4Unavailable),
            "Metal": "Metal",
        ]
        return TemplateOptionField(ID.gameTechnology, "Game Technology", .popUp(values.map { all[$0]! }), default: def)
    }

    static let integrateGK = TemplateOptionField(ID.integrateGameplayKit, "Integrate GameplayKit", .checkbox, default: "false",
                                                 requires: [.is(ID.gameTechnology, "SpriteKit")])
    static func platform(_ id: String, _ label: String, requires: [TemplateCondition] = []) -> TemplateOptionField {
        TemplateOptionField(id, label, .checkbox, default: "true", requires: requires)
    }

    static let appFields = id + [TemplateFields.interface, TemplateFields.lifecycle, TemplateFields.appLanguage, TemplateFields.testing,
                                 TemplateFields.storage, TemplateFields.cloudKit]

    static func documentStorage(_ coreData: Bool) -> TemplateOptionField {
        var c: [TemplateChoice] = ["None", TemplateChoice("SwiftData", requires: [.is(ID.lifecycle, "SwiftUI")])]
        if coreData { c.append(TemplateChoice("Core Data", requires: [.is(ID.lifecycle, "Cocoa")])) }
        return TemplateOptionField(ID.documentStorage, "Storage", .popUp(c), default: "None")
    }

    static let renderer = TemplateOptionField(ID.immersiveSpaceRenderer, "Immersive Space Renderer", .popUp([
        "None", "RealityKit", "Metal", TemplateChoice("Metal 4", unavailable: metal4Unavailable),
    ]), default: "None")
    static let immersion = TemplateOptionField(ID.immersiveSpace, "Immersive Space", .popUp([
        TemplateChoice("None", requires: [.is(ID.immersiveSpaceRenderer, "None")]),
        TemplateChoice("Mixed", requires: [.not(ID.immersiveSpaceRenderer, "None")]),
        TemplateChoice("Progressive", requires: [.not(ID.immersiveSpaceRenderer, "None")]),
        TemplateChoice("Full", requires: [.not(ID.immersiveSpaceRenderer, "None")]),
    ]), default: "Full", requires: [.not(ID.immersiveSpaceRenderer, "None")])

    static let libraryLanguage = [TemplateFields.language, TemplateFields.unitTesting, TemplateFields.documentation]

    static let audioUnitFields: [TemplateOptionField] = id + [
        TemplateOptionField(ID.organizationName, "Organization Name", .text, placeholder: "Your Company", required: true),
        TemplateOptionField(ID.audioUnitType, "Audio Unit Type", .popUp(["Instrument", "Generator", "Effect", "Music Effect", "MIDI Processor",
                                                                         TemplateChoice("Speech Synthesizer", unavailable: "Ycode has no speech synthesizer unit yet.")]),
                            default: "MIDI Processor"),
        TemplateOptionField(ID.subtypeCode, "Subtype Code", .text, placeholder: "Exactly 4 characters", required: true, persisted: false),
        TemplateOptionField(ID.manufacturerCode, "Manufacturer Code", .text, placeholder: "Exactly 4 characters, at least one upper-case",
                            required: true, persisted: false),
        TemplateOptionField(ID.hasUserInterface, "User Interface", .popUp(["Presents User Interface", "No User Interface"]),
                            default: "Presents User Interface", persisted: false),
        TemplateFields.swiftLanguage, TemplateFields.testing, TemplateFields.storage, TemplateFields.cloudKit,
    ]

    /// Every New Project template.
    public static let all: [ProjectTemplateDescriptor] = {
        var out: [ProjectTemplateDescriptor] = []
        let mp = "Multiplatform", ios = "iOS", mac = "macOS", watch = "watchOS", tv = "tvOS", vision = "visionOS", dk = "DriverKit"
        out += [
            d(mp, appSection, "App", 1, "One SwiftUI app target for iOS, iPadOS, macOS and visionOS", "app.badge",
              id + [TemplateFields.testing, TemplateFields.storage, TemplateFields.cloudKit], "app"),
            d(mp, appSection, "Document App", 1, "The same, built around a document type", "doc.richtext",
              id + [TemplateFields.testing, documentStorage(false)], "documentApp"),
            d(mp, appSection, "Foveated Streaming App", 10, "An iOS sender app and a visionOS receiver app that stream to each other", "eye",
              id + [platform(ID.iOSPlatform, "Include iOS Application"), platform(ID.visionOSPlatform, "Include visionOS Application")],
              "unavailable", unavailable: "Ycode cannot create this template yet: it needs a streaming package Ycode does not have."),
            d(mp, appSection, "Game", 10, "A game for iOS, tvOS, macOS and visionOS in the chosen game technology", "gamecontroller",
              id + [gameType(["RealityKit", "SceneKit", "SpriteKit", "Metal 4", "Metal"], default: "RealityKit"), swiftOnlyLanguage,
                    platform(ID.iOSPlatform, "Include iOS Application"),
                    platform(ID.visionOSPlatform, "Include visionOS Application", requires: [.is(ID.gameTechnology, "RealityKit")]),
                    platform(ID.tvOSPlatform, "Include tvOS Application", requires: [.is(ID.iOSPlatform, "true")]),
                    platform(ID.macOSPlatform, "Include macOS Application")], "game"),
            d(mp, appSection, "Audio Unit Extension App", 30, "A host app with an Audio Unit extension", "waveform", audioUnitFields, "audioUnitApp"),
            d(mp, appSection, "Safari Extension App", nil, "iOS and macOS apps, each with a Safari web extension", "globe",
              id + [swiftOnlyLanguage], "safariExtensionApp"),
            d(mp, lib, "Framework", 1, "A framework built for every Apple platform", "shippingbox",
              id + [TemplateFields.swiftLanguage, TemplateFields.unitTesting, TemplateFields.documentation], "framework"),
        ]
        out += [
            d(ios, appSection, "App", 1, "An iOS app (SwiftUI or UIKit storyboard)", "app.badge", appFields, "app"),
            d(ios, appSection, "Document App", 2, "An iOS document-based app", "doc.richtext",
              id + [TemplateFields.interface.with(choices: ["SwiftUI", TemplateChoice("Storyboard", title: "UIKit")]), TemplateFields.lifecycle,
                    swiftOnlyLanguage, TemplateFields.testing, documentStorage(false)], "documentApp"),
            d(ios, appSection, "Game", 10, "An iOS game (SceneKit, SpriteKit, Metal 4 or Metal)", "gamecontroller",
              id + [gameType(["SceneKit", "SpriteKit", "Metal 4", "Metal"], default: "SpriteKit"), integrateGK, swiftOnlyLanguage,
                    TemplateFields.testing], "game"),
            d(ios, appSection, "Augmented Reality App", 11, "An iOS AR app (RealityKit, SceneKit, SpriteKit or Metal)", "camera.viewfinder",
              id + [TemplateOptionField(ID.contentTechnology, "Content Technology", .popUp([
                        "RealityKit", TemplateChoice("SceneKit", title: "SceneKit (Deprecated)"), "SpriteKit",
                        TemplateChoice("Metal", unavailable: "Ycode has no AR Metal renderer yet."),
                    ]), default: "RealityKit"),
                    TemplateFields.interface.with(choices: [TemplateChoice("SwiftUI", requires: [.is(ID.contentTechnology, "RealityKit")]),
                                                            TemplateChoice("Storyboard", requires: [.not(ID.contentTechnology, "RealityKit")])]),
                    swiftOnlyLanguage, TemplateFields.testing], "arApp"),
            d(ios, appSection, "App Playground", 12, "A Swift Playgrounds app package (.swiftpm)", "play.rectangle",
              [TemplateFields.productName.with(label: "App Name"), TemplateFields.team, TemplateFields.organization, TemplateFields.bundleIdentifier],
              "appPlayground", save: "My App"),
            d(ios, appSection, "Sticker Pack App", 30, "A Messages sticker pack with no code", "face.smiling", id, "stickerPackApp"),
            d(ios, appSection, "iMessage App", 31, "A Messages-only app with an iMessage extension", "message", id + [swiftOnlyLanguage], "iMessageApp"),
            d(ios, appSection, "Safari Extension App", nil, "An iOS app with a Safari web extension", "globe",
              id + [swiftOnlyLanguage, TemplateFields.testing], "safariExtensionApp"),
            d(ios, lib, "Framework", 1, "An iOS framework", "shippingbox", id + libraryLanguage, "framework"),
            d(ios, lib, "Static Library", 10, "An iOS static library", "building.columns", id + [TemplateFields.language], "staticLibrary"),
            d(ios, lib, "Metal Library", nil, "A standalone .metallib", "cube", [TemplateFields.productName, TemplateFields.team], "metalLibrary"),
        ]
        out += [
            d(mac, appSection, "App", 1, "A macOS app (SwiftUI, storyboard or XIB)", "macwindow",
              id + [TemplateFields.interface.with(choices: ["SwiftUI", "Storyboard", "XIB"]), TemplateFields.lifecycle, TemplateFields.appLanguage,
                    TemplateFields.testing, TemplateFields.storage, TemplateFields.cloudKit], "app"),
            d(mac, appSection, "Document App", 1, "A macOS document-based app", "doc.richtext",
              id + [TemplateFields.interface.with(choices: ["SwiftUI", "Storyboard", "XIB"]), TemplateFields.lifecycle, swiftOnlyLanguage,
                    TemplateFields.testing, documentStorage(true)], "documentApp"),
            d(mac, appSection, "Game", 10, "A macOS game (RealityKit, SceneKit, SpriteKit, Metal 4 or Metal)", "gamecontroller",
              id + [gameType(["RealityKit", "SceneKit", "SpriteKit", "Metal 4", "Metal"], default: "SpriteKit", swiftRealityKit: true), integrateGK,
                    swiftOnlyLanguage, TemplateFields.testing], "game"),
            d(mac, appSection, "Spatial Rendering App", 11, "A macOS app that renders an immersive space for Apple Vision Pro", "rectangle.on.rectangle",
              id + [renderer.with(default: "Metal", choices: ["Metal", TemplateChoice("Metal 4", unavailable: metal4Unavailable)]),
                    TemplateOptionField(ID.immersiveSpace, "Immersive Space", .popUp(["Progressive", "Full"]), default: "Full"),
                    TemplateFields.testing], "unavailable",
              unavailable: "Ycode cannot create this template yet: it has no remote immersive-space renderer."),
            d(mac, appSection, "Command Line Tool", 50, "A command-line tool (Swift, Objective-C, C++ or C)", "terminal",
              id + [TemplateFields.language.with(choices: ["Swift", "Objective-C", "C++", "C"])], "commandLineTool"),
            d(mac, appSection, "Safari Extension App", nil, "A macOS app with a Safari web or app extension", "globe",
              id + [TemplateOptionField(ID.safariExtensionType, "Type", .popUp([
                        TemplateChoice("Safari App Extension", unavailable: "Ycode writes Safari Web Extensions only."), "Safari Web Extension",
                    ]), default: "Safari Web Extension"), swiftOnlyLanguage, TemplateFields.testing], "safariExtensionApp"),
            d(mac, lib, "Framework", 1, "A macOS framework", "shippingbox", id + libraryLanguage, "framework"),
            d(mac, lib, "Library", 10, "A dynamic or static library (Cocoa, C++ STL or plain C)", "building.columns",
              id + [TemplateOptionField(ID.libraryFramework, "Framework", .popUp(["Cocoa", TemplateChoice("STL", title: "STL (C++ Library)"),
                                                                                 TemplateChoice("None", title: "None (Plain C/C++ Library)")]), default: "Cocoa"),
                    TemplateOptionField(ID.libraryType, "Type", .popUp(["Dynamic", "Static"]), default: "Dynamic")], "library"),
            d(mac, lib, "XPC Service", 100, "An XPC service bundle", "point.3.connected.trianglepath.dotted",
              id + [swiftOnlyLanguage, TemplateOptionField(ID.apiLevel, "API Level", .popUp([
                  TemplateChoice("Low Level", title: "Low Level - libXPC"), TemplateChoice("High Level", title: "High Level - NSXPCConnection"),
              ]), default: "High Level")], "xpcService"),
            d(mac, lib, "Bundle", 101, "A loadable bundle with a chosen extension", "archivebox",
              id + [TemplateOptionField(ID.bundleExtension, "Bundle Extension", .text, default: "bundle")], "bundle"),
            d(mac, lib, "Metal Library", nil, "A standalone .metallib", "cube", [TemplateFields.productName, TemplateFields.team], "metalLibrary"),
            d(mac, "Other", "Generic Kernel Extension", nil, "A C kernel extension", "cpu", id, "kernelExtension"),
            d(mac, "Other", "IOKit Driver", nil, "A C++ IOKit kernel extension", "cpu.fill", id, "iokitDriver"),
            d(mac, "Other", "Installer Plug-in", nil, "An Installer pane plug-in", "shippingbox.and.arrow.backward", id, "installerPlugin"),
            d(mac, "Other", "Instruments Package", nil, "An Instruments package", "gauge.with.dots.needle.33percent", id, "instrumentsPackage"),
            d(mac, "Other", "Preference Pane", nil, "A System Settings pane bundle", "gearshape", id, "preferencePane"),
            d(mac, "Other", "Screen Saver", nil, "A screen saver bundle", "sparkles.tv", id, "screenSaver"),
        ]
        out += [
            d(watch, appSection, "App", 1, "A watchOS app, alone or with a companion iOS app", "timer",
              id + [TemplateOptionField(ID.watchAppType, "Create Companion iOS App", .popUp([
                        "Watch-only App", "Watch App with New Companion iOS App",
                        TemplateChoice("Watch App for Existing iOS App", unavailable: "Use File ▸ New ▸ Target… in a project with an iOS app."),
                    ]), default: "Watch-only App"), TemplateFields.swiftLanguage, TemplateFields.testing], "watchApp"),
            d(watch, lib, "Framework", 1, "A watchOS framework", "shippingbox", id + [TemplateFields.documentation, TemplateFields.language,
                                                                                       TemplateFields.unitTesting], "framework"),
            d(watch, lib, "Static Library", 10, "A watchOS static library", "building.columns", id + [TemplateFields.language, TemplateFields.unitTesting],
              "staticLibrary"),
        ]
        out += [
            d(tv, appSection, "App", 1, "A tvOS app (SwiftUI or storyboard)", "tv", appFields, "app"),
            d(tv, appSection, "Game", 10, "A tvOS game (RealityKit, SceneKit, SpriteKit, Metal 4 or Metal)", "gamecontroller",
              id + [gameType(["RealityKit", "SceneKit", "SpriteKit", "Metal 4", "Metal"], default: "RealityKit", swiftRealityKit: true), integrateGK,
                    swiftOnlyLanguage, TemplateFields.testing], "game"),
            d(tv, lib, "Framework", 1, "A tvOS framework", "shippingbox", id + libraryLanguage, "framework"),
            d(tv, lib, "Static Library", 10, "A tvOS static library", "building.columns", id + [TemplateFields.language], "staticLibrary"),
            d(tv, lib, "Metal Library", nil, "A standalone .metallib", "cube", [TemplateFields.productName, TemplateFields.team], "metalLibrary"),
        ]
        out += [
            d(vision, appSection, "App", 1, "A visionOS app with a window or a volume, and optionally an immersive space", "cube.transparent",
              id + [TemplateOptionField(ID.initialScene, "Initial Scene", .popUp(["Window", "Volume"]), default: "Window"), renderer, immersion,
                    TemplateFields.swiftLanguage, TemplateFields.unitTesting], "visionApp"),
            d(vision, appSection, "Immersive Environment App", 1, "A visionOS app that opens a full or progressive environment", "mountain.2",
              id + [TemplateOptionField(ID.immersiveSpace, "Immersive Space", .popUp(["Progressive", "Full"]), default: "Full"),
                    TemplateFields.swiftLanguage, TemplateFields.unitTesting], "immersiveEnvironmentApp"),
            d(vision, lib, "Framework", 1, "A visionOS framework", "shippingbox", id + libraryLanguage, "framework"),
            d(vision, lib, "Static Library", 10, "A visionOS static library", "building.columns", id + [TemplateFields.language], "staticLibrary"),
        ]
        out += [
            d(dk, "Driver", "Driver", nil, "A DriverKit driver extension", "cpu", id, "driver"),
            d(dk, lib, "Framework", 1, "A DriverKit framework", "shippingbox",
              id + [TemplateFields.documentation, TemplateFields.language.with(forced: "Objective-C")], "framework"),
            d(dk, lib, "Library", 10, "A DriverKit dynamic or static library", "building.columns",
              id + [TemplateOptionField(ID.libraryType, "Type", .popUp(["Dynamic", "Static"]), default: "Dynamic")], "driverKitLibrary"),
        ]
        out += [
            d("Other", "", "Empty", nil, "A project with no targets", "doc", [TemplateFields.productName, TemplateFields.team], "empty"),
            d("Other", "", "External Build System", nil, "A legacy target that runs a build tool", "hammer",
              id + [TemplateOptionField(ID.buildTool, "Build Tool", .text, default: "/usr/bin/make", required: true)], "externalBuildSystem"),
        ]
        return out
    }()

    public static let projects = TemplateChooserCatalog(tabs: ProjectTemplateCatalog.platforms, templates: all)

    /// The Package… chooser (`templates.md` § "Package…"): SwiftPM's own
    /// `swift package init` types.
    public static let packages: TemplateChooserCatalog = {
        let testing = TemplateOptionField(ID.testingSystem, "Testing System", .popUp(["None", "XCTest", "Swift Testing"]), default: "None")
        func p(_ tab: String, _ section: String, _ title: String, _ key: Int, _ type: String, _ fields: [TemplateOptionField], _ save: String,
               _ symbol: String, _ summary: String) -> ProjectTemplateDescriptor {
            ProjectTemplateDescriptor(id: "package.\(tab == "macOS" ? "macos." : "")\(slug(title))", platform: tab, section: section, title: title,
                                      sortKey: key, summary: summary, symbol: symbol, fields: [TemplateFields.productName] + fields,
                                      generator: "package:\(type)", defaultSaveName: save)
        }
        return TemplateChooserCatalog(tabs: ["Multiplatform", "macOS"], templates: [
            p("Multiplatform", "Library", "Library", 100, "library", [testing], "MyLibrary", "building.columns", "A library package"),
            p("Multiplatform", "Other", "Empty", 100, "empty", [], "MyPackage", "shippingbox", "A package with an empty manifest"),
            p("Multiplatform", "Other", "Build Tool Plug-in", 200, "build-tool-plugin", [], "MyBuildToolPlugin", "hammer", "A build tool plug-in"),
            p("Multiplatform", "Other", "Command Plug-in", 300, "command-plugin", [testing], "MyCommandPlugin", "terminal", "A command plug-in"),
            p("Multiplatform", "Other", "Swift Macro", 400, "macro", [testing.with(default: "XCTest", choices: ["None", "XCTest"])], "MyMacro",
              "number", "A Swift macro package"),
            p("macOS", "Executable", "Command-Line Tool", 100, "tool", [], "MyTool", "terminal.fill", "A command-line tool with argument parsing"),
            p("macOS", "Executable", "Executable", 200, "executable", [], "MyExecutable", "play", "An executable package"),
        ])
    }()

    public static func templates(platform: String) -> [ProjectTemplateDescriptor] { projects.templates(platform: platform) }

    /// A New Project template, or a package template ("package.…").
    public static func find(_ key: String, platform: String? = nil) -> ProjectTemplateDescriptor? {
        if key.lowercased().hasPrefix("package.") { return packages.find(key, platform: platform) }
        return projects.find(key, platform: platform)
    }

    public static func find(platform: String, title: String) -> ProjectTemplateDescriptor? {
        all.first { $0.platform == platform && $0.title == title }
    }

    public static func sections(platform: String, filter: String = "") -> [TemplateSection] { projects.sections(platform: platform, filter: filter) }
}
