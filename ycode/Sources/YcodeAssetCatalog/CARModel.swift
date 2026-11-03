import Foundation

/// Rendition-key attributes (`specs/formats/assets-car.md` §4.1).
public enum CARAttribute: UInt32, CaseIterable, Sendable, Comparable {
    case look = 0, element, part, size, direction, placeholder, value, appearance, dimension1, dimension2
    case state, layer, scale, localization, presentationState, idiom, subtype, identifier, previousValue, previousState
    case sizeClassHorizontal, sizeClassVertical, memoryClass, graphicsClass, displayGamut, deploymentTarget, glyphWeight, glyphSize

    public static func < (a: CARAttribute, b: CARAttribute) -> Bool { a.rawValue < b.rawValue }

    public var name: String {
        switch self {
        case .look: "look"
        case .element: "element"
        case .part: "part"
        case .size: "size"
        case .direction: "direction"
        case .placeholder: "placeholder"
        case .value: "value"
        case .appearance: "appearance"
        case .dimension1: "dimension1"
        case .dimension2: "dimension2"
        case .state: "state"
        case .layer: "layer"
        case .scale: "scale"
        case .localization: "localization"
        case .presentationState: "presentation state"
        case .idiom: "idiom"
        case .subtype: "subtype"
        case .identifier: "identifier"
        case .previousValue: "previous value"
        case .previousState: "previous state"
        case .sizeClassHorizontal: "size class horizontal"
        case .sizeClassVertical: "size class vertical"
        case .memoryClass: "memory class"
        case .graphicsClass: "graphics class"
        case .displayGamut: "display gamut"
        case .deploymentTarget: "deployment target"
        case .glyphWeight: "glyph weight"
        case .glyphSize: "glyph size"
        }
    }
}

/// Values of the `idiom` attribute (§4.1).
public enum CARIdiom: UInt16, CaseIterable, Sendable {
    case universal = 0, phone, pad, tv, car, watch, marketing, mac, vision

    /// From an asset catalog `idiom` value.
    public init?(catalogName: String) {
        switch catalogName {
        case "universal": self = .universal
        case "iphone": self = .phone
        case "ipad": self = .pad
        case "tv": self = .tv
        case "car": self = .car
        case "watch": self = .watch
        case "ios-marketing", "watch-marketing", "marketing": self = .marketing
        case "mac": self = .mac
        case "vision": self = .vision
        default: return nil
        }
    }

    public var name: String { ["universal", "phone", "pad", "tv", "car", "watch", "marketing", "mac", "vision"][Int(rawValue)] }
}

/// Part numbers of the kinds Ycode writes (§6).
public enum CARPart {
    public static let image: UInt16 = 181
    public static let color: UInt16 = 217
    public static let multisizeImage: UInt16 = 218
    public static let iconImage: UInt16 = 220
    public static let iconImageStack: UInt16 = 245
    public static let iconGroup: UInt16 = 246
    public static let namedGradient: UInt16 = 247

    public static func name(_ p: UInt16) -> String {
        switch p {
        case image: "Image"
        case color: "Color"
        case multisizeImage: "MultiSized Image"
        case iconImage: "Icon Image"
        case iconImageStack: "IconImageStack"
        case iconGroup: "IconGroup"
        case namedGradient: "Named Gradient"
        default: "part \(p)"
        }
    }
}

/// The element every catalog asset uses (§4.1).
public let carCatalogElement: UInt16 = 85

/// Appearances by role; the names and numbers differ per platform (§4.4).
public enum CARAppearance: CaseIterable, Sendable, Hashable {
    case any, dark, light, tinted
}

/// The platform a car is written for: it fixes the key format, the key
/// semantics, the metadata platform and the appearance names.
public enum CARPlatform: String, CaseIterable, Sendable {
    case iOS, macOS, watchOS, tvOS, visionOS

    /// From `actool`'s `--platform` values (`icon-compile.md` §1).
    public init?(platformName p: String) {
        switch p {
        case "iphoneos", "iphonesimulator", "ios": self = .iOS
        case "macosx", "macos": self = .macOS
        case "watchos", "watchsimulator": self = .watchOS
        case "appletvos", "appletvsimulator", "tvos": self = .tvOS
        case "xros", "xrsimulator", "visionos": self = .visionOS
        default: return nil
        }
    }

    public var keySemantics: UInt32 { self == .macOS ? 1 : 2 }

    /// The KEYFORMAT `actool` 27.1 writes (§3.3).
    public var keyFormat: [CARAttribute] {
        self == .macOS ? [.appearance, .localization, .element, .part, .size, .identifier, .dimension2, .layer, .scale]
            : [.appearance, .localization, .scale, .idiom, .subtype, .dimension2, .identifier, .element, .part]
    }

    /// EXTENDED_METADATA's deployment platform (§3.2).
    public var metadataPlatform: String {
        switch self {
        case .iOS: "ios"
        case .macOS: "macosx"
        case .watchOS: "watch"
        case .tvOS: "atv"
        case .visionOS: "xros"
        }
    }

    public func appearanceName(_ a: CARAppearance) -> String {
        switch (self, a) {
        case (.macOS, .any): "NSAppearanceNameSystem"
        case (.macOS, .dark): "NSAppearanceNameDarkAqua"
        case (.macOS, .light): "NSAppearanceNameAqua"
        case (_, .any): "UIAppearanceAny"
        case (_, .dark): "UIAppearanceDark"
        case (_, .light): "UIAppearanceLight"
        case (_, .tinted): "ISAppearanceTintable"
        }
    }

    public func appearanceNumber(_ a: CARAppearance) -> UInt16 {
        switch (self, a) {
        case (_, .any): 0
        case (_, .dark): 1
        case (.macOS, .light): 8
        case (_, .light): 4
        case (_, .tinted): 10
        }
    }

    /// CELM version for app-icon bitmaps (§7.3): 3 on iOS-family platforms
    /// (opaque), 1 on macOS. Other bitmaps always use 1: versions 2 and 3
    /// draw as opaque.
    public var celmVersion: UInt32 { self == .macOS ? 1 : 3 }
}

/// A colour as COLR stores it (§7.1).
public struct CARColor: Equatable, Sendable {
    /// Colour-space numbers: 0 generic, 1 sRGB, 2 gray gamma 2.2, 3 Display P3,
    /// 4 extended sRGB, 5 extended linear sRGB, 6 extended gray.
    public var colorSpace: UInt8
    public var components: [Double]

    public init(colorSpace: UInt8, components: [Double]) {
        self.colorSpace = colorSpace
        self.components = components
    }

    public static func space(named n: String) -> UInt8? {
        switch n {
        case "srgb": 1
        case "gray-gamma-22", "gray": 2
        case "display-p3": 3
        case "extended-srgb": 4
        case "extended-linear-srgb": 5
        case "extended-gray": 6
        default: nil
        }
    }

    public static func spaceName(_ s: UInt8) -> String {
        ["generic", "srgb", "gray-gamma-22", "display-p3", "extended-srgb", "extended-linear-srgb", "extended-gray"][min(Int(s), 6)]
    }
}

/// One size of a MultiSized Image (§7.5), in points.
public struct CARMultisizeEntry: Equatable, Sendable {
    public var width: UInt32
    public var height: UInt32
    public var index: UInt16
    public init(width: UInt32, height: UInt32, index: UInt16) {
        self.width = width
        self.height = height
        self.index = index
    }
}

public enum CARCompression: String, Sendable, CaseIterable {
    /// CELM compression 0.
    case none
    /// CELM compression 4: LZFSE in row chunks (KCBC).
    case lzfse
}

/// What a rendition holds; it fixes the part, layout and payload (§6).
public enum CARContent: Equatable, Sendable {
    /// An image-set bitmap (part 181, layout 12).
    case image(Bitmap)
    /// A flattened app-icon bitmap (part 220, layout 12).
    case iconImage(Bitmap)
    /// A colour (part 217, layout 1009).
    case color(CARColor)
    /// The size list of an app icon (part 218, layout 1010).
    case multisize([CARMultisizeEntry])

    public var part: UInt16 {
        switch self {
        case .image: CARPart.image
        case .iconImage: CARPart.iconImage
        case .color: CARPart.color
        case .multisize: CARPart.multisizeImage
        }
    }

    public var layout: UInt16 {
        switch self {
        case .image, .iconImage: 12
        case .color: 1009
        case .multisize: 1010
        }
    }
}

/// One rendition: an asset name, its key attributes and its content.
public struct CARRendition: Equatable, Sendable {
    /// The asset (facet) name, e.g. `AppIcon` or `Folder/Image`.
    public var name: String
    /// Key attributes besides element, part and identifier (which come from
    /// the content and the asset name). Attributes the platform's key format
    /// lacks are dropped.
    public var attributes: [CARAttribute: UInt16]
    /// The CSI name field (a source file name, …).
    public var renditionName: String
    public var content: CARContent
    public var flags: UInt32

    public init(name: String, attributes: [CARAttribute: UInt16] = [:], renditionName: String, content: CARContent, flags: UInt32 = 0) {
        self.name = name
        self.attributes = attributes
        self.renditionName = renditionName
        self.content = content
        self.flags = flags
    }
}
