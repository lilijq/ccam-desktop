import Foundation

struct Account: Decodable {
    var name: String
    var email: String?
    var slot: Int?
    var shortcut: String?
    var dir: String?
    var groups: [String]?
    var plan: String?
    var isDefault: Bool?
    enum CodingKeys: String, CodingKey {
        case name, email, slot, shortcut, dir, groups, plan
        case isDefault = "default"
    }
}

struct UsageWindow {
    let label: String
    let used: Double
    let reset: String?
}

struct AccountUsage {
    let name: String
    let status: String
    let error: String?
    let windows: [UsageWindow]
    let raw: [String: Any]
    var source: String { raw["source"] as? String ?? "" }
    var measuredAt: String? { raw["at"] as? String }
    var cached: Bool { ["cache", "statusline", "limit"].contains(source) }
    var needsLogin: Bool { ["logged_out", "expired", "not_logged_in", "unauthorized"].contains(status) }
    var statusText: String {
        if status == "expired" { return "登录令牌已过期" }
        if needsLogin { return "需要登录" }
        if status == "error" || error?.isEmpty == false { return "额度暂不可用" }
        if status == "api" || status == "api_key" { return "API 账号" }
        if windows.isEmpty { return status.isEmpty ? "暂无额度数据" : status }
        return cached ? "缓存数据" : "已读取额度"
    }
    var errorSummary: String? {
        guard let error, !error.isEmpty else { return nil }
        if needsLogin { return status == "expired" ? "登录已过期，请重新登录" : "请完成账号登录" }
        let value = error.lowercased()
        if value.contains("timeout") || value.contains("timed out") || value.contains("deadline exceeded") || value.contains("no response (over") {
            return "额度查询超时，请刷新重试"
        }
        if value.contains("429") || value.contains("too many requests") || value.contains("retry after") {
            return "查询过于频繁，请稍后刷新"
        }
        if value.contains("connection refused") || value.contains("no such host") || value.contains("network is unreachable") {
            return "无法连接额度服务，请检查网络"
        }
        return "暂时无法获取额度，请稍后刷新"
    }
    static func parse(_ data: Data) throws -> [AccountUsage] {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if object is NSNull { return [] }
        guard let rows = object as? [[String: Any]] else {
            throw AppError.message("CCAM 额度数据不是预期的 JSON 数组。请在维护工具中检查版本。")
        }
        return rows.map { row in
            var windows: [UsageWindow] = []
            if let limits = row["limits"] as? [String: Any] {
                func add(_ label: String, _ value: [String: Any]?) {
                    guard let value, value["known"] as? Bool == true,
                          let number = value["percent"] as? NSNumber, number.doubleValue.isFinite else { return }
                    let reset = (value["resets_at"] as? String).flatMap { $0.hasPrefix("0001-") ? nil : $0 }
                    windows.append(UsageWindow(label: label, used: number.doubleValue, reset: reset))
                }
                add("5 小时额度", limits["five_hour"] as? [String: Any])
                add("每周额度", limits["weekly"] as? [String: Any])
                for scoped in limits["scoped"] as? [[String: Any]] ?? [] {
                    add((scoped["name"] as? String ?? "模型") + " · 每周", scoped["window"] as? [String: Any])
                }
            }
            // Keep unknown windows available in the raw-data view rather than inventing a percentage.
            return AccountUsage(name: row["name"] as? String ?? "", status: row["status"] as? String ?? "", error: row["error"] as? String, windows: windows, raw: row)
        }
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

struct CommandResult {
    let code: Int32
    let output: String
    var succeeded: Bool { code == 0 }
}

enum Shell {
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    static func display(_ args: [String]) -> String { (["ccam"] + args).map(quote).joined(separator: " ") }
    static func arguments(_ text: String) throws -> [String] {
        let data = Data(text.utf8)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String] else { throw AppError.message("附加参数必须是 JSON 字符串数组，例如 [\"--resume\"]。") }
        if value.contains(where: { $0.contains("\0") }) { throw AppError.message("参数不能包含空字符。") }
        return value
    }
}

final class CCAMClient {
    static var executable: String {
        let fm = FileManager.default
        let candidates = [ProcessInfo.processInfo.environment["CCAM_EXECUTABLE"], UserDefaults.standard.string(forKey: "ccamPath"), fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/ccam").path, "/opt/homebrew/bin/ccam", "/usr/local/bin/ccam"].compactMap { $0 }
        return candidates.first(where: { fm.isExecutableFile(atPath: $0) }) ?? candidates[0]
    }
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env["CLICOLOR"] = "0"
        // Claude's BROWSER is one executable path, never a shell command string.
        if let executable = Bundle.main.executableURL {
            let helper = executable.deletingLastPathComponent().appendingPathComponent("CCAMBrowser").path
            if FileManager.default.isExecutableFile(atPath: helper) { env["BROWSER"] = helper }
        }
        return env
    }
    static func read(_ args: [String], directory: String, timeout: TimeInterval = 45, completion: @escaping (CommandResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do {
                process.environment = try executionEnvironment(arguments: args)
                try process.run()
                let watchdog = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                let text = String(decoding: data, as: UTF8.self)
                let result = CommandResult(code: process.terminationStatus, output: text.isEmpty && process.terminationStatus != 0 ? "命令未完成，可能已超时。" : text)
                DispatchQueue.main.async { completion(result) }
            } catch {
                DispatchQueue.main.async { completion(CommandResult(code: -1, output: error.localizedDescription)) }
            }
        }
    }

    /// Local inventory/cache commands stay available offline. Every other command
    /// must resolve the current required proxy before a process can be launched.
    static func executionEnvironment(arguments: [String]) throws -> [String: String] {
        ExecutionProxy.requiresProxy(arguments: arguments)
            ? try ExecutionProxy.resolve(environment: environment).environment : environment
    }
}

struct FieldSpec {
    let label: String
    let key: String
    let placeholder: String
    var required = false
    var initial = ""
}

struct ActionSpec {
    let title: String
    let detail: String
    let command: [String]
    var fields: [FieldSpec] = []
    var dryRun = false
    var launchesClaude = false
    var build: (([String: String]) throws -> [String])? = nil
    var options: [(String, [String])] = []
    var stdinKey: String? = nil
    func arguments(_ values: [String: String]) throws -> [String] {
        for field in fields where field.required {
            if values[field.key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw AppError.message("请填写“\(field.label)”。") }
        }
        var result = try build?(values) ?? command
        if let extra = values["extra"], !extra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result += try Shell.arguments(extra) }
        guard !result.contains(where: { $0.contains("\0") }) else { throw AppError.message("参数不能包含空字符。") }
        return result
    }
}

enum Catalog {
    static func field(_ label: String, _ key: String, _ hint: String, required: Bool = true) -> FieldSpec { FieldSpec(label: label, key: key, placeholder: hint, required: required) }
    static func positional(_ title: String, _ detail: String, _ command: [String], _ fields: [FieldSpec], dry: Bool = false, launch: Bool = false) -> ActionSpec {
        ActionSpec(title: title, detail: detail, command: command, fields: fields, dryRun: dry, launchesClaude: launch, build: { values in command + fields.compactMap { let v = values[$0.key, default: ""]; return v.isEmpty ? nil : v } })
    }
    static let account = field("账号名称", "account", "例如 work")
    static let group = field("共享组", "group", "例如 default")
    static let folder = field("文件夹路径", "folder", "/Users/你的名字/Projects/example")
    static var groups: [ActionSpec] { [
        ActionSpec(title: "创建共享组", detail: "选择共享内容与成员，CCAM 会展示迁移计划并询问如何处理冲突。", command: ["group", "add"], fields: [group, field("共享项目", "items", "mcp,settings,memory,extensions,history"), field("成员账号", "members", "work,personal", required: false)], dryRun: true, build: { v in
            var a = ["group", "add", v["group"]!, "--items", v["items"]!]
            if let m = v["members"], !m.isEmpty { a += ["--members", m] }; return a
        }),
        ActionSpec(title: "编辑共享内容", detail: "设置完整共享列表。取消共享的内容会按 CCAM 的规则保留副本。", command: ["group", "set"], fields: [group, field("共享项目", "items", "mcp,settings,memory,extensions,history")], dryRun: true, build: { ["group", "set", $0["group"]!, "--items", $0["items"]!] }),
        positional("加入共享组", "将一个账号加入共享组；冲突时由 CCAM 提示选择。", ["group", "join"], [group, account], dry: true),
        positional("退出共享组", "退出后保留所共享内容的副本。", ["group", "leave"], [group, account], dry: true),
        positional("查看共享组", "查看共享项目、成员、文件夹与 MCP 服务。", ["group", "show"], [group]),
        positional("重命名共享组", "更改共享组名称。", ["group", "rename"], [group, field("新名称", "new", "team")]),
        positional("移除共享组", "有成员时需在附加参数中填写 [\"--leave\"]；执行前可预览计划。", ["group", "remove"], [group], dry: true)
    ] }
    static var mcp: [ActionSpec] { [
        ActionSpec(title: "添加远程 MCP", detail: "连接 HTTP / SSE MCP 服务。授权头可通过附加参数设置。", command: ["mcp", "add"], fields: [field("服务名称", "name", "context7"), field("服务 URL", "url", "https://mcp.example.com/mcp"), field("共享组", "group", "default", required: false)], build: { v in
            guard let url = URL(string: v["url"]!), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw AppError.message("请输入有效的 HTTP 或 HTTPS URL。") }
            var a = ["mcp", "add", v["name"]!, "--url", v["url"]!]; if let g = v["group"], !g.isEmpty { a += ["--group", g] }; return a
        }),
        ActionSpec(title: "通过 JSON 添加 MCP", detail: "支持 stdio 命令、环境变量、HTTP 地址和授权头等完整 MCP 配置。", command: ["mcp", "add-json"], fields: [field("服务名称", "name", "filesystem"), field("JSON 配置", "json", "{\"command\":\"npx\",\"args\":[\"…\"]}"), field("共享组", "group", "default", required: false)], build: { v in
            guard let _ = try JSONSerialization.jsonObject(with: Data(v["json"]!.utf8)) as? [String: Any] else { throw AppError.message("MCP 配置必须是 JSON 对象。") }
            var a = ["mcp", "add-json", v["name"]!, v["json"]!]; if let g = v["group"], !g.isEmpty { a += ["--group", g] }; return a
        }),
        positional("导入账号的 MCP", "将仅属于此账号的 MCP 服务导入它的共享组。", ["mcp", "import"], [account, field("服务名称", "name", "留空导入全部", required: false)]),
        ActionSpec(title: "移除 MCP", detail: "从指定共享组移除服务配置。", command: ["mcp", "remove"], fields: [field("服务名称", "name", "filesystem"), field("共享组", "group", "default", required: false)], build: { v in var a = ["mcp", "remove", v["name"]!]; if let g = v["group"], !g.isEmpty { a += ["--group", g] }; return a })
    ] }
    static var maintenance: [ActionSpec] { [
        ActionSpec(title: "健康检查", detail: "检查账号目录、共享链接、登录状态和 Claude Code 版本。", command: ["doctor"]),
        ActionSpec(title: "修复配置", detail: "由 CCAM 修复可安全修复的问题，修改前会备份。", command: ["doctor", "--fix"], dryRun: true),
        ActionSpec(title: "检查更新", detail: "检查是否有新的 CCAM 版本。", command: ["update", "--check"]),
        ActionSpec(title: "更新 CCAM", detail: "下载并校验新版本，替换 CCAM 可执行文件。", command: ["update"], dryRun: true),
        positional("导入已有账号", "原位注册配置目录。留空时由 CCAM 搜索现有目录。", ["import"], [field("配置目录", "folder", "例如 /Users/你的名字/.claude", required: false)]),
        positional("迁移已有设置", "复制设置到共享组；登录凭据不会复制。附加参数可选择 --history 等项目。", ["migrate"], [field("源目录", "folder", "留空使用 ~/.claude", required: false)], dry: true),
        ActionSpec(title: "安装额度状态栏", detail: "在 Claude Code 状态栏中显示账号与用量，保留已有状态栏。", command: ["statusline", "install"]),
        ActionSpec(title: "修复快捷命令", detail: "重新创建所有账号已配置的快捷命令链接。", command: ["shims", "install"]),
        ActionSpec(title: "刷新过期登录", detail: "为过期账号重新登录，可能需要浏览器授权。", command: ["login", "--expired"]),
        ActionSpec(title: "重新读取额度", detail: "绕过额度缓存；不会自动刷新登录令牌。", command: ["usage", "--no-cache"]),
        ActionSpec(title: "刷新额度令牌", detail: "显式刷新非运行账号的过期令牌，可能每个账号耗时 30 秒。", command: ["usage", "--refresh"])
    ] }
}
