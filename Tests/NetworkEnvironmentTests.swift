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
        print("PASS: \(count) network environment checks (injected proxy decisions, no network requests)")
    }
}
