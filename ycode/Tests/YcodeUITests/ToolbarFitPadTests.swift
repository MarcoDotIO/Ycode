import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
@testable import YcodeUI

/// The toolbar's room steps do not follow the activity view's leading pad
/// (`liquid-glass.md` §8.2, `reference-ui-6.md` R39, B10).
///
/// The pad makes up the gap the system leaves before the view (12.5 from
/// Back | Forward, row 212). That gap is measured in the laid-out toolbar,
/// so it changes with the layout: 4 points on 27.2, 8 on 27.0, other
/// values on 27.0 at 1x while the toolbar is short of room, and no pad
/// when Back | Forward is in the overflow. When the steps followed the
/// width with the pad, a fit chose from one list and the next layout made
/// another: on the public runner (27.0.1, 1x) the 1150 fit capped the view
/// at 188, a step of a 222-point natural width, and the 1100 and 1050
/// fits at 124 and 90, steps of 226.
@MainActor
@Suite(.serialized) struct ToolbarFitPadTests {
    let r39 = ToolbarIssuesR39R41Tests()

    /// The natural width the steps follow is the mark's, the title's and
    /// the subtitle's, without the pad; the pad comes on top of the cap.
    @Test func naturalWidthLeavesOutThePad() throws {
        let dir = r39.scratch("b10-natural")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir)))
        let wc = r39.window(session)
        defer { wc.window?.orderOut(nil) }
        let a = wc.activityView
        a.status = "Build Succeeded \u{2022} Today at 1:17 PM"
        wc.window?.contentView?.superview?.layoutSubtreeIfNeeded()
        let neighbor = a.leadingNeighbor
        var seen: [(pad: CGFloat, natural: CGFloat, frame: CGFloat)] = []
        for n in [neighbor, nil, neighbor] {
            a.leadingNeighbor = n
            a.updateLeadingPad()
            seen.append((a.leadingPad, a.naturalWidth, a.naturalFrameWidth))
        }
        print("B10 activity pad/natural/frame: \(seen)")
        #expect(Set(seen.map(\.natural)).count == 1)
        #expect(seen.allSatisfy { $0.frame == $0.pad + $0.natural })
        // Capped: the pad, then the cap (never under the mark and 40 of text).
        a.maximumWidth = 120
        #expect(a.intrinsicContentSize.width == max(a.textStart + 40, a.leadingPad + 120))
        a.maximumWidth = .greatestFiniteMagnitude
        #expect(a.intrinsicContentSize.width == a.naturalFrameWidth)
    }

    /// The runner's case on this Mac: the pad changes between the fits
    /// (Back | Forward taken away and given back, as the system's gap
    /// moved on the runner). Every fit is still one of the steps, in order.
    @Test func fitsStayOnTheStepsWhileThePadChanges() throws {
        let dir = r39.scratch("b10-fit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = WorkspaceSession(model: try WorkspaceModel(url: try writeToolProject(at: dir)))
        let wc = r39.window(session)
        defer { wc.window?.orderOut(nil) }
        let sim = Destination(name: "iPhone 18 Pro Max", specifier: "platform=iOS Simulator,id=S1", platform: "iOS", kind: .simulator,
                              osVersion: "27.0", identifier: "S1")
        wc.setDestinationGroups(DestinationCatalog.groups(devices: [], simulators: [sim]))
        session.destination = sim
        wc.rebuildDestinationMenu()
        wc.schemePopUp.removeAllItems()
        wc.schemePopUp.addItem(withTitle: "A Rather Long Scheme Name For Testing")
        wc.issueCapsule.errors = 1
        wc.issueCapsule.warnings = 2
        wc.activityView.status = "Build Succeeded \u{2022} Today at 1:17 PM"
        let window = try #require(wc.window)
        let neighbor = wc.activityView.leadingNeighbor
        var fits: [Int: ToolbarFit] = [:]
        var pads: [Int: CGFloat] = [:]
        for (i, w) in [1600, 1400, 1250, 1150, 1100, 1050, 1000, 2000].enumerated() {
            // Every other width without the neighbour: no pad, then the pad.
            wc.activityView.leadingNeighbor = i % 2 == 0 ? neighbor : nil
            window.setFrame(NSRect(x: 0, y: 0, width: CGFloat(w), height: 900), display: false)
            wc.fitToolbar()
            let steps = ToolbarFit.steps(activityNatural: wc.activityView.naturalWidth)
            print("B10 toolbar \(w): \(wc.toolbarFit) pad \(wc.activityView.leadingPad) natural \(wc.activityView.naturalWidth)")
            #expect(steps.contains(wc.toolbarFit), "at \(w): \(wc.toolbarFit) not in \(steps)")
            fits[w] = wc.toolbarFit
            pads[w] = wc.activityView.leadingPad
        }
        wc.activityView.leadingNeighbor = neighbor
        // The pad did change (on this Mac 0 and the 27.2 gap's 9).
        #expect(Set(pads.values).count > 1, "pads \(pads)")
        let steps = ToolbarFit.steps(activityNatural: wc.activityView.naturalWidth)
        let order = [1600, 1400, 1250, 1150, 1100, 1050, 1000].compactMap { fits[$0] }
        let ranks = order.compactMap { steps.firstIndex(of: $0) }
        #expect(ranks.count == order.count && ranks == ranks.sorted(), "fits \(order) steps \(steps)")
        #expect(fits[2000] == ToolbarFit())
        // At least one width truncates the subtitle, so the caps are tested.
        #expect(order.contains { $0.activityWidth != nil })
    }
}
