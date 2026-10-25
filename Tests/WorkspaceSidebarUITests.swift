import AppKit

private final class SidebarFixtureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

enum WorkspaceSidebarUITests {
    static func run() throws -> Int {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            count += 1
            if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccam-sidebar-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let records = try ["Alpha project", "Beta project"].map { name -> ProjectRecord in
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return ProjectRecord(id: UUID(), name: name, path: folder.path, createdAt: Date(), lastOpenedAt: Date(), archived: false)
        }
        let alpha = ChatConversation(id: UUID().uuidString, title: "设计登录流程", projectID: records[0].id.uuidString, directory: records[0].path)
        var deleted = ChatConversation(id: UUID().uuidString, title: "已删除", projectID: records[0].id.uuidString, directory: records[0].path)
        deleted.deletedAt = Date()
        var beta = ChatConversation(id: UUID().uuidString, title: "检查文件改动", projectID: records[1].id.uuidString, directory: records[1].path)
        let storeA = try ChatStore(project: records[0]), storeB = try ChatStore(project: records[1])
        try storeA.save([alpha, deleted], selectedID: alpha.id)
        try storeB.save([beta], selectedID: beta.id)
        let workspace = ProjectWorkspace(terminal: TerminalWorkspace(frame: .zero))
        let collapsed = workspace.sidebarGroups(records: records, expandedIDs: [])
        check(collapsed.allSatisfy { $0.items.isEmpty }, "collapsed unmounted projects do not load conversation lists")
        let sameSecond = floor(Date().timeIntervalSinceReferenceDate)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceReferenceDate: sameSecond + 0.1)], ofItemAtPath: storeB.fileURL.path)
        let initial = workspace.sidebarGroups(records: records, expandedIDs: Set(records.map(\.id)))
        check(initial[0].items.map(\.id) == [alpha.id] && initial[1].items.map(\.id) == [beta.id], "local histories stay with their project and omit deleted records")
        check(workspace.selectedConversationID == nil, "reading unmounted history does not select or mount another chat")
        beta.title = "检查代码改动"
        try storeB.save([beta], selectedID: beta.id)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceReferenceDate: sameSecond + 0.8)], ofItemAtPath: storeB.fileURL.path)
        let changed = workspace.sidebarGroups(records: records, expandedIDs: Set(records.map(\.id)))
        check(changed[1].items.first?.title == beta.title, "same-second same-length history changes invalidate the metadata cache")
        workspace.select(project: records[0]); workspace.newConversation()
        let selected = workspace.selectedConversationID
        let mounted = workspace.sidebarGroups(records: records, expandedIDs: Set(records.map(\.id)))
        check(mounted[0].items.count == 2, "mounted project histories use current in-memory conversations")
        check(workspace.selectedConversationID == selected, "background project history reads do not change the active conversation")

        let sidebar = WorkspaceSidebar(frame: NSRect(x: 0, y: 0, width: 224, height: 640))
        let window = SidebarFixtureWindow(contentRect: sidebar.frame, styleMask: [.titled], backing: .buffered, defer: false)
        let host = ThemeSurface(Theme.sidebar); host.addSubview(sidebar); sidebar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([sidebar.topAnchor.constraint(equalTo: host.topAnchor), sidebar.bottomAnchor.constraint(equalTo: host.bottomAnchor), sidebar.leadingAnchor.constraint(equalTo: host.leadingAnchor), sidebar.trailingAnchor.constraint(equalTo: host.trailingAnchor)])
        window.contentView = host
        var selectedProject: UUID?, selectedConversation: String?, actionProject: UUID?, deletedProject: UUID?
        sidebar.onProject = { selectedProject = $0.id }
        sidebar.onConversation = { selectedProject = $0.id; selectedConversation = $1 }
        sidebar.onConversationActions = { actionProject = $0.id; selectedConversation = $1; _ = $2 }
        sidebar.onDeletedConversations = { deletedProject = $0.id; _ = $1 }
        sidebar.update(groups: initial, currentID: records[0].id); host.layoutSubtreeIfNeeded()
        func button(_ label: String) -> SidebarItemButton? { all(sidebar).compactMap { $0 as? SidebarItemButton }.first { $0.accessibilityLabel() == label } }
        check(sidebar.expandedProjectIDs == [records[0].id] && button(alpha.title) != nil && button("检查文件改动") == nil, "only the selected project opens initially")
        check(button("最近对话") == nil, "there is no detached top-level recent-conversation list")
        button("展开项目：" + records[1].name)!.performClick(nil)
        check(selectedProject == nil && button("检查文件改动") != nil, "expanding a background project shows its own conversations without switching projects")
        button("检查文件改动")!.performClick(nil)
        check(selectedProject == records[1].id && selectedConversation == beta.id, "conversation selection carries its owning project")
        button("对话操作：检查文件改动")!.performClick(nil)
        check(actionProject == records[1].id && selectedConversation == beta.id, "conversation actions retain the owning project")
        button("已删除的对话：" + records[1].name)!.performClick(nil)
        check(deletedProject == records[1].id, "each recovery button targets its project")
        sidebar.update(groups: initial, currentID: records[1].id)
        check(button("检查文件改动")?.selected == true && button(alpha.title)?.selected == false, "conversation highlight is scoped to the active project")
        button("收起项目：" + records[1].name)!.performClick(nil)
        sidebar.update(groups: changed, currentID: records[1].id)
        check(!sidebar.expandedProjectIDs.contains(records[1].id) && button(beta.title) == nil, "stream/state updates preserve a manual collapse")
        sidebar.revealProject(records[1].id); sidebar.update(groups: changed, currentID: records[1].id)
        check(button(beta.title) != nil, "an explicit new-conversation action can reveal its project")
        var runningGroups = changed; runningGroups[0].running = true
        sidebar.update(groups: runningGroups, currentID: records[1].id)
        check(button(alpha.title)?.isEnabled == true && button(beta.title)?.isEnabled == true, "running tasks keep navigation available within their project and across projects")
        sidebar.update(groups: changed, currentID: records[1].id); host.layoutSubtreeIfNeeded()
        let title = button(beta.title)!, more = button("对话操作：" + beta.title)!
        check(title.bounds.width > 130 && abs(title.bounds.width + more.bounds.width - title.superview!.bounds.width) < 1, "nested conversation titles fill their row beside the action button")
        check(all(sidebar).compactMap { $0 as? NSScrollView }.count == 1, "projects and their conversations share one scroll area")
        check((title.enclosingScrollView?.contentView.bounds.height ?? 0) > 150, "project tree retains useful scroll space above the persistent quota footer")
        check(!window.isVisible, "project tree validation is offscreen")
        try ChatUITests.snapshot(host, name: "project-conversations-sidebar")
        return count
    }
}
