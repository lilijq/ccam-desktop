import Foundation

/// A read-only, five-hour gauge. Unknown capacity is the range from
/// `knownFraction` to 1; it must not be drawn as used or exhausted capacity.
/// Pool fractions are normalized per account, not weighted by plan size.
struct QuotaGaugeSnapshot {
    let remainingFraction: Double?
    let knownFraction: Double
    let stale: Bool
    let tooltip: String
}

/// Offline quota arithmetic. A "份" is a fraction of one account's own full
/// window, not a shared token balance or a capacity-weighted subscription total.
struct QuotaSummary {
    let title: String
    let detail: String
    let tooltip: String
    let currentAccountName: String?
    let currentFiveHour: String
    let currentWeekly: String
    let totalFiveHour: String
    let totalWeekly: String
    let poolCoverage: String
    let cacheLabel: String
    let currentGauge: QuotaGaugeSnapshot
    let totalGauge: QuotaGaugeSnapshot

    static func make(accounts: [Account], usage: [AccountUsage], now: Date = Date(), preferredAccount: String? = nil) -> QuotaSummary {
        let provenance = "显示最近读取的额度记录。每轮问答后经代理更新，不发送模型消息。实际可用量可能已变化。"
        // CCAM profile names are unique, but reject duplicate rows defensively.
        var seen = Set<String>()
        let accounts = accounts.filter { seen.insert($0.name).inserted }
        guard !accounts.isEmpty else {
            let empty = QuotaGaugeSnapshot(remainingFraction: nil, knownFraction: 0, stale: false,
                                          tooltip: "暂无账号\n" + provenance)
            return QuotaSummary(title: "暂无账号", detail: "账号与额度", tooltip: provenance,
                                currentAccountName: nil, currentFiveHour: "--", currentWeekly: "--",
                                totalFiveHour: "--", totalWeekly: "--", poolCoverage: "0 个账号", cacheLabel: "暂无缓存",
                                currentGauge: empty, totalGauge: empty)
        }
        let names = Set(accounts.map(\.name))
        let reports = usage.filter { names.contains($0.name) }
        // Choose the newest record, never combine multiple readings of one account.
        func latest(_ candidates: [AccountUsage]) -> AccountUsage? {
            candidates.enumerated().max { lhs, rhs in
                let a = lhs.element.measuredAt.flatMap(parseDate) ?? .distantPast
                let b = rhs.element.measuredAt.flatMap(parseDate) ?? .distantPast
                return a == b ? lhs.offset < rhs.offset : a < b
            }?.element
        }
        let byName = Dictionary(grouping: reports, by: \.name).compactMapValues(latest)
        let current = accounts.first { $0.name == preferredAccount }
            ?? accounts.first { $0.isDefault == true } ?? accounts[0]
        let report = byName[current.name]
        func window(_ report: AccountUsage?, _ label: String) -> UsageWindow? {
            report?.windows.first { $0.label == label && $0.used.isFinite }
        }
        let five = window(report, "5 小时额度"), week = window(report, "每周额度")
        let currentFive = five.map { percentage($0.used) } ?? "--"
        let currentWeek = week.map { percentage($0.used) } ?? "--"
        let pieces = [("5h", five), ("周", week)].compactMap { prefix, value -> String? in
            value.map { prefix + " " + percentage($0.used) }
        }
        let title: String
        if !pieces.isEmpty { title = pieces.joined(separator: " · ") }
        else if report?.needsLogin == true { title = "需要登录" }
        else if let report, ["api", "api_key"].contains(report.status) { title = "API 账号" }
        else if report?.windows.contains(where: { $0.used.isFinite }) == true { title = "已保存模型额度" }
        else { title = "额度未知" }

        func normalizedEmail(_ account: Account) -> String? {
            let email = account.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return email.isEmpty ? nil : email
        }
        // The public account model has no organization/identity UUID. Same-email
        // profiles are counted once conservatively; the limitation is disclosed.
        let groups = Dictionary(grouping: accounts) { account in
            normalizedEmail(account).map { "email:" + $0 } ?? "profile:" + account.name
        }
        let poolReports = groups.values.compactMap { group in latest(group.compactMap { byName[$0.name] }) }
        let fiveWindows = poolReports.compactMap { window($0, "5 小时额度") }
        let weekWindows = poolReports.compactMap { window($0, "每周额度") }
        let count = groups.count
        let coverage: String
        if fiveWindows.count == count && weekWindows.count == count { coverage = "\(count) 个账号" }
        else if fiveWindows.count == weekWindows.count { coverage = "部分缓存 \(fiveWindows.count)/\(count)" }
        else { coverage = "部分缓存" }
        let knownReports = poolReports.filter { $0.windows.contains { $0.used.isFinite } }
        let oldReports = knownReports.filter { isOld($0, now: now) }
        let displayedReports = knownReports + (report.map { [$0] } ?? [])
        let dates = displayedReports.compactMap { $0.measuredAt.flatMap(parseDate) }
        let cache: String
        if knownReports.isEmpty { cache = "暂无缓存" }
        else { cache = marker(old: displayedReports.contains { isOld($0, now: now) }, date: dates.min()) }
        let currentMarker = report.map { marker(old: isOld($0, now: now), date: $0.measuredAt.flatMap(parseDate)) } ?? "暂无缓存"

        var lines = ["\(current.name) 的剩余额度（缓存）"]
        if let report {
            for value in report.windows where value.used.isFinite { lines.append("\(value.label)：\(percentage(value.used))") }
            if let date = report.measuredAt.flatMap(parseDate) {
                lines.append("记录时间：" + DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short))
            } else { lines.append("记录时间未知") }
            if report.needsLogin { lines.append("此账号需要登录；缓存不代表登录状态。") }
            else if report.status == "error" || report.error?.isEmpty == false { lines.append("上次读取未成功，保留此前数值。") }
        } else { lines.append("此账号暂无额度缓存。") }
        lines.append("\(accounts.count) 个账号，\(byName.values.filter { $0.windows.contains { $0.used.isFinite } }.count) 个有额度缓存")
        lines += ["", "账号池总剩余（缓存）", "5 小时：\(portions(fiveWindows))，覆盖 \(fiveWindows.count)/\(count) 个账号",
                  "每周：\(portions(weekWindows))，覆盖 \(weekWindows.count)/\(count) 个账号",
                  "1 份 = 一个账号自身的满额度。按各账号剩余比例相加，不表示 token、金额或统一容量。",
                  "5 小时和每周分开合计，不互相相加；各账号按自己的时间重置。未知额度未计入，不能当作 0。"]
        let plans = Set(accounts.compactMap { $0.plan?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        if plans.count > 1 || accounts.contains(where: { $0.plan?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }) {
            lines.append("套餐不同或未确认，每份的实际容量可能不同，合计未按套餐加权。")
        }
        if groups.count < accounts.count { lines.append("同邮箱的多个账号仅计一份，采用最近缓存；不同组织的独立额度无法从本机字段确认。") }
        if accounts.contains(where: { normalizedEmail($0) == nil }) { lines.append("部分账号未提供邮箱，按独立账号计；身份去重尚未完全确认。") }
        if !oldReports.isEmpty { lines.append("合计包含 \(oldReports.count) 个账号的旧缓存；过期、读取失败或已过重置时间的数值不会自动补满。") }
        if knownReports.contains(where: \.needsLogin) { lines.append("合计包含需要重新登录的账号历史额度，不代表现在可执行。") }
        lines.append(provenance)

        func windowDescription(_ name: String, _ value: UsageWindow?) -> String {
            guard let value else { return name + "：未知" }
            return name + "：剩余 " + percentage(value.used) + "，已用 " + percentage(100 - value.used)
        }
        func dateDescription(_ date: Date) -> String {
            DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
        }
        var currentLines = ["当前账号 " + current.name, windowDescription("5 小时", five), windowDescription("每周", week)]
        if let report {
            let stamp = report.measuredAt.flatMap(parseDate).map(dateDescription) ?? "时间未知"
            currentLines.append((isOld(report, now: now) ? "旧缓存：" : "缓存：") + stamp)
            if let reset = five?.reset.flatMap(parseDate) { currentLines.append("5 小时重置：" + dateDescription(reset)) }
            if report.needsLogin { currentLines.append("需要重新登录；历史额度不代表现在可用。") }
            else if report.status == "error" || report.error?.isEmpty == false { currentLines.append("上次读取未成功，保留此前数值。") }
            if isOld(report, now: now), five != nil { currentLines.append("旧缓存不会因已过重置时间自动补满。") }
        } else { currentLines.append("此账号暂无额度缓存。") }
        currentLines.append(provenance)
        let currentGauge = QuotaGaugeSnapshot(remainingFraction: five.map { remaining($0.used) / 100 },
                                              knownFraction: five == nil ? 0 : 1,
                                              stale: five != nil && report.map { isOld($0, now: now) } == true,
                                              tooltip: currentLines.joined(separator: "\n"))

        // Keep all distinct accounts in the denominator. A partially known pool
        // draws known remaining / known used / unknown as separate intervals.
        let fiveReports = poolReports.filter { window($0, "5 小时额度") != nil }
        let fiveDates = fiveReports.compactMap { $0.measuredAt.flatMap(parseDate) }
        let totalStale = fiveReports.contains { isOld($0, now: now) }
        let remainingTotal = fiveWindows.isEmpty ? nil : fiveWindows.reduce(0.0) { $0 + remaining($1.used) / 100 } / Double(count)
        let usedTotal = fiveWindows.map { UsageWindow(label: $0.label, used: 100 - $0.used, reset: $0.reset) }
        var totalLines = ["总剩余（5 小时）", "已知剩余 " + portions(fiveWindows) + " / \(count)份",
                          "已知已用 " + portions(usedTotal) + "，覆盖 \(fiveWindows.count)/\(count) 个账号",
                          "每周剩余 " + portions(weekWindows) + "，覆盖 \(weekWindows.count)/\(count) 个账号"]
        if fiveReports.isEmpty { totalLines.append("暂无 5 小时额度缓存。") }
        else {
            let stamp = fiveDates.min().map(dateDescription) ?? "时间未知"
            totalLines.append((totalStale ? "含旧缓存，已知最早记录：" : "缓存，已知最早记录：") + stamp)
        }
        if fiveWindows.count < count { totalLines.append("虚线为未知额度，不能当作 0；已知剩余按全部 \(count) 个账号满额归一化。") }
        totalLines.append("1 份 = 一个账号自身的满额度；不表示 token、金额或统一容量，未按套餐加权。")
        totalLines.append("5 小时和每周分开计算，各账号按自己的时间重置。")
        if groups.count < accounts.count { totalLines.append("同邮箱账号仅计一份，采用最近缓存；不同组织的独立额度尚未确认。") }
        if accounts.contains(where: { normalizedEmail($0) == nil }) { totalLines.append("部分账号未提供邮箱，身份去重尚未完全确认。") }
        if totalStale { totalLines.append("旧缓存不会因已过重置时间自动补满。") }
        if fiveReports.contains(where: \.needsLogin) { totalLines.append("包含需要重新登录的账号历史额度，不代表现在可执行。") }
        totalLines.append(provenance)
        let totalGauge = QuotaGaugeSnapshot(remainingFraction: remainingTotal,
                                            knownFraction: Double(fiveWindows.count) / Double(count), stale: totalStale,
                                            tooltip: totalLines.joined(separator: "\n"))
        return QuotaSummary(title: title, detail: current.name + " · " + currentMarker, tooltip: lines.joined(separator: "\n"),
                            currentAccountName: current.name, currentFiveHour: currentFive, currentWeekly: currentWeek,
                            totalFiveHour: portions(fiveWindows), totalWeekly: portions(weekWindows), poolCoverage: coverage, cacheLabel: cache,
                            currentGauge: currentGauge, totalGauge: totalGauge)
    }

    private static func remaining(_ used: Double) -> Double { max(0, min(100, 100 - used)) }
    private static func percentage(_ used: Double) -> String {
        let value = remaining(used)
        if value > 0 && value < 1 { return "<1%" }
        return String(format: "%.0f%%", floor(value))
    }
    private static func portions(_ windows: [UsageWindow]) -> String {
        guard !windows.isEmpty else { return "--" }
        let value = windows.reduce(0) { $0 + remaining($1.used) / 100 }
        if value > 0 && value < 0.01 { return "<0.01份" }
        // Avoid both overstating a fraction and dropping 1.20 to 1.19 due to
        // binary floating-point representation of exact hundredths.
        return String(format: "%.2f份", floor(value * 100 + 1e-9) / 100)
    }
    private static func isOld(_ report: AccountUsage, now: Date) -> Bool {
        guard !report.needsLogin, report.status != "error", report.error?.isEmpty != false,
              let date = report.measuredAt.flatMap(parseDate), date <= now, now.timeIntervalSince(date) < 3600 else { return true }
        return report.windows.contains { value in
            guard let raw = value.reset else { return false }
            guard let reset = parseDate(raw) else { return true }
            return reset <= now
        }
    }
    private static func marker(old: Bool, date: Date?) -> String {
        var value = old ? "旧缓存" : "缓存"
        if let date { let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"; value += " " + formatter.string(from: date) }
        return value
    }
    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}
