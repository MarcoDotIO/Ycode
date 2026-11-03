import Foundation
import SwiftUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
import YcodeIDECore
import YcodeIDEShell
import YcodeRelease
#if os(Linux)
import OVText
#endif

// ycode-ide: the SwiftUI workspace shell (docs/PARITY.md §5, milestone L1).
// On Linux `import SwiftUI` is OpenViews (frameworks/swiftui), Ycode's own
// SwiftUI; on macOS it is Apple's SwiftUI, so the same views prove the
// shell is shared. The macOS product is still the AppKit IDE (YcodeApp).
//
//     ycode-ide [<project, workspace, Package.swift or package folder>]
//
// Without a path the Welcome screen shows; File ▸ Open… asks for a path.
// The Linux driver switches (ShellDriver.swift) run only on OpenViews.

/// The app's one model, shared by the scene, the menus and the driver.
@MainActor
enum ShellApp {
    static let model = ShellAppModel()
}

@main
struct YcodeIDEApp: App {
    init() {
        YcodeRelease.handleVersionFlag(tool: "ycode-ide")
        YcodeRelease.adoptBundledHelpers()
        ShellLook.apply()
        if let path = ShellAppModel.launchPath() {
            if !ShellApp.model.open(path: path) {
                FileHandle.standardError.write(Data("ycode-ide: \(ShellApp.model.openError ?? "cannot open \(path)")\n".utf8))
            }
        }
    }

    var body: some Scene {
        WindowGroup("Ycode") {
            ShellRootView(app: ShellApp.model)
        }
        .defaultSize(width: ShellMetrics.windowSize.width, height: ShellMetrics.windowSize.height)
        .commands { ShellMenus(app: ShellApp.model) }
    }
}

/// The window's content: Welcome, or the workspace.
struct ShellRootView: View {
    @Bindable var app: ShellAppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if let ws = app.workspace {
                WorkspaceView(model: ws, app: app)
            } else {
                WelcomeView(app: app)
            }
        }
        // File ▸ Open…: the toolkit's file dialog (OpenViews draws its own
        // on Linux).
        .fileImporter(isPresented: $app.isOpenSheetShown, allowedContentTypes: ShellOpenTypes.all) { result in
            if case .success(let url) = result { app.open(path: url.path) }
        }
        .fileDialogDefaultDirectory(app.recent.first?.deletingLastPathComponent())
        // File ▸ New ▸ Project…: the core's New Project flow.
        .sheet(isPresented: Binding(get: { app.newProject != nil }, set: { if !$0 { app.cancelNewProject() } })) {
            if let m = app.newProject { NewProjectSheet(model: m, app: app) }
        }
        .sheet(isPresented: Binding(get: { app.clone != nil }, set: { if !$0 { app.cancelClone() } })) {
            if let m = app.clone { CloneSheet(model: m, app: app) }
        }
        .sheet(isPresented: $app.isAboutShown) { AboutSheet(app: app) }
        .alert(app.notice?.title ?? "", isPresented: Binding(get: { app.notice != nil }, set: { if !$0 { app.notice = nil } })) {
            Button("OK") { app.notice = nil }
        } message: {
            Text(verbatim: app.notice?.message ?? "")
        }
        .alert("Cannot Open", isPresented: Binding(get: { app.openError != nil && !app.isOpenSheetShown },
                                                   set: { if !$0 { app.clearOpenError() } })) {
            Button("OK") { app.clearOpenError() }
        } message: {
            Text(verbatim: app.openError ?? "")
        }
        .onAppear {
            let app = app, openURL = openURL
            app.openExternally = { url in
                openURL(url) { accepted in
                    if !accepted { app.linkCouldNotOpen(url) }
                }
            }
        }
        .task { await ShellDriver.start(app) }
    }
}

/// What File ▸ Open… accepts: projects, workspaces, Package.swift, folders.
enum ShellOpenTypes {
    static var all: [UTType] {
        [UTType(filenameExtension: "xcodeproj", conformingTo: .package),
         UTType(filenameExtension: "xcworkspace", conformingTo: .package),
         .swiftSource, .folder].compactMap { $0 }
    }
}

/// Window sizes (`workspace-window.md`, `WorkspaceChrome`): the AppKit
/// window's 1400 × 900, plus, on Linux, the in-window menu bar above it
/// (OpenViews draws the menu bar in the window, 26 points), so the area
/// under the menu bar is the AppKit window's size.
enum ShellMetrics {
    #if os(Linux)
    static let menuBarHeight: CGFloat = 26
    #else
    static let menuBarHeight: CGFloat = 0
    #endif
    static let windowSize = CGSize(width: WorkspaceChrome.windowWidth, height: WorkspaceChrome.windowHeight + menuBarHeight)
}

/// The app's name and UI font on Linux: the menus say "Ycode" (not the
/// executable's name), and text is set in Inter (bundled with OpenViews,
/// SIL OFL 1.1), whose metrics are close to the desktop UI font the AppKit
/// IDE uses; the source font stays Noto Sans Mono.
enum ShellLook {
    @MainActor static func apply() {
        #if os(Linux)
        if ProcessInfo.processInfo.environment["OV_APP_NAME"] == nil { setenv("OV_APP_NAME", "Ycode", 1) }
        if ProcessInfo.processInfo.environment["YCODE_IDE_UI_FONT"] != "noto" {
            FontCatalog.shared.setFamilies(["Inter 24pt", "Noto Sans"], for: .default)
        }
        #endif
    }
}

extension ThemeColor {
    var color: Color { Color(.sRGB, red: redFraction, green: greenFraction, blue: blueFraction) }
}

extension ShellShortcut {
    var keyboardShortcut: KeyboardShortcut {
        var m: EventModifiers = []
        if modifiers.contains(.command) { m.insert(.command) }
        if modifiers.contains(.shift) { m.insert(.shift) }
        if modifiers.contains(.option) { m.insert(.option) }
        if modifiers.contains(.control) { m.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(Character(key)), modifiers: m)
    }
}

extension View {
    /// Names the view for drivers (the accessibility identifier).
    func shellTarget(_ name: String) -> some View {
        accessibilityIdentifier(name)
    }
}

/// An image by symbol name (OpenViews draws every name the shell uses).
func symbol(_ name: String) -> Image {
    Image(systemName: name)
}
