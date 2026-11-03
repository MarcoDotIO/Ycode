import Foundation
import OVDBus

// The interface descriptions the exporter publishes (introspection and
// `Properties.GetAll`). Names and signatures are those of the public
// at-spi2-core interface XML (`xml/*.xml`); only members the exporter
// answers are listed.

enum ATSPIInterfaces {
    typealias I = DBusInterfaceDescription
    typealias P = DBusInterfaceDescription.Property

    static let accessible = I(ATSPI.accessible, methods: [
        .method("GetChildAtIndex", in: ["i"], out: ["(so)"]), .method("GetChildren", out: ["a(so)"]),
        .method("GetIndexInParent", out: ["i"]), .method("GetRelationSet", out: ["a(ua(so))"]),
        .method("GetRole", out: ["u"]), .method("GetRoleName", out: ["s"]), .method("GetLocalizedRoleName", out: ["s"]),
        .method("GetState", out: ["au"]), .method("GetAttributes", out: ["a{ss}"]),
        .method("GetApplication", out: ["(so)"]), .method("GetInterfaces", out: ["as"]),
    ], properties: [
        P("version", "u"), P("Name", "s"), P("Description", "s"), P("Parent", "(so)"), P("ChildCount", "i"),
        P("Locale", "s"), P("AccessibleId", "s"), P("HelpText", "s"),
    ])

    static let application = I(ATSPI.application, methods: [
        .method("GetLocale", in: ["u"], out: ["s"]), .method("GetApplicationBusAddress", out: ["s"]),
    ], properties: [
        P("ToolkitName", "s"), P("Version", "s"), P("ToolkitVersion", "s"), P("AtspiVersion", "s"),
        P("InterfaceVersion", "u"), P("Id", "i", .readwrite),
    ])

    static let component = I(ATSPI.component, methods: [
        .method("Contains", in: ["i", "i", "u"], out: ["b"]), .method("GetAccessibleAtPoint", in: ["i", "i", "u"], out: ["(so)"]),
        .method("GetExtents", in: ["u"], out: ["(iiii)"]), .method("GetPosition", in: ["u"], out: ["i", "i"]),
        .method("GetSize", out: ["i", "i"]), .method("GetLayer", out: ["u"]), .method("GetMDIZOrder", out: ["n"]),
        .method("GrabFocus", out: ["b"]), .method("GetAlpha", out: ["d"]),
        .method("SetExtents", in: ["i", "i", "i", "i", "u"], out: ["b"]), .method("SetPosition", in: ["i", "i", "u"], out: ["b"]),
        .method("SetSize", in: ["i", "i"], out: ["b"]), .method("ScrollTo", in: ["u"], out: ["b"]),
        .method("ScrollToPoint", in: ["u", "i", "i"], out: ["b"]),
    ], properties: [P("version", "u")])

    static let action = I(ATSPI.action, methods: [
        .method("GetDescription", in: ["i"], out: ["s"]), .method("GetName", in: ["i"], out: ["s"]),
        .method("GetLocalizedName", in: ["i"], out: ["s"]), .method("GetKeyBinding", in: ["i"], out: ["s"]),
        .method("GetActions", out: ["a(sss)"]), .method("DoAction", in: ["i"], out: ["b"]),
    ], properties: [P("version", "u"), P("NActions", "i")])

    static let text = I(ATSPI.text, methods: [
        .method("GetStringAtOffset", in: ["i", "u"], out: ["s", "i", "i"]), .method("GetText", in: ["i", "i"], out: ["s"]),
        .method("SetCaretOffset", in: ["i"], out: ["b"]),
        .method("GetTextBeforeOffset", in: ["i", "u"], out: ["s", "i", "i"]),
        .method("GetTextAtOffset", in: ["i", "u"], out: ["s", "i", "i"]),
        .method("GetTextAfterOffset", in: ["i", "u"], out: ["s", "i", "i"]),
        .method("GetCharacterAtOffset", in: ["i"], out: ["i"]), .method("GetAttributeValue", in: ["i", "s"], out: ["s"]),
        .method("GetAttributes", in: ["i"], out: ["a{ss}", "i", "i"]), .method("GetDefaultAttributes", out: ["a{ss}"]),
        .method("GetCharacterExtents", in: ["i", "u"], out: ["i", "i", "i", "i"]),
        .method("GetOffsetAtPoint", in: ["i", "i", "u"], out: ["i"]), .method("GetNSelections", out: ["i"]),
        .method("GetSelection", in: ["i"], out: ["i", "i"]), .method("AddSelection", in: ["i", "i"], out: ["b"]),
        .method("RemoveSelection", in: ["i"], out: ["b"]), .method("SetSelection", in: ["i", "i", "i"], out: ["b"]),
        .method("GetRangeExtents", in: ["i", "i", "u"], out: ["i", "i", "i", "i"]),
        .method("GetBoundedRanges", in: ["i", "i", "i", "i", "u", "u", "u"], out: ["a(iisv)"]),
        .method("GetAttributeRun", in: ["i", "b"], out: ["a{ss}", "i", "i"]), .method("GetDefaultAttributeSet", out: ["a{ss}"]),
        .method("ScrollSubstringTo", in: ["i", "i", "u"], out: ["b"]),
        .method("ScrollSubstringToPoint", in: ["i", "i", "u", "i", "i"], out: ["b"]),
    ], properties: [P("version", "u"), P("CharacterCount", "i"), P("CaretOffset", "i")])

    static let editableText = I(ATSPI.editableText, methods: [
        .method("SetTextContents", in: ["s"], out: ["b"]), .method("InsertText", in: ["i", "s", "i"], out: ["b"]),
        .method("CopyText", in: ["i", "i"]), .method("CutText", in: ["i", "i"], out: ["b"]),
        .method("DeleteText", in: ["i", "i"], out: ["b"]), .method("PasteText", in: ["i"], out: ["b"]),
    ], properties: [P("version", "u")])

    static let value = I(ATSPI.value, properties: [
        P("version", "u"), P("MinimumValue", "d"), P("MaximumValue", "d"), P("MinimumIncrement", "d"),
        P("CurrentValue", "d", .readwrite), P("Text", "s"),
    ])

    static let selection = I(ATSPI.selection, methods: [
        .method("GetSelectedChild", in: ["i"], out: ["(so)"]), .method("SelectChild", in: ["i"], out: ["b"]),
        .method("DeselectSelectedChild", in: ["i"], out: ["b"]), .method("IsChildSelected", in: ["i"], out: ["b"]),
        .method("SelectAll", out: ["b"]), .method("ClearSelection", out: ["b"]), .method("DeselectChild", in: ["i"], out: ["b"]),
    ], properties: [P("version", "u"), P("NSelectedChildren", "i")])

    static let cacheItem = "((so)(so)(so)iiassusau)"
    static let cache = I(ATSPI.cache, methods: [.method("GetItems", out: ["a" + cacheItem])],
                         properties: [P("version", "u")],
                         signals: [.init("AddAccessible", [.init(cacheItem)]), .init("RemoveAccessible", [.init("(so)")])])

    static let all: [String: I] = [
        ATSPI.accessible: accessible, ATSPI.application: application, ATSPI.component: component, ATSPI.action: action,
        ATSPI.text: text, ATSPI.editableText: editableText, ATSPI.value: value, ATSPI.selection: selection,
        ATSPI.cache: cache,
    ]
}
