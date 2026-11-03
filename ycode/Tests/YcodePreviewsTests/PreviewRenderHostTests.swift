// The headless preview-render package (PreviewRenderHost): what it writes
// for a file and a chosen #Preview. Building and running it needs the open
// SwiftUI port and a toolchain, which `ycode preview --render` does.

import Foundation
import Testing
@testable import YcodePreviews

@Suite struct PreviewRenderHostTests {
    let source = """
    import SwiftUI

    @main struct DemoApp: App {
        var body: some Scene { WindowGroup { Text("x") } }
    }

    #Preview("Fixed", traits: .fixedLayout(width: 200, height: 100)) {
        Text("Hello")
    }

    #Preview(traits: .sizeThatFitsLayout) {
        Color.red.frame(width: 10, height: 10)
    }
    """

    @Test func linuxPackage() throws {
        let previews = PreviewDiscovery.previews(in: source)
        let fixed = try #require(previews.first { $0.name == "Fixed" })
        let files = PreviewRenderHost.files(source: source, preview: fixed, all: previews, openViewsPath: "/x/frameworks/swiftui",
                                            appleHost: false)
        let file = try #require(files["Sources/PreviewHost/Preview.swift"])
        #expect(!file.contains("#Preview"))
        #expect(!file.contains("@main"))
        #expect(file.split(separator: "\n", omittingEmptySubsequences: false).count
                == source.split(separator: "\n", omittingEmptySubsequences: false).count)
        let main = try #require(files["Sources/PreviewHost/main.swift"])
        #expect(main.contains("import SwiftUI"))
        #expect(main.contains("Text(\"Hello\")"))
        #expect(main.contains("content.frame(width: 200.0, height: 100.0)"))
        let manifest = try #require(files["Package.swift"])
        #expect(manifest.contains(".package(path: \"/x/frameworks/swiftui\")"))
        #expect(manifest.contains(".product(name: \"SwiftUI\", package: \"swiftui\")"))
    }

    @Test func appleHostAndFittingSize() throws {
        let previews = PreviewDiscovery.previews(in: source)
        let fitting = try #require(previews.first { $0.traits.contains("sizeThatFitsLayout") })
        let files = PreviewRenderHost.files(source: source, preview: fitting, all: previews, openViewsPath: "/p", appleHost: true)
        #expect(files["Sources/PreviewHost/Preview.swift"]?.contains("import OpenViews") == true)
        #expect(files["Sources/PreviewHost/main.swift"]?.contains("ImageRenderer(content: content)") == true)
        #expect(files["Package.swift"]?.contains("\"OpenViews\"") == true)
    }
}
