import Foundation

/// `ycode new`: New Project from the command line, over the same catalog,
/// options and generators as the sheets (`templates.md` §Ycode
/// implementation).
///
///     ycode new --list [--platform P] [--json]
///     ycode new --template <id|title> [--platform P] --name N [--org O]
///               [--option key=value]... [--git] [--save-as S]
///               [--add-to <.xcworkspace|.xcodeproj>] [--group G] <dir>
public enum NewProjectCLI {
    public static let usage = """
    usage: ycode new --list [--platform P] [--json]
           ycode new --template <id|title> [--platform P] --name N [--org O] [--option key=value]...
                     [--git] [--save-as S] [--add-to <.xcworkspace|.xcodeproj>] [--group G] <dir>
    Options take a field's identifier or its label ("--option \\"Testing System=None\\""); see --list.

    """

    /// Runs the command; returns the exit status. Output and errors go
    /// to the given handlers (stdout/stderr by default).
    public static func run(_ args: [String], out: (String) -> Void = { print($0) },
                           err: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
                           gitEnvironment: [String: String]? = nil) -> Int32 {
        var team: String?
        var template: String?, platform: String?, name: String?, org: String?, dir: String?, saveAs: String?, addTo: String?, group: String?
        var options: [(String, String)] = []
        var git = false, list = false, json = false
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--template", "-t": template = it.next()
            case "--platform", "-p": platform = it.next()
            case "--name", "-n": name = it.next()
            case "--org", "--organization": org = it.next()
            case "--option", "-o":
                guard let kv = it.next(), let eq = kv.firstIndex(of: "=") else { err("ycode new: --option takes key=value"); return 2 }
                options.append((String(kv[..<eq]), String(kv[kv.index(after: eq)...])))
            case "--team": team = it.next()
            case "--git": git = true
            case "--no-git": git = false
            case "--save-as": saveAs = it.next()
            case "--add-to": addTo = it.next()
            case "--group": group = it.next()
            case "--list": list = true
            case "--json": json = true
            case "-h", "--help": out(usage); return 0
            default:
                if a.hasPrefix("-") { err("ycode new: unknown option \(a)\n" + usage); return 2 }
                dir = a
            }
        }
        if list { return listTemplates(platform: platform, json: json, out: out) }
        guard let template else { err(usage); return 2 }
        guard let d = ProjectTemplates.find(template, platform: platform) else {
            err("ycode new: no template “\(template)”\(platform.map { " on \($0)" } ?? ""); see ycode new --list")
            return 1
        }
        var form = d.makeForm()
        if let name { form.set(TemplateOptionID.productName, name) }
        if let org { form.set(TemplateOptionID.organizationIdentifier, org) }
        for (k, v) in options {
            let key = d.fields.first { $0.id == k || $0.label.caseInsensitiveCompare(k) == .orderedSame }?.id ?? k
            if let f = d.fields.first(where: { $0.id == key }), case .popUp(let choices) = f.kind,
               !choices.contains(where: { $0.value.caseInsensitiveCompare(v) == .orderedSame || $0.title.caseInsensitiveCompare(v) == .orderedSame }) {
                err("ycode new: \(f.label) is one of: \(choices.map(\.value).joined(separator: ", "))")
                return 1
            }
            form.set(key, v)
        }
        guard d.isAvailable else { err("ycode new: \(ProjectGeneratorError.unavailable(d.title))"); return 1 }
        guard form.isNextEnabled else { err("ycode new: " + form.issues.joined(separator: " ")); return 1 }
        let location = URL(fileURLWithPath: dir ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        var save = NewProjectSaveOptions(location: location, saveAs: saveAs, createGitRepository: git,
                                         addTo: addTo.map { URL(fileURLWithPath: $0) }, group: group)
        save.team = team
        do {
            let created = try NewProjectCreator.create(d, form, save: save, gitEnvironment: gitEnvironment)
            if let w = created.gitWarning { err("ycode new: warning: \(w)") }
            out(created.openURL.path)
            return 0
        } catch {
            err("ycode new: \(error)")
            return 1
        }
    }

    static func listTemplates(platform: String?, json: Bool, out: (String) -> Void) -> Int32 {
        let pool = (ProjectTemplates.all + ProjectTemplates.packages.templates).filter { t in platform.map { t.platform.caseInsensitiveCompare($0) == .orderedSame } ?? true }
        if json {
            let items: [[String: Any]] = pool.map { t in
                ["id": t.id, "platform": t.platform, "section": t.section, "title": t.title, "available": t.isAvailable,
                 "options": t.fields.filter { $0.kind != .derived && $0.forcedValue == nil && !$0.isHidden }.map { f -> [String: Any] in
                     var o: [String: Any] = ["id": f.id, "label": f.label, "default": f.defaultValue]
                     if !f.choices.isEmpty { o["choices"] = f.choices.filter { $0.unavailableReason == nil }.map(\.value) }
                     if f.kind == .checkbox { o["choices"] = ["true", "false"] }
                     return o
                 }]
            }
            let data = (try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            out(String(decoding: data, as: UTF8.self))
            return 0
        }
        var tab = ""
        for t in pool {
            if t.platform != tab {
                tab = t.platform
                out("\(tab):")
            }
            out("  \(t.id.padding(toLength: max(36, t.id.count), withPad: " ", startingAt: 0)) \(t.title)\(t.isAvailable ? "" : "  (not available)")")
            for f in t.fields where f.kind != .derived && !f.isHidden && f.forcedValue == nil && f.id != TemplateOptionID.productName && f.id != TemplateOptionID.team {
                let choices = f.kind == .checkbox ? "true|false" : f.choices.isEmpty ? "text" : f.choices.filter { $0.unavailableReason == nil }.map(\.value).joined(separator: "|")
                out("      \(f.id)=\(choices)  (default \(f.defaultValue.isEmpty ? "empty" : f.defaultValue))")
            }
        }
        return 0
    }
}
