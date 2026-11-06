#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// What each Library object writes (`library.md` §Insert defaults): the
/// element, its attributes in the canonical order (common view attributes,
/// kind leading attributes, hugging priorities, `fixedFrame`, content
/// alignment, the other kind attributes, then
/// `translatesAutoresizingMaskIntoConstraints`, `id`), and its children
/// (frame, autoresizing mask, value elements, kind children). A placed
/// view carries the three-part frame rule: `fixedFrame="YES"`,
/// `translatesAutoresizingMaskIntoConstraints="NO"` and an autoresizing
/// mask with `flexibleMaxX` and `flexibleMaxY`.
///
/// Templates use tokens: `@ID` is the new object's ID, `@1` … `@9` more
/// fresh IDs; on a line of its own `@FRAME` is the frame and the
/// three-part rule's mask, `@RECT` the frame alone, `@BOUNDS` a frame at
/// the origin with the object's size; `@W` and `@H` are the size, and
/// `@SM` the scene member attribute of a storyboard controller.
extension IBDocument {
    static let placedMask = "<autoresizingMask key=\"autoresizingMask\" flexibleMaxX=\"YES\" flexibleMaxY=\"YES\"/>"
    static let fillMask = "<autoresizingMask key=\"autoresizingMask\" widthSizable=\"YES\" heightSizable=\"YES\"/>"
    static let tamic = "translatesAutoresizingMaskIntoConstraints=\"NO\""

    /// The iOS template of a kind (see the type's comment for tokens).
    static func iosTemplate(_ kind: NewObject) -> String {
        let placed = "fixedFrame=\"YES\""
        let t = tamic
        let button = { (style: String, lead: String, extra: String, menu: String) in
            """
            <button opaque="NO" contentMode="scaleToFill"\(lead) \(placed) contentHorizontalAlignment="center" contentVerticalAlignment="center" buttonType="system" lineBreakMode="middleTruncation"\(extra) \(t) id="@ID">
                @FRAME
            \(menu)    <state key="normal" title="Button"/>
                <buttonConfiguration key="configuration" style="\(style)" title="Button"/>
            </button>
            """
        }
        let menu = { (first: String) in
            """
                <menu key="menu" id="@1">
                    <children>
                        <command title="Item 1"\(first) id="@2"/>
                        <command title="Item 2" id="@3"/>
                    </children>
                </menu>

            """
        }
        func simple(_ e: String, _ attrs: String) -> String { "<\(e) \(attrs) id=\"@ID\">\n    @FRAME\n</\(e)>" }
        let control = "contentHorizontalAlignment=\"center\" contentVerticalAlignment=\"center\""
        let rootView = """
                <view key="view" contentMode="scaleToFill" id="@1">
                    @BOUNDS
                    \(fillMask)
                    <viewLayoutGuide key="safeArea" id="@2"/>
                    <color key="backgroundColor" systemColor="systemBackgroundColor"/>
                </view>
            """
        let tableAttrs = "alwaysBounceVertical=\"YES\" dataMode=\"prototypes\" style=\"plain\" separatorStyle=\"default\" rowHeight=\"-1\" estimatedRowHeight=\"-1\" sectionHeaderHeight=\"-1\" estimatedSectionHeaderHeight=\"-1\" sectionFooterHeight=\"-1\" estimatedSectionFooterHeight=\"-1\""
        let flowLayout = """
                <collectionViewFlowLayout key="collectionViewLayout" automaticEstimatedItemSize="YES" minimumLineSpacing="10" minimumInteritemSpacing="10" id="@3">
                    <size key="itemSize" width="128" height="128"/>
                    <size key="headerReferenceSize" width="0.0" height="0.0"/>
                    <size key="footerReferenceSize" width="0.0" height="0.0"/>
                    <inset key="sectionInset" minX="0.0" minY="0.0" maxX="0.0" maxY="0.0"/>
                </collectionViewFlowLayout>
                <cells/>
            """
        let effectContent = { (inner: String) in
            """
                <view key="contentView" opaque="NO" clipsSubviews="YES" multipleTouchEnabled="YES" contentMode="center" insetsLayoutMarginsFromSafeArea="NO" id="@1">
                    @BOUNDS
                    \(fillMask)
            \(inner)    </view>
            """
        }
        switch kind {
        case .label:
            return """
                <label opaque="NO" userInteractionEnabled="NO" contentMode="left" horizontalHuggingPriority="251" verticalHuggingPriority="251" \(placed) text="Label" textAlignment="natural" lineBreakMode="tailTruncation" baselineAdjustment="alignBaselines" adjustsFontSizeToFit="NO" \(t) id="@ID">
                    @FRAME
                    <fontDescription key="fontDescription" type="system" pointSize="17"/>
                    <nil key="textColor"/>
                    <nil key="highlightedColor"/>
                </label>
                """
        case .button: return button("plain", "", "", "")
        case .grayButton: return button("gray", "", "", "")
        case .tintedButton: return button("tinted", "", "", "")
        case .filledButton: return button("filled", "", "", "")
        case .pullDownButton: return button("plain", " showsMenuAsPrimaryAction=\"YES\"", "", menu(""))
        case .popUpButton:
            return button("plain", " showsMenuAsPrimaryAction=\"YES\"", " changesSelectionAsPrimaryAction=\"YES\"", menu(" menuElementState=\"on\""))
        case .segmentedControl:
            return """
                <segmentedControl opaque="NO" contentMode="scaleToFill" \(placed) contentHorizontalAlignment="left" contentVerticalAlignment="top" segmentControlStyle="plain" selectedSegmentIndex="0" \(t) id="@ID">
                    @FRAME
                    <segments>
                        <segment title="First"/>
                        <segment title="Second"/>
                    </segments>
                </segmentedControl>
                """
        case .textField:
            return """
                <textField opaque="NO" contentMode="scaleToFill" \(placed) contentHorizontalAlignment="left" contentVerticalAlignment="center" borderStyle="roundedRect" textAlignment="natural" minimumFontSize="17" \(t) id="@ID">
                    @FRAME
                    <fontDescription key="fontDescription" type="system" pointSize="14"/>
                    <textInputTraits key="textInputTraits"/>
                </textField>
                """
        case .slider: return simple("slider", "opaque=\"NO\" contentMode=\"scaleToFill\" \(placed) \(control) value=\"0.5\" minValue=\"0.0\" maxValue=\"1\" \(t)")
        case .switchControl:
            return simple("switch", "opaque=\"NO\" contentMode=\"scaleToFill\" horizontalHuggingPriority=\"750\" verticalHuggingPriority=\"750\" \(placed) \(control) on=\"YES\" \(t)")
        case .activityIndicator:
            return simple("activityIndicatorView", "opaque=\"NO\" contentMode=\"scaleToFill\" horizontalHuggingPriority=\"750\" verticalHuggingPriority=\"750\" \(placed) style=\"medium\" \(t)")
        case .progressView: return simple("progressView", "opaque=\"NO\" contentMode=\"scaleToFill\" verticalHuggingPriority=\"750\" \(placed) progress=\"0.5\" \(t)")
        case .pageControl: return simple("pageControl", "opaque=\"NO\" contentMode=\"scaleToFill\" \(placed) \(control) numberOfPages=\"3\" \(t)")
        case .stepper:
            return simple("stepper", "opaque=\"NO\" contentMode=\"scaleToFill\" horizontalHuggingPriority=\"750\" verticalHuggingPriority=\"750\" \(placed) \(control) maximumValue=\"100\" \(t)")
        case .colorWell: return simple("colorWell", "opaque=\"NO\" contentMode=\"scaleToFill\" \(placed) \(control) \(t)")
        case .pasteControl: return simple("pasteControl", "opaque=\"NO\" contentMode=\"scaleToFill\" \(placed) \(control) \(t)")
        case .horizontalStackView: return simple("stackView", "opaque=\"NO\" contentMode=\"scaleToFill\" \(placed) \(t)")
        case .verticalStackView: return simple("stackView", "opaque=\"NO\" contentMode=\"scaleToFill\" \(placed) axis=\"vertical\" \(t)")
        case .tableView:
            return """
                <tableView clipsSubviews="YES" contentMode="scaleToFill" \(placed) \(tableAttrs) \(t) id="@ID">
                    @FRAME
                    <color key="backgroundColor" systemColor="systemBackgroundColor"/>
                </tableView>
                """
        case .tableViewCell:
            return """
                <tableViewCell clipsSubviews="YES" contentMode="scaleToFill" preservesSuperviewLayoutMargins="YES" selectionStyle="default" indentationWidth="10" id="@ID">
                    @RECT
                    <autoresizingMask key="autoresizingMask"/>
                    <tableViewCellContentView key="contentView" opaque="NO" clipsSubviews="YES" multipleTouchEnabled="YES" contentMode="center" preservesSuperviewLayoutMargins="YES" insetsLayoutMarginsFromSafeArea="NO" tableViewCell="@ID" id="@1">
                        @BOUNDS
                        <autoresizingMask key="autoresizingMask"/>
                    </tableViewCellContentView>
                </tableViewCell>
                """
        case .imageView:
            return simple("imageView", "clipsSubviews=\"YES\" userInteractionEnabled=\"NO\" contentMode=\"scaleAspectFit\" horizontalHuggingPriority=\"251\" verticalHuggingPriority=\"251\" \(placed) \(t)")
        case .collectionView:
            return """
                <collectionView clipsSubviews="YES" multipleTouchEnabled="YES" contentMode="scaleToFill" \(placed) dataMode="prototypes" \(t) id="@ID">
                    @FRAME
                \(flowLayout)
                </collectionView>
                """
        case .collectionViewCell:
            return """
                <collectionViewCell opaque="NO" clipsSubviews="YES" multipleTouchEnabled="YES" contentMode="center" id="@ID">
                    @RECT
                    \(placedMask)
                    <collectionViewCellContentView key="contentView" opaque="NO" clipsSubviews="YES" multipleTouchEnabled="YES" contentMode="center" insetsLayoutMarginsFromSafeArea="NO" id="@1">
                        @BOUNDS
                        <autoresizingMask key="autoresizingMask"/>
                    </collectionViewCellContentView>
                </collectionViewCell>
                """
        case .collectionReusableView:
            return """
                <collectionReusableView opaque="NO" clipsSubviews="YES" multipleTouchEnabled="YES" contentMode="center" id="@ID">
                    @RECT
                    \(placedMask)
                </collectionReusableView>
                """
        case .textView:
            return """
                <textView clipsSubviews="YES" multipleTouchEnabled="YES" contentMode="scaleToFill" \(placed) text="Text" textAlignment="natural" \(t) id="@ID">
                    @FRAME
                    <color key="backgroundColor" systemColor="systemBackgroundColor"/>
                    <fontDescription key="fontDescription" type="system" pointSize="14"/>
                    <color key="textColor" systemColor="labelColor"/>
                    <textInputTraits key="textInputTraits" autocapitalizationType="sentences"/>
                </textView>
                """
        case .scrollView:
            return """
                <scrollView clipsSubviews="YES" multipleTouchEnabled="YES" contentMode="scaleToFill" \(placed) \(t) id="@ID">
                    @FRAME
                    <viewLayoutGuide key="contentLayoutGuide" id="@1"/>
                    <viewLayoutGuide key="frameLayoutGuide" id="@2"/>
                </scrollView>
                """
        case .datePicker: return simple("datePicker", "opaque=\"NO\" contentMode=\"scaleToFill\" \(placed) \(control) datePickerMode=\"dateAndTime\" style=\"compact\" \(t)")
        case .pickerView: return simple("pickerView", "contentMode=\"scaleToFill\" \(placed) \(t)")
        case .blurView:
            return """
                <visualEffectView opaque="NO" contentMode="scaleToFill" \(placed) \(t) id="@ID">
                    @FRAME
                \(effectContent(""))
                    <blurEffect style="regular"/>
                </visualEffectView>
                """
        case .vibrancyView:
            let inner = """
                        <subviews>
                            <visualEffectView opaque="NO" contentMode="scaleToFill" id="@2">
                                @BOUNDS
                                \(fillMask)
                                <view key="contentView" opaque="NO" clipsSubviews="YES" multipleTouchEnabled="YES" contentMode="center" insetsLayoutMarginsFromSafeArea="NO" id="@3">
                                    @BOUNDS
                                    \(fillMask)
                                </view>
                                <vibrancyEffect>
                                    <blurEffect style="regular"/>
                                </vibrancyEffect>
                            </visualEffectView>
                        </subviews>

                """
            return """
                <visualEffectView opaque="NO" contentMode="scaleToFill" \(placed) \(t) id="@ID">
                    @FRAME
                \(effectContent(inner))
                    <blurEffect style="regular"/>
                </visualEffectView>
                """
        case .mapView: return simple("mapView", "clipsSubviews=\"YES\" multipleTouchEnabled=\"YES\" contentMode=\"scaleToFill\" \(placed) mapType=\"standard\" \(t)")
        case .metalKitView: return simple("mtkView", "contentMode=\"scaleToFill\" \(placed) colorPixelFormat=\"BGRA8Unorm\" depthStencilPixelFormat=\"Depth32Float\" \(t)")
        case .glkView: return simple("glkView", "opaque=\"NO\" clipsSubviews=\"YES\" multipleTouchEnabled=\"YES\" contentMode=\"center\" \(placed) enableSetNeedsDisplay=\"NO\" \(t)")
        case .sceneKitView: return simple("sceneKitView", "clipsSubviews=\"YES\" multipleTouchEnabled=\"YES\" contentMode=\"scaleToFill\" \(placed) \(t)")
        case .spriteKitView: return simple("skView", "contentMode=\"scaleToFill\" \(placed) \(t)")
        case .arSceneKitView: return simple("arscnView", "clipsSubviews=\"YES\" multipleTouchEnabled=\"YES\" contentMode=\"scaleToFill\" \(placed) \(t)")
        case .arSpriteKitView: return simple("arskView", "contentMode=\"scaleToFill\" \(placed) \(t)")
        case .webView: return simple("webView", "contentMode=\"scaleToFill\" \(placed) \(t)")
        case .webKitView:
            return """
                <wkWebView contentMode="scaleToFill" \(placed) \(t) id="@ID">
                    @FRAME
                    <wkWebViewConfiguration key="configuration">
                        <audiovisualMediaTypes key="mediaTypesRequiringUserActionForPlayback" none="YES"/>
                        <wkPreferences key="preferences"/>
                    </wkWebViewConfiguration>
                </wkWebView>
                """
        case .realityKitView: return simple("arView", "multipleTouchEnabled=\"YES\" contentMode=\"scaleToFill\" \(placed) \(t)")
        case .roomCaptureView: return simple("roomCaptureView", "contentMode=\"scaleToFill\" \(placed) \(t)")
        case .locationButton: return simple("clLocationButton", "opaque=\"NO\" contentMode=\"scaleToFill\" \(placed) \(control) \(t)")
        case .navigationBar:
            return """
                <navigationBar contentMode="scaleToFill" \(placed) \(t) id="@ID">
                    @FRAME
                    <items>
                        <navigationItem title="Title" id="@1"/>
                    </items>
                </navigationBar>
                """
        case .navigationItem: return "<navigationItem title=\"Title\" id=\"@ID\"/>"
        case .toolbar:
            return """
                <toolbar opaque="NO" clearsContextBeforeDrawing="NO" contentMode="scaleToFill" \(placed) \(t) id="@ID">
                    @FRAME
                    <items>
                        <barButtonItem title="Item" id="@1"/>
                    </items>
                </toolbar>
                """
        case .barButtonItem: return "<barButtonItem title=\"Item\" id=\"@ID\"/>"
        case .barButtonItemGroup:
            return """
                <barButtonItemGroup id="@ID">
                    <barButtonItems>
                        <barButtonItem title="Item" id="@1"/>
                    </barButtonItems>
                </barButtonItemGroup>
                """
        case .fixedSpace: return "<barButtonItem style=\"plain\" systemItem=\"fixedSpace\" id=\"@ID\"/>"
        case .flexibleSpace: return "<barButtonItem style=\"plain\" systemItem=\"flexibleSpace\" id=\"@ID\"/>"
        case .tabBar:
            return """
                <tabBar contentMode="scaleToFill" \(placed) \(t) id="@ID">
                    @FRAME
                    <items>
                        <tabBarItem systemItem="favorites" id="@1"/>
                        <tabBarItem systemItem="more" id="@2"/>
                    </items>
                </tabBar>
                """
        case .tabBarItem: return "<tabBarItem title=\"Item\" id=\"@ID\"/>"
        case .searchBar:
            return """
                <searchBar contentMode="redraw" \(placed) \(t) id="@ID">
                    @FRAME
                    <textInputTraits key="textInputTraits"/>
                </searchBar>
                """
        case .command: return "<command title=\"Item\" id=\"@ID\"/>"
        case .mainMenu: return "<menu title=\"Main Menu\" id=\"@ID\">\n    <children/>\n</menu>"
        case .subMenu:
            return """
                <menu title="Menu" id="@ID">
                    <children>
                        <command title="Item" id="@1"/>
                    </children>
                </menu>
                """
        case .inlineMenu:
            return """
                <menu id="@ID">
                    <menuOptions key="options" displayInline="YES"/>
                    <children>
                        <command title="Item" id="@1"/>
                    </children>
                </menu>
                """
        case .window:
            return """
                <window opaque="NO" clearsContextBeforeDrawing="NO" contentMode="scaleToFill" id="@ID">
                    @RECT
                    \(placedMask)
                    <color key="backgroundColor" systemColor="systemBackgroundColor"/>
                </window>
                """
        case .view:
            return """
                <view contentMode="scaleToFill" \(placed) \(t) id="@ID">
                    @FRAME
                    <color key="backgroundColor" systemColor="systemBackgroundColor"/>
                </view>
                """
        case .containerView:
            return """
                <containerView opaque="NO" contentMode="scaleToFill" \(placed) \(t) id="@ID">
                    @FRAME
                    <connections>
                        <segue destination="@5" kind="embed" id="@6"/>
                    </connections>
                </containerView>
                """
        case .viewController: return "<viewController id=\"@ID\"@SM>\n\(rootView)\n</viewController>"
        case .storyboardReference: return "<viewControllerPlaceholder id=\"@ID\"@SM/>"
        case .navigationController:
            return """
                <navigationController id="@ID"@SM>
                    <navigationBar key="navigationBar" contentMode="scaleToFill" id="@1">
                        <autoresizingMask key="autoresizingMask"/>
                    </navigationBar>
                </navigationController>
                """
        case .tableViewController:
            return """
                <tableViewController id="@ID"@SM>
                    <tableView key="view" clipsSubviews="YES" contentMode="scaleToFill" \(tableAttrs) id="@1">
                        @BOUNDS
                        \(fillMask)
                        <color key="backgroundColor" systemColor="systemBackgroundColor"/>
                        <connections>
                            <outlet property="dataSource" destination="@ID" id="@2"/>
                            <outlet property="delegate" destination="@ID" id="@3"/>
                        </connections>
                    </tableView>
                </tableViewController>
                """
        case .collectionViewController:
            return """
                <collectionViewController id="@ID"@SM>
                    <collectionView key="view" clipsSubviews="YES" multipleTouchEnabled="YES" contentMode="scaleToFill" dataMode="prototypes" id="@1">
                        @BOUNDS
                        \(fillMask)
                \("    " + flowLayout.replacingOccurrences(of: "\n", with: "\n    "))
                        <connections>
                            <outlet property="dataSource" destination="@ID" id="@2"/>
                            <outlet property="delegate" destination="@ID" id="@4"/>
                        </connections>
                    </collectionView>
                </collectionViewController>
                """
        case .tabBarController:
            return """
                <tabBarController id="@ID"@SM>
                    <tabBar key="tabBar" contentMode="scaleToFill" id="@1">
                        <rect key="frame" x="0.0" y="0.0" width="393" height="49"/>
                        <autoresizingMask key="autoresizingMask"/>
                    </tabBar>
                </tabBarController>
                """
        case .splitViewController: return "<splitViewController id=\"@ID\"@SM/>"
        case .pageViewController:
            return "<pageViewController autoresizesArchivedViewToFullSize=\"NO\" transitionStyle=\"pageCurl\" navigationOrientation=\"horizontal\" spineLocation=\"min\" id=\"@ID\"@SM/>"
        case .hostingController: return "<hostingController id=\"@ID\"@SM/>"
        case .glkViewController:
            return """
                <glkViewController preferredFramesPerSecond="30" id="@ID"@SM>
                    <glkView key="view" opaque="NO" clipsSubviews="YES" multipleTouchEnabled="YES" contentMode="center" enableSetNeedsDisplay="NO" id="@1">
                        @BOUNDS
                        \(fillMask)
                        <viewLayoutGuide key="safeArea" id="@2"/>
                    </glkView>
                </glkViewController>
                """
        case .playerViewController: return "<avPlayerViewController videoGravity=\"AVLayerVideoGravityResizeAspect\" id=\"@ID\"@SM/>"
        case .lookAroundViewController: return "<lookAroundViewController id=\"@ID\"@SM/>"
        case .object: return "<customObject id=\"@ID\"/>"
        case .externalObject: return "<placeholder placeholderIdentifier=\"ExternalObject\" id=\"@ID\" userLabel=\"External Object\"/>"
        case .tapGesture: return "<tapGestureRecognizer id=\"@ID\"/>"
        case .pinchGesture: return "<pinchGestureRecognizer id=\"@ID\"/>"
        case .rotationGesture: return "<rotationGestureRecognizer id=\"@ID\"/>"
        case .swipeGesture: return "<swipeGestureRecognizer direction=\"right\" id=\"@ID\"/>"
        case .panGesture: return "<panGestureRecognizer minimumNumberOfTouches=\"1\" id=\"@ID\"/>"
        case .screenEdgePanGesture: return "<screenEdgePanGestureRecognizer minimumNumberOfTouches=\"1\" id=\"@ID\"/>"
        // The file format spells the element with a "p" (library.md, item 79).
        case .longPressGesture: return "<pongPressGestureRecognizer allowableMovement=\"10\" minimumPressDuration=\"0.5\" id=\"@ID\"/>"
        case .customGesture: return "<gestureRecognizer id=\"@ID\"/>"
        }
    }

    /// The macOS (AppKit) template of the kinds a macOS document offers.
    static func macTemplate(_ kind: NewObject) -> String {
        let t = tamic
        switch kind {
        case .label:
            return """
                <textField focusRingType="none" horizontalHuggingPriority="251" verticalHuggingPriority="750" \(t) id="@ID">
                    @RECT
                    <textFieldCell key="cell" lineBreakMode="clipping" title="Label" id="@1">
                        <font key="font" metaFont="system"/>
                    </textFieldCell>
                </textField>
                """
        case .button:
            return """
                <button verticalHuggingPriority="750" \(t) id="@ID">
                    @RECT
                    <buttonCell key="cell" type="push" title="Button" bezelStyle="rounded" alignment="center" borderStyle="border" imageScaling="proportionallyDown" inset="2" id="@1">
                        <font key="font" metaFont="system"/>
                    </buttonCell>
                </button>
                """
        case .textField:
            return """
                <textField focusRingType="none" verticalHuggingPriority="750" \(t) id="@ID">
                    @RECT
                    <textFieldCell key="cell" scrollable="YES" lineBreakMode="clipping" selectable="YES" editable="YES" sendsActionOnEndEditing="YES" borderStyle="bezel" drawsBackground="YES" id="@1">
                        <font key="font" metaFont="system"/>
                    </textFieldCell>
                </textField>
                """
        case .imageView:
            return """
                <imageView horizontalHuggingPriority="251" verticalHuggingPriority="251" \(t) id="@ID">
                    @RECT
                    <imageCell key="cell" refusesFirstResponder="YES" alignment="left" imageScaling="proportionallyDown" id="@1"/>
                </imageView>
                """
        case .horizontalStackView, .verticalStackView:
            let o = kind == .verticalStackView ? "vertical" : "horizontal"
            return "<stackView distribution=\"fill\" orientation=\"\(o)\" alignment=\"top\" spacing=\"8\" \(t) id=\"@ID\">\n    @RECT\n</stackView>"
        default:
            return "<customView \(t) id=\"@ID\">\n    @RECT\n</customView>"
        }
    }

    /// The macOS sizes (unchanged since the first Library).
    static func macSize(_ kind: NewObject) -> CGSize {
        switch kind {
        case .label: CGSize(width: 100, height: 21)
        case .button: CGSize(width: 90, height: 32)
        case .textField: CGSize(width: 150, height: 24)
        case .imageView: CGSize(width: 64, height: 64)
        case .horizontalStackView: CGSize(width: 160, height: 40)
        case .verticalStackView: CGSize(width: 40, height: 160)
        default: CGSize(width: 160, height: 120)
        }
    }

    /// Expands a template into lines (depth, text). `ids` maps `@1`… to
    /// fresh IDs, created on first use.
    static func expand(_ template: String, id: String, frame f: CGRect, storyboard: Bool, ids: inout [String: String], fresh: () -> String) -> [(Int, String)] {
        let rect = "<rect key=\"frame\" x=\"\(number(f.minX))\" y=\"\(number(f.minY))\" width=\"\(number(f.width))\" height=\"\(number(f.height))\"/>"
        let bounds = "<rect key=\"frame\" x=\"0.0\" y=\"0.0\" width=\"\(number(f.width))\" height=\"\(number(f.height))\"/>"
        var out: [(Int, String)] = []
        for raw in template.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = raw.drop { $0 == " " }
            let depth = (raw.count - trimmed.count) / 4
            switch trimmed {
            case "@FRAME": out += [(depth, rect), (depth, placedMask)]
            case "@RECT": out.append((depth, rect))
            case "@BOUNDS": out.append((depth, bounds))
            default:
                var line = String(trimmed).replacingOccurrences(of: "@SM", with: storyboard ? " sceneMemberID=\"viewController\"" : "")
                line = line.replacingOccurrences(of: "\"@ID\"", with: "\"\(id)\"")
                for n in 1...9 where line.contains("\"@\(n)\"") {
                    let v = ids["@\(n)"] ?? fresh()
                    ids["@\(n)"] = v
                    line = line.replacingOccurrences(of: "\"@\(n)\"", with: "\"\(v)\"")
                }
                out.append((depth, line))
            }
        }
        return out
    }
}
