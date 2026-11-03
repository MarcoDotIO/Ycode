import Foundation
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// Expressions common SwiftUI code uses that must compile and mean what the
// reference API means (QA report B3; overloads resolved as the public API
// declares them: the view forms of background/overlay are disfavoured, the
// deprecated long-press overload too).

@MainActor
@Suite("R8 source compatibility")
struct SourceCompatibilityTests {
    @Test func backgroundsWithColours() {
        let flag = true
        let a = Text("a").background(Color.blue)
        let b = Text("a").background(Color.blue.opacity(0.25))
        let c = Text("a").background(flag ? Color.red : Color.green)
        let d = Text("a").overlay(Color.black.opacity(0.1))
        for v in [String(describing: type(of: a)), String(describing: type(of: b)), String(describing: type(of: c)),
                  String(describing: type(of: d))] {
            #expect(v.contains("Rectangle"))
        }
        let e = Color.red.opacity(0.5)
        #expect(e.resolve(in: EnvironmentValues()).opacity == 0.5)
    }

    @Test func longPressWithATrailingClosure() {
        var fired = 0
        _ = Text("press").onLongPressGesture { fired += 1 }
        _ = Text("press").onLongPressGesture(minimumDuration: 1) { fired += 1 }
        #expect(fired == 0)
    }

    @Test func interpolationWithASpecifier() {
        let x = 3.14159
        let n = 7
        let t = Text("v \(x, specifier: "%.1f") n \(n)")
        let s = ViewGraph.layoutNode(for: t)
        _ = s
        let key = LocalizedStringKey("v \(x, specifier: "%.1f") n \(n)")
        #expect(key.resolved == "v 3.1 n 7")
        let de = LocalizedStringKey.format(key.key, key.arguments, locale: Locale(identifier: "de_DE"))
        #expect(de == "v 3,1 n 7")
    }
}
