import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux) && canImport(OVDBus)
import OVDBus
#endif

// The build-result bezel (`specs/ide/build-notifications.md` §4) over the
// workspace window, and the system notification route (§3): on Linux
// `org.freedesktop.Notifications` on the session bus.
//
//   YCODE_IDE_BEZEL_SHOT=<prefix>   (Linux) writes <prefix>-<n>.png of the
//                                   window 0.3 s after each bezel appears

/// The bezel layer: fills the window, passes clicks through, and keeps the
/// notifier told about the window's phase and Reduce Motion.
struct BuildBezelOverlay: View {
    var notifier: ShellBuildNotifier
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let n = notifier.bezel {
                BuildBezelView(notice: n)
                    .opacity(notifier.isFading ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: BezelTimeline.fadeDuration), value: notifier.isFading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .onAppear { sync() }
        .onChange(of: scenePhase) { _, _ in sync() }
        .onChange(of: reduceMotion) { _, _ in sync() }
        .onChange(of: notifier.log.count) { _, n in BezelShots.take(n, notifier) }
    }

    private func sync() {
        notifier.isWindowActive = scenePhase == .active
        notifier.reduceMotion = reduceMotion
        if notifier.announce == nil {
            notifier.announce = { AccessibilityNotification.Announcement($0).post() }
        }
        if notifier.postSystemNotification == nil { notifier.postSystemNotification = DesktopNotifications.post }
    }
}

/// 200 × 200, radius 18, near-black at 86 %; the glyph over a one-line title.
struct BuildBezelView: View {
    var notice: BuildNotice

    /// 17-point semibold, as the AppKit bezel's title; Inter SemiBold reads
    /// lighter than the AppKit title at this size, so Linux uses Bold.
    #if os(Linux)
    static let titleWeight: Font.Weight = .bold
    #else
    static let titleWeight: Font.Weight = .semibold
    #endif

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.sRGB, red: 0.08, green: 0.08, blue: 0.08).opacity(0.86))
            VStack(spacing: 0) {
                glyph
                    .frame(width: 112, height: 96)
                    .foregroundStyle(Color.white.opacity(0.9))
                    .padding(.top, 40)
                Spacer(minLength: 0)
                Text(notice.title)
                    .font(.system(size: 17, weight: Self.titleWeight))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 28)
            }
        }
        .frame(width: 200, height: 200)
        .accessibilityHidden(true)
        .accessibilityIdentifier("build bezel")
    }

    /// The notice's symbol (OpenViews draws `hammer` as a claw hammer that
    /// holds up at this size, since OV-R13).
    private var glyph: some View {
        Image(systemName: notice.symbolName)
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}

/// The system notification route on Linux (§3); elsewhere none (the macOS
/// product is the AppKit IDE, which has its own).
enum DesktopNotifications {
    static let service = "org.freedesktop.Notifications"

    /// Asks the bus whether a notification server is there, then sends
    /// `Notify`; both replies arrive on the main queue (nothing blocks but
    /// the connection's handshake, bounded at 1 s). Quiet when there is no
    /// session bus or no server.
    @MainActor
    static func post(_ n: BuildNotice, workspace: String) {
        #if os(Linux) && canImport(OVDBus)
        guard let bus = try? DBusConnection.session(timeout: 1) else { return }
        bus.startDispatch()
        let hasOwner = DBusMessage.methodCall(destination: DBusConnection.busName, path: DBusConnection.busPath,
                                              interface: DBusConnection.busName, member: "NameHasOwner", body: [.string(service)])
        let notify = DBusMessage.methodCall(destination: service, path: "/org/freedesktop/Notifications", interface: service,
                                            member: "Notify",
                                            body: [.string("Ycode"), .uint32(0), .string(""), .string(n.title), .string(workspace),
                                                   .strings([]), .emptyProperties, .int32(-1)])
        do {
            try bus.call(hasOwner) { reply in
                guard reply.type == .methodReturn, reply.body.first?.boolValue == true else { return bus.close() }
                do { try bus.call(notify) { _ in bus.close() } } catch { bus.close() }
            }
        } catch {
            bus.close()
        }
        #endif
    }
}

/// `YCODE_IDE_BEZEL_SHOT` (Linux): photographs each bezel.
@MainActor
enum BezelShots {
    static func take(_ count: Int, _ notifier: ShellBuildNotifier) {
        #if os(Linux)
        guard let prefix = ProcessInfo.processInfo.environment["YCODE_IDE_BEZEL_SHOT"],
              let last = notifier.log.last, last.hasPrefix("bezel ") else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            let r = OpenViewsAutomation.screenshot(to: "\(prefix)-\(count).png")
            FileHandle.standardOutput.write(Data("bezel shot \(count) \(last): \(r)\n".utf8))
        }
        #endif
    }
}
