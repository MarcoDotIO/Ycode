// The `SwiftUI` module re-exports `SwiftUICore`, as the reference SDK does
// (specs/frameworks/swiftui/README.md, "Framework layout facts"). On Apple
// hosts the two modules are built as OpenViews / OpenViewsCore (Package.swift).
#if OPENVIEWS_RENAMED
@_exported import OpenViewsCore
#else
@_exported import SwiftUICore
#endif
