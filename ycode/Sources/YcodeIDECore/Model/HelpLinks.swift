import Foundation

/// Public web pages the Help, Window and Ycode menus open on both IDEs
/// (Ycode has no documentation viewer of its own).
public enum HelpLinks {
    public static let developerDocumentation = URL(string: "https://developer.apple.com/documentation/")!
    public static let humanInterfaceGuidelines = URL(string: "https://developer.apple.com/design/human-interface-guidelines/")!
    public static let swiftBook = URL(string: "https://docs.swift.org/swift-book/")!
    public static let moreDeveloperTools = URL(string: "https://developer.apple.com/download/all/")!
}
