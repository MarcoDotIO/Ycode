import Foundation

/// The options step's help tags (P-178: every control has one), in
/// Ycode's own words. Both IDEs show them: a tooltip on macOS, `.help` on
/// Linux.
extension TemplateOptionField {
    public var help: String {
        typealias ID = TemplateOptionID
        switch id {
        case ID.productName: return "The name of the product the project builds. The project folder and the first target are named after it."
        case ID.team: return "The development team that signs the product. Choose None to sign it later."
        case ID.organizationIdentifier:
            return "A reverse-domain prefix, such as com.example, that makes the bundle identifier unique. New projects start from the last one used."
        case ID.bundleIdentifier: return "The product's unique identifier: the organization identifier followed by the product name."
        case ID.interface: return "The user interface technology the template starts from."
        case ID.language: return "The programming language of the template's source files."
        case ID.testingSystem: return "The test targets to add and the framework they use."
        case ID.storage, ID.documentStorage: return "How the app keeps its data: no storage, SwiftData or Core Data."
        case ID.hostInCloudKit: return "Keeps the app's data in a cloud container as well."
        case ID.hasDocumentation: return "Adds a documentation catalog to the target."
        case ID.gameTechnology, ID.contentTechnology: return "The technology that renders the template's content."
        case ID.integrateGameplayKit: return "Adds GameplayKit to the game's starting code."
        case ID.iOSPlatform, ID.visionOSPlatform, ID.tvOSPlatform, ID.macOSPlatform: return "Builds the app for this platform as well."
        case ID.initialScene: return "The kind of scene the app opens with."
        case ID.immersiveSpaceRenderer: return "The renderer of the app's immersive space, if it has one."
        case ID.immersiveSpace: return "How much of the surroundings the immersive space replaces."
        case ID.watchAppType: return "Whether the watch app stands alone or comes with a phone app."
        case ID.safariExtensionType: return "The kind of browser extension to create."
        case ID.libraryFramework: return "The framework the library links against."
        case ID.libraryType: return "Whether the library is linked dynamically or statically."
        case ID.apiLevel: return "The interface the service's starting code uses."
        case ID.bundleExtension: return "The file name extension of the built bundle."
        case ID.buildTool: return "The program that builds the target."
        case ID.organizationName: return "The organization named in the project."
        case ID.audioUnitType: return "The kind of audio unit the extension provides."
        case ID.subtypeCode: return "A four-character code that identifies the audio unit."
        case ID.manufacturerCode: return "A four-character code that identifies the maker; at least one letter is upper-case."
        case ID.hasUserInterface: return "Whether the audio unit shows a user interface."
        default: return label
        }
    }

    /// Whether a value the rules do not allow is left out of the pop-up
    /// (P-178: with SwiftUI the Language pop-up offers Swift only) rather
    /// than drawn disabled.
    public var hidesDisallowedValues: Bool { id == TemplateOptionID.language }
}
