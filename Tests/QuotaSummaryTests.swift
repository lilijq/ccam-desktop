import Foundation

@main struct QuotaSummaryTests {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        count += 1
        if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-25T04:30:00Z")!
        let accounts = try JSONDecoder().decode([Account].self, from: Data(#"[{"name":"first","default":true},{"name":"second"}]"#.utf8))
        func report(_ name: String, five: Double? = nil, week: Double? = nil, status: String = "ok", error: String? = nil,
                    at: String? = "2026-10-25T04:20:00Z") -> AccountUsage {
            var windows: [UsageWindow] = []
            if let five { windows.append(UsageWindow(label: "5 小时额度", used: five, reset: nil)) }
            if let week { windows.append(UsageWindow(label: "每周额度", used: week, reset: nil)) }
            var raw: [String: Any] = ["source": "cache"]
            if let at { raw["at"] = at }
            return AccountUsage(name: name, status: status, error: error, windows: windows, raw: raw)
        }
        func summary(_ values: [AccountUsage]) -> QuotaSummary { QuotaSummary.make(accounts: accounts, usage: values, now: now) }

        let none = QuotaSummary.make(accounts: [], usage: [report("removed", five: 0)], now: now)
        check(none.title == "暂无账号", "removed accounts cannot leak into the footer")
        check(none.tooltip.contains("不连接 Claude"), "offline behavior is explicit")
        check(summary([]).title == "额度未知", "missing limits are unknown rather than zero")
        check(summary([report("first", status: "logged_out")]).title == "需要登录", "login-needed status remains distinct")
        check(summary([report("first", status: "api")]).title == "API 账号", "API account gets no fabricated percentage")
        let regular = summary([report("first", five: 0, week: 98), report("second", five: 40, week: 30)])
        check(regular.title == "5h 100% · 周 2%", "footer shows remaining limits for one account")
        check(regular.detail.hasPrefix("first · 缓存"), "default account is explicitly identified")
        check(regular.tooltip.contains("2 个账号，2 个有额度缓存"), "account cache count is separate from quota")
        check(regular.tooltip.contains("实际可用量可能已变化"), "cached percentage does not claim live availability")
        let fallback = summary([report("first", status: "logged_out"), report("second", five: 75)])
        check(fallback.title == "需要登录" && fallback.currentAccountName == "first", "default account stays identified when its limits are unknown")
        check(fallback.currentFiveHour == "--" && fallback.currentWeekly == "--", "unknown current windows never borrow another account's limits")
        let exhausted = summary([report("first", five: 100, week: 100), report("second", five: 0, week: 0)])
        check(exhausted.title == "5h 0% · 周 0%" && exhausted.detail.hasPrefix("first ·"), "default account is not silently replaced by one with more quota")
        let old = summary([report("first", five: 0, at: "2026-10-24T04:20:00Z")])
        check(old.detail.contains("旧缓存") && old.tooltip.contains("记录时间"), "old measurements stay visibly old")
        let failed = summary([report("first", five: 20, status: "error", error: "timeout")])
        check(failed.detail.contains("旧缓存") && failed.tooltip.contains("上次读取未成功"), "failed query retains historical value without success claim")
        let expired = summary([report("first", five: 20, status: "expired")])
        check(expired.detail.contains("旧缓存") && expired.tooltip.contains("此账号需要登录"), "expired login with cached limits is clearly marked")
        check(summary([report("first", five: 30, at: nil)]).detail.contains("旧缓存"), "unknown timestamp is not fresh")
        check(summary([report("first", five: 30, at: "2026-10-26T04:20:00Z")]).detail.contains("旧缓存"), "future timestamp is not fresh")
        let bounds = summary([report("first", five: -12, week: 101)])
        check(bounds.title == "5h 100% · 周 0%", "stored out-of-range percentages are bounded")
        check(summary([report("first", five: 99.4)]).title == "5h <1%", "small positive remaining amount is not rounded up to one")
        check(summary([report("first", five: 25.4)]).title == "5h 74%", "remaining integer is conservative")
        check(summary([report("first", five: .nan)]).title == "额度未知", "non-finite window is unknown")
        check(summary([report("outsider", five: 0)]).title == "额度未知", "unknown account reports are ignored")
        let scoped = AccountUsage(name: "first", status: "ok", error: nil,
                                  windows: [UsageWindow(label: "Opus · 每周", used: 12, reset: nil)],
                                  raw: ["source": "statusline", "at": "2026-10-25T04:20:00.120Z"])
        let onlyModel = summary([scoped])
        check(onlyModel.title == "已保存模型额度" && onlyModel.tooltip.contains("Opus · 每周：88%"), "scoped limits stay available without becoming a general weekly limit")
        check(!onlyModel.detail.contains("旧缓存"), "fractional ISO timestamp is parsed")
        check(regular.currentFiveHour == "100%" && regular.currentWeekly == "2%", "current windows are exposed independently")
        check(regular.totalFiveHour == "1.60份" && regular.totalWeekly == "0.72份", "pool totals sum account fractions per independent window")
        check(regular.poolCoverage == "2 个账号", "complete cache coverage is concise")
        check(regular.tooltip.contains("1 份 = 一个账号自身的满额度") && regular.tooltip.contains("不表示 token"), "pool units cannot be mistaken for absolute capacity")
        let selected = QuotaSummary.make(accounts: accounts, usage: [report("first", five: 20), report("second", five: 80)], now: now, preferredAccount: "second")
        check(selected.currentAccountName == "second" && selected.currentFiveHour == "20%", "explicit active conversation account takes precedence over default")
        let selectedUnknown = QuotaSummary.make(accounts: accounts, usage: [report("first", five: 20)], now: now, preferredAccount: "second")
        check(selectedUnknown.currentAccountName == "second" && selectedUnknown.currentFiveHour == "--", "selected account with no cache remains unknown")
        check(summary([]).totalFiveHour == "--" && summary([]).totalWeekly == "--", "unknown total is not fabricated as zero")
        let partial = summary([report("first", five: 100, week: 100)])
        check(partial.totalFiveHour == "0.00份" && partial.poolCoverage == "部分缓存 1/2", "zero known balance is distinct from missing second account")
        check(partial.tooltip.contains("覆盖 1/2 个账号"), "partial coverage is disclosed for each window")
        let independent = summary([report("first", five: 0), report("second", week: 50)])
        check(independent.totalFiveHour == "1.00份" && independent.totalWeekly == "0.50份", "different reset windows are never combined into one quota")
        let recent = summary([report("first", five: 0, at: "2026-10-25T04:10:00Z"), report("first", five: 80, at: "2026-10-25T04:25:00Z")])
        check(recent.currentFiveHour == "20%" && recent.totalFiveHour == "0.20份", "duplicate reports use newest measurement once")
        let reversed = summary([report("first", five: 80, at: "2026-10-25T04:25:00Z"), report("first", five: 0, at: "2026-10-25T04:10:00Z")])
        check(reversed.totalFiveHour == "0.20份", "newest measurement does not depend on array ordering")
        let sameIdentity = try JSONDecoder().decode([Account].self, from: Data(#"[{"name":"first","default":true,"email":" USER@example.test ","plan":"pro"},{"name":"second","email":"user@example.test","plan":"pro"}]"#.utf8))
        let deduped = QuotaSummary.make(accounts: sameIdentity, usage: [report("first", five: 0, week: 90, at: "2026-10-25T04:10:00Z"), report("second", five: 40, week: 20)], now: now)
        check(deduped.currentAccountName == "first" && deduped.currentFiveHour == "100%", "identity deduplication never changes the current account")
        check(deduped.totalFiveHour == "0.60份" && deduped.totalWeekly == "0.80份" && deduped.poolCoverage == "1 个账号", "same-email profiles contribute the latest record only once")
        check(deduped.tooltip.contains("同邮箱") && deduped.tooltip.contains("不同组织"), "email-based deduplication limitation is explicit")
        check(regular.tooltip.contains("身份去重尚未完全确认"), "missing account identity is disclosed")
        let mixedPlans = try JSONDecoder().decode([Account].self, from: Data(#"[{"name":"first","plan":"pro"},{"name":"second","plan":"max"}]"#.utf8))
        let mixed = QuotaSummary.make(accounts: mixedPlans, usage: [report("first", five: 50), report("second", five: 50)], now: now)
        check(mixed.totalFiveHour == "1.00份" && mixed.tooltip.contains("未按套餐加权"), "different plans retain per-account fractions without fabricated weighting")
        var reset = report("first", five: 20)
        reset = AccountUsage(name: reset.name, status: reset.status, error: nil,
                             windows: [UsageWindow(label: "5 小时额度", used: 20, reset: "2026-10-25T04:25:00Z")], raw: reset.raw)
        let passedReset = summary([reset])
        check(passedReset.totalFiveHour == "0.80份" && passedReset.cacheLabel.contains("旧缓存"), "past reset does not automatically refill historical quota")
        check(passedReset.tooltip.contains("不会自动补满"), "past-reset cache warning is explicit")
        check(summary([report("first", five: 30, at: "2026-10-26T04:20:00Z")]).cacheLabel.contains("旧缓存"), "future timestamp never makes pool totals fresh")
        check(summary([report("first", five: 30, status: "error", error: "timeout")]).cacheLabel.contains("旧缓存"), "failed reads retain history with old status")
        check(summary([report("first", five: 30, status: "expired")]).tooltip.contains("不代表现在可执行"), "expired accounts cannot imply executable quota")
        check(summary([report("first", five: .infinity)]).totalFiveHour == "--", "non-finite windows never reach arithmetic")
        check(summary([report("first", five: -20), report("second", five: 300)]).totalFiveHour == "1.00份", "pool arithmetic clamps stored percentages")
        check(summary([report("first", five: 99.8)]).totalFiveHour == "<0.01份", "small known total stays positive without rounding up")
        check(onlyModel.totalWeekly == "--", "model-scoped weekly cache is not the general pool weekly balance")
        print("PASS: \(count) cached quota summary checks (fixtures only, no CLI or network requests)")
    }
}
