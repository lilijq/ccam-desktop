import AppKit

/// Uses the real application shell without its launch/refresh lifecycle.
enum WindowChromeUITests {
    static func run() throws -> Int {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            count += 1; if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        func settle(_ view: NSView) {
            for _ in 0..<3 {
                view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }
        let key = WindowSidebarPresentation.preferenceKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ccam-window-test-" + UUID().uuidString)
        let folder = temporary.appendingPathComponent("studio-workspace")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
            try? FileManager.default.removeItem(at: temporary)
        }
        try "# Studio workspace\n\nLocal preview and source files share the same workspace.\n".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let store = try ProjectStore(fileURL: temporary.appendingPathComponent("projects.json"))
        let project = try store.add(directory: folder.path)
        defer { UserDefaults.standard.removeObject(forKey: WorkspacePaneLayout.key(project.id)) }
        let conversations = (0..<16).map { index in
            ChatConversation(id: UUID().uuidString, title: index == 0 ? "整理工作台" : "本地设计记录 \(index)", projectID: project.id.uuidString, directory: project.path,
                             messages: index == 0 ? [
                                ChatMessage(role: "user", text: "把文件放在对话旁边，给网页留出更多空间。"),
                                ChatMessage(role: "assistant", text: "拖动面板标题调整位置，拖动分隔线改变大小。\n\n左侧收起后，项目、额度与设置仍然可以直接打开。")
                             ] : [])
        }
        try ChatStore(project: project).save(conversations, selectedID: conversations[0].id)
        let app = AppDelegate(); app.projectStore = store; app.selected = 2
        app.accounts = try JSONDecoder().decode([Account].self, from: Data(#"[{"name":"work","default":true},{"name":"personal"}]"#.utf8))
        app.usage = [
            AccountUsage(name: "work", status: "ok", error: nil, windows: [UsageWindow(label: "5 小时额度", used: 24, reset: nil)], raw: [:]),
            AccountUsage(name: "personal", status: "ok", error: nil, windows: [UsageWindow(label: "5 小时额度", used: 64, reset: nil)], raw: [:])
        ]
        app.makeWindow(visible: false)
        defer { app.window.orderOut(nil); app.window.delegate = nil; app.projectWorkspace.stopAll(); app.terminalWorkspace.stopAll() }
        let window = app.window!, host = window.contentView!
        window.setContentSize(NSSize(width: 1240, height: 820))
        app.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window)); settle(host)
        let all = ChatUITests.all
        let sidebar = all(host).compactMap { $0 as? WorkspaceSidebar }.first!
        let rail = all(host).compactMap { $0 as? WorkspaceSidebarRail }.first!
        let drag = all(host).compactMap { $0 as? WindowDragSurface }.first!
        let input = all(app.projectWorkspace).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "对话输入" }!
        let draft = "保留这段草稿，再调整窗口布局。"
        input.string = draft
        let chat = all(app.projectWorkspace).compactMap { $0 as? ProjectChatView }.first!
        chat.textDidChange(Notification(name: NSText.didChangeNotification))
        check(!sidebar.isHidden && rail.isHidden && abs(sidebar.superview!.bounds.width - 224) < 1, "desktop starts with the full project sidebar")
        check(!window.isMovableByWindowBackground, "editable workspace content never becomes a window drag surface")
        check(drag.acceptsFirstMouse(for: nil), "title strip accepts the first drag even when the window is inactive")
        let dragRect = drag.convert(drag.bounds, to: host)
        check(dragRect.minX >= 90 && abs(dragRect.height - 36) < 1 && dragRect.maxY == host.bounds.maxY, "dedicated title drag strip avoids traffic lights and content controls")
        check(!window.isVisible && app.timer == nil && !app.refreshing, "isolated application shell starts no lifecycle timer or account query")
        _ = app.projectWorkspace.splitActive(adding: .files, axis: .right)
        app.projectWorkspace.showSection(.chat); settle(host)
        window.makeFirstResponder(input)
        let contentWidth = app.projectWorkspace.bounds.width
        try ChatUITests.snapshot(host, name: "window-expanded-sidebar")
        let scroll = all(sidebar).compactMap { $0 as? NSScrollView }.first!
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 70)); scroll.reflectScrolledClipView(scroll.contentView)
        let scrollOrigin = scroll.contentView.bounds.origin
        let expandedIDs = sidebar.expandedProjectIDs
        let collapse = all(sidebar).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "收起侧边栏" }!
        collapse.performClick(nil); settle(host)
        check(app.sidebarCollapsed && UserDefaults.standard.bool(forKey: key), "visible collapse action persists the manual sidebar preference")
        check(sidebar.isHidden && !rail.isHidden && abs(rail.superview!.bounds.width - 56) < 1, "manual collapse reveals a 56-point icon rail")
        check(app.conversationMenuAnchor === rail.projectsButton && !app.conversationMenuAnchor.isHiddenOrHasHiddenAncestor, "rail conversation management anchors to the visible project control")
        check(app.projectWorkspace.bounds.width > contentWidth + 160, "collapsing returns the saved navigation width to the workspace")
        check(input.string == draft && input.window === window && window.firstResponder === input, "collapsing keeps the same live draft and keyboard responder")
        check(rail.quotaView.currentButton.ringOnly && rail.quotaView.totalButton.ringOnly, "rail keeps both independent quota rings without clipped labels")
        for button in [rail.quotaView.currentButton, rail.quotaView.totalButton] {
            check(button.bounds.contains(button.ringRect.insetBy(dx: -2, dy: -2)), "rail quota circle fits its hit target")
            check(button.toolTip?.contains("点击进入账号与额度") == true && button.accessibilityLabel()?.contains("剩余") == true, "compact quota retains complete hover and accessibility information")
        }
        check(AppDelegate().sidebarCollapsed, "a fresh application delegate restores the manual rail preference")
        try ChatUITests.snapshot(host, name: "window-collapsed-sidebar")
        window.setContentSize(NSSize(width: 640, height: 820))
        app.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window)); settle(host)
        check(app.sidebarCollapsed && sidebar.superview!.isHidden, "temporary narrow layout does not erase the manual rail preference")
        check(app.conversationMenuAnchor.accessibilityLabel() == "项目导航" && !app.conversationMenuAnchor.isHiddenOrHasHiddenAncestor, "narrow conversation management uses the compact navigation anchor")
        check(all(host).compactMap { $0 as? NSButton }.contains { $0.accessibilityLabel() == "项目导航" && !$0.isHiddenOrHasHiddenAncestor }, "narrow layout retains an accessible project navigation control")
        window.setContentSize(NSSize(width: 1240, height: 820))
        app.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window)); settle(host)
        check(!rail.isHiddenOrHasHiddenAncestor && sidebar.isHidden, "widening restores the rail instead of unexpectedly expanding navigation")
        rail.expandButton.performClick(nil); settle(host)
        check(!app.sidebarCollapsed && !sidebar.isHidden && rail.isHidden, "rail expand button reverses manual collapse")
        check(sidebar.expandedProjectIDs == expandedIDs && scroll.contentView.bounds.origin == scrollOrigin, "expanded project tree and scroll position survive collapse and narrow-window changes")
        check(input.string == draft && !app.projectWorkspace.hasRunning && !app.terminalWorkspace.hasRunning, "all shell operations preserve the draft and start no model or terminal process")
        app.toggleSidebar(); settle(host)
        var quotaInvocations = 0, manageInvocations = 0, projectsInvocations = 0
        rail.onQuota = { quotaInvocations += 1 }
        rail.onManage = { anchor in if anchor === rail.manageButton { manageInvocations += 1 } }
        rail.onProjects = { anchor in if anchor === rail.projectsButton { projectsInvocations += 1 } }
        rail.quotaView.currentButton.performClick(nil); rail.quotaView.totalButton.performClick(nil)
        rail.manageButton.performClick(nil); rail.projectsButton.performClick(nil)
        check(quotaInvocations == 2 && manageInvocations == 1 && projectsInvocations == 1, "rail controls invoke navigation using their visible anchors")
        let unknown = QuotaSummary.make(accounts: [], usage: [])
        rail.updateQuota(unknown, readFailed: true)
        check(rail.quotaView.currentButton.displayedPercentage == "--" && rail.quotaView.currentButton.toolTip?.contains("读取失败") == true, "unknown rail quota keeps failure context instead of inventing a balance")

        // A running conversation is a status, not a project-wide navigation lock.
        // Intercept callbacks so no menu, task or model process is opened here.
        let concurrentSidebar = WorkspaceSidebar(frame: NSRect(x: 0, y: 0, width: 224, height: 700))
        let concurrentWindow = NSWindow(contentRect: concurrentSidebar.frame, styleMask: [.titled], backing: .buffered, defer: false)
        concurrentWindow.contentView = concurrentSidebar
        defer { concurrentWindow.orderOut(nil) }
        let firstID = conversations[0].id, secondID = conversations[1].id, thirdID = conversations[2].id
        var group = SidebarProjectGroup(project: project, items: Array(conversations.prefix(3)).map { ($0.id, $0.title) },
                                        selectedID: firstID, running: true, visibleIDs: [firstID, secondID], runningIDs: [firstID])
        var created = 0, selectedConversation: String?, actionConversation: String?, recoveryProject: UUID?
        var actionAnchor: NSView?
        concurrentSidebar.onNewConversation = { created += 1 }
        concurrentSidebar.onConversation = { record, id in if record.id == project.id { selectedConversation = id } }
        concurrentSidebar.onConversationActions = { record, id, anchor in
            if record.id == project.id { actionConversation = id; actionAnchor = anchor }
        }
        concurrentSidebar.onDeletedConversations = { record, _ in recoveryProject = record.id }
        concurrentSidebar.update(groups: [group], currentID: project.id); settle(concurrentSidebar)
        func concurrentButton(_ identifier: String) -> SidebarItemButton {
            all(concurrentSidebar).compactMap { $0 as? SidebarItemButton }.first { $0.identifier?.rawValue == identifier }!
        }
        func conversationButton(_ id: String) -> SidebarItemButton { concurrentButton("conversation:" + project.id.uuidString + ":" + id) }
        func conversationAction(_ id: String) -> SidebarItemButton { concurrentButton("actions:" + project.id.uuidString + ":" + id) }
        let create = all(concurrentSidebar).compactMap { $0 as? SidebarItemButton }.first { $0.accessibilityLabel() == "新对话" }!
        check(create.isEnabled, "a running project keeps the new-conversation button enabled")
        create.performClick(nil)
        check(created == 1, "a running project can request a separate new conversation")
        for id in [firstID, secondID, thirdID] {
            let conversation = conversationButton(id), actions = conversationAction(id)
            check(conversation.isEnabled && actions.isEnabled, "running, visible and unopened conversations all remain navigable")
            conversation.performClick(nil)
            check(selectedConversation == id, "conversation navigation dispatches the exact requested identity while its project is running")
            actions.performClick(nil)
            check(actionConversation == id && actionAnchor === actions, "conversation action menus use the exact target identity and visible row anchor")
        }
        let deleted = concurrentButton("deleted:" + project.id.uuidString)
        check(deleted.isEnabled, "recovering other conversations remains available during a running turn")
        deleted.performClick(nil)
        check(recoveryProject == project.id, "recovery dispatch remains project scoped without stopping a task")
        let projectRow = concurrentButton("project:" + project.id.uuidString)
        check(projectRow.symbol == "circle.dotted" && projectRow.toolTip?.contains("对话运行中") == true, "the project keeps its running indicator without disabling navigation")
        check(conversationButton(firstID).toolTip?.contains("对话运行中") == true && conversationButton(firstID).selected,
              "the focused running conversation exposes its own status")
        check(conversationButton(secondID).toolTip?.contains("已在工作台打开") == true && !conversationButton(secondID).selected,
              "another visible conversation is distinguished from the focused running conversation")
        check(conversationButton(thirdID).toolTip == conversations[2].title,
              "an unopened conversation does not inherit a different conversation's visible or running status")
        try ChatUITests.snapshot(concurrentSidebar, name: "sidebar-concurrent-conversations")
        group.running = false; group.runningIDs = []; group.visibleIDs = [secondID]; group.selectedID = secondID
        concurrentSidebar.update(groups: [group], currentID: project.id); settle(concurrentSidebar)
        check(concurrentButton("project:" + project.id.uuidString).symbol == "folder" && conversationButton(firstID).toolTip == conversations[0].title,
              "finishing a background turn removes only its former running status")
        check(conversationButton(secondID).selected && conversationButton(secondID).toolTip?.contains("已在工作台打开") == true,
              "sidebar state refresh keeps the separately focused conversation visible")
        check(!concurrentWindow.isVisible && !app.projectWorkspace.hasRunning && !app.terminalWorkspace.hasRunning,
              "concurrent-sidebar validation starts no model, terminal or visible application window")
        return count
    }
}
