import AppKit

/// Policy and data tests only: no AppDelegate instance, CLI launch or network.
enum TurnQuotaRefreshUITests {
    static func run() throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        typealias Source = AccountQuotaRefreshQueue.Source
        check(Source.cache.arguments == ["usage", "--json", "--source", "cache"], "idle refresh stays cache-only")
        check(Source.live.arguments == ["usage", "--json", "--source", "live", "--no-cache"], "turn refresh uses uncached usage endpoint without Claude or token refresh")
        check(!ExecutionProxy.requiresProxy(arguments: Source.cache.arguments) && ExecutionProxy.requiresProxy(arguments: Source.live.arguments),
              "turn quota query requires the same proxy as chat")
        var queue = AccountQuotaRefreshQueue()
        check(queue.begin(.cache) && queue.active == .cache, "initial local read starts once")
        check(!queue.begin(.live) && !queue.begin(.live), "simultaneous completed turns queue one live read")
        check(!queue.begin(.cache, repeatCache: true), "manual cache read cannot overlap live update")
        check(queue.finish() == .live && queue.active == nil, "completed turns take priority over pending cache reads")
        check(queue.begin(.live), "queued live refresh starts after previous read completes")
        check(!queue.begin(.cache) && queue.finish() == nil, "background cache timers do not cause a follow-up request")
        check(queue.begin(.live) && !queue.begin(.live) && !queue.begin(.live), "later completed turns coalesce during a live read")
        check(queue.finish() == .live && queue.begin(.live) && queue.finish() == nil, "one trailing read captures usage after overlapping turns")
        check(queue.begin(.cache) && !queue.begin(.cache, repeatCache: true) && queue.finish() == .cache, "explicit manual refresh still queues one local retry")
        let liveControl = AccountRefreshControl(refreshing: true, lastRefresh: nil, failed: false, live: true) { }
        check(liveControl.feedback.stringValue == "正在更新额度" && liveControl.button.toolTip?.contains("经代理") == true,
              "live quota query is distinguished from a local cache read")
        check(liveControl.button.toolTip?.contains("不发送模型消息") == true && !liveControl.button.isEnabled,
              "live quota feedback describes endpoint-only update and prevents duplicate clicks")
        let manualControl = AccountRefreshControl(refreshing: false, lastRefresh: nil, failed: false, live: true) { }
        check(manualControl.button.toolTip?.contains("本机账号状态") == true, "idle button continues to explain its local manual action")

        func report(_ name: String, used: Int?, at: String, status: String = "ok", error: String? = nil) throws -> AccountUsage {
            var row: [String: Any] = ["name": name, "at": at, "source": "live", "status": status]
            if let used { row["limits"] = ["five_hour": ["known": true, "percent": used]] }
            if let error { row["error"] = error }
            return try AccountUsage.parse(JSONSerialization.data(withJSONObject: [row]))[0]
        }
        let old = try report("work", used: 20, at: "2025-01-02T03:04:05Z")
        let error = try report("work", used: nil, at: "2025-01-02T03:05:00Z", status: "error", error: "connection refused")
        let retained = AppDelegate.mergeUsage([error], previous: [old])[0]
        check(retained.windows.first?.used == 20 && retained.measuredAt == old.measuredAt, "failed usage row preserves known limits and their actual measurement time")
        check(retained.status == "error" && retained.error == error.error && retained.cached, "preserved limits still disclose the new query error and cached source")
        let expired = try report("work", used: nil, at: "2025-01-02T03:05:00Z", status: "expired")
        let loggedOut = AppDelegate.mergeUsage([expired], previous: [old])[0]
        check(loggedOut.needsLogin && loggedOut.windows.first?.used == 20, "expired accounts retain historical figures without concealing login state")
        let fresh = try report("work", used: 35, at: "2025-01-02T03:06:00.500Z")
        check(AppDelegate.mergeUsage([fresh], previous: [retained])[0].windows.first?.used == 35, "successful usage query replaces the prior failed reading")
        check(AppDelegate.mergeUsage([old], previous: [fresh])[0].windows.first?.used == 35, "a later cache read cannot overwrite a newer endpoint reading")
        let another = try report("other", used: nil, at: "2025-01-02T03:05:00Z", status: "error", error: "timeout")
        check(AppDelegate.mergeUsage([another], previous: [old])[0].windows.isEmpty, "account cache fallback never crosses account names")
        return checks
    }
}
