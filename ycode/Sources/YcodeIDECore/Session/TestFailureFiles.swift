import Foundation
import YcodeBuild

/// swift-testing names a failure's file without its folder
/// ("recorded an issue at MathTests.swift:12:5"). The issue navigator and
/// the editor need the whole path: the file of the discovered test the
/// failure belongs to, else of any discovered test with that name.
public enum TestFailureFiles {
    public static func resolve(_ outcomes: [TestOutcome], tests: [DiscoveredTest]) -> [TestOutcome] {
        outcomes.map { o in
            var o = o
            o.failures = o.failures.map { d in
                guard var loc = d.location, !loc.file.hasPrefix("/") else { return d }
                let name = (loc.file as NSString).lastPathComponent
                let own = tests.first { $0.matches(o) && ($0.file as NSString).lastPathComponent == name }
                guard let file = (own ?? tests.first { ($0.file as NSString).lastPathComponent == name })?.file else { return d }
                var d = d
                loc.file = file
                d.location = loc
                return d
            }
            return o
        }
    }
}
