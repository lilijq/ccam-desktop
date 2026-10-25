import Foundation

enum BrowserSettingsGuardError: LocalizedError {
    case unavailable(String), conflict(source: String, key: String), dynamicPolicy(String), missingHelper
    var errorDescription: String? {
        switch self {
        case .missingHelper: return "登录浏览器助手不可用，已停止登录。请重新安装本应用。"
        case .unavailable(let source): return "无法检查浏览器锁相关设置：\(source)。请修复此设置文件后再登录。"
        case .conflict(let source, let key): return "\(source) 中的 \(key) 会改变登录浏览器或账号路由。请移除此设置后再登录；浏览器锁未被绕过。"
        case .dynamicPolicy(let source): return "\(source) 使用动态策略助手，无法在登录前确认浏览器路由。请联系策略管理员提供固定设置后再登录。"
        }
    }
}

/// Read-only, deliberately conservative preflight. It checks all candidate sources,
/// including sources shadowed by a higher-priority tier, without modifying policy.
/// Only named settings documents are opened; credentials, cookies and history are not.
enum BrowserSettingsGuard {
    static func validate(directory: String, profileDirectories: [String], environment: [String: String],
                         claudeArguments: [String] = [],
                         systemSettingsDirectory: URL = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode", isDirectory: true),
                         managedPreferenceFiles: [URL]? = nil) throws {
        guard let browser = environment["BROWSER"], browser.hasPrefix("/"), !browser.contains("\0") else {
            throw BrowserSettingsGuardError.missingHelper
        }
        let home = URL(fileURLWithPath: environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path, isDirectory: true)
        var scanner = Scanner(directory: URL(fileURLWithPath: directory, isDirectory: true), environment: environment, expectedBrowser: browser)
        let explicit = profileDirectories.filter { !$0.isEmpty }
        if explicit.isEmpty {
            if let config = environment["CLAUDE_CONFIG_DIR"], !config.isEmpty {
                try scanner.config(at: scanner.resolve(config))
            } else {
                try scanner.config(at: home.appendingPathComponent(".claude"))
                try scanner.document(home.appendingPathComponent(".claude.json"))
            }
        } else {
            for path in explicit { try scanner.config(at: scanner.resolve(path)) }
        }

        // Claude can read parent project settings and canonicalize local settings to
        // the Git root. Checking ancestors also covers linked worktree directories.
        var ancestor = scanner.directory.standardizedFileURL
        while true {
            let config = ancestor.appendingPathComponent(".claude", isDirectory: true)
            try scanner.document(config.appendingPathComponent("settings.json"))
            try scanner.document(config.appendingPathComponent("settings.local.json"))
            let next = ancestor.deletingLastPathComponent()
            if next.path == ancestor.path { break }
            ancestor = next
        }

        try scanner.document(systemSettingsDirectory.appendingPathComponent("managed-settings.json"), managed: true)
        for file in try scanner.children(systemSettingsDirectory.appendingPathComponent("managed-settings.d"))
        where file.pathExtension == "json" && !file.lastPathComponent.hasPrefix(".") {
            try scanner.document(file, managed: true)
        }
        let preferences = managedPreferenceFiles ?? [
            URL(fileURLWithPath: "/Library/Managed Preferences/\(NSUserName())/com.anthropic.claudecode.plist"),
            URL(fileURLWithPath: "/Library/Managed Preferences/com.anthropic.claudecode.plist")
        ]
        for file in preferences { try scanner.document(file, managed: true, plist: true) }

        // New `ccam add` may join a group before the account exists. CCAM 0.11.0
        // shares settings.json from these immediate group folders (paths.FromEnv).
        let data: URL
        if let root = environment["CCAM_HOME"], !root.isEmpty {
            data = scanner.resolve(root).appendingPathComponent("data")
        } else if let xdg = environment["XDG_DATA_HOME"], xdg.hasPrefix("/") {
            data = URL(fileURLWithPath: xdg).appendingPathComponent("ccam")
        } else {
            data = home.appendingPathComponent(".local/share/ccam")
        }
        for group in try scanner.children(data.appendingPathComponent("groups")) {
            for name in ["settings.json", "settings.local.json", "cowork_settings.json", "remote-settings.json"] {
                try scanner.document(group.appendingPathComponent(name), managed: name == "remote-settings.json")
            }
        }
        try scanner.arguments(claudeArguments)
    }

    private struct Scanner {
        let directory: URL
        let environment: [String: String]
        let expectedBrowser: String
        var visited = Set<String>()
        var configs = Set<String>()
        let sizeLimit = 8 * 1024 * 1024

        func resolve(_ path: String) -> URL {
            if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
            return directory.appendingPathComponent(path).standardizedFileURL
        }
        mutating func config(at root: URL) throws {
            let path = root.standardizedFileURL.path
            guard configs.insert(path).inserted else { return }
            guard configs.count <= 32 else { throw BrowserSettingsGuardError.unavailable(path) }
            for name in ["settings.json", "settings.local.json", "cowork_settings.json", ".claude.json", ".claude-custom-oauth.json", "remote-settings.json"] {
                try document(root.appendingPathComponent(name), managed: name == "remote-settings.json")
            }
        }
        func children(_ directory: URL) throws -> [URL] {
            do {
                return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
            } catch let error as NSError where Self.isMissing(error) { return [] }
            catch { throw BrowserSettingsGuardError.unavailable(directory.path) }
        }
        static func isMissing(_ error: NSError) -> Bool {
            if error.domain == NSPOSIXErrorDomain { return error.code == 2 }
            if error.domain == NSCocoaErrorDomain { return error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError }
            return false
        }
        mutating func document(_ url: URL, managed: Bool = false, plist: Bool = false, required: Bool = false) throws {
            let key = url.standardizedFileURL.path + (managed ? "|managed" : "")
            guard visited.insert(key).inserted else { return }
            let data: Data
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                // Following a normal CCAM settings symlink is intentional. Refuse
                // pipes/devices to avoid blocking, and bound memory for bad files.
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    let target = url.resolvingSymlinksInPath()
                    guard target.path != url.path else { throw BrowserSettingsGuardError.unavailable(url.path) }
                    try document(target, managed: managed, plist: plist, required: true)
                    return
                }
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber, size.intValue <= sizeLimit else {
                    throw BrowserSettingsGuardError.unavailable(url.path)
                }
                data = try Data(contentsOf: url)
            } catch let error as BrowserSettingsGuardError { throw error }
            catch let error as NSError where Self.isMissing(error) && !required { return }
            catch { throw BrowserSettingsGuardError.unavailable(url.path) }
            let object: Any
            do {
                if plist { object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
                else { object = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) }
            } catch { throw BrowserSettingsGuardError.unavailable(url.path) }
            try inspect(object, source: url.path, managed: managed)
        }
        mutating func inspect(_ object: Any, source: String, managed: Bool) throws {
            guard let dictionary = object as? [String: Any] else { throw BrowserSettingsGuardError.unavailable(source) }
            if let raw = dictionary["env"] {
                guard let env = raw as? [String: Any] else { throw BrowserSettingsGuardError.unavailable(source) }
                for (key, value) in env {
                    switch key.uppercased() {
                    case "BROWSER":
                        guard let value = value as? String, value == expectedBrowser else {
                            throw BrowserSettingsGuardError.conflict(source: source, key: "env.BROWSER")
                        }
                    case "CCAM_PROFILE":
                        throw BrowserSettingsGuardError.conflict(source: source, key: "env.CCAM_PROFILE")
                    case "CCAM_DESKTOP_DATA_DIR":
                        guard let value = value as? String, value == environment[key] else {
                            throw BrowserSettingsGuardError.conflict(source: source, key: "env.CCAM_DESKTOP_DATA_DIR")
                        }
                    case "CLAUDE_CONFIG_DIR":
                        guard let value = value as? String, !value.isEmpty else { throw BrowserSettingsGuardError.unavailable(source) }
                        try config(at: resolve(value))
                    default: break
                    }
                }
            }
            if managed {
                if let helper = dictionary["policyHelper"] as? [String: Any],
                   (helper["path"] as? String)?.isEmpty == false || (helper["script"] as? String)?.isEmpty == false {
                    throw BrowserSettingsGuardError.dynamicPolicy(source)
                }
                if let variants = dictionary["policyHelpers"] as? [String: Any] {
                    if let mac = variants["macos"] as? [String: Any] {
                        if (mac["path"] as? String)?.isEmpty == false || (mac["script"] as? String)?.isEmpty == false {
                            throw BrowserSettingsGuardError.dynamicPolicy(source)
                        }
                        if let settings = mac["defaultSettings"] { try inspect(settings, source: source, managed: true) }
                    }
                    if let settings = variants["default"] { try inspect(settings, source: source, managed: true) }
                }
            }
        }
        mutating func arguments(_ arguments: [String]) throws {
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--" { break }
                let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                if parts[0] == "--settings" || parts[0] == "--managed-settings" {
                    let value: String
                    if parts.count == 2 { value = parts[1] }
                    else {
                        index += 1
                        guard index < arguments.count else { throw BrowserSettingsGuardError.unavailable(parts[0]) }
                        value = arguments[index]
                    }
                    let managed = parts[0] == "--managed-settings"
                    if value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                        let object: Any
                        do { object = try JSONSerialization.jsonObject(with: Data(value.utf8), options: [.json5Allowed]) }
                        catch { throw BrowserSettingsGuardError.unavailable(parts[0]) }
                        try inspect(object, source: parts[0], managed: managed)
                    } else {
                        guard !value.isEmpty else { throw BrowserSettingsGuardError.unavailable(parts[0]) }
                        try document(resolve(value), managed: managed, required: true)
                    }
                }
                index += 1
            }
        }
    }
}
