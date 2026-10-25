import Foundation

@main struct BrowserRoutingTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func rejects(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); check(false, message) }
        catch { check(true, message) }
    }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ccam-routing-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Applications with spaces/Chrome & Test.app", isDirectory: true)
        let dataDirectory = root.appendingPathComponent("Browser Data & Work", isDirectory: true)
        let profileDirectory = "Profile 4 & Tasks"
        let profileFolder = dataDirectory.appendingPathComponent(profileDirectory, isDirectory: true)
        let infoFile = app.appendingPathComponent("Contents/Info.plist")
        let stateFile = dataDirectory.appendingPathComponent("Local State")
        try fm.createDirectory(at: infoFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: profileFolder, withIntermediateDirectories: true)
        func writeIdentity(_ bundleID: String) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID, "CFBundleName": "Test Chrome"], format: .xml, options: 0)
            try data.write(to: infoFile)
        }
        func writeCache(_ includeProfile: Bool) throws {
            let entries: [String: [String: String]] = includeProfile ? [profileDirectory: ["name": "Work identity", "user_name": "fixture@example.invalid"]] : [:]
            try JSONSerialization.data(withJSONObject: ["profile": ["info_cache": entries]]).write(to: stateFile)
        }
        try writeIdentity("com.google.Chrome"); try writeCache(true)
        let profile = BrowserProfile(id: "isolated-chrome-profile", browserName: "Google Chrome", bundleID: "com.google.Chrome", appPath: app.path, userDataDirectory: dataDirectory.path, profileDirectory: profileDirectory, displayName: "Work identity", identityHint: "fixture@example.invalid")
        let store = try BrowserLockStore(url: root.appendingPathComponent("Store/browser-locks.json"))
        try store.lock(account: "locked", profile: profile)
        let emptyStore = try BrowserLockStore(url: root.appendingPathComponent("Empty Store/browser-locks.json"))
        let url = URL(string: "https://example.invalid/oauth/authorize?state=one%20two&scope=openid%20email&label=two words")!
        let beforeInfo = try Data(contentsOf: infoFile), beforeState = try Data(contentsOf: stateFile)
        let plan = try BrowserRouting.plan(url: url, account: "locked", store: store)
        let expectedArguments = ["-n", "-a", app.path, "--args", "--user-data-dir=" + dataDirectory.path, "--profile-directory=" + profileDirectory, "--new-window", url.absoluteString]
        check(plan.executable == "/usr/bin/open", "locked launch uses the known macOS opener")
        check(plan.arguments == expectedArguments, "locked account selects the exact app, data root, profile, new window and URL")
        check(plan.arguments.count == 8, "spaces and ampersands stay within argument boundaries")
        check(plan.arguments[2] == app.path && plan.arguments[4].contains("Browser Data & Work"), "application and user-data paths are passed verbatim")
        check(plan.arguments[5] == "--profile-directory=Profile 4 & Tasks", "profile name is one exact argument")
        check(plan.arguments.last == url.absoluteString && plan.arguments.last?.contains("&scope=") == true && plan.arguments.last?.contains("two%20words") == true, "OAuth query delimiters and escaped spaces are preserved")
        check(try BrowserRouting.plan(url: url, account: " \nlocked\t ", store: store) == plan, "account whitespace does not change the selected lock")
        let reopened = try BrowserLockStore(url: store.url)
        check(try BrowserRouting.plan(url: url, account: "locked", store: reopened) == plan, "persisted binding produces the same exact route")
        check(try Data(contentsOf: infoFile) == beforeInfo && Data(contentsOf: stateFile) == beforeState, "planning does not alter browser metadata")

        let defaultPlan = BrowserOpenPlan(executable: "/usr/bin/open", arguments: [url.absoluteString])
        check(try BrowserRouting.plan(url: url, account: "unlocked", store: store) == defaultPlan, "explicit unbound account keeps its normal default-browser route")
        check(try BrowserRouting.plan(url: url, account: nil, store: emptyStore) == defaultPlan, "unidentified account uses default only when there are no locks")
        check(try BrowserRouting.plan(url: url, account: "", store: emptyStore) == defaultPlan, "empty account is safe when no locks exist")
        check(try BrowserRouting.plan(url: url, account: "any-account", store: emptyStore) == defaultPlan, "unlocked accounts do not gain profile overrides")
        for identity: String? in [nil, "", " \n\t "] {
            rejects("unknown account identity fails closed while any login lock exists") {
                _ = try BrowserRouting.plan(url: url, account: identity, store: store)
            }
        }

        try fm.removeItem(at: profileFolder)
        rejects("missing locked profile fails instead of falling back") { _ = try BrowserRouting.plan(url: url, account: "locked", store: store) }
        check(store.binding(account: "locked") != nil, "stale binding remains recorded")
        try fm.createDirectory(at: profileFolder, withIntermediateDirectories: true)
        try writeCache(false)
        rejects("profile absent from Local State fails instead of falling back") { _ = try BrowserRouting.plan(url: url, account: "locked", store: store) }
        try writeCache(true)
        try writeIdentity("com.example.replaced-browser")
        rejects("changed application identity fails instead of falling back") { _ = try BrowserRouting.plan(url: url, account: "locked", store: store) }
        try writeIdentity("com.google.Chrome")
        check(try BrowserRouting.plan(url: url, account: "locked", store: store) == plan, "repairing the selected browser restores the original exact route")

        for invalid in ["javascript:alert(1)", "file:///tmp/private-login.html", "https://user:password@example.invalid/login", "https://user@example.invalid/login", "data:text/html,login", "ftp://example.invalid/login"] {
            guard let badURL = URL(string: invalid) else { check(false, "invalid-URL fixture could not be constructed"); continue }
            rejects("unsafe URL scheme or embedded credentials are rejected: \(badURL.scheme ?? "none")") {
                _ = try BrowserRouting.plan(url: badURL, account: "locked", store: store)
            }
            rejects("unsafe URLs are rejected even without a browser lock") {
                _ = try BrowserRouting.plan(url: badURL, account: nil, store: emptyStore)
            }
        }
        let localURL = URL(string: "http://127.0.0.1:8080/authorize?state=local")!
        check(try BrowserRouting.plan(url: localURL, account: nil, store: emptyStore).arguments == [localURL.absoluteString], "HTTP local authorization links remain supported")

        let cases: [([String], String?)] = [
            ([], nil), (["login"], nil), (["login", "work"], "work"),
            (["login", "--expired"], nil), (["login", "--expired", "work"], nil),
            (["login", "--unknown-option", "work"], nil), (["login", "--", "work"], nil),
            (["--dry-run", "login", "work"], nil), (["login", "-h"], nil),
            (["add", "new-account"], "new-account"), (["add", "new-account", "--api"], "new-account"),
            (["add", "--api", "env:TEST_KEY"], nil), (["add", "--no-login"], nil),
            (["logout", "work"], "work"), (["remove", "work"], "work"),
            (["rename", "old", "new"], "old"), (["rename", "--help"], nil),
            (["run", "work"], nil), (["usage", "--refresh"], nil),
            (["group", "remove", "work"], nil), (["work"], nil)
        ]
        for (arguments, account) in cases {
            check(BrowserRouting.explicitAccount(arguments) == account, "explicitAccount handles positional identities without treating flags as accounts: \(arguments)")
        }
        check(BrowserRouting.isLoginLink(URL(string: "https://claude.ai/oauth/authorize")!), "Claude authorization links use the account lock")
        check(BrowserRouting.isLoginLink(URL(string: "https://example.invalid/start?client_id=test&response_type=code")!), "OAuth query routes use the account lock")
        check(!BrowserRouting.isLoginLink(URL(string: "https://docs.example.invalid/authentication/guide")!), "ordinary documentation links remain usable")
        check(!BrowserRouting.isLoginLink(URL(string: "http://localhost:3000/preview")!), "local project preview links remain usable")
        print("PASS: \(checks) browser routing and account parsing checks; no browser launched")
    }
}
