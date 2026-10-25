import Foundation
import CFNetwork
import Darwin

/// Applies the macOS static proxy decision to a known HTTPS query made by a command-line client.
enum NetworkEnvironment {
    /// For a child process whose HTTPS destination is known in advance, let CFNetwork interpret
    /// macOS bypass patterns. This environment must not be reused for arbitrary project commands:
    /// its proxy choice is valid for this destination, not for every URL the child could request.
    static func applyingSystemProxy(to environment: [String: String], destination: URL) -> [String: String] {
        guard destination.scheme?.lowercased() == "https", destination.host != nil,
              let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let dictionary = settings as? [String: Any] else { return environment }
        for key in [kCFNetworkProxiesProxyAutoConfigEnable, kCFNetworkProxiesProxyAutoDiscoveryEnable] {
            if let value = dictionary[key as String], !isZero(value) { return environment }
        }
        // This API returns proxy descriptions. The PAC evaluation APIs are deliberately never used.
        guard let proxies = CFNetworkCopyProxiesForURL(destination as CFURL, settings).takeRetainedValue() as? [[String: Any]] else { return environment }
        return applyingResolvedProxies(proxies, to: environment, destination: destination)
    }

    static func applyingResolvedProxies(_ proxies: [[String: Any]], to environment: [String: String], destination: URL) -> [String: String] {
        guard destination.scheme?.lowercased() == "https", destination.host != nil,
              environment["HTTPS_PROXY"] == nil, environment["https_proxy"] == nil,
              environment["HTTP_PROXY"] == nil, environment["http_proxy"] == nil,
              environment["ALL_PROXY"] == nil, environment["all_proxy"] == nil,
              let first = proxies.first, let type = first[kCFProxyTypeKey as String] as? String else { return environment }
        // Preserve the first-choice policy. Never skip a PAC, direct, or invalid entry to use a
        // later proxy, and never copy proxy credentials into an environment variable.
        guard first[kCFProxyUsernameKey as String] == nil, first[kCFProxyPasswordKey as String] == nil else { return environment }
        let scheme: String
        if type == (kCFProxyTypeHTTP as String) || type == (kCFProxyTypeHTTPS as String) { scheme = "http" }
        else if type == (kCFProxyTypeSOCKS as String) { scheme = "socks5h" }
        else { return environment } // Includes kCFProxyTypeNone, PAC, and unknown proxy kinds.
        guard let proxy = proxyURL(host: first[kCFProxyHostNameKey as String], port: first[kCFProxyPortNumberKey as String], scheme: scheme) else { return environment }
        var result = environment
        result["HTTPS_PROXY"] = proxy
        // Claude's probe also consults HTTP_PROXY for HTTPS requests. Both aliases
        // describe the proxy resolved for this specific destination, not general routing.
        result["HTTP_PROXY"] = proxy
        // NO_PROXY remains exactly as supplied; CFNetwork already applied system exceptions.
        return result
    }

    private static func isZero(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return number.doubleValue == 0
    }

    fileprivate static func proxyURL(host: Any?, port: Any?, scheme: String) -> String? {
        guard let name = host as? String,
              let hostname = validatedHost(name), let number = port as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 1, value <= 65535, value.rounded() == value else { return nil }
        // HTTPSProxy names an HTTP CONNECT proxy; it does not imply TLS to the proxy itself.
        return "\(scheme)://\(hostname):\(Int(value))"
    }

    fileprivate static func validatedHost(_ input: String) -> String? {
        guard !input.isEmpty, input.utf8.allSatisfy({ $0 > 32 && $0 < 127 }), !input.contains("%") else { return nil }
        var host = input
        let bracketed = host.hasPrefix("[") && host.hasSuffix("]")
        if bracketed { host = String(host.dropFirst().dropLast()) }
        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return "[\(host)]" }
        guard !bracketed else { return nil }
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return host }
        // Reject URLs, userinfo, scoped IPv6, malformed numeric addresses and non-ASCII labels.
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return nil }
        guard host.utf8.count <= 253 else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { return nil }
        return host
    }
}

/// Required proxy policy for launches that can contact a remote service.
/// Resolution is entirely local. A valid endpoint is configuration, not proof that
/// the proxy is reachable. Standard proxy clients must fail if that endpoint fails;
/// this policy never retries a command without its proxy environment.
enum ExecutionProxy {
    static let defaultsKey = "executionProxyURL"
    static let proxyKeys = ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]
    static let loopbackBypass = "localhost,127.0.0.1,::1"
    private static let sourceKey = "CCAM_DESKTOP_PROXY_SOURCE"
    private static let endpointKey = "CCAM_DESKTOP_PROXY_ENDPOINT"

    struct State {
        let environment: [String: String]
        /// Credential-free canonical URL, safe to show in the settings interface.
        let endpoint: String
        let sourceSummary: String
    }

    struct ShellConfiguration {
        let directory: URL
        let environment: [String: String]
        let arguments: [String]
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    /// The developer terminal starts without user startup files: those can unset
    /// proxy variables or launch a network client before a corrective hook runs.
    /// This fixes shell configuration, not arbitrary programs' network behavior.
    static func makeShellConfiguration(state: State) throws -> ShellConfiguration {
        let endpoint = try validatedEndpoint(state.endpoint)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccam-proxy-shell-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            // validatedEndpoint contains no quotes or metacharacters; quoting is
            // retained so this file is a literal environment assignment.
            let assignments = proxyKeys.map { "export \($0)='\(endpoint)'" } +
                ["export NO_PROXY='\(loopbackBypass)'", "export no_proxy='\(loopbackBypass)'"]
            let script = (["# CCAM isolated terminal. User startup files are intentionally not loaded.",
                           "unsetopt GLOBAL_RCS", "unsetopt RCS"] + assignments +
                          ["readonly " + (proxyKeys + ["NO_PROXY", "no_proxy", "ZDOTDIR"]).joined(separator: " "),
                           "PROMPT='%n@%m %1~ %# '", ""]).joined(separator: "\n")
            guard FileManager.default.createFile(atPath: directory.appendingPathComponent(".zshenv").path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            var environment = state.environment
            for key in proxyKeys { environment[key] = endpoint }
            environment["NO_PROXY"] = loopbackBypass; environment["no_proxy"] = loopbackBypass
            environment["ZDOTDIR"] = directory.path; environment["SHELL"] = "/bin/zsh"
            return ShellConfiguration(directory: directory, environment: environment, arguments: ["-d", "-i"])
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    /// Only commands known to stay local can run before a proxy is configured.
    /// A usage query is local only when its final source is cache and it cannot
    /// refresh tokens or bypass that cache. Unknown future commands fail closed.
    static func requiresProxy(arguments: [String]) -> Bool {
        guard let command = arguments.first else { return true }
        guard !arguments.contains("--") else { return true }
        let local = Set(["list", "agents", "folder", "share", "shortcut", "use", "rename", "group", "help", "version", "completion"])
        if local.contains(command) { return false }
        guard command == "usage" else { return true }
        var source: String?
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return true }
            if ["--refresh", "--no-cache", "--watch"].contains(argument) ||
                ["--refresh=", "--no-cache=", "--watch="].contains(where: { argument.hasPrefix($0) }) { return true }
            if argument == "--source" {
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("-") else { return true }
                source = arguments[index]
            } else if argument.hasPrefix("--source=") {
                source = String(argument.dropFirst("--source=".count))
            } else if argument.hasPrefix("-") && !["--json", "--verbose", "-v", "--all"].contains(argument) {
                return true
            }
            index += 1
        }
        return source != "cache"
    }

    enum Failure: Error, LocalizedError {
        case missing, invalid, conflict, automatic, unsupported
        var errorDescription: String? {
            switch self {
            case .missing: return "未配置代理，已阻止启动。请在设置中填写 HTTP 代理地址。"
            case .invalid: return "代理配置无效，已阻止启动。请填写完整的 HTTP 或 HTTPS 代理地址和端口，例如 http://127.0.0.1:7890。"
            case .conflict: return "检测到多个不同的代理地址，已阻止启动。请在设置中指定一个代理。"
            case .automatic: return "系统使用自动代理脚本，无法离线确认代理地址，已阻止启动。请在设置中填写代理软件的 HTTP 端口。"
            case .unsupported: return "此代理类型尚未确认兼容，已阻止启动。请使用代理软件的 HTTP 或 HTTPS 代理端口。"
            }
        }
    }

    static func resolve(environment: [String: String], manualURL: String? = UserDefaults.standard.string(forKey: defaultsKey)) throws -> State {
        let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]
        return try resolve(environment: environment, manualURL: manualURL, systemSettings: settings)
    }

    /// Injectable settings keep validation independent of the machine and network.
    static func resolve(environment: [String: String], manualURL: String?, systemSettings: [String: Any]?) throws -> State {
        var base = environment
        // A continuation contains the previous launch environment. Re-read manual
        // or system settings instead of promoting our old injection to an explicit
        // environment override. A changed/deleted proxy must not remain cached.
        if ["manual", "system"].contains(base[sourceKey] ?? ""), let previous = base[endpointKey],
           proxyKeys.allSatisfy({ base[$0] == previous }) {
            for key in proxyKeys { base.removeValue(forKey: key) }
        }
        base.removeValue(forKey: sourceKey); base.removeValue(forKey: endpointKey)
        let endpoint: String
        let source: String
        let summary: String
        if let manual = manualURL?.trimmingCharacters(in: .whitespacesAndNewlines), !manual.isEmpty {
            endpoint = try validatedEndpoint(manual); source = "manual"; summary = "手动代理"
        } else {
            let inherited = proxyKeys.compactMap { base[$0] }
            if !inherited.isEmpty {
                let endpoints = try Set(inherited.map(validatedEndpoint))
                guard endpoints.count == 1, let selected = endpoints.first else { throw Failure.conflict }
                endpoint = selected; source = "environment"; summary = "环境代理"
            } else {
                endpoint = try systemEndpoint(systemSettings); source = "system"; summary = "系统代理"
            }
        }
        // Resolve casing conflicts and prevent NO_PROXY=* or a remote hostname
        // from bypassing the required proxy. Loopback remains available for local
        // development servers and OAuth callbacks.
        for key in proxyKeys { base[key] = endpoint }
        base["NO_PROXY"] = loopbackBypass; base["no_proxy"] = loopbackBypass
        base[sourceKey] = source; base[endpointKey] = endpoint
        return State(environment: base, endpoint: endpoint, sourceSummary: summary)
    }

    static func validatedEndpoint(_ raw: String) throws -> String {
        // No URL credentials, PAC URLs, query strings, paths, encoded separators,
        // or implicit ports. Never include the rejected value in diagnostics.
        guard raw.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw Failure.invalid }
        if raw.lowercased().hasPrefix("socks") { throw Failure.unsupported }
        let pattern = #"^(https?)://(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+):([0-9]{1,5})/?$"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range), match.range == range,
              let schemeRange = Range(match.range(at: 1), in: raw),
              let hostRange = Range(match.range(at: 2), in: raw),
              let portRange = Range(match.range(at: 3), in: raw),
              let host = NetworkEnvironment.validatedHost(String(raw[hostRange])),
              let port = Int(raw[portRange]), (1...65535).contains(port) else { throw Failure.invalid }
        return "\(raw[schemeRange].lowercased())://\(host.lowercased()):\(port)"
    }

    private static func systemEndpoint(_ settings: [String: Any]?) throws -> String {
        guard let settings else { throw Failure.missing }
        for key in [kCFNetworkProxiesProxyAutoConfigEnable, kCFNetworkProxiesProxyAutoDiscoveryEnable] {
            if try enabled(settings[key as String]) { throw Failure.automatic }
        }
        var endpoints = Set<String>()
        for keys in [(kCFNetworkProxiesHTTPEnable, kCFNetworkProxiesHTTPProxy, kCFNetworkProxiesHTTPPort),
                     (kCFNetworkProxiesHTTPSEnable, kCFNetworkProxiesHTTPSProxy, kCFNetworkProxiesHTTPSPort)] {
            guard try enabled(settings[keys.0 as String]) else { continue }
            // macOS's HTTPSProxy is HTTP CONNECT, not TLS to the proxy itself.
            guard let value = NetworkEnvironment.proxyURL(host: settings[keys.1 as String], port: settings[keys.2 as String], scheme: "http") else { throw Failure.invalid }
            endpoints.insert(try validatedEndpoint(value))
        }
        guard endpoints.count <= 1 else { throw Failure.conflict }
        if let endpoint = endpoints.first { return endpoint }
        if try enabled(settings[kCFNetworkProxiesSOCKSEnable as String]) { throw Failure.unsupported }
        throw Failure.missing
    }

    private static func enabled(_ value: Any?) throws -> Bool {
        guard let value else { return false }
        guard let number = value as? NSNumber, number.doubleValue == 0 || number.doubleValue == 1 else { throw Failure.invalid }
        return number.doubleValue == 1
    }
}

enum ProxySettingsGuardError: LocalizedError {
    case unavailable(String), conflict(source: String, key: String), dynamicPolicy(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let source): return "无法检查代理相关设置：\(source)。已阻止启动，请修复设置文件后重试。"
        case .conflict(let source, let key): return "\(source) 中的 \(key) 会覆盖固定代理。已阻止启动，请移除此设置或与应用代理保持一致。"
        case .dynamicPolicy(let source): return "\(source) 使用动态策略，无法离线确认代理不会被覆盖。已阻止启动，请使用固定代理策略。"
        }
    }
}

/// Claude applies settings.env after inheriting its launch environment. Inspect
/// only named settings documents, including managed tiers that override --settings.
/// No account credentials, history, startup scripts or policy helpers are executed.
enum ProxySettingsGuard {
    static func validate(directory: String, profileDirectories: [String], environment: [String: String], claudeArguments: [String] = [],
                         systemSettingsDirectory: URL = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode", isDirectory: true),
                         managedPreferenceFiles: [URL]? = nil) throws {
        guard let raw = environment["HTTPS_PROXY"] else { throw ExecutionProxy.Failure.missing }
        let endpoint = try ExecutionProxy.validatedEndpoint(raw)
        var scanner = Scanner(directory: URL(fileURLWithPath: directory, isDirectory: true), environment: environment, endpoint: endpoint)
        try scanner.inspectEnvironment(environment, source: "启动环境")
        let home = URL(fileURLWithPath: environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path, isDirectory: true)
        try scanner.config(home.appendingPathComponent(".claude"))
        try scanner.document(home.appendingPathComponent(".claude.json"))
        if let path = environment["CLAUDE_CONFIG_DIR"], !path.isEmpty { try scanner.config(scanner.resolve(path)) }
        for path in profileDirectories where !path.isEmpty { try scanner.config(scanner.resolve(path)) }
        var ancestor = scanner.directory.standardizedFileURL
        while true {
            try scanner.document(ancestor.appendingPathComponent(".claude/settings.json"))
            try scanner.document(ancestor.appendingPathComponent(".claude/settings.local.json"))
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }
            ancestor = parent
        }
        try scanner.document(systemSettingsDirectory.appendingPathComponent("managed-settings.json"), managed: true)
        for file in try scanner.children(systemSettingsDirectory.appendingPathComponent("managed-settings.d"))
        where file.pathExtension == "json" && !file.lastPathComponent.hasPrefix(".") {
            try scanner.document(file, managed: true)
        }
        let preferences = managedPreferenceFiles ?? [URL(fileURLWithPath: "/Library/Managed Preferences/\(NSUserName())/com.anthropic.claudecode.plist"),
                                                     URL(fileURLWithPath: "/Library/Managed Preferences/com.anthropic.claudecode.plist")]
        for file in preferences { try scanner.document(file, managed: true, plist: true) }
        let data: URL
        if let root = environment["CCAM_HOME"], !root.isEmpty { data = scanner.resolve(root).appendingPathComponent("data") }
        else if let xdg = environment["XDG_DATA_HOME"], xdg.hasPrefix("/") { data = URL(fileURLWithPath: xdg).appendingPathComponent("ccam") }
        else { data = home.appendingPathComponent(".local/share/ccam") }
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
        let endpoint: String
        var visited = Set<String>()
        var configs = Set<String>()
        let proxyNames = Set(["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "CLAUDE_CODE_HTTP_PROXY", "CLAUDE_CODE_HTTPS_PROXY",
                              "NPM_CONFIG_PROXY", "NPM_CONFIG_HTTP_PROXY", "NPM_CONFIG_HTTPS_PROXY"])
        let scriptNames = Set(["BASH_ENV", "ENV", "CLAUDE_ENV_FILE", "CLAUDE_CODE_SHELL_PREFIX"])
        func resolve(_ path: String) -> URL {
            path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL : directory.appendingPathComponent(path).standardizedFileURL
        }
        mutating func config(_ root: URL) throws {
            let path = root.standardizedFileURL.path
            guard configs.insert(path).inserted else { return }
            guard configs.count <= 32 else { throw ProxySettingsGuardError.unavailable(path) }
            for name in ["settings.json", "settings.local.json", "cowork_settings.json", ".claude.json", ".claude-custom-oauth.json", "remote-settings.json"] {
                try document(root.appendingPathComponent(name), managed: name == "remote-settings.json")
            }
        }
        static func missing(_ error: NSError) -> Bool {
            (error.domain == NSPOSIXErrorDomain && error.code == 2) ||
            (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
        }
        func children(_ directory: URL) throws -> [URL] {
            do { return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.path < $1.path } }
            catch let error as NSError where Self.missing(error) { return [] }
            catch { throw ProxySettingsGuardError.unavailable(directory.path) }
        }
        mutating func document(_ url: URL, managed: Bool = false, plist: Bool = false, required: Bool = false) throws {
            let key = url.standardizedFileURL.path + (managed ? "|managed" : "")
            guard visited.insert(key).inserted else { return }
            guard visited.count <= 256 else { throw ProxySettingsGuardError.unavailable(url.path) }
            let data: Data
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    let target = url.resolvingSymlinksInPath()
                    guard target.path != url.path else { throw ProxySettingsGuardError.unavailable(url.path) }
                    try document(target, managed: managed, plist: plist, required: true)
                    return
                }
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber, size.intValue <= 8 * 1024 * 1024 else {
                    throw ProxySettingsGuardError.unavailable(url.path)
                }
                data = try Data(contentsOf: url)
            } catch let error as ProxySettingsGuardError { throw error }
            catch let error as NSError where Self.missing(error) && !required { return }
            catch { throw ProxySettingsGuardError.unavailable(url.path) }
            do {
                let object = try plist ? PropertyListSerialization.propertyList(from: data, options: [], format: nil) : JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
                try inspect(object, source: url.path, managed: managed)
            } catch let error as ProxySettingsGuardError { throw error }
            catch { throw ProxySettingsGuardError.unavailable(url.path) }
        }
        func inspectEnvironment(_ env: [String: Any], source: String) throws {
            for (key, raw) in env {
                let name = key.uppercased()
                guard proxyNames.contains(name) || name == "NO_PROXY" || scriptNames.contains(name) || name == "ZDOTDIR" else { continue }
                let conflict = ProxySettingsGuardError.conflict(source: source, key: "env." + key)
                guard key == name || key == name.lowercased(), let value = raw as? String else { throw conflict }
                if proxyNames.contains(name) {
                    guard (try? ExecutionProxy.validatedEndpoint(value)) == endpoint else { throw conflict }
                } else if name == "NO_PROXY" {
                    guard value == ExecutionProxy.loopbackBypass else { throw conflict }
                } else if name == "ZDOTDIR" {
                    // Only the application's own isolated shell directory may be
                    // carried through a child. Settings cannot replace it.
                    guard value.isEmpty || value == environment["ZDOTDIR"] &&
                          URL(fileURLWithPath: value).lastPathComponent.hasPrefix("ccam-proxy-shell-") else { throw conflict }
                } else if !value.isEmpty { throw conflict }
            }
        }
        mutating func inspect(_ object: Any, source: String, managed: Bool) throws {
            guard let dictionary = object as? [String: Any] else { throw ProxySettingsGuardError.unavailable(source) }
            if let raw = dictionary["env"] {
                guard let env = raw as? [String: Any] else { throw ProxySettingsGuardError.unavailable(source) }
                try inspectEnvironment(env, source: source)
                if let config = env["CLAUDE_CONFIG_DIR"] {
                    guard let path = config as? String, !path.isEmpty else { throw ProxySettingsGuardError.unavailable(source) }
                    try self.config(resolve(path))
                }
            }
            if managed {
                if let helper = dictionary["policyHelper"] as? [String: Any],
                   (helper["path"] as? String)?.isEmpty == false || (helper["script"] as? String)?.isEmpty == false {
                    throw ProxySettingsGuardError.dynamicPolicy(source)
                }
                if let variants = dictionary["policyHelpers"] as? [String: Any] {
                    if let mac = variants["macos"] as? [String: Any] {
                        if (mac["path"] as? String)?.isEmpty == false || (mac["script"] as? String)?.isEmpty == false { throw ProxySettingsGuardError.dynamicPolicy(source) }
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
                    else { index += 1; guard index < arguments.count else { throw ProxySettingsGuardError.unavailable("命令设置") }; value = arguments[index] }
                    let managed = parts[0] == "--managed-settings"
                    if value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                        guard value.utf8.count <= 8 * 1024 * 1024,
                              let object = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.json5Allowed]) else { throw ProxySettingsGuardError.unavailable("命令设置") }
                        try inspect(object, source: "命令设置", managed: managed)
                    } else { try document(resolve(value), managed: managed, required: true) }
                }
                index += 1
            }
        }
    }
}
