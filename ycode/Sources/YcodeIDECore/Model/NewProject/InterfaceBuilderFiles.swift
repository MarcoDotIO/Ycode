import Foundation
import YcodePlist

/// Storyboards and XIBs the templates write: Ycode's own minimal
/// documents in the public Interface Builder file format (element and
/// attribute names as in open-source projects; `templates.md` §
/// "Storyboard interface"). Object IDs are "Ycd-<kind>-<n>".
enum InterfaceBuilderFiles {
    enum Runtime {
        case iOS, tvOS
        var type: String { self == .iOS ? "com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB" : "com.apple.InterfaceBuilder.AppleTV.Storyboard" }
        var target: String { self == .iOS ? "iOS.CocoaTouch" : "AppleTV" }
        var size: (Int, Int) { self == .iOS ? (393, 852) : (1920, 1080) }
    }

    /// One UIKit scene: the initial view controller (`customClass` in the
    /// app's module unless `objc`), its root view (optionally of a view
    /// class such as `SKView`).
    static func uikitStoryboard(_ rt: Runtime, viewController: String?, module: String?, viewClass: String? = nil, launch: Bool = false,
                                id: String = "1") -> String {
        let vcClass = viewController.map { c in " customClass=\"\(c)\"" + (module.map { " customModule=\"\($0.xmlEscaped)\" customModuleProvider=\"target\"" } ?? "") } ?? ""
        let view = viewClass.map { " customClass=\"\($0)\"" } ?? ""
        let (w, h) = rt.size
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <document type="\(rt.type)" version="3.0" toolsVersion="1" targetRuntime="\(rt.target)" propertyAccessControl="none" useAutolayout="YES" useSafeAreas="YES"\(launch ? " launchScreen=\"YES\"" : "") initialViewController="Ycd-vc-\(id)">
            <scenes>
                <scene sceneID="Ycd-sc-\(id)">
                    <objects>
                        <viewController id="Ycd-vc-\(id)"\(vcClass) sceneMemberID="viewController">
                            <view key="view" contentMode="scaleToFill" id="Ycd-vw-\(id)"\(view)>
                                <rect key="frame" x="0.0" y="0.0" width="\(w)" height="\(h)"/>
                                <autoresizingMask key="autoresizingMask" widthSizable="YES" heightSizable="YES"/>
                                <color key="backgroundColor" systemColor="systemBackgroundColor"/>
                            </view>
                        </viewController>
                        <placeholder placeholderIdentifier="IBFirstResponder" id="Ycd-fr-\(id)" userLabel="First Responder" sceneMemberID="firstResponder"/>
                    </objects>
                </scene>
            </scenes>
            <resources>
                <systemColor name="systemBackgroundColor">
                    <color white="1" alpha="1" colorSpace="custom" customColorSpace="genericGamma22GrayColorSpace"/>
                </systemColor>
            </resources>
        </document>

        """
    }

    static func moduleAttributes(_ module: String?) -> String {
        module.map { " customModule=\"\($0.xmlEscaped)\" customModuleProvider=\"target\"" } ?? ""
    }

    /// The application menu with Quit (the main menu's one item).
    static func mainMenu(_ appName: String, quitTarget: String) -> String {
        let n = appName.xmlEscaped
        return """
                    <menu key="mainMenu" title="Main Menu" systemMenu="main" id="Ycd-menu-main">
                        <items>
                            <menuItem title="\(n)" id="Ycd-mi-app">
                                <modifierMask key="keyEquivalentModifierMask"/>
                                <menu key="submenu" title="\(n)" systemMenu="apple" id="Ycd-menu-app">
                                    <items>
                                        <menuItem title="Quit \(n)" keyEquivalent="q" id="Ycd-mi-quit">
                                            <connections>
                                                <action selector="terminate:" target="\(quitTarget)" id="Ycd-c-quit"/>
                                            </connections>
                                        </menuItem>
                                    </items>
                                </menu>
                            </menuItem>
                        </items>
                    </menu>
        """
    }

    /// A Cocoa storyboard: the application scene (main menu, app
    /// delegate); with `viewController`, a window controller (initial, or
    /// with `windowControllerID` as its storyboard identifier) whose
    /// content is that view controller.
    static func cocoaStoryboard(appName: String, module: String?, viewController: String?, viewClass: String? = nil,
                                windowControllerID: String? = nil) -> String {
        let mod = moduleAttributes(module)
        var scenes = """
                <scene sceneID="Ycd-sc-app">
                    <objects>
                        <application id="Ycd-app-1" sceneMemberID="viewController">
        \(mainMenu(appName, quitTarget: "Ycd-fr-app").replacingOccurrences(of: "\n            ", with: "\n                    "))
                            <connections>
                                <outlet property="delegate" destination="Ycd-ad-1" id="Ycd-c-delegate"/>
                            </connections>
                        </application>
                        <customObject id="Ycd-ad-1" customClass="AppDelegate"\(mod)/>
                        <customObject id="Ycd-fr-app" userLabel="First Responder" customClass="NSResponder" sceneMemberID="firstResponder"/>
                    </objects>
                </scene>

        """
        if let viewController {
            let sid = windowControllerID.map { " storyboardIdentifier=\"\($0)\"" } ?? ""
            scenes += """
                    <scene sceneID="Ycd-sc-wc">
                        <objects>
                            <windowController id="Ycd-wc-1"\(sid) sceneMemberID="viewController">
                                <window key="window" title="\(appName.xmlEscaped)" allowsToolTipsWhenApplicationIsInactive="NO" autorecalculatesKeyViewLoop="NO" releasedWhenClosed="NO" animationBehavior="default" id="Ycd-win-1">
                                    <windowStyleMask key="styleMask" titled="YES" closable="YES" miniaturizable="YES" resizable="YES"/>
                                    <rect key="contentRect" x="196" y="240" width="640" height="420"/>
                                    <rect key="screenRect" x="0.0" y="0.0" width="1680" height="1027"/>
                                    <connections>
                                        <outlet property="delegate" destination="Ycd-wc-1" id="Ycd-c-wdel"/>
                                    </connections>
                                </window>
                                <connections>
                                    <segue destination="Ycd-vc-1" kind="relationship" relationship="window.shadowedContentViewController" id="Ycd-seg-1"/>
                                </connections>
                            </windowController>
                            <customObject id="Ycd-fr-wc" userLabel="First Responder" customClass="NSResponder" sceneMemberID="firstResponder"/>
                        </objects>
                    </scene>
                    <scene sceneID="Ycd-sc-vc">
                        <objects>
                            <viewController id="Ycd-vc-1" customClass="\(viewController)"\(mod) sceneMemberID="viewController">
                                <view key="view" id="Ycd-vw-1"\(viewClass.map { " customClass=\"\($0)\"" } ?? "")>
                                    <rect key="frame" x="0.0" y="0.0" width="640" height="420"/>
                                    <autoresizingMask key="autoresizingMask"/>
                                </view>
                            </viewController>
                            <customObject id="Ycd-fr-vc" userLabel="First Responder" customClass="NSResponder" sceneMemberID="firstResponder"/>
                        </objects>
                    </scene>

            """
        }
        let initial = viewController != nil && windowControllerID == nil ? " initialViewController=\"Ycd-wc-1\"" : ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <document type="com.apple.InterfaceBuilder3.Cocoa.Storyboard.XIB" version="3.0" toolsVersion="1" targetRuntime="MacOSX.Cocoa" propertyAccessControl="none" useAutolayout="YES"\(initial)>
            <scenes>
        \(scenes)    </scenes>
        </document>

        """
    }

    /// A Cocoa XIB. `owner` is File's Owner's class; `window` adds a window
    /// connected to the owner's (or the app delegate's) `window` outlet;
    /// `menu` adds the main menu and the app delegate.
    static func cocoaXIB(owner: String, module: String?, appName: String, menu: Bool, window: Bool, ownerHasWindowOutlet: Bool = false) -> String {
        let mod = moduleAttributes(module)
        var objects = ""
        var ownerConnections = ""
        if menu { ownerConnections += "                <outlet property=\"delegate\" destination=\"Ycd-ad-1\" id=\"Ycd-c-1\"/>\n" }
        if window && ownerHasWindowOutlet { ownerConnections += "                <outlet property=\"window\" destination=\"Ycd-win-1\" id=\"Ycd-c-2\"/>\n" }
        let ownerMod = owner == "NSApplication" ? "" : mod
        objects += "        <customObject id=\"-2\" userLabel=\"File's Owner\" customClass=\"\(owner)\"\(ownerMod)"
        objects += ownerConnections.isEmpty ? "/>\n" : ">\n            <connections>\n\(ownerConnections)            </connections>\n        </customObject>\n"
        objects += "        <customObject id=\"-1\" userLabel=\"First Responder\" customClass=\"FirstResponder\"/>\n"
        objects += "        <customObject id=\"-3\" userLabel=\"Application\" customClass=\"NSObject\"/>\n"
        if menu {
            let wout = window && !ownerHasWindowOutlet
                ? ">\n            <connections>\n                <outlet property=\"window\" destination=\"Ycd-win-1\" id=\"Ycd-c-3\"/>\n            </connections>\n        </customObject>\n"
                : "/>\n"
            objects += "        <customObject id=\"Ycd-ad-1\" customClass=\"AppDelegate\"\(mod)\(wout)"
            objects += mainMenu(appName, quitTarget: "-1").replacingOccurrences(of: "<menu key=\"mainMenu\" ", with: "<menu ") + "\n"
        }
        if window {
            objects += """
                    <window title="\(appName.xmlEscaped)" allowsToolTipsWhenApplicationIsInactive="NO" autorecalculatesKeyViewLoop="NO" releasedWhenClosed="NO" animationBehavior="default" id="Ycd-win-1">
                        <windowStyleMask key="styleMask" titled="YES" closable="YES" miniaturizable="YES" resizable="YES"/>
                        <rect key="contentRect" x="196" y="240" width="640" height="420"/>
                        <rect key="screenRect" x="0.0" y="0.0" width="1680" height="1027"/>
                        <view key="contentView" id="Ycd-cv-1">
                            <rect key="frame" x="0.0" y="0.0" width="640" height="420"/>
                            <autoresizingMask key="autoresizingMask"/>
                        </view>
                    </window>

            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <document type="com.apple.InterfaceBuilder3.Cocoa.XIB" version="3.0" toolsVersion="1" targetRuntime="MacOSX.Cocoa" propertyAccessControl="none" useAutolayout="YES">
            <objects>
        \(objects)    </objects>
        </document>

        """
    }

    /// A UIKit app's scene manifest (Info.plist), with `UISceneStoryboardFile`
    /// when a storyboard names the first scene.
    static func sceneManifest(storyboard: String?, delegate: String = "$(PRODUCT_MODULE_NAME).SceneDelegate") -> PropertyListItem {
        var config: [(String, PropertyListItem)] = [("UISceneConfigurationName", .string("Default Configuration")),
                                                    ("UISceneDelegateClassName", .string(delegate))]
        if let storyboard { config.append(("UISceneStoryboardFile", .string(storyboard))) }
        return ProjectGenerator.pd([
            ("UIApplicationSupportsMultipleScenes", .bool(false)),
            ("UISceneConfigurations", ProjectGenerator.pd([("UIWindowSceneSessionRoleApplication", .array([ProjectGenerator.pd(config)]))])),
        ])
    }
}
