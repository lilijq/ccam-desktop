import Foundation
import CFNetwork

@main struct NetworkEnvironmentTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() {
        let base = ["PATH": "/test/bin", "CUSTOM": "unchanged"]
        let target = URL(string: "https://service.example.test/usage")!
        func proxy(_ type: CFString, host: String = "selected.example.test", port: Any = 8123) -> [String: Any] {
            [kCFProxyTypeKey as String: type as String, kCFProxyHostNameKey as String: host, kCFProxyPortNumberKey as String: port]
        }
        func resolved(_ proxies: [[String: Any]], _ environment: [String: String] = [:], _ destination: URL? = nil) -> [String: String] {
            NetworkEnvironment.applyingResolvedProxies(proxies, to: environment, destination: destination ?? target)
        }
        for type in [kCFProxyTypeHTTP, kCFProxyTypeHTTPS] {
            let result = resolved([proxy(type)], base)
            check(result["HTTPS_PROXY"] == "http://selected.example.test:8123" && result["HTTP_PROXY"] == result["HTTPS_PROXY"], "known HTTPS query supports both Claude proxy aliases")
            check(result["NO_PROXY"] == nil && result["CUSTOM"] == base["CUSTOM"], "resolved policy does not invent global bypass rules")
        }
        check(resolved([proxy(kCFProxyTypeSOCKS, host: "::1")])["HTTPS_PROXY"] == "socks5h://[::1]:8123", "resolved SOCKS supports IPv6")
        for type in [kCFProxyTypeNone, kCFProxyTypeAutoConfigurationURL, kCFProxyTypeAutoConfigurationJavaScript, kCFProxyTypeFTP] {
            check(resolved([proxy(type), proxy(kCFProxyTypeHTTPS)], base) == base, "never skip first direct/PAC/unsupported policy")
        }
        for key in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"] {
            check(resolved([proxy(kCFProxyTypeHTTPS)], [key: ""]) == [key: ""], "destination policy preserves explicit proxy variables")
        }
        check(resolved([proxy(kCFProxyTypeHTTPS)], ["HTTP_PROXY": "http://explicit.test:1", "no_proxy": "custom.test"])["no_proxy"] == "custom.test", "destination policy preserves existing no_proxy")
        check(resolved([proxy(kCFProxyTypeHTTPS)], base, URL(string: "http://service.example.test")!) == base, "destination-specific helper is HTTPS-only")
        check(resolved([], base) == base, "empty resolved proxy list is unchanged")
        check(resolved([[:]], base) == base, "missing proxy type is unchanged")
        check(resolved([proxy(kCFProxyTypeHTTPS)], base, URL(string: "https:relative")!) == base, "destination requires a host")
        for host in ["::1", "[::1]", "2001:db8::7"] {
            check(resolved([proxy(kCFProxyTypeSOCKS, host: host)])["HTTPS_PROXY"]?.hasPrefix("socks5h://[") == true, "SOCKS IPv6 endpoint is bracketed")
        }
        check(resolved([proxy(kCFProxyTypeHTTP, host: "127.0.0.1")])["HTTPS_PROXY"] == "http://127.0.0.1:8123", "IPv4 proxy endpoint")
        for host in ["", " proxy.test", "proxy.test\n", "http://proxy.test", "user:pass@proxy.test", "proxy.test/path", "proxy.test?x=1", "bad,host", "999.1.2.3", "fe80::1%en0", "[bad]", "bad..test", "-bad.test", "bad-.test", "127.0.0.1\0suffix"] {
            check(resolved([proxy(kCFProxyTypeHTTPS, host: host)], base) == base, "invalid proxy host rejected: \(host.debugDescription)")
        }
        for port: Any in [0, -1, 65536, 2.5, Double.infinity, Double.nan, "8080", true] {
            check(resolved([proxy(kCFProxyTypeHTTPS, port: port)], base) == base, "invalid proxy port rejected")
        }
        check(resolved([proxy(kCFProxyTypeHTTPS, port: 65535)])["HTTPS_PROXY"]?.hasSuffix(":65535") == true, "maximum valid proxy port")
        for key in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"] {
            check(resolved([proxy(kCFProxyTypeHTTPS)], [key: "http://explicit.example.test:9000"]) == [key: "http://explicit.example.test:9000"], "existing populated proxy environment is preserved")
        }
        for key in ["HTTP_PROXY", "http_proxy", "NO_PROXY", "no_proxy"] {
            let result = resolved([proxy(kCFProxyTypeHTTPS)], [key: "custom"])
            check(result[key] == "custom" && result.count == (key.lowercased() == "http_proxy" ? 1 : 3), "existing HTTP and bypass variables preserved without competing casing")
        }
        for key in [kCFProxyUsernameKey, kCFProxyPasswordKey] {
            check(resolved([proxy(kCFProxyTypeHTTPS).merging([key as String: "fixture"]) { _, new in new }], base) == base, "proxy credential-bearing entry is not copied")
        }
        executionProxyChecks()
        print("PASS: \(count) network environment checks (injected proxy decisions, no network requests)")
    }

    static func executionProxyChecks() {
        let base = ["PATH": "/test/bin", "CUSTOM": "unchanged"]
        let settings: [String: Any] = [kCFNetworkProxiesHTTPSEnable as String: 1,
                                       kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1", kCFNetworkProxiesHTTPSPort as String: 8123]
        func resolve(_ environment: [String: String] = [:], _ manual: String? = nil, _ system: [String: Any]? = nil) throws -> ExecutionProxy.State {
            try ExecutionProxy.resolve(environment: environment, manualURL: manual, systemSettings: system)
        }
        func rejected(_ message: String, _ body: () throws -> Void) {
            do { try body(); check(false, message) } catch { check(error is ExecutionProxy.Failure, message) }
        }
        rejected("no proxy cannot launch") { _ = try resolve(base) }
        rejected("empty system proxy cannot launch") { _ = try resolve(base, nil, [:]) }
        for raw in ["", " ", "http://localhost", "localhost:8123", "https://u:p@host.test:8123", "http://host.test:8123/path", "http://host.test:8123?secret=x", "http://host.test:8123#x", "http://host.test:0", "http://host.test:65536", "http://host.test:1\n", "http://host.test:1\0x", "http://bad..test:1", "http://999.1.2.3:1", "http://[fe80::1%en0]:1", "http://127.0.0.1%2f:1", "http://host.test:000001", "file:///proxy.pac", "socks5://127.0.0.1:8123", "socks5h://127.0.0.1:8123"] {
            rejected("invalid inherited proxy blocks even if system proxy is available") { _ = try resolve(["HTTPS_PROXY": raw], nil, settings) }
        }
        for key in ExecutionProxy.proxyKeys {
            do {
                let state = try resolve([key: "http://127.0.0.1:8123", "NO_PROXY": "*", "no_proxy": "api.anthropic.com", "CUSTOM": "unchanged"])
                check(ExecutionProxy.proxyKeys.allSatisfy { state.environment[$0] == state.endpoint }, "every alias receives canonical endpoint")
                check(state.environment["NO_PROXY"] == ExecutionProxy.loopbackBypass && state.environment["no_proxy"] == ExecutionProxy.loopbackBypass, "external bypass is removed")
                check(state.environment["CUSTOM"] == "unchanged", "unrelated child environment survives")
            } catch { check(false, "valid inherited endpoint") }
        }
        do {
            let state = try resolve(["HTTPS_PROXY": "HTTP://LOCALHOST:08123/", "http_proxy": "http://localhost:8123"])
            check(state.endpoint == "http://localhost:8123" && state.sourceSummary == "环境代理", "equivalent aliases canonicalize without conflict")
            let ipv6 = try resolve(base, "https://[::1]:8123")
            check(ipv6.endpoint == "https://[::1]:8123", "HTTPS endpoint and IPv6 supported")
            let manual = try resolve(["HTTPS_PROXY": "invalid"], "http://127.0.0.1:8123", settings)
            check(manual.sourceSummary == "手动代理" && manual.endpoint == "http://127.0.0.1:8123", "manual choice supersedes inherited conflict")
            let system = try resolve(base, nil, settings)
            check(system.sourceSummary == "系统代理" && system.endpoint == "http://127.0.0.1:8123", "system HTTPS proxy means HTTP CONNECT")
            var changed = settings; changed[kCFNetworkProxiesHTTPSPort as String] = 9000
            let continued = try resolve(system.environment, nil, changed)
            check(continued.endpoint == "http://127.0.0.1:9000", "continuation re-resolves system configuration")
            let manualRemoved = try resolve(manual.environment, nil, changed)
            check(manualRemoved.sourceSummary == "系统代理" && manualRemoved.endpoint == "http://127.0.0.1:9000", "removing manual override does not reuse old injected endpoint")
            rejected("removed system configuration blocks continuation") { _ = try resolve(system.environment) }
            rejected("removed manual configuration blocks continuation") { _ = try resolve(manual.environment) }
            // Only an isolated shell sees this environment. No CLI, DNS or socket is used.
            let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sh")
            child.arguments = ["-c", "test \"$HTTP_PROXY\" = \"$https_proxy\" && test \"$ALL_PROXY\" = \"$HTTP_PROXY\" && test \"$NO_PROXY\" = 'localhost,127.0.0.1,::1'"]
            child.environment = system.environment; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run(); child.waitUntilExit(); check(child.terminationStatus == 0, "offline child receives enforced aliases")
        } catch { check(false, "valid proxy resolution failed") }
        rejected("conflicting inherited endpoints block") { _ = try resolve(["HTTPS_PROXY": "http://one.test:8123", "https_proxy": "http://two.test:8123"]) }
        for key in [kCFNetworkProxiesProxyAutoConfigEnable, kCFNetworkProxiesProxyAutoDiscoveryEnable] {
            var automatic = settings; automatic[key as String] = 1
            rejected("PAC and discovery never silently fall back") { _ = try resolve(base, nil, automatic) }
        }
        for value: Any in [-1, 2, "yes", 0.5] {
            var malformed = settings; malformed[kCFNetworkProxiesHTTPSEnable as String] = value
            rejected("malformed enable flag blocks") { _ = try resolve(base, nil, malformed) }
        }
        for port: Any in [0, -1, 65536, true, "8123", 0.5] {
            var malformed = settings; malformed[kCFNetworkProxiesHTTPSPort as String] = port
            rejected("invalid system endpoint blocks") { _ = try resolve(base, nil, malformed) }
        }
        var conflicting = settings
        conflicting[kCFNetworkProxiesHTTPEnable as String] = 1; conflicting[kCFNetworkProxiesHTTPProxy as String] = "127.0.0.1"; conflicting[kCFNetworkProxiesHTTPPort as String] = 9000
        rejected("different HTTP and HTTPS system endpoints require explicit choice") { _ = try resolve(base, nil, conflicting) }
        rejected("SOCKS-only system configuration blocks") { _ = try resolve(base, nil, [kCFNetworkProxiesSOCKSEnable as String: 1]) }
        do { _ = try resolve(base, "http://secret-user:secret-password@host.test:8123") }
        catch { check(!error.localizedDescription.contains("secret-"), "error text does not expose rejected credentials") }
        shellChecks()
        settingsGuardChecks()
        for arguments in [["list", "--json"], ["agents"], ["group", "list"], ["usage", "--json", "--source", "cache"], ["usage", "--source=claude", "--source=cache"]] {
            check(!ExecutionProxy.requiresProxy(arguments: arguments), "known local operation available offline")
        }
        for arguments in [[], ["run"], ["next", "--dry-run"], ["login"], ["add", "--no-login"], ["update"], ["unknown"], ["list", "--", "claude"], ["usage"], ["usage", "--source", "cache", "--source", "claude"], ["usage", "--source=cache", "--refresh"], ["usage", "--source=cache", "--no-cache=false"], ["usage", "--source=cache", "--watch"], ["usage", "--source=cache", "--unknown"], ["usage", "--source"], ["usage", "--source=cache", "--"]] {
            check(ExecutionProxy.requiresProxy(arguments: arguments), "unknown or potentially networked operation requires proxy")
        }
    }

    static func shellChecks() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ccam-proxy-test-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: home) }
            let marker = home.appendingPathComponent("user-startup-ran")
            let malicious = "unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy\n/bin/touch '\(marker.path)'\n"
            for filename in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
                try Data(malicious.utf8).write(to: home.appendingPathComponent(filename))
            }
            let state = try ExecutionProxy.resolve(environment: ["HOME": home.path, "PATH": "/usr/bin:/bin", "NO_PROXY": "*"], manualURL: "http://127.0.0.1:18123", systemSettings: nil)
            let shell = try ExecutionProxy.makeShellConfiguration(state: state)
            defer { shell.cleanup() }
            let directoryMode = try FileManager.default.attributesOfItem(atPath: shell.directory.path)[.posixPermissions] as? NSNumber
            let fileMode = try FileManager.default.attributesOfItem(atPath: shell.directory.appendingPathComponent(".zshenv").path)[.posixPermissions] as? NSNumber
            check(directoryMode?.intValue == 0o700 && fileMode?.intValue == 0o600, "shell configuration stays private")
            let expected = ExecutionProxy.proxyKeys + ["NO_PROXY", "no_proxy", "ZDOTDIR"]
            for variable in expected {
                let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/zsh")
                child.arguments = shell.arguments + ["-c", "unset \(variable)"]
                child.environment = shell.environment; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
                try child.run(); child.waitUntilExit()
                check(child.terminationStatus != 0, "proxy and startup path cannot be unset in isolated shell")
            }
            let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/zsh")
            child.arguments = shell.arguments + ["-c", "[[ $HTTP_PROXY = http://127.0.0.1:18123 && $https_proxy = $HTTP_PROXY && $ALL_PROXY = $HTTP_PROXY && $NO_PROXY = localhost,127.0.0.1,::1 ]]"]
            child.environment = shell.environment; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run(); child.waitUntilExit()
            check(child.terminationStatus == 0, "isolated interactive shell retains required proxy")
            check(!FileManager.default.fileExists(atPath: marker.path), "user startup files were not loaded")
            shell.cleanup(); check(!FileManager.default.fileExists(atPath: shell.directory.path), "shell configuration can be cleaned after exit")
        } catch { check(false, "isolated shell fixture failed: \(error.localizedDescription)") }
    }

    static func settingsGuardChecks() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccam-proxy-settings-test-" + UUID().uuidString)
        let home = root.appendingPathComponent("home"), profile = root.appendingPathComponent("profile"), project = root.appendingPathComponent("project/subfolder"), policy = root.appendingPathComponent("policy")
        let settings = profile.appendingPathComponent("settings.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            var env = try ExecutionProxy.resolve(environment: ["HOME": home.path, "CCAM_HOME": root.appendingPathComponent("ccam").path], manualURL: "http://127.0.0.1:18123", systemSettings: nil).environment
            func validate(_ args: [String] = []) throws {
                try ProxySettingsGuard.validate(directory: project.path, profileDirectories: [profile.path], environment: env, claudeArguments: args,
                                                systemSettingsDirectory: policy, managedPreferenceFiles: [root.appendingPathComponent("managed.plist")])
            }
            func write(_ object: [String: Any], to file: URL = settings) throws {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: object).write(to: file)
            }
            func reject(_ title: String, _ block: () throws -> Void) {
                do { try block(); check(false, title) } catch { check(error is ProxySettingsGuardError, title) }
            }
            try validate(); check(true, "missing settings remain usable")
            for key in ExecutionProxy.proxyKeys {
                try write(["env": [key: "http://127.0.0.1:18123"]]); try validate(); check(true, "matching proxy settings allowed")
                try write(["env": [key: "http://other.test:18123"]]); reject("account proxy cannot override required endpoint") { try validate() }
            }
            for (key, value): (String, Any) in [("HTTP_PROXY", ""), ("Http_Proxy", "http://127.0.0.1:18123"), ("HTTPS_PROXY", 1), ("NO_PROXY", ""), ("NO_PROXY", "*"), ("no_proxy", "api.anthropic.com"), ("BASH_ENV", "/not-executed"), ("ENV", "/not-executed"), ("CLAUDE_ENV_FILE", "/not-executed"), ("CLAUDE_CODE_SHELL_PREFIX", "unset HTTPS_PROXY"), ("ZDOTDIR", "/not-executed")] {
                try write(["env": [key: value]]); reject("settings bypass or startup script is blocked") { try validate() }
            }
            try write(["env": ["HTTPS_PROXY": "http://127.0.0.1:18123", "NO_PROXY": ExecutionProxy.loopbackBypass], "permissions": ["deny": ["Bash(rm:*)"]]])
            let before = try Data(contentsOf: settings); try validate()
            let after = try Data(contentsOf: settings)
            check(after == before, "preflight never rewrites settings")
            try FileManager.default.removeItem(at: settings)
            let sources = [home.appendingPathComponent(".claude/settings.json"), project.deletingLastPathComponent().appendingPathComponent(".claude/settings.local.json"),
                           policy.appendingPathComponent("managed-settings.json"), policy.appendingPathComponent("managed-settings.d/20-proxy.json"), root.appendingPathComponent("ccam/data/groups/default/settings.json")]
            for source in sources {
                try write(["env": ["no_proxy": "*"]], to: source)
                reject("all known project/account/managed sources checked") { try validate() }
                try FileManager.default.removeItem(at: source)
            }
            let plist = root.appendingPathComponent("managed.plist")
            try PropertyListSerialization.data(fromPropertyList: ["env": ["HTTPS_PROXY": ""]], format: .binary, options: 0).write(to: plist)
            reject("MDM proxy override checked") { try validate() }; try FileManager.default.removeItem(at: plist)
            try write(["policyHelper": ["path": "/not-executed"]], to: policy.appendingPathComponent("managed-settings.json"))
            reject("dynamic managed policy never executes") { try validate() }; try FileManager.default.removeItem(at: policy.appendingPathComponent("managed-settings.json"))
            try validate(["--settings", "{env:{HTTPS_PROXY:'http://127.0.0.1:18123',NO_PROXY:'localhost,127.0.0.1,::1'}}"])
            check(true, "inline injected proxy and JSON5 accepted")
            reject("inline overriding settings blocked") { try validate(["--settings={\"env\":{\"NO_PROXY\":\"*\"}}"] ) }
            reject("explicit missing settings blocked") { try validate(["--settings", "missing.json"]) }
            try validate(["--", "--settings={\"env\":{\"NO_PROXY\":\"*\"}}"])
            check(true, "prompt after separator is not interpreted as settings")
            env["BASH_ENV"] = "/not-executed"; reject("inherited shell startup script blocks before launch") { try validate() }; env.removeValue(forKey: "BASH_ENV")
            try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: root.appendingPathComponent("missing-target"))
            reject("broken settings symlink fails closed") { try validate() }; try FileManager.default.removeItem(at: settings)
            try Data("{invalid: private-value-do-not-print".utf8).write(to: settings)
            do { try validate(); check(false, "malformed settings rejected") }
            catch { check(!error.localizedDescription.contains("private-value"), "diagnostics contain no settings values") }
        } catch { check(false, "proxy settings fixture failed: \(error.localizedDescription)") }
    }
}
