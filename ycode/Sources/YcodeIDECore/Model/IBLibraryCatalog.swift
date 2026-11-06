#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// The Library's Objects tab (`library.md` §Reference Objects library):
/// every UIKit object kind in list order, with its class, the XML element
/// it writes, where it goes when inserted, its default size, and Ycode's
/// own one-line summary and description. Storyboards list 80 kinds; xibs
/// list 79 (no Main Menu, Container View or Storyboard Reference; Window
/// and External Object added). macOS documents keep the AppKit kinds the
/// editor has always offered.
extension IBDocument {
    public enum NewObject: String, CaseIterable, Sendable {
        case label = "Label", button = "Button", grayButton = "Gray Button", tintedButton = "Tinted Button", filledButton = "Filled Button"
        case pullDownButton = "Pull Down Button", popUpButton = "Pop Up Button", segmentedControl = "Segmented Control"
        case textField = "Text Field", slider = "Slider", switchControl = "Switch", activityIndicator = "Activity Indicator View"
        case progressView = "Progress View", pageControl = "Page Control", stepper = "Stepper", colorWell = "Color Well"
        case pasteControl = "Paste Control", horizontalStackView = "Horizontal Stack View", verticalStackView = "Vertical Stack View"
        case tableView = "Table View", tableViewCell = "Table View Cell", imageView = "Image View", collectionView = "Collection View"
        case collectionViewCell = "Collection View Cell", collectionReusableView = "Collection Reusable View", textView = "Text View"
        case scrollView = "Scroll View", datePicker = "Date Picker", pickerView = "Picker View"
        case blurView = "Visual Effect View with Blur", vibrancyView = "Visual Effect Views with Blur and Vibrancy"
        case mapView = "Map Kit View", metalKitView = "MetalKit View", glkView = "GLKit View", sceneKitView = "SceneKit View"
        case spriteKitView = "SpriteKit View", arSceneKitView = "ARKit SceneKit View", arSpriteKitView = "ARKit SpriteKit View"
        case webView = "Web View (deprecated)", webKitView = "WebKit View", realityKitView = "RealityKit AR View"
        case roomCaptureView = "Room Capture View", locationButton = "Core Location Button", navigationBar = "Navigation Bar"
        case navigationItem = "Navigation Item", toolbar = "Toolbar", barButtonItem = "Bar Button Item"
        case barButtonItemGroup = "Bar Button Item Group", fixedSpace = "Fixed Space Bar Button Item"
        case flexibleSpace = "Flexible Space Bar Button Item", tabBar = "Tab Bar", tabBarItem = "Tab Bar Item", searchBar = "Search Bar"
        case command = "Menu Command", mainMenu = "Main Menu", subMenu = "Sub Menu", inlineMenu = "Inline Section Menu"
        case window = "Window", view = "View", containerView = "Container View", viewController = "View Controller"
        case storyboardReference = "Storyboard Reference", navigationController = "Navigation Controller"
        case tableViewController = "Table View Controller", collectionViewController = "Collection View Controller"
        case tabBarController = "Tab Bar Controller", splitViewController = "Split View Controller"
        case pageViewController = "Page View Controller", hostingController = "Hosting View Controller"
        case glkViewController = "GLKit View Controller", playerViewController = "AVKit Player View Controller"
        case lookAroundViewController = "Look Around View Controller", object = "Object", externalObject = "External Object"
        case tapGesture = "Tap Gesture Recognizer", pinchGesture = "Pinch Gesture Recognizer"
        case rotationGesture = "Rotation Gesture Recognizer", swipeGesture = "Swipe Gesture Recognizer"
        case panGesture = "Pan Gesture Recognizer", screenEdgePanGesture = "Screen Edge Pan Gesture Recognizer"
        case longPressGesture = "Long Press Gesture Recognizer", customGesture = "Custom Gesture Recognizer"

        /// The kinds a storyboard lists, in Library order (80).
        public static let storyboardList: [Self] = allCases.filter { $0 != .window && $0 != .externalObject }
        /// The kinds an iOS xib lists, in Library order (79).
        public static let xibList: [Self] = allCases.filter { ![.mainMenu, .containerView, .storyboardReference].contains($0) }
        /// The kinds a macOS document lists (AppKit equivalents).
        public static let macList: [Self] = [.label, .button, .textField, .imageView, .view, .horizontalStackView, .verticalStackView]

        /// The Library's list for a document.
        public static func list(for d: IBDocument) -> [Self] {
            !d.isFlippedRuntime ? macList : d.isStoryboard ? storyboardList : xibList
        }

        /// Where an inserted object goes.
        public enum Placement: Sendable {
            /// A subview of the target view (the three-part frame rule).
            case subview
            /// A new scene (storyboards) or a top-level object (xibs).
            case scene
            /// An object of the target's scene (storyboards) or a top-level object (xibs).
            case sceneObject
            /// A gesture recognizer: a scene object connected to the target view.
            case gesture
            case tableCell, collectionCell, reusableView
            /// A bar button item: into a toolbar's items or a navigation item.
            case barItem, barItemGroup
            case navigationItem, tabBarItem
            /// A command or menu: into a menu's children or a button's menu.
            case menuElement
            /// A top-level object of a xib (Window).
            case topLevel
        }

        /// What the kind is: class, element, placement, size, and Ycode's
        /// own texts (`library.md`: the reference's texts are not copied).
        public struct Info: Sendable {
            public var className: String
            public var element: String
            public var placement: Placement
            /// The width a placed view gets; nil = the parent's width.
            public var width: CGFloat?
            /// The height a placed view gets; nil for objects without a frame.
            public var height: CGFloat?
            public var summary: String
            public var details: String
        }

        public var info: Info { Self.table[self]! }
        /// The class the object makes on iOS.
        public var className: String { info.className }
        /// The element it writes on iOS.
        public var element: String { info.element }
        public var placement: Placement { info.placement }
        /// The one-line description under the object's name.
        public var summary: String { info.summary }
        /// The detail area's longer description.
        public var details: String { info.details }

        /// The class the object makes, per runtime (shown in the Library's
        /// detail area).
        public func className(iOS: Bool) -> String {
            if iOS { return className }
            switch self {
            case .label, .textField: return "NSTextField"
            case .button: return "NSButton"
            case .imageView: return "NSImageView"
            case .horizontalStackView, .verticalStackView: return "NSStackView"
            default: return "NSView"
            }
        }

        /// The size a placed view gets. Sizes marked "(older)" in
        /// `library.md` come from files written by earlier Xcode versions,
        /// the best evidence there is; the others are Ycode's choice (the
        /// reference's insert size is OPEN there).
        public var defaultSize: CGSize { size(parentWidth: 320) }

        /// The default size inside a parent of the given width (bars and
        /// cells take the parent's width).
        public func size(parentWidth: CGFloat) -> CGSize {
            CGSize(width: info.width ?? parentWidth, height: info.height ?? 128)
        }

        /// The kind's subtitle in the detail area: `ClassName: summary`.
        public func subtitle(iOS: Bool = true) -> String { "\(className(iOS: iOS)): \(summary)" }

        /// Whether a Library query matches (`library.md` §Search): every
        /// whitespace-separated word of the query is a substring of the name
        /// or of the class name, ignoring case.
        public func matches(_ query: String, iOS: Bool = true) -> Bool {
            let words = query.lowercased().split(whereSeparator: \.isWhitespace)
            let name = rawValue.lowercased(), cls = className(iOS: iOS).lowercased()
            return words.allSatisfy { name.contains($0) || cls.contains($0) }
        }

        /// Objects matching a Library query, in list order.
        public static func matching(_ query: String, in list: [Self] = storyboardList, iOS: Bool = true) -> [Self] {
            list.filter { $0.matches(query, iOS: iOS) }
        }
    }
}

extension IBDocument.NewObject {
    private static func i(_ c: String, _ e: String, _ p: Placement, _ w: CGFloat?, _ h: CGFloat?, _ s: String, _ d: String) -> Info {
        Info(className: c, element: e, placement: p, width: w, height: h, summary: s, details: d)
    }

    // Sizes: "(older)" = seen in files from earlier Xcode versions
    // (library.md §Insert defaults, item 2); every other size is Ycode's.
    static let table: [Self: Info] = [
        .label: i("UILabel", "label", .subview, 42, 21, // (older)
                  "Shows one or more lines of read-only text.",
                  "A label shows text the user cannot edit: a title, a caption or a value. Set its text, font, colour and alignment in the Attributes inspector; set Lines to 0 to let it wrap."),
        .button: i("UIButton", "button", .subview, 75, 35,
                   "Runs an action when tapped; drawn as text only.",
                   "A plain button draws its title in the tint colour with no background. Connect its Primary Action Triggered event to a method to respond to taps."),
        .grayButton: i("UIButton", "button", .subview, 75, 35,
                       "Runs an action when tapped; on a grey capsule.",
                       "A button with a soft grey background, for secondary actions next to a filled button."),
        .tintedButton: i("UIButton", "button", .subview, 75, 35,
                         "Runs an action when tapped; on a light tint.",
                         "A button whose background is a light shade of the tint colour, for actions that should stand out without dominating."),
        .filledButton: i("UIButton", "button", .subview, 75, 35,
                         "Runs an action when tapped; on a solid tint.",
                         "A button filled with the tint colour and white text: the main action of a screen."),
        .pullDownButton: i("UIButton", "button", .subview, 75, 35,
                           "Opens a menu of commands when tapped.",
                           "A button whose menu opens on the first tap. Add commands to its menu in the outline; each command runs its own action."),
        .popUpButton: i("UIButton", "button", .subview, 75, 35,
                        "Offers a menu of choices and shows the chosen one.",
                        "A button that opens a menu and keeps the last chosen item as its title, for picking one value from a short list."),
        .segmentedControl: i("UISegmentedControl", "segmentedControl", .subview, 121, 32,
                             "A row of segments; one of them is selected.",
                             "A segmented control switches between a few related modes or views. Set the number of segments and each segment's title or image in the Attributes inspector."),
        .textField: i("UITextField", "textField", .subview, 97, 34,
                      "Lets the user type one line of text.",
                      "A text field takes a single line of input: a name, a search term, a password. The Text Input Traits choose the keyboard, capitalization and return key."),
        .slider: i("UISlider", "slider", .subview, 118, 30, // (older)
                   "Picks a value from a continuous range.",
                   "A slider sets a number between a minimum and a maximum by dragging its thumb along a track."),
        .switchControl: i("UISwitch", "switch", .subview, 51, 31, // (older)
                          "Turns a single setting on or off.",
                          "A switch shows and changes a two-state setting. Its value is the On state in the Attributes inspector."),
        .activityIndicator: i("UIActivityIndicatorView", "activityIndicatorView", .subview, 20, 20,
                              "A spinning wheel for work of unknown length.",
                              "An activity indicator shows that something is in progress when its duration is unknown. Start and stop it from code, or tick Animating."),
        .progressView: i("UIProgressView", "progressView", .subview, 150, 4,
                         "A bar that fills as a task progresses.",
                         "A progress view shows how much of a task is done, from 0 to 1."),
        .pageControl: i("UIPageControl", "pageControl", .subview, 123, 26,
                        "A row of dots, one per page.",
                        "A page control shows how many pages there are and which one is current, usually under a paging scroll view."),
        .stepper: i("UIStepper", "stepper", .subview, 94, 32,
                    "Raises or lowers a value with − and + buttons.",
                    "A stepper changes a number by a fixed step between a minimum and a maximum."),
        .colorWell: i("UIColorWell", "colorWell", .subview, 44, 44,
                      "Shows a colour and opens a colour picker.",
                      "A colour well displays the selected colour; tapping it lets the user choose another."),
        .pasteControl: i("UIPasteControl", "pasteControl", .subview, 80, 36,
                         "Pastes from the clipboard without asking.",
                         "A paste control lets the user paste into a target without the system's paste permission prompt."),
        .horizontalStackView: i("UIStackView", "stackView", .subview, 240, 128,
                                "Lines up its views in a row.",
                                "A horizontal stack view arranges the views it holds side by side and lays them out for you; set the alignment, distribution and spacing in the Attributes inspector."),
        .verticalStackView: i("UIStackView", "stackView", .subview, 240, 128,
                              "Lines up its views in a column.",
                              "A vertical stack view arranges the views it holds one above another and lays them out for you."),
        .tableView: i("UITableView", "tableView", .subview, 320, 240,
                      "Shows rows of data in a scrolling list.",
                      "A table view shows a scrolling list of rows, in sections. Add prototype cells and fill them from a data source."),
        .tableViewCell: i("UITableViewCell", "tableViewCell", .tableCell, nil, 43.67, // row height (older)
                          "One row of a table view, used as a prototype.",
                          "A table view cell is a prototype row: design it once, give it an identifier, and dequeue it for every row of that kind. It goes into a table view."),
        .imageView: i("UIImageView", "imageView", .subview, 240, 128, // (older)
                      "Shows an image.",
                      "An image view shows an image from the asset catalog or a symbol, scaled by its content mode."),
        .collectionView: i("UICollectionView", "collectionView", .subview, 320, 240,
                           "Shows items in a flexible scrolling layout.",
                           "A collection view lays out items in a grid or any custom layout. Add prototype cells and supply the items from a data source."),
        .collectionViewCell: i("UICollectionViewCell", "collectionViewCell", .collectionCell, 128, 128, // (older)
                               "One item of a collection view, used as a prototype.",
                               "A collection view cell is a prototype item, reused for every item of its kind. It goes into a collection view."),
        .collectionReusableView: i("UICollectionReusableView", "collectionReusableView", .reusableView, nil, 50,
                                   "A section header or footer of a collection view.",
                                   "A reusable view shows supplementary content such as a section's header or footer. It goes into a collection view."),
        .textView: i("UITextView", "textView", .subview, 240, 128,
                     "Shows and edits several lines of text.",
                     "A text view holds scrolling, multi-line text, editable or read-only, and can detect links, addresses and dates."),
        .scrollView: i("UIScrollView", "scrollView", .subview, 240, 128,
                       "Scrolls and zooms content larger than itself.",
                       "A scroll view shows part of a larger content area and lets the user scroll or zoom it. Lay out its content against the content and frame layout guides."),
        .datePicker: i("UIDatePicker", "datePicker", .subview, 200, 35,
                       "Picks a date, a time or both.",
                       "A date picker lets the user choose a date and time, compactly, inline or with wheels."),
        .pickerView: i("UIPickerView", "pickerView", .subview, 320, 216,
                       "Spinning wheels of values to choose from.",
                       "A picker view shows one or more wheels; the rows of each come from its data source."),
        .blurView: i("UIVisualEffectView", "visualEffectView", .subview, 240, 128,
                     "Blurs the content behind it.",
                     "A visual effect view with a blur effect softens whatever is behind it. Put views in its content view."),
        .vibrancyView: i("UIVisualEffectView", "visualEffectView", .subview, 240, 128,
                         "Blurs the content behind it and adds vibrancy.",
                         "Two nested visual effect views: a blur, and inside it a vibrancy effect that makes labels and symbols stand out against the blur."),
        .mapView: i("MKMapView", "mapView", .subview, 240, 128,
                    "Shows an interactive map.",
                    "A map view shows a map that can be panned and zoomed, with annotations and overlays."),
        .metalKitView: i("MTKView", "mtkView", .subview, 240, 128,
                         "Draws with Metal.",
                         "A MetalKit view provides a drawable and a render loop for drawing with Metal."),
        .glkView: i("GLKView", "glkView", .subview, 240, 128,
                    "Draws with OpenGL ES (deprecated).",
                    "A GLKit view hosts OpenGL ES drawing. OpenGL ES is deprecated; prefer a MetalKit view."),
        .sceneKitView: i("SCNView", "sceneKitView", .subview, 240, 128,
                         "Shows a 3D SceneKit scene.",
                         "A SceneKit view renders a 3D scene and can let the user move the camera."),
        .spriteKitView: i("SKView", "skView", .subview, 240, 128,
                          "Shows a 2D SpriteKit scene.",
                          "A SpriteKit view runs and renders a 2D scene of sprites and actions."),
        .arSceneKitView: i("ARSCNView", "arscnView", .subview, 240, 128,
                           "Mixes a SceneKit scene with the camera feed.",
                           "An ARKit SceneKit view places 3D SceneKit content in the camera image, anchored to the real world."),
        .arSpriteKitView: i("ARSKView", "arskView", .subview, 240, 128,
                            "Mixes SpriteKit content with the camera feed.",
                            "An ARKit SpriteKit view places 2D sprites in the camera image, anchored to the real world."),
        .webView: i("UIWebView", "webView", .subview, 240, 128,
                    "Shows web content (deprecated).",
                    "The old web view. It is deprecated; use a WebKit view instead."),
        .webKitView: i("WKWebView", "wkWebView", .subview, 240, 128,
                       "Shows web content.",
                       "A WebKit view loads and shows web pages and HTML, with navigation and JavaScript."),
        .realityKitView: i("ARView", "arView", .subview, 240, 128,
                           "Shows RealityKit content, with or without AR.",
                           "A RealityKit view renders RealityKit entities, either in the camera image for AR or in a virtual scene."),
        .roomCaptureView: i("RoomCaptureView", "roomCaptureView", .subview, 240, 128,
                            "Scans a room and shows the captured model.",
                            "A room capture view guides the user through scanning a room with the camera and LiDAR."),
        .locationButton: i("CLLocationButton", "clLocationButton", .subview, 44, 44,
                           "Asks for the location once, with one tap.",
                           "A Core Location button grants the app the user's location for one session when tapped, without a permission prompt."),
        .navigationBar: i("UINavigationBar", "navigationBar", .subview, nil, 44, // (older)
                          "A bar with a title and buttons at the top of a screen.",
                          "A navigation bar shows a navigation item's title and bar button items. A navigation controller provides its own."),
        .navigationItem: i("UINavigationItem", "navigationItem", .navigationItem, nil, nil,
                           "The title and buttons a navigation bar shows.",
                           "A navigation item holds a title and the bar button items shown in a navigation bar. It goes into a navigation bar or a view controller."),
        .toolbar: i("UIToolbar", "toolbar", .subview, nil, 44,
                    "A bar of buttons, usually at the bottom.",
                    "A toolbar holds bar button items for actions on the current screen."),
        .barButtonItem: i("UIBarButtonItem", "barButtonItem", .barItem, nil, nil,
                          "A button for a toolbar or navigation bar.",
                          "A bar button item is a button in a toolbar or a navigation bar: a title, an image or a system item."),
        .barButtonItemGroup: i("UIBarButtonItemGroup", "barButtonItemGroup", .barItemGroup, nil, nil,
                               "A group of bar button items shown together.",
                               "A bar button item group keeps related bar button items together in a navigation item."),
        .fixedSpace: i("UIBarButtonItem", "barButtonItem", .barItem, nil, nil,
                       "A fixed gap between bar button items.",
                       "A fixed space item puts a gap of a set width between bar button items."),
        .flexibleSpace: i("UIBarButtonItem", "barButtonItem", .barItem, nil, nil,
                          "A gap that grows to fill a bar.",
                          "A flexible space item takes the free room in a toolbar, pushing the items around it apart."),
        .tabBar: i("UITabBar", "tabBar", .subview, nil, 49, // (older)
                   "A bar of tabs at the bottom of a screen.",
                   "A tab bar shows tab bar items; the selected one is highlighted. A tab bar controller provides its own."),
        .tabBarItem: i("UITabBarItem", "tabBarItem", .tabBarItem, nil, nil,
                       "One tab of a tab bar.",
                       "A tab bar item is the title, image and badge of a tab. It goes into a tab bar or a view controller."),
        .searchBar: i("UISearchBar", "searchBar", .subview, nil, 44, // (older)
                      "A field for typing a search, with optional scopes.",
                      "A search bar takes a search term and can offer scope buttons and a cancel button."),
        .command: i("UICommand", "command", .menuElement, nil, nil,
                    "One command of a menu.",
                    "A menu command has a title, an optional image and key equivalent, and runs an action. It goes into a menu."),
        .mainMenu: i("UIMenu", "menu", .scene, nil, nil,
                     "The app's menu bar on the Mac.",
                     "The main menu holds the menus of the app's menu bar when it runs on the Mac."),
        .subMenu: i("UIMenu", "menu", .menuElement, nil, nil,
                    "A menu nested in another menu.",
                    "A sub menu opens from its parent menu and holds its own commands."),
        .inlineMenu: i("UIMenu", "menu", .menuElement, nil, nil,
                       "A section of commands shown inline in its parent menu.",
                       "An inline section menu shows its commands inside the parent menu, separated from the others by a line."),
        .window: i("UIWindow", "window", .topLevel, 393, 852,
                   "A window that holds the app's views.",
                   "A window is the top of a view hierarchy. Most apps create their windows in code; a xib can hold one for older app designs."),
        .view: i("UIView", "view", .subview, 240, 128,
                 "A plain rectangular area that holds other views.",
                 "A view draws a background and holds subviews. Use it to group views and lay them out together."),
        .containerView: i("UIContainerView", "containerView", .subview, 240, 128,
                          "Embeds another view controller's view.",
                          "A container view shows the view of a child view controller, connected to it by an embed segue."),
        .viewController: i("UIViewController", "viewController", .scene, nil, nil,
                           "Manages one screen of content.",
                           "A view controller owns a view and responds to what happens in it. Set its class in the Identity inspector."),
        .storyboardReference: i("UIViewController", "viewControllerPlaceholder", .scene, nil, nil,
                                "Stands for a view controller in another storyboard.",
                                "A storyboard reference lets segues lead into another storyboard, to its initial view controller or one with a given identifier."),
        .navigationController: i("UINavigationController", "navigationController", .scene, nil, nil,
                                 "Manages a stack of screens with a navigation bar.",
                                 "A navigation controller pushes and pops view controllers and shows a navigation bar with a back button."),
        .tableViewController: i("UITableViewController", "tableViewController", .scene, nil, nil,
                                "A view controller whose view is a table view.",
                                "A table view controller manages a table view and is its data source and delegate."),
        .collectionViewController: i("UICollectionViewController", "collectionViewController", .scene, nil, nil,
                                     "A view controller whose view is a collection view.",
                                     "A collection view controller manages a collection view and is its data source and delegate."),
        .tabBarController: i("UITabBarController", "tabBarController", .scene, nil, nil,
                             "Switches between screens with a tab bar.",
                             "A tab bar controller shows one child view controller per tab, chosen with the tab bar at the bottom."),
        .splitViewController: i("UISplitViewController", "splitViewController", .scene, nil, nil,
                                "Shows a list and its detail side by side.",
                                "A split view controller shows two or three columns on wide screens and collapses them on narrow ones."),
        .pageViewController: i("UIPageViewController", "pageViewController", .scene, nil, nil,
                               "Pages between view controllers.",
                               "A page view controller moves between child view controllers by scrolling or turning pages."),
        .hostingController: i("UIHostingController", "hostingController", .scene, nil, nil,
                              "Shows a SwiftUI view.",
                              "A hosting view controller shows a SwiftUI view inside a UIKit app."),
        .glkViewController: i("GLKViewController", "glkViewController", .scene, nil, nil,
                              "Runs an OpenGL ES render loop (deprecated).",
                              "A GLKit view controller drives a GLKit view's render loop. OpenGL ES is deprecated."),
        .playerViewController: i("AVPlayerViewController", "avPlayerViewController", .scene, nil, nil,
                                 "Plays video with the system controls.",
                                 "An AVKit player view controller shows a player's video with playback controls."),
        .lookAroundViewController: i("MKLookAroundViewController", "lookAroundViewController", .scene, nil, nil,
                                     "Shows street-level imagery of a place.",
                                     "A Look Around view controller shows interactive street-level imagery for a location."),
        .object: i("NSObject", "customObject", .sceneObject, nil, nil,
                   "An instance of a class you name.",
                   "An object is created when the scene loads. Set its class in the Identity inspector and connect outlets and actions to it."),
        .externalObject: i("NSObject", "placeholder", .sceneObject, nil, nil,
                           "An object provided by the code that loads the xib.",
                           "An external object stands for an object passed in when the xib is loaded, so views can connect to it."),
        .tapGesture: i("UITapGestureRecognizer", "tapGestureRecognizer", .gesture, nil, nil,
                       "Recognizes taps.",
                       "A tap gesture recognizer sends its action when the view is tapped the set number of times."),
        .pinchGesture: i("UIPinchGestureRecognizer", "pinchGestureRecognizer", .gesture, nil, nil,
                         "Recognizes two-finger pinches.",
                         "A pinch gesture recognizer reports the scale of a pinch, for zooming."),
        .rotationGesture: i("UIRotationGestureRecognizer", "rotationGestureRecognizer", .gesture, nil, nil,
                            "Recognizes two-finger rotation.",
                            "A rotation gesture recognizer reports the angle of a two-finger turn."),
        .swipeGesture: i("UISwipeGestureRecognizer", "swipeGestureRecognizer", .gesture, nil, nil,
                         "Recognizes swipes in one direction.",
                         "A swipe gesture recognizer sends its action for a quick swipe in its direction."),
        .panGesture: i("UIPanGestureRecognizer", "panGestureRecognizer", .gesture, nil, nil,
                       "Recognizes dragging.",
                       "A pan gesture recognizer follows a finger dragged across the view."),
        .screenEdgePanGesture: i("UIScreenEdgePanGestureRecognizer", "screenEdgePanGestureRecognizer", .gesture, nil, nil,
                                 "Recognizes drags that start at a screen edge.",
                                 "A screen edge pan gesture recognizer follows a drag that begins at the chosen edges of the screen."),
        .longPressGesture: i("UILongPressGestureRecognizer", "pongPressGestureRecognizer", .gesture, nil, nil,
                             "Recognizes touches held in place.",
                             "A long press gesture recognizer sends its action when a touch stays down for the minimum duration."),
        .customGesture: i("UIGestureRecognizer", "gestureRecognizer", .gesture, nil, nil,
                          "A gesture recognizer of your own class.",
                          "A custom gesture recognizer is an instance of your own gesture recognizer subclass; set its class in the Identity inspector."),
    ]
}
