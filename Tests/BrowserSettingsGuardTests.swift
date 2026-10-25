import Foundation

@main struct BrowserSettingsGuardTests {
    static var passed = 0
    struct Fixture {
        let root: URL
        let home: URL
        let cwd: URL
        let profile: URL
        let policy: URL
        var env: [String: String]
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ccam-browser-guard-" + UUID().uuidString)
            home = root.appendingPathComponent("home")
            cwd = root.appendingPathComponent("project/subdir")
            profile = root.appendingPathComponent("profile")
            policy = root.appendingPathComponent("policy")
            env = ["HOME": home.path, "CCAM_HOME": root.appendingPathComponent("ccam").path,
                   "BROWSER": root.appendingPathComponent("CCAMBrowser").path]
            for url in [home, cwd, profile, policy] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        }
        func write(_ file: URL, _ text: String) throws {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        func check(_ args: [String] = [], preferences: [URL] = [], directories: [String]? = nil) throws {
            try BrowserSettingsGuard.validate(directory: cwd.path, profileDirectories: directories ?? [profile.path], environment: env,
                                              claudeArguments: args, systemSettingsDirectory: policy, managedPreferenceFiles: preferences)
        }
    }
    static func expect(_ condition: Bool, _ label: String) {
        guard condition else { fputs("FAIL: \(label)\n", stderr); exit(1) }
        passed += 1
    }
    static func rejects(_ label: String, _ action: () throws -> Void) {
        do { try action(); expect(false, label) } catch { expect(true, label) }
    }
    static func fixture(_ action: (inout Fixture) throws -> Void) throws {
        var f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }; try action(&f)
    }
    static func main() throws {
        try fixture { f in
            try f.check(); expect(true, "missing settings allowed")
            try f.write(f.profile.appendingPathComponent("settings.json"), "{ // JSON5\n env: {EDITOR:'code'}, permissions: {deny:['Bash(rm:*)'],},}")
            let file = f.profile.appendingPathComponent("settings.json"), before = try Data(contentsOf: file)
            try f.check(); expect(try Data(contentsOf: file) == before, "ordinary settings preserved verbatim")
            try f.write(f.profile.appendingPathComponent(".credentials.json"), "not-json-secret")
            try f.write(f.profile.appendingPathComponent("Cookies"), "not-a-settings-file")
            try f.check(); expect(true, "credentials and cookies never inspected")
        }
        for name in ["settings.json", "settings.local.json", "cowork_settings.json", ".claude.json", ".claude-custom-oauth.json", "remote-settings.json"] {
            try fixture { f in
                try f.write(f.profile.appendingPathComponent(name), "{\"env\":{\"BROWSER\":\"/usr/bin/open\"}}")
                rejects("profile source \(name)") { try f.check() }
            }
        }
        try fixture { f in
            let object = ["env": ["BROWSER": f.env["BROWSER"]!]]
            try JSONSerialization.data(withJSONObject: object).write(to: f.profile.appendingPathComponent("settings.json"))
            try f.check(); expect(true, "exact helper may be repeated")
        }
        for name in ["settings.json", "settings.local.json"] {
            try fixture { f in
                try f.write(f.cwd.deletingLastPathComponent().appendingPathComponent(".claude/" + name), "{\"env\":{\"BROWSER\":\"browser\"}}")
                rejects("parent project \(name)") { try f.check() }
            }
        }
        try fixture { f in
            try f.write(f.policy.appendingPathComponent("managed-settings.json"), "{\"env\":{\"BROWSER\":\"open\"}}")
            rejects("managed base") { try f.check() }
        }
        try fixture { f in
            try f.write(f.policy.appendingPathComponent("managed-settings.d/20-browser.json"), "{\"env\":{\"BROWSER\":\"open\"}}")
            rejects("managed drop-in") { try f.check() }
        }
        try fixture { f in
            try f.write(f.policy.appendingPathComponent("managed-settings.d/.disabled.json"), "{\"env\":{\"BROWSER\":\"open\"}}")
            try f.check(); expect(true, "hidden managed drop-in ignored like Claude")
            let plist = f.root.appendingPathComponent("managed.plist")
            try PropertyListSerialization.data(fromPropertyList: ["env": ["BROWSER": "open"]], format: .binary, options: 0).write(to: plist)
            rejects("binary MDM plist") { try f.check(preferences: [plist]) }
        }
        try fixture { f in
            try f.write(f.root.appendingPathComponent("ccam/data/groups/default/settings.json"), "{\"env\":{\"BROWSER\":\"open\"}}")
            rejects("new add CCAM_HOME shared group") { try f.check(directories: []) }
        }
        try fixture { f in
            f.env.removeValue(forKey: "CCAM_HOME"); f.env["XDG_DATA_HOME"] = f.root.appendingPathComponent("xdg").path
            try f.write(f.root.appendingPathComponent("xdg/ccam/groups/team/settings.json"), "{\"env\":{\"BROWSER\":\"open\"}}")
            rejects("XDG shared groups") { try f.check() }
        }
        try fixture { f in
            f.env.removeValue(forKey: "CCAM_HOME"); f.env["XDG_DATA_HOME"] = "relative-is-ignored"
            try f.write(f.home.appendingPathComponent(".local/share/ccam/groups/team/settings.json"), "{\"env\":{\"BROWSER\":\"open\"}}")
            rejects("relative XDG uses standard group path") { try f.check() }
        }
        try fixture { f in
            let target = f.root.appendingPathComponent("shared-settings.json")
            try f.write(target, "{\"env\":{\"BROWSER\":\"open\"}}")
            try FileManager.default.createSymbolicLink(at: f.profile.appendingPathComponent("settings.json"), withDestinationURL: target)
            rejects("CCAM settings symlink followed") { try f.check() }
        }
        try fixture { f in
            try FileManager.default.createSymbolicLink(at: f.profile.appendingPathComponent("settings.json"), withDestinationURL: f.root.appendingPathComponent("missing"))
            rejects("broken settings symlink fails closed") { try f.check() }
        }
        try fixture { f in
            rejects("inline --settings") { try f.check(["--settings", "{\"env\":{\"BROWSER\":\"open\"}}"] ) }
            rejects("inline equals --settings") { try f.check(["--settings={\"env\":{\"BROWSER\":\"open\"}}"] ) }
            rejects("inline --managed-settings") { try f.check(["--managed-settings", "{\"env\":{\"BROWSER\":\"open\"}}"] ) }
            try f.write(f.cwd.appendingPathComponent("custom.json"), "{\"env\":{\"BROWSER\":\"open\"}}")
            rejects("relative settings file") { try f.check(["--settings", "custom.json"]) }
            rejects("missing explicit settings") { try f.check(["--settings", "missing.json"]) }
            try f.check(["--", "--settings={\"env\":{\"BROWSER\":\"open\"}}"])
            expect(true, "prompt after terminator is not a flag")
        }
        for key in ["CCAM_PROFILE", "CCAM_DESKTOP_DATA_DIR"] {
            try fixture { f in
                try f.write(f.profile.appendingPathComponent("settings.json"), "{\"env\":{\"\(key)\":\"another-account-or-store\"}}")
                rejects("routing key \(key)") { try f.check() }
            }
        }
        try fixture { f in
            let alternate = f.root.appendingPathComponent("alternate")
            try f.write(alternate.appendingPathComponent("settings.json"), "{\"env\":{\"BROWSER\":\"open\"}}")
            let object = ["env": ["CLAUDE_CONFIG_DIR": alternate.path]]
            try JSONSerialization.data(withJSONObject: object).write(to: f.profile.appendingPathComponent("settings.json"))
            rejects("settings config-dir redirect inspected") { try f.check() }
        }
        try fixture { f in
            try f.write(f.policy.appendingPathComponent("managed-settings.json"), "{\"policyHelper\":{\"path\":\"/not-executed\"}}")
            rejects("dynamic policy blocked without execution") { try f.check() }
        }
        try fixture { f in
            try f.write(f.policy.appendingPathComponent("managed-settings.json"), "{\"policyHelpers\":{\"macos\":{\"defaultSettings\":{\"env\":{\"BROWSER\":\"open\"}}}}}")
            rejects("static policy-helper fallback inspected") { try f.check() }
        }
        try fixture { f in
            try f.write(f.profile.appendingPathComponent("settings.json"), "{invalid: secret-do-not-echo")
            do { try f.check(); expect(false, "invalid JSON blocked") }
            catch { expect(!error.localizedDescription.contains("secret-do-not-echo"), "parse error does not expose contents") }
        }
        print("Browser settings guard: \(passed) checks passed; no browser or authentication process launched.")
    }
}
