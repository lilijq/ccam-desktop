import AppKit

private final class SidebarGaugeFixtureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Offline fixtures exercise the sidebar as navigation, not as a quota editor.
enum SidebarGaugeUITests {
    static func run() throws -> Int {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            count += 1
            if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let now = ISO8601DateFormatter().date(from: "2026-10-25T04:30:00Z")!
        let accounts = try JSONDecoder().decode([Account].self, from: Data(#"[{"name":"work","default":true,"email":"work@example.test","plan":"pro"},{"name":"studio","email":"studio@example.test","plan":"pro"},{"name":"personal","email":"personal@example.test","plan":"pro"}]"#.utf8))
        func report(_ name: String, five: Double, week: Double, old: Bool = false) -> AccountUsage {
            AccountUsage(name: name, status: "ok", error: nil,
                         windows: [UsageWindow(label: "5 小时额度", used: five, reset: nil),
                                   UsageWindow(label: "每周额度", used: week, reset: nil)],
                         raw: ["source": "cache", "at": old ? "2026-10-24T04:20:00Z" : "2026-10-25T04:20:00Z"])
        }
        func summary(_ usage: [AccountUsage]) -> QuotaSummary { .make(accounts: accounts, usage: usage, now: now) }
        let fresh = summary([report("work", five: 24, week: 46), report("studio", five: 72, week: 33), report("personal", five: 80, week: 81)])
        let partial = summary([report("work", five: 24, week: 46)])
        let zero = summary(accounts.map { report($0.name, five: 100, week: 100) })
        let full = summary(accounts.map { report($0.name, five: 0, week: 0) })
        let unknown = summary([])
        let old = summary([report("work", five: 24, week: 46, old: true), report("studio", five: 72, week: 33, old: true), report("personal", five: 80, week: 81, old: true)])

        let records = ["工作台", "pixel-lab", "workspace-sample-with-a-long-project-name"].map { name in
            ProjectRecord(id: UUID(), name: name, path: "/offline-fixtures/" + name, createdAt: now, lastOpenedAt: now, archived: false)
        }
        let groups = [
            SidebarProjectGroup(project: records[0], items: [("layout", "调整分屏与文件树"), ("input", "检查输入与快捷键"), ("theme", "统一暗黑模式")], selectedID: "layout"),
            SidebarProjectGroup(project: records[1], items: [("icons", "整理图标资源"), ("review", "Review the image preview")]),
            SidebarProjectGroup(project: records[2], items: [("long", "检查特别长的对话标题在窄侧栏中的截断和悬浮提示")])
        ]
        let sidebar = WorkspaceSidebar(frame: NSRect(x: 0, y: 0, width: 224, height: 740))
        let host = ThemeSurface(Theme.sidebar)
        host.addSubview(sidebar); sidebar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([sidebar.topAnchor.constraint(equalTo: host.topAnchor), sidebar.bottomAnchor.constraint(equalTo: host.bottomAnchor), sidebar.leadingAnchor.constraint(equalTo: host.leadingAnchor), sidebar.trailingAnchor.constraint(equalTo: host.trailingAnchor)])
        let window = SidebarGaugeFixtureWindow(contentRect: sidebar.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host; window.appearance = NSAppearance(named: .darkAqua)
        for record in records { sidebar.revealProject(record.id) }
        sidebar.update(groups: groups, currentID: records[0].id); sidebar.updateQuota(fresh)
        host.layoutSubtreeIfNeeded()
        let quota = all(sidebar).compactMap { $0 as? SidebarQuotaView }.first!
        let current = quota.currentButton, total = quota.totalButton
        let currentRect = quota.convert(current.bounds, from: current), totalRect = quota.convert(total.bounds, from: total)
        check(currentRect.minY >= totalRect.maxY - 0.5, "current quota is above pooled quota with separate full-row hit targets")
        check(current.bounds.height >= 30 && total.bounds.height >= 30 && current.bounds.width > 180, "quota hit targets remain usable at the 224-point sidebar width")
        for button in [current, total] {
            check(button.ringRect.width == button.ringRect.height && button.bounds.contains(button.ringRect.insetBy(dx: -2, dy: -2)) && button.bounds.contains(button.percentageRect), "circular quota, endpoint and percentage remain inside their button")
            check(button.accessibilityRole() == .button && button.acceptsFirstResponder, "quota is a keyboard-accessible navigation button rather than an editable slider")
        }
        check((current.snapshot?.remainingFraction ?? 0) > (total.snapshot?.remainingFraction ?? 1), "current and pool indicators retain different fixture balances")
        check(current.displayedPercentage == "76%" && total.displayedPercentage == "41%", "current and pool display conservative normalized percentages beside their rings")
        check(current.tone == .healthy && total.tone == .low, "remaining percentages distinguish healthy and low balances without relying on labels alone")
        check(current.toolTip?.contains("work") == true && current.toolTip?.contains("每周") == true && current.toolTip?.contains("点击进入账号与额度") == true, "current hover reveals account, separate weekly quota and navigation")
        check(total.toolTip?.contains("总") == true && total.toolTip?.contains("每周") == true && total.toolTip?.contains("份") == true, "pool hover identifies the aggregate and its per-account units")
        var quotaClicks = 0
        sidebar.onQuota = { quotaClicks += 1 }
        check(window.makeFirstResponder(current) && window.firstResponder === current, "current quota can receive keyboard focus without a visible window")
        current.performClick(nil)
        check(window.makeFirstResponder(total) && window.firstResponder === total, "total quota can independently receive keyboard focus")
        total.performClick(nil)
        check(quotaClicks == 2, "both quota rows use the existing account-page navigation callback")
        window.makeFirstResponder(nil)

        func nav(_ name: String) -> SidebarItemButton? { all(sidebar).compactMap { $0 as? SidebarItemButton }.first { $0.accessibilityLabel() == name } }
        let longProject = nav(records[2].name)!
        check(longProject.bounds.width > 100 && longProject.toolTip == records[2].path, "long project names retain a useful title area and full-path hover")
        let selectedProject = nav(records[0].name)!, selectedConversation = nav("调整分屏与文件树")!
        check(selectedProject.selected && selectedConversation.selected && !selectedProject.drawsSelection, "owning project remains selected without duplicating the conversation selection fill")
        var projectSelection: UUID?, conversationSelection: String?, recoveryProject: UUID?
        sidebar.onProject = { projectSelection = $0.id }
        sidebar.onConversation = { projectSelection = $0.id; conversationSelection = $1 }
        sidebar.onDeletedConversations = { recoveryProject = $0.id; _ = $1 }
        nav(records[1].name)!.performClick(nil)
        nav("整理图标资源")!.performClick(nil)
        nav("已删除的对话：" + records[1].name)!.performClick(nil)
        check(projectSelection == records[1].id && conversationSelection == "icons" && recoveryProject == records[1].id, "quiet project, conversation and recovery controls preserve owning-project navigation")
        let disclosure = nav("收起项目：" + records[1].name)!
        window.makeFirstResponder(disclosure)
        disclosure.performClick(nil)
        check(nav("整理图标资源") == nil, "redesigned disclosure still collapses its own conversations")
        check((window.firstResponder as? NSView)?.identifier == disclosure.identifier, "collapsing a project preserves keyboard focus on its replacement disclosure")
        nav("展开项目：" + records[1].name)!.performClick(nil)
        check(nav("整理图标资源") != nil, "redesigned disclosure restores its conversations without selecting a different project")
        window.makeFirstResponder(nil)
        host.layoutSubtreeIfNeeded()
        try ChatUITests.snapshot(host, name: "sidebar-redesign-dark")
        window.appearance = NSAppearance(named: .aqua)
        host.needsDisplay = true; all(host).forEach { $0.needsDisplay = true }
        try ChatUITests.snapshot(host, name: "sidebar-redesign-light")
        window.appearance = NSAppearance(named: .darkAqua)

        let scroll = all(sidebar).compactMap { $0 as? NSScrollView }.first!
        window.setContentSize(NSSize(width: 224, height: 640))
        let longGroups = (0..<18).map { index -> SidebarProjectGroup in
            let record = ProjectRecord(id: UUID(), name: "项目 \(index + 1)", path: "/offline-fixtures/project-\(index)", createdAt: now, lastOpenedAt: now, archived: false)
            sidebar.revealProject(record.id)
            return SidebarProjectGroup(project: record, items: [("task-\(index)", "检查本地文件与修改")])
        }
        sidebar.update(groups: longGroups, currentID: longGroups[0].project.id); host.layoutSubtreeIfNeeded()
        let before = quota.convert(quota.bounds, to: host)
        check((scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height && scroll.contentView.bounds.height > 200, "short desktop window keeps a useful scrolling project tree")
        if let document = scroll.documentView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        host.layoutSubtreeIfNeeded()
        let after = quota.convert(quota.bounds, to: host), scrollFrame = scroll.convert(scroll.bounds, to: host)
        check(before == after && after.maxY + 8 < scrollFrame.minY && host.bounds.contains(after), "scrolling a long project list cannot move or cover the persistent quota footer")
        check(all(sidebar).compactMap { $0 as? NSScrollView }.count == 1, "long navigation retains one shared scroll area")
        try ChatUITests.snapshot(host, name: "sidebar-redesign-short-long-list")
        check(!window.isVisible, "sidebar fixtures remain offscreen")

        // A compact contact sheet makes empty, partial and exhausted states
        // visually reviewable without consulting a real account or API.
        let sheet = ThemeSurface(Theme.sidebar)
        let statesWindow = SidebarGaugeFixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 744, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        statesWindow.contentView = sheet; statesWindow.appearance = NSAppearance(named: .darkAqua)
        let cases: [(String, QuotaSummary)] = [("完整缓存", fresh), ("部分未知", partial), ("全部未知", unknown), ("额度耗尽", zero), ("满额缓存", full), ("旧缓存", old)]
        for (index, entry) in cases.enumerated() {
            let title = label(entry.0, size: 12, weight: .medium)
            let gauge = SidebarQuotaView()
            gauge.update(entry.1)
            for view in [title, gauge] { view.translatesAutoresizingMaskIntoConstraints = false; sheet.addSubview(view) }
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: sheet.leadingAnchor, constant: CGFloat(20 + (index % 3) * 244)),
                title.topAnchor.constraint(equalTo: sheet.topAnchor, constant: CGFloat(24 + (index / 3) * 138)),
                gauge.leadingAnchor.constraint(equalTo: title.leadingAnchor), gauge.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
                gauge.widthAnchor.constraint(equalToConstant: 216), gauge.heightAnchor.constraint(equalToConstant: 64)
            ])
        }
        sheet.layoutSubtreeIfNeeded()
        let gauges = all(sheet).compactMap { $0 as? SidebarQuotaView }
        check((gauges[1].totalButton.snapshot?.knownFraction ?? 1) < 1 && gauges[1].totalButton.toolTip?.contains("未知") == true, "partial pool hover and track preserve unknown capacity")
        check(gauges[2].currentButton.snapshot?.remainingFraction == nil && gauges[3].currentButton.snapshot?.remainingFraction == 0, "unknown and exhausted indicators remain visually distinct states")
        check(gauges[2].currentButton.displayedPercentage == "--" && gauges[3].currentButton.displayedPercentage == "0%" && gauges[3].currentButton.tone == .critical, "unknown quota never displays as an exhausted red zero")
        check(gauges[1].totalButton.displayedPercentage == "≥25%" && gauges[1].totalButton.tone == .unknown, "partially known pool displays a neutral lower bound rather than a precise low balance")
        check(gauges[4].currentButton.snapshot?.remainingFraction == 1 && gauges[5].currentButton.snapshot?.stale == true, "full and stale fixtures exercise opposite endpoint and historical markers")
        check(gauges.allSatisfy { gauge in gauge.bounds.contains(gauge.convert(gauge.currentButton.ringRect.insetBy(dx: -2, dy: -2), from: gauge.currentButton)) && gauge.bounds.contains(gauge.convert(gauge.totalButton.ringRect.insetBy(dx: -2, dy: -2), from: gauge.totalButton)) }, "all quota states keep circles and knobs within the fixture bounds")
        try ChatUITests.snapshot(sheet, name: "sidebar-quota-states")
        gauges[0].update(fresh, readFailed: true)
        check(gauges[0].currentButton.toolTip?.contains("读取失败") == true && gauges[0].totalButton.toolTip?.contains("读取失败") == true, "local read failure is disclosed on either quota hover while keeping old measurements")
        check(!statesWindow.isVisible, "quota state contact sheet stays offscreen")
        return count
    }
}
