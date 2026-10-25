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

    private static func proxyURL(host: Any?, port: Any?, scheme: String) -> String? {
        guard let name = host as? String,
              let hostname = validatedHost(name), let number = port as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 1, value <= 65535, value.rounded() == value else { return nil }
        // HTTPSProxy names an HTTP CONNECT proxy; it does not imply TLS to the proxy itself.
        return "\(scheme)://\(hostname):\(Int(value))"
    }

    private static func validatedHost(_ input: String) -> String? {
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
