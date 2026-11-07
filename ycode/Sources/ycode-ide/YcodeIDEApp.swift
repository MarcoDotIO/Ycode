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
        // The models' Copy commands (Debug ▸ Console ▸ Copy Row) write here.
        ShellPasteboard.writer = { ShellClipboard.copy($0) }
        #if os(Linux)
        // Quit and the window's close button ask about unsaved changes first.
        ApplicationTermination.shouldTerminate = { ShellApp.model.shouldQuit() }
        ShellApp.model.terminateApp = { OpenViewsAutomation.terminate() }
        #endif
        // A language server or build tool that dies must not take the app
        // with it: writing to its closed pipe fails instead of signalling.
        signal(SIGPIPE, SIG_IGN)
        // Live issues from sourcekit-lsp; YCODE_IDE_LSP=0 leaves it off.
        ShellApp.model.startsLanguageService = ProcessInfo.processInfo.environment["YCODE_IDE_LSP"] != "0"
        // The simulator runtime wizard, once, when this computer has none (runtime-onboarding.md §3).
        ShellApp.model.offerRuntimeSetupAtFirstLaunch()
        if let path = ShellAppModel.launchPath() {
            if !ShellApp.model.open(path: path) {
                FileHandle.standardError.write(Data("ycode-ide: \(ShellApp.model.openError ?? "cannot open \(path)")\n".utf8))
            }
        }
    }

    var body: some Scene {
        // The workspace window: no title bar, the window's buttons drawn at
        // the AppKit window's places, the menu bar on demand (OpenViews,
        // `cross-platform-parity.md` §2, OV-1). At launch it opens when a
        // workspace was given, Welcome otherwise.
        WindowGroup("Ycode", id: ShellWindowID.workspace) {
            ShellRootView(app: ShellApp.model).shellAppearance()
        }
        .defaultSize(width: ShellMetrics.windowSize.width, height: ShellMetrics.windowSize.height)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(ShellApp.model.workspace == nil ? .suppressed : .presented)
        .commands { ShellMenus(app: ShellApp.model) }
        // Welcome in a window of its own, 480 × 632, as the AppKit IDE's
        // (`cross-platform-parity.md` §9, OV-7).
        Window(WelcomeView.windowTitle, id: ShellWindowID.welcome) {
            WelcomeWindowRoot(app: ShellApp.model).shellAppearance()
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(ShellApp.model.workspace == nil ? .presented : .suppressed)
        Settings { ShellSettingsView().shellAppearance() }
        // Window ▸ Organizer (OrganizerWindow.swift).
        Window("Organizer", id: ShellAppModel.organizerWindowID) {
            OrganizerWindowView(model: ShellApp.model.organizer).shellAppearance()
        }
        .defaultSize(width: OrganizerWindowView.windowSize.width, height: OrganizerWindowView.windowSize.height)
        // Window ▸ Organizer is the command table's item; the toolkit's own
        // entry for the scene would list it twice.
        .commandsRemoved()
        // The simulator runtime wizard, in a window of its own as on macOS
        // (RuntimeSetupSheet.swift).
        Window("Simulator Runtimes", id: ShellAppModel.runtimeSetupWindowID) {
            RuntimeSetupWindow(app: ShellApp.model).shellAppearance()
        }
        // As macOS's wizard window: no title bar (only the close button,
        // `RuntimeSetupWindow`), the content's size, the menus on demand.
        .defaultSize(width: RuntimeSetupSheet.size.width, height: RuntimeSetupSheet.size.height)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commandsRemoved()
    }
}

/// The windows' identifiers.
enum ShellWindowID {
    static let workspace = "workspace"
    static let welcome = "welcome"
}

/// The workspace window's content. When the workspace closes, Welcome's
/// window opens and this one closes (closing the last window would quit).
struct ShellRootView: View {
    @Bindable var app: ShellAppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let ws = app.workspace {
                WorkspaceView(model: ws, app: app)
            } else {
                Color.clear
            }
        }
        .modifier(ShellPresentations(app: app))
        .onChange(of: app.workspace == nil) { _, closed in
            if closed {
                openWindow(id: ShellWindowID.welcome)
                dismissWindow()
            }
        }
    }
}

/// Welcome's window. Opening a project opens the workspace window first,
/// then closes this one.
struct WelcomeWindowRoot: View {
    @Bindable var app: ShellAppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        WelcomeView(app: app)
            .modifier(ShellPresentations(app: app))
            .onChange(of: app.workspace != nil) { _, opened in
                if opened {
                    openWindow(id: ShellWindowID.workspace)
                    dismissWindow()
                }
            }
    }
}

/// What either window presents for the app: the file dialog, the New
/// Project, Clone, About and runtime sheets, notices and the unsaved-changes
/// question; and the app's hooks into the window environment.
struct ShellPresentations: ViewModifier {
    @Bindable var app: ShellAppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
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
        // Closing the workspace or quitting with unsaved changes.
        .alert(unsavedTitle, isPresented: Binding(get: { app.pendingClose != nil }, set: { if !$0 { app.answerClose(.cancel) } })) {
            Button((app.workspace?.editedPaths.count ?? 0) > 1 ? "Save All" : "Save") { app.answerClose(.saveAll) }.keyboardShortcut(.defaultAction)
            Button("Don't Save", role: .destructive) { app.answerClose(.discard) }
            Button("Cancel", role: .cancel) { app.answerClose(.cancel) }
        } message: {
            Text(verbatim: "Your changes will be lost if you don't save them.")
        }
        .onAppear {
            let app = app, openURL = openURL, openWindow = openWindow
            app.openWindow = { id in openWindow(id: id) }
            // A wizard asked for before the window could open (the first launch).
            if app.runtimeSetup != nil { openWindow(id: ShellAppModel.runtimeSetupWindowID) }
            app.openExternally = { url in
                openURL(url) { accepted in
                    if !accepted { app.linkCouldNotOpen(url) }
                }
            }
        }
        .task { await ShellDriver.start(app) }
    }
}

extension ShellPresentations {
    var unsavedTitle: String {
        let names = app.workspace?.editedDocumentNames ?? []
        if names.count == 1 { return "Save changes to “\(names[0])”?" }
        return "Save changes to \(names.count) files?"
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
    /// None: OpenViews shows the menu bar on demand over a window without
    /// a title bar (the top edge, F10 or Alt), so the window is the AppKit
    /// window's size.
    static let menuBarHeight: CGFloat = 0
    /// `YCODE_IDE_WINDOW_SIZE=<w>x<h>` (drivers: the parity audit's 1100 ×
    /// 880) sets the area under the menu bar.
    static let windowSize: CGSize = {
        let parts = (ProcessInfo.processInfo.environment["YCODE_IDE_WINDOW_SIZE"] ?? "").split(separator: "x").compactMap { Double($0) }
        if parts.count == 2 { return CGSize(width: parts[0], height: parts[1] + menuBarHeight) }
        return CGSize(width: WorkspaceChrome.windowWidth, height: WorkspaceChrome.windowHeight + menuBarHeight)
    }()
}

/// The app's name and UI font on Linux: the menus say "Ycode" (not the
/// executable's name), and text is set in Inter (bundled with OpenViews,
/// SIL OFL 1.1), whose metrics are close to the desktop UI font the AppKit
/// IDE uses; the source font stays Noto Sans Mono, tracked to the macOS
/// editor's advance (`FontTracking.desktopMonospaced`).
enum ShellLook {
    @MainActor static func apply() {
        #if os(Linux)
        if ProcessInfo.processInfo.environment["OV_APP_NAME"] == nil { setenv("OV_APP_NAME", "Ycode", 1) }
        // The source face advances as the macOS editor's (8.04 at 13 points);
        // EditorCell rounds the cell at 1x as the macOS editor does.
        FontCatalog.shared.setTracking(.desktopMonospaced, forFamily: FontTracking.desktopMonospacedFamily)
        if ProcessInfo.processInfo.environment["YCODE_IDE_UI_FONT"] != "noto" {
            FontCatalog.shared.setFamilies(["Inter 24pt", "Noto Sans"], for: .default)
            // Inter tracked to the desktop UI font's widths (OpenViews,
            // OV-4), in place of the views' own small-size tracking.
            FontCatalog.shared.setTracking(.desktopUI, forFamily: FontTracking.desktopUIFamily)
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
