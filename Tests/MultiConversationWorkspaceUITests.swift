import AppKit

private final class MultiChatFixtureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

enum MultiConversationWorkspaceUITests {
    static func run() throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1; if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ccam-multichat-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let project = ProjectRecord(id: UUID(), name: "window-lab", path: temporary.path, createdAt: Date(), lastOpenedAt: Date(), archived: false)
        let other = ProjectRecord(id: UUID(), name: "second-project", path: temporary.path, createdAt: Date(), lastOpenedAt: Date(), archived: false)
        defer {
            try? FileManager.default.removeItem(at: temporary)
            UserDefaults.standard.removeObject(forKey: WorkspacePaneLayout.key(project.id))
            UserDefaults.standard.removeObject(forKey: WorkspacePaneLayout.key(other.id))
        }
        let first = ChatConversation(id: UUID().uuidString, title: "API 设计", projectID: project.id.uuidString, directory: project.path,
            messages: [ChatMessage(role: "assistant", text: "先定义接口，再比较实现。")], options: ChatOptions(model: "sonnet", permissionMode: .plan, effort: "medium"))
        let second = ChatConversation(id: UUID().uuidString, title: "测试计划", projectID: project.id.uuidString, directory: project.path,
            messages: [ChatMessage(role: "assistant", text: "按输入边界与失败恢复组织测试。")], options: ChatOptions(model: "haiku", permissionMode: .default, effort: "low"))
        try ChatStore(project: project).save([first, second], selectedID: first.id)

        // Real legacy encoding has no conversation identity map.
        struct LegacyLayout: Codable { var root: WorkspacePaneNode; var active: Int }
        let legacy = try JSONEncoder().encode(LegacyLayout(root: .pane(0), active: 0))
        UserDefaults.standard.set(legacy, forKey: WorkspacePaneLayout.key(project.id))
        check(WorkspacePaneLayout.load(projectID: project.id).root == .pane(0), "legacy pane persistence decodes without a conversation identity map")
        let terminal = TerminalWorkspace(frame: .zero)
        let workspace = ProjectWorkspace(terminal: terminal)
        workspace.beforeChatStart = { _, _ in throw AppError.message("Offline test prohibits execution") }
        let host = ThemeSurface(Theme.workspaceCanvas)
        workspace.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(workspace)
        NSLayoutConstraint.activate([workspace.leadingAnchor.constraint(equalTo: host.leadingAnchor), workspace.trailingAnchor.constraint(equalTo: host.trailingAnchor), workspace.topAnchor.constraint(equalTo: host.topAnchor), workspace.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
        let window = MultiChatFixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host; workspace.select(project: project); host.layoutSubtreeIfNeeded()
        check(workspace.visibleConversationIDs == [first.id], "legacy chat slot binds to the selected saved conversation")
        let a = all(workspace).compactMap { $0 as? ProjectChatView }.first!
        let inputA = all(a).compactMap { $0 as? NSTextView }.first { $0.isEditable }!
        inputA.string = "接口草稿只属于第一段对话"; inputA.setSelectedRange(NSRange(location: 2, length: 2))
        check(workspace.splitConversation(id: second.id, axis: .right), "an existing second conversation can open alongside the first")
        host.layoutSubtreeIfNeeded()
        let chats = all(workspace).compactMap { $0 as? ProjectChatView }
        let b = chats.first { $0 !== a }!, inputB = all(b).compactMap { $0 as? NSTextView }.first { $0.isEditable }!
        inputB.string = "测试草稿只属于第二段对话"
        check(chats.count == 2 && Set(workspace.visibleConversationIDs) == Set([first.id, second.id]), "two distinct conversation views are visible")
        check(a.boundConversationID == first.id && b.boundConversationID == second.id, "each pane has a fixed conversation identity")
        let modelA = all(a).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "选择模型" }!
        let modelB = all(b).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "选择模型" }!
        check(modelA.titleOfSelectedItem != modelB.titleOfSelectedItem, "the two conversation panes retain independent model choices")
        let initialPair = WorkspacePaneLayout.load(projectID: project.id)
        check(initialPair.isValid && initialPair.conversationIDs.count == 2, "both conversation bindings persist with the split layout")
        check(workspace.splitConversation(id: second.id, axis: .down) && all(workspace).compactMap { $0 as? ProjectChatView }.count == 2, "opening an already-visible conversation focuses its existing view")
        workspace.selectConversation(id: first.id)
        check(workspace.selectedConversationID == first.id && window.firstResponder === inputA, "selecting a visible conversation focuses that exact input")
        let groups = workspace.sidebarGroups(records: [project], expandedIDs: [project.id])
        check(groups[0].visibleIDs == Set([first.id, second.id]) && groups[0].selectedID == first.id, "sidebar identity follows the focused conversation and both visible panels")
        let titles = all(workspace).compactMap { $0 as? NSTextField }.filter { $0.accessibilityLabel() == "窗格标题" }.map(\.stringValue)
        check(Set(titles) == Set([first.title, second.title]), "panel headers display real conversation names")
        let controls = all(workspace).compactMap { $0 as? WorkspacePaneView }
        check(controls.allSatisfy { $0.header.bounds.height >= 42 && $0.layer?.cornerRadius == 12 }, "modern pane headers and corners use consistent dimensions")
        try ChatUITests.snapshot(host, name: "workspace-two-conversations")

        let paneA = initialPair.pane(for: first.id)!, paneB = initialPair.pane(for: second.id)!
        window.makeFirstResponder(inputA); inputA.setSelectedRange(NSRange(location: 2, length: 2))
        check(workspace.rearrangePaneID(paneB, relativeTo: paneA, position: .center), "conversation panes swap using stable pane identities")
        check(window.firstResponder === inputA && inputA.selectedRange() == NSRange(location: 2, length: 2), "swapping panels preserves the original editor and selected range")
        check(inputA.string == "接口草稿只属于第一段对话" && inputB.string == "测试草稿只属于第二段对话", "drafts do not cross after swapping conversations")
        workspace.openSectionFromNavigation(.files); host.layoutSubtreeIfNeeded()
        check(Set(workspace.visibleConversationIDs) == Set([first.id, second.id]) && workspace.visibleSections == [.chat, .chat, .files], "opening a tool preserves both conversations on the left")
        workspace.openSectionFromNavigation(.terminal)
        check(Set(workspace.visibleConversationIDs) == Set([first.id, second.id]) && workspace.visibleSections.last == .terminal, "switching tools reuses only the companion tool pane")
        workspace.closePane(.terminal); workspace.closeConversationPane(id: second.id)
        check(workspace.visibleConversationIDs == [first.id] && workspace.historyItems.contains { $0.id == second.id }, "closing a panel leaves its conversation record intact")
        check(workspace.splitConversation(id: second.id, axis: .down), "a closed conversation can reopen below the current pane")
        host.layoutSubtreeIfNeeded()
        check(all(workspace).contains { $0 === b } && inputB.string == "测试草稿只属于第二段对话", "reopening uses the same cached view and draft")
        try ChatUITests.snapshot(host, name: "workspace-two-conversations-vertical")
        workspace.select(project: other); workspace.select(project: project); host.layoutSubtreeIfNeeded()
        check(all(workspace).contains { $0 === a } && all(workspace).contains { $0 === b }, "switching projects preserves each existing conversation view")
        window.setContentSize(NSSize(width: 640, height: 480)); host.layoutSubtreeIfNeeded()
        check(workspace.displayedSections.count == 1 && workspace.visibleConversationIDs.count == 2, "a small window temporarily focuses one conversation without discarding the split")
        window.setContentSize(NSSize(width: 1500, height: 900)); host.layoutSubtreeIfNeeded()
        check(workspace.displayedSections.count == 2 && inputA.string == "接口草稿只属于第一段对话" && inputB.string == "测试草稿只属于第二段对话", "restoring window space restores both independent drafts")
        let persisted = WorkspacePaneLayout.load(projectID: project.id)
        let reopened = ProjectWorkspace(terminal: TerminalWorkspace(frame: .zero)); reopened.select(project: project)
        check(Set(reopened.visibleConversationIDs) == Set([first.id, second.id]) && WorkspacePaneLayout.load(projectID: project.id) == persisted, "reopening restores both persisted conversation identities and ratios")

        check(workspace.splitNewConversation(axis: .right), "a new conversation can be created directly in a split")
        check(workspace.splitNewConversation(axis: .down), "a fourth conversation can have its own pane")
        check(workspace.visibleConversationIDs.count == 4 && Set(workspace.visibleConversationIDs).count == 4, "all four visible conversation identities remain unique")
        let beforeLimit = workspace.historyItems.count
        check(!workspace.splitNewConversation(axis: .right) && workspace.historyItems.count == beforeLimit, "at the pane limit, a split attempt creates no hidden extra conversation")
        var duplicate = WorkspacePaneLayout(root: .split(id: UUID(), axis: .right, ratio: 0.5, first: .pane(0), second: .pane(5)), active: 0,
            conversationIDs: [0: first.id, 5: first.id])
        check(!duplicate.isValid, "duplicate conversation bindings cannot be persisted or mounted")
        duplicate.conversationIDs[5] = second.id
        check(duplicate.isValid, "different conversations can use different chat slots")

        // A saved reference to a missing conversation stays explicit, while
        // unrelated valid conversations remain discoverable in the sidebar.
        let unavailable = "missing-conversation-" + UUID().uuidString
        WorkspacePaneLayout(root: .pane(0), active: 0, conversationIDs: [0: unavailable]).save(projectID: project.id)
        let invalidBinding = ProjectWorkspace(terminal: TerminalWorkspace(frame: .zero)); invalidBinding.select(project: project)
        check(invalidBinding.selectedConversationID == unavailable && invalidBinding.visibleConversationIDs == [unavailable], "missing saved conversation references never silently select a different conversation")
        check(invalidBinding.historyItems.contains { $0.id == first.id } && invalidBinding.historyItems.contains { $0.id == second.id }, "an unavailable bound view cannot erase unrelated sidebar conversation entries")
        let recovered = ChatConversation(id: unavailable, title: "恢复的对话", projectID: project.id.uuidString, directory: project.path)
        let restoredStore = try ChatStore(project: project)
        try restoredStore.save(restoredStore.conversations + [recovered], selectedID: first.id)
        let restoredDeadline = Date().addingTimeInterval(2)
        while !invalidBinding.historyItems.contains(where: { $0.id == unavailable }), Date() < restoredDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        invalidBinding.selectConversation(id: unavailable)
        let recoveredView = all(invalidBinding).compactMap { $0 as? ProjectChatView }.first
        check(invalidBinding.historyItems.contains { $0.id == unavailable } && recoveredView?.boundConversationUnavailable == false,
              "restoring a formerly missing binding recreates only its failed startup view")
        let deletionStore = try ChatStore(project: project)
        var deletedItems = deletionStore.conversations
        deletedItems[deletedItems.firstIndex { $0.id == unavailable }!].deletedAt = Date()
        try deletionStore.save(deletedItems, selectedID: first.id)
        WorkspacePaneLayout(root: .pane(0), active: 0, conversationIDs: [0: unavailable]).save(projectID: project.id)
        let deletedStartup = ProjectWorkspace(terminal: TerminalWorkspace(frame: .zero)); deletedStartup.select(project: project)
        let recoveryMenu = deletedStartup.deletedConversationsMenu()
        let recoverItem = recoveryMenu.items.first { $0.title == "恢复的对话" }
        check(recoverItem?.isEnabled == true, "project recovery remains available when the mounted bound runtime could not initialize")
        if let recoverItem, let action = recoverItem.action { _ = NSApp.sendAction(action, to: recoverItem.target, from: recoverItem) }
        let restoredMountedView = all(deletedStartup).compactMap { $0 as? ProjectChatView }.first
        check(restoredMountedView?.boundConversationID == unavailable && restoredMountedView?.boundConversationUnavailable == false,
              "restoring the visible deleted conversation replaces its failed startup placeholder")
        check(!workspace.hasRunning && !terminal.hasRunning && !window.isVisible, "multi-conversation validation runs offline and starts no task or terminal")
        return checks
    }
}
