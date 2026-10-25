import Foundation

struct BrowserOpenPlan: Equatable {
    let executable: String
    let arguments: [String]
}

enum BrowserRouting {
    static func isLoginLink(_ url: URL) -> Bool {
        let components = Set(url.pathComponents.map { $0.lowercased() })
        if !components.isDisjoint(with: ["oauth", "oauth2", "authorize", "authorization", "login", "signin", "sign-in", "auth", "callback"]) { return true }
        let keys = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { $0.name.lowercased() } ?? [])
        return keys.contains("client_id") && (keys.contains("redirect_uri") || keys.contains("response_type"))
    }
    static func plan(url: URL, account: String?, store: BrowserLockStore) throws -> BrowserOpenPlan {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { throw AppError.message("无法打开此登录链接。") }
        let name = account?.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == nil || name == "" {
            guard store.locks.isEmpty else { throw AppError.message("请从具体账号的“登录”按钮打开，以应用登录锁。") }
        }
        if let name, let binding = store.binding(account: name) {
            try BrowserLockStore.validate(profile: binding.profile)
            let p = binding.profile
            return BrowserOpenPlan(executable: "/usr/bin/open", arguments: ["-n", "-a", p.appPath, "--args", "--user-data-dir=" + p.userDataDirectory, "--profile-directory=" + p.profileDirectory, "--new-window", url.absoluteString])
        }
        return BrowserOpenPlan(executable: "/usr/bin/open", arguments: [url.absoluteString])
    }
    static func open(url: URL, account: String?, store: BrowserLockStore? = nil) throws {
        let selectedStore = try store ?? BrowserLockStore()
        let request = try plan(url: url, account: account, store: selectedStore)
        let process = Process(); process.executableURL = URL(fileURLWithPath: request.executable); process.arguments = request.arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppError.message("登录浏览器未能打开，请检查锁定配置。") }
    }
    static func handleHelperInvocation() -> Int32? {
        guard URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "CCAMBrowser" else { return nil }
        do {
            guard CommandLine.arguments.count == 2, let url = URL(string: CommandLine.arguments[1]) else { throw AppError.message("登录链接无效。") }
            // CCAM sets this for every selected account, including expired-account batches.
            let account = ProcessInfo.processInfo.environment["CCAM_PROFILE"]
            try open(url: url, account: account)
            return 0
        } catch {
            fputs((error.localizedDescription + "\n").cString(using: .utf8)!, stderr)
            return 1
        }
    }
    static func explicitAccount(_ args: [String]) -> String? {
        guard let command = args.first, ["login", "add", "logout", "remove", "rename"].contains(command), args.count > 1, !args[1].hasPrefix("-") else { return nil }
        return args[1]
    }
    static func preflight(_ args: [String]) throws {
        guard args.first == "login" || (args.first == "add" && !args.contains("--api") && !args.contains("--no-login")) else { return }
        let store = try BrowserLockStore()
        if let name = explicitAccount(args), let lock = store.binding(account: name) { try BrowserLockStore.validate(profile: lock.profile) }
    }
}
