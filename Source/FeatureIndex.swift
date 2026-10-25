import Foundation

struct FeatureGroup: Equatable {
    let id: String
    let title: String
    let symbol: String
}

/// Navigation metadata only. CommandCatalog remains the executable source of truth.
enum FeatureIndex {
    static let groups: [FeatureGroup] = [
        FeatureGroup(id: "accounts", title: "账号", symbol: "person.crop.circle"),
        FeatureGroup(id: "quota", title: "额度", symbol: "gauge.with.dots.needle.50percent"),
        FeatureGroup(id: "sessions", title: "会话", symbol: "bubble.left.and.bubble.right"),
        FeatureGroup(id: "sharing", title: "共享组", symbol: "person.2"),
        FeatureGroup(id: "extensions", title: "MCP 与扩展", symbol: "puzzlepiece.extension"),
        FeatureGroup(id: "projects", title: "项目配置", symbol: "folder.badge.gearshape"),
        FeatureGroup(id: "maintenance", title: "维护", symbol: "wrench.and.screwdriver")
    ]
    static var entries: [CommandEntry] {
        CommandCatalog.all.filter { !$0.path.isEmpty && $0.path.first != "help" && $0.path.first != "hook" && $0.path != ["statusline"] }
    }
    static func id(for entry: CommandEntry) -> String { (entry.path + [entry.spec.title]).joined(separator: "\u{1F}") }
    static func groupID(for entry: CommandEntry) -> String {
        switch entry.path.first {
        case "list", "add", "login", "logout", "use", "rename", "remove", "shortcut", "import": return "accounts"
        case "usage", "pick": return "quota"
        case "run", "agents", "attach", "next": return "sessions"
        case "group", "share": return "sharing"
        case "mcp", "ext": return "extensions"
        case "folder", "migrate": return "projects"
        default: return "maintenance"
        }
    }
    static func entries(in groupID: String) -> [CommandEntry] { entries.filter { self.groupID(for: $0) == groupID } }
    static var common: [CommandEntry] {
        let paths = [["add"], ["usage"], ["login"], ["doctor"]]
        return paths.compactMap { path in entries.first { $0.path == path } }
    }
    /// Search always spans the full index, including while viewing a single group.
    static func search(_ query: String, displayText: (CommandEntry) -> String = { $0.spec.title + " " + $0.spec.detail + " " + $0.category }) -> [CommandEntry] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return entries }
        return entries.filter { entry in
            let text = displayText(entry)
            return terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}
