import Foundation
import Darwin

/// Each interactive launch has a private, single-use event channel. Only CCAM's
/// structured StopFailure hook can populate it; terminal text is never inspected.
struct PoolLaunch {
    let args: [String]
    let environment: [String: String]
    let eventDirectory: URL
    let token: String
    let directory: String
    let createdAt: Date
    let ticket: String?
    let automaticallyContinuesTask: Bool
    let helperExecutable: String
    var eventURL: URL { eventDirectory.appendingPathComponent("limit.json") }
}

struct PoolLimitEvent: Codable {
    let token: String
    let account: String
    let sessionID: String
    let transcript: String
    let directory: String
    let ticket: String
    let claudePID: Int32
    let relay: String
    let at: Date
    var limitAt: Date? = nil
}

struct PoolChatIdentity: Codable {
    let token: String
    let account: String
    let sessionID: String
    let transcript: String
    let directory: String
    let claudePID: Int32
    let at: Date
}

struct ChatTerminalTarget {
    let directory: String
    let sessionID: String?
    let account: String?
    let ticket: String?
    var canResume = true
}

enum GlobalPool {
    static let helperFlag = "--desktop-quota-hook"
    static let chatHelperFlag = "--desktop-chat-hook"
    static let maximumWait: TimeInterval = 5 * 60 * 60
    static let retryInterval: TimeInterval = 60
    // CCAM's launcher explicitly warns that these credentials override the
    // selected account. A custom API endpoint must also be removed before any
    // account token can be used. This changes child environments only.
    static let overrideKeys = ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"]
    static let continuationPrompt = "上一个账号的额度已耗尽，应用已切换到可用账号并恢复这段对话。请从原任务的中断处自动继续，直到完成原任务。先核对对话中已有的工具结果、当前文件和实际执行状态，保留已完成的工作，不从头重做，不重复已经执行的提交、发送、部署、付款或其他有副作用的步骤。若上一步结果不确定，先查证再继续。遵守原任务范围和权限要求，不跳过确认或安全限制；只有确实需要用户信息或授权时才暂停询问。"

    /// `next --auto` explicitly chooses from the global pool, bypassing folder
    /// bindings and the global default. All account organizations are eligible.
    static func prepare(directory: String, continueLast: Bool, ticket: String? = nil, automaticallyContinueTask: Bool = false, initialPrompt: String? = nil,
                        helperExecutable: String = CommandLine.arguments[0],
                        ccamExecutable: String = CCAMClient.executable,
                        baseEnvironment: [String: String] = CCAMClient.environment) throws -> PoolLaunch {
        let recovery = automaticallyContinueTask ? try recoveryArguments(ticket: ticket, directory: directory, environment: baseEnvironment) : []
        let token = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccam-desktop-pool-" + token, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let helperPath = URL(fileURLWithPath: helperExecutable).standardizedFileURL.path
        let settings: [String: Any] = ["hooks": ["StopFailure": [["matcher": "rate_limit", "hooks": [["type": "command", "command": Shell.quote(helperPath) + " " + helperFlag, "timeout": 15]]]]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), as: UTF8.self)
        var args = ["next", "--auto", "--cross-org", "--max-usage", "100", "--strategy", "headroom"]
        if continueLast || ticket != nil { args.append("--continue") }
        if let ticket { args += ["--note", ticket] }
        args += ["--", "--settings", json]
        args += recovery
        if !automaticallyContinueTask, let initialPrompt, !initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The second separator belongs to Claude and preserves even prompts
            // beginning with '-' as one literal positional argument.
            args += ["--", initialPrompt]
        }
        var env = baseEnvironment
        for key in overrideKeys { env.removeValue(forKey: key) }
        env["CCAM_DESKTOP_EVENT_DIR"] = root.path
        env["CCAM_DESKTOP_TOKEN"] = token
        env["CCAM_DESKTOP_CCAM"] = ccamExecutable
        env["CCAM_DESKTOP_CWD"] = directory
        return PoolLaunch(args: args, environment: env, eventDirectory: root, token: token, directory: directory, createdAt: Date(), ticket: ticket, automaticallyContinuesTask: automaticallyContinueTask, helperExecutable: helperPath)
    }

    /// The initial continuation prompt is an explicit quota-recovery operation,
    /// never a side effect of opening a project or manually restoring history.
    /// CCAM will still validate and consume the same exact native ticket.
    static func recoveryArguments(ticket: String?, directory: String, environment: [String: String], now: Date = Date()) throws -> [String] {
        guard let ticket, let data = try? Data(contentsOf: URL(fileURLWithPath: ticket)), data.count <= 1_048_576,
              let note = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              note["reason"] as? String == "limit", let account = note["account"] as? String,
              account.range(of: "^[a-z0-9][a-z0-9_-]{0,31}$", options: .regularExpression) != nil,
              let sessionID = note["session_id"] as? String, !sessionID.isEmpty,
              let cwd = note["cwd"] as? String, sameDirectory(cwd, directory),
              let timestamp = note["at"] as? String, let at = date(timestamp), at <= now.addingTimeInterval(1), now.timeIntervalSince(at) <= 12 * 3600,
              let transcript = note["transcript_path"] as? String, FileManager.default.fileExists(atPath: transcript) else {
            throw AppError.message("自动续做所需的额度中断记录已失效。原对话保留，可从项目手动恢复。")
        }
        let expected = stateDirectory(environment: environment).appendingPathComponent("handoff").appendingPathComponent(account).appendingPathComponent(safeSessionName(sessionID) + ".json")
        guard expected.standardizedFileURL.path == URL(fileURLWithPath: ticket).standardizedFileURL.path else {
            throw AppError.message("自动续做记录不属于当前账号池。")
        }
        let mode = permissionMode(transcript: transcript)
        let allowed = ["default", "plan", "acceptEdits", "manual", "dontAsk", "auto"]
        // Never introduce bypass flags on an automatically resumed turn. Unknown
        // or bypass modes return to ordinary permission checks.
        return ["--permission-mode", allowed.contains(mode) ? mode : "default", "--", continuationPrompt]
    }

    /// Mirrors CCAM's native transcript.PermissionMode selection: the latest
    /// explicit mode row or main-thread human prompt, never a tool result,
    /// assistant message, subagent or quoted string from the transcript.
    static func permissionMode(transcript: String) -> String {
        guard let file = FileHandle(forReadingAtPath: transcript) else { return "" }
        defer { try? file.close() }
        do {
            let size = try file.seekToEnd()
            let start = size > 8 * 1024 * 1024 ? size - 8 * 1024 * 1024 : 0
            try file.seek(toOffset: start)
            let data = try file.readToEnd() ?? Data()
            for line in data.split(separator: 10).reversed() {
                guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let mode = row["permissionMode"] as? String, !mode.isEmpty else { continue }
                if row["type"] as? String == "permission-mode" { return mode }
                guard row["type"] as? String == "user", row["isMeta"] as? Bool != true, row["isSidechain"] as? Bool != true,
                      (row["origin"] as? [String: Any])?["kind"] as? String == nil || (row["origin"] as? [String: Any])?["kind"] as? String == "human",
                      let message = row["message"] as? [String: Any] else { continue }
                if message["content"] is String { return mode }
                if let content = message["content"] as? [[String: Any]], content.contains(where: { $0["type"] as? String != "tool_result" }) { return mode }
            }
        } catch { return "" }
        return ""
    }

    static func clean(_ launch: PoolLaunch) { try? FileManager.default.removeItem(at: launch.eventDirectory) }

    /// Print turns preserve the owning account until a real quota handoff. Native
    /// `next --note` supplies the exact transcript and forks only when necessary.
    static func prepareChat(directory: String, account: String?, sessionID: String?, newSessionID: String?, ticket: String?, permissionMode: String,
                            helperExecutable: String = CommandLine.arguments[0], ccamExecutable: String = CCAMClient.executable,
                            baseEnvironment: [String: String] = CCAMClient.environment) throws -> PoolLaunch {
        if let ticket { _ = try recoveryArguments(ticket: ticket, directory: directory, environment: baseEnvironment) }
        if let account, account.range(of: "^[a-z0-9][a-z0-9_-]{0,31}$", options: .regularExpression) == nil { throw AppError.message("会话账号无效。") }
        if let sessionID, UUID(uuidString: sessionID) == nil { throw AppError.message("无法恢复这个会话标识。") }
        let base = try prepare(directory: directory, continueLast: ticket != nil, ticket: ticket,
                               helperExecutable: helperExecutable, ccamExecutable: ccamExecutable, baseEnvironment: baseEnvironment)
        let hook: [String: Any] = ["type": "command", "command": Shell.quote(base.helperExecutable) + " " + chatHelperFlag, "timeout": 15]
        let settings: [String: Any] = ["hooks": ["SessionStart": [["hooks": [hook]]], "StopFailure": [["matcher": "rate_limit", "hooks": [hook]]]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: settings), as: UTF8.self)
        var prefix = Array(base.args.prefix { $0 != "--" })
        if ticket == nil, let account { prefix = ["run", account] }
        var claude = ["--print", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--permission-prompts", "none",
                      "--permission-mode", ["plan", "acceptEdits"].contains(permissionMode) ? permissionMode : "manual", "--settings", json]
        if ticket == nil {
            if let sessionID { claude += ["--resume", sessionID] }
            else if let newSessionID, UUID(uuidString: newSessionID) != nil { claude += ["--session-id", newSessionID] }
        }
        var env = base.environment; env["CCAM_DESKTOP_CHAT"] = "1"
        return PoolLaunch(args: prefix + ["--"] + claude, environment: env, eventDirectory: base.eventDirectory, token: base.token,
                          directory: directory, createdAt: base.createdAt, ticket: ticket, automaticallyContinuesTask: ticket != nil, helperExecutable: base.helperExecutable)
    }

    static func prepareChatTerminal(target: ChatTerminalTarget) throws -> PoolLaunch {
        guard target.canResume else { throw AppError.message("这段对话的身份未能验证，不能安全转到终端。请新建对话。") }
        if let ticket = target.ticket { return try prepare(directory: target.directory, continueLast: true, ticket: ticket) }
        let base = try prepare(directory: target.directory, continueLast: false)
        guard let sessionID = target.sessionID else { return base }
        guard UUID(uuidString: sessionID) != nil, let account = target.account,
              account.range(of: "^[a-z0-9][a-z0-9_-]{0,31}$", options: .regularExpression) != nil else {
            clean(base); throw AppError.message("原会话的账号身份不完整，无法安全接续。")
        }
        let claude = Array(base.args.drop(while: { $0 != "--" }).dropFirst())
        return PoolLaunch(args: ["run", account, "--", "--resume", sessionID] + claude, environment: base.environment,
                          eventDirectory: base.eventDirectory, token: base.token, directory: base.directory, createdAt: base.createdAt,
                          ticket: nil, automaticallyContinuesTask: false, helperExecutable: base.helperExecutable)
    }

    static func readChatIdentity(_ launch: PoolLaunch, rootPID: Int32) -> PoolChatIdentity? {
        guard let data = try? Data(contentsOf: launch.eventDirectory.appendingPathComponent("identity.json")), data.count < 1_048_576,
              let identity = try? JSONDecoder().decode(PoolChatIdentity.self, from: data), identity.token == launch.token,
              identity.at >= launch.createdAt, identity.claudePID == rootPID,
              sameDirectory(identity.directory, launch.directory), UUID(uuidString: identity.sessionID) != nil,
              identity.account.range(of: "^[a-z0-9][a-z0-9_-]{0,31}$", options: .regularExpression) != nil else { return nil }
        return identity
    }

    static func preflightArguments(_ launch: PoolLaunch) -> [String] {
        var args = launch.args
        let index = args.firstIndex(of: "--") ?? args.endIndex
        args.insert("--dry-run", at: index)
        return args
    }

    static func stateDirectory(environment: [String: String]) -> URL {
        if let root = environment["CCAM_HOME"], !root.isEmpty { return URL(fileURLWithPath: root).appendingPathComponent("state") }
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let base = environment["XDG_STATE_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? (home + "/.local/state")
        return URL(fileURLWithPath: base).appendingPathComponent("ccam")
    }

    static func safeSessionName(_ value: String) -> String {
        if value.isEmpty { return "unknown" }
        return String(value.utf8.map { byte -> Character in
            let valid = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45 || byte == 95
            return valid ? Character(UnicodeScalar(byte)) : "_"
        })
    }

    static func sameDirectory(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.resolvingSymlinksInPath().path == URL(fileURLWithPath: b).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func date(_ value: String) -> Date? {
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// A native CCAM ticket must agree with the actual hook input. Reused, old,
    /// unrelated-session and non-limit notes never initiate a switch.
    static func validatedEvent(input: [String: Any], environment env: [String: String], started: Date,
                               now: Date = Date()) -> PoolLimitEvent? {
        guard input["error"] as? String == "rate_limit", (input["agent_id"] as? String ?? "").isEmpty,
              env["CLAUDE_CODE_SESSION_ATTENDED"] != "0", !(env["CLAUDE_CODE_ENTRYPOINT"] ?? "").hasPrefix("sdk-"),
              let account = env["CCAM_PROFILE"], account.range(of: "^[a-z0-9][a-z0-9_-]{0,31}$", options: .regularExpression) != nil,
              let sessionID = input["session_id"] as? String, !sessionID.isEmpty,
              let transcript = input["transcript_path"] as? String, FileManager.default.fileExists(atPath: transcript),
              let expectedCwd = env["CCAM_DESKTOP_CWD"],
              let cwd = env["CLAUDE_PROJECT_DIR"] ?? input["cwd"] as? String, sameDirectory(cwd, expectedCwd),
              let token = env["CCAM_DESKTOP_TOKEN"], UUID(uuidString: token) != nil,
              let pid = env["CLAUDE_PID"].flatMap(Int32.init), pid > 1 else { return nil }
        let path = stateDirectory(environment: env).appendingPathComponent("handoff").appendingPathComponent(account).appendingPathComponent(safeSessionName(sessionID) + ".json")
        guard let data = try? Data(contentsOf: path), data.count < 1_048_576,
              let note = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              note["reason"] as? String == "limit", note["account"] as? String == account,
              note["session_id"] as? String == sessionID,
              note["transcript_path"] as? String == transcript,
              let noteCwd = note["cwd"] as? String, sameDirectory(noteCwd, expectedCwd),
              let atString = note["at"] as? String, let at = date(atString),
              at >= started.addingTimeInterval(-0.1), at <= now.addingTimeInterval(1) else { return nil }
        return PoolLimitEvent(token: token, account: account, sessionID: sessionID, transcript: transcript, directory: expectedCwd,
                              ticket: path.path, claudePID: pid, relay: env["CCAM_RELAY"] ?? "", at: now,
                              limitAt: (note["limit_at"] as? String).flatMap(date) ?? at)
    }

    static func readEvent(_ launch: PoolLaunch) -> PoolLimitEvent? {
        guard let data = try? Data(contentsOf: launch.eventURL), data.count < 1_048_576,
              let event = try? JSONDecoder().decode(PoolLimitEvent.self, from: data),
              event.token == launch.token, event.at >= launch.createdAt,
              Date().timeIntervalSince(event.at) < 120,
              sameDirectory(event.directory, launch.directory) else { return nil }
        return event
    }

    /// CCAM normally execs Claude (same PID). If the user enabled CCAM's native
    /// relay, accept only its direct child, never a Claude launched in its shell.
    static func ownedProcess(event: PoolLimitEvent, rootPID: Int32) -> Bool {
        if event.claudePID == rootPID { return true }
        guard event.relay == "2:\(rootPID)" else { return false }
        let result = command(executable: "/bin/ps", args: ["-o", "ppid=", "-p", String(event.claudePID)], directory: "/", environment: ProcessInfo.processInfo.environment, timeout: 3)
        return result.code == 0 && Int32(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) == rootPID
    }

    /// Returns nil for the normal graphical entry point. No AppKit application
    /// should be created for this helper invocation.
    static func handleHelperInvocation() -> Int32? {
        let flag = CommandLine.arguments.dropFirst().first
        guard flag == helperFlag || flag == chatHelperFlag else { return nil }
        let env = ProcessInfo.processInfo.environment
        guard let ccam = env["CCAM_DESKTOP_CCAM"], let directory = env["CCAM_DESKTOP_EVENT_DIR"],
              let token = env["CCAM_DESKTOP_TOKEN"], UUID(uuidString: token) != nil,
              URL(fileURLWithPath: directory).lastPathComponent == "ccam-desktop-pool-" + token else { return 0 }
        let inputData = FileHandle.standardInput.readData(ofLength: 1_048_577)
        guard inputData.count <= 1_048_576, let input = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] else { return 0 }
        let chat = flag == chatHelperFlag
        if chat {
            guard env["CCAM_DESKTOP_CHAT"] == "1", (input["agent_id"] as? String ?? "").isEmpty,
                  let account = env["CCAM_PROFILE"], account.range(of: "^[a-z0-9][a-z0-9_-]{0,31}$", options: .regularExpression) != nil,
                  let sid = input["session_id"] as? String, UUID(uuidString: sid) != nil,
                  let cwd = env["CCAM_DESKTOP_CWD"], let actual = env["CLAUDE_PROJECT_DIR"] ?? input["cwd"] as? String, sameDirectory(cwd, actual),
                  let pid = env["CLAUDE_PID"].flatMap(Int32.init), pid > 1 else { return 0 }
            if input["hook_event_name"] as? String == "SessionStart" {
                let identity = PoolChatIdentity(token: token, account: account, sessionID: sid, transcript: input["transcript_path"] as? String ?? "", directory: cwd, claudePID: pid, at: Date())
                if let data = try? JSONEncoder().encode(identity) { try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("identity.json"), options: .atomic) }
                return 0
            }
            guard input["hook_event_name"] as? String == "StopFailure", input["error"] as? String == "rate_limit" else { return 0 }
        }
        let started = Date()
        var hookEnvironment = env
        if chat {
            // This app owns the print workflow and explicitly implements safe
            // continuation. Adapt only this native-hook child: the actual Claude
            // process remains print/unattended. Never replay --fallback input.
            hookEnvironment["CLAUDE_CODE_SESSION_ATTENDED"] = "1"
            hookEnvironment["CLAUDE_CODE_ENTRYPOINT"] = "ccam-desktop-chat-hook"
        }
        let result = command(executable: ccam, args: ["hook", "stop-failure"], directory: env["CCAM_DESKTOP_CWD"] ?? "/", environment: hookEnvironment, input: inputData, timeout: 10)
        if !chat, let output = result.output.data(using: .utf8) { FileHandle.standardOutput.write(output) }
        guard result.code == 0, let event = validatedEvent(input: input, environment: hookEnvironment, started: started),
              let data = try? JSONEncoder().encode(event) else { return 0 }
        let destination = URL(fileURLWithPath: directory).appendingPathComponent("limit.json")
        do {
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch { return 0 }
        return 0
    }

    /// Run only on a worker queue. Stdin and output are drained concurrently so
    /// hook JSON or diagnostic output cannot deadlock the process.
    static func command(executable: String, args: [String], directory: String, environment: [String: String],
                        input: Data? = nil, timeout: TimeInterval = 45) -> CommandResult {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory); process.environment = environment
        let output = Pipe(), stdin = Pipe()
        process.standardOutput = output; process.standardError = output
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        do {
            try process.run()
            if let input {
                DispatchQueue.global().async { try? stdin.fileHandleForWriting.write(contentsOf: input); try? stdin.fileHandleForWriting.close() }
            }
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } } } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); watchdog.cancel()
            return CommandResult(code: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        } catch { return CommandResult(code: -1, output: error.localizedDescription) }
    }
}
