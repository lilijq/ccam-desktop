import AppKit

private final class SplitFixtureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

enum WorkspaceSplitUITests {
    static func run() throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1; if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        var model = WorkspacePaneLayout()
        check(model.split(adding: 1, axis: .right), "a new section can split beside the active pane")
        check(!model.split(adding: 1, axis: .down), "a section cannot mount its mutable view twice")
        check(model.split(adding: 3, axis: .down) && model.isValid, "nested orthogonal splits are valid")
        model.select(0); check(model.root.sections == [0, 1, 3] && model.active == 0, "selecting an existing pane preserves the layout")
        model.select(2); check(model.root.sections == [2, 1, 3], "selecting a hidden section replaces only the active pane")
        check(model.close(1) && model.root.sections == [2, 3], "closing a nested pane collapses only its empty branch")
        check(model.close(3) && !model.close(2), "the last pane cannot be closed")
        let invalid = WorkspacePaneLayout(root: .split(id: UUID(), axis: .right, ratio: 0.5, first: .pane(0), second: .pane(0)), active: 0)
        check(!invalid.isValid, "duplicate-section persisted layouts are rejected")

        // Test every ordered edge/center move on a populated tree. Moving is
        // atomic and preserves the set of unique content owners.
        let dragModel = WorkspacePaneLayout(root: .split(id: UUID(), axis: .right, ratio: 0.62,
            first: .split(id: UUID(), axis: .down, ratio: 0.35, first: .pane(0), second: .pane(1)),
            second: .split(id: UUID(), axis: .down, ratio: 0.7, first: .pane(2), second: .pane(3))), active: 0)
        for source in 0...3 {
            for target in 0...3 where source != target {
                for position in WorkspacePaneDropPosition.allCases {
                    var moved = dragModel
                    check(moved.move(source, relativeTo: target, position: position) && moved.isValid && Set(moved.root.sections) == Set(0...3) && moved.active == source,
                          "every valid pane drop retains all unique panes and produces a valid tree")
                    if position == .center {
                        check(moved.root == dragModel.root.swapping(source, target), "center drops preserve exact split identities and ratios while swapping slots")
                    }
                }
            }
        }
        var rejected = dragModel
        check(!rejected.move(0, relativeTo: 0, position: .right) && rejected == dragModel, "self drops leave layout and selection unchanged")
        check(!rejected.move(4, relativeTo: 0, position: .left) && rejected == dragModel, "hidden source cannot mutate layout")
        check(!rejected.move(0, relativeTo: 9, position: .center) && rejected == dragModel, "invalid destination cannot mutate layout")
        let dropBounds = NSRect(x: 0, y: 0, width: 400, height: 300)
        check(WorkspacePaneDropPosition.at(NSPoint(x: 200, y: 150), in: dropBounds) == .center, "the center is an exchange target")
        check(WorkspacePaneDropPosition.at(NSPoint(x: 5, y: 150), in: dropBounds) == .left && WorkspacePaneDropPosition.at(NSPoint(x: 395, y: 150), in: dropBounds) == .right, "horizontal edges select their own docking directions")
        check(WorkspacePaneDropPosition.at(NSPoint(x: 200, y: 295), in: dropBounds) == .top && WorkspacePaneDropPosition.at(NSPoint(x: 200, y: 5), in: dropBounds) == .bottom, "vertical drop coordinates match native AppKit orientation")
        check(WorkspacePaneDropPosition.at(NSPoint(x: -1, y: 150), in: dropBounds) == nil, "outside drops have no target")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ccam-split-test-" + UUID().uuidString)
        let root = temporary.appendingPathComponent("sample-project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The fixture has no remote and uses only local Git status/diff reads.
        let initialize = Process(); initialize.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        initialize.arguments = ["init", "--quiet", "--initial-branch=main", "--template=", root.path]
        initialize.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        try initialize.run(); initialize.waitUntilExit()
        check(initialize.terminationStatus == 0, "the split fixture initializes only a local Git repository")
        let project = ProjectRecord(id: UUID(), name: "sample-project", path: root.path, createdAt: Date(), lastOpenedAt: Date(), archived: false)
        let other = ProjectRecord(id: UUID(), name: "Another project", path: root.path, createdAt: Date(), lastOpenedAt: Date(), archived: false)
        defer {
            try? FileManager.default.removeItem(at: temporary)
            UserDefaults.standard.removeObject(forKey: WorkspacePaneLayout.key(project.id))
            UserDefaults.standard.removeObject(forKey: WorkspacePaneLayout.key(other.id))
        }
        try "fn main() {\n    let message = \"Hello from Rust\";\n    println!(\"{}\", message);\n}\n".write(to: root.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
        let conversation = ChatConversation(id: UUID().uuidString, title: "比较文件和改动", projectID: project.id.uuidString, directory: root.path,
                                            messages: [ChatMessage(role: "user", text: "把文件和 Git 放在对话旁边，终端也保留。"),
                                                       ChatMessage(role: "assistant", text: "右侧展示入口文件，下方同时显示 Git 和终端。拖动分隔线可以调整空间。\n\n这是离线界面示例，未执行模型请求。")],
                                            options: ChatOptions(model: "sonnet", permissionMode: .plan, effort: "medium"))
        try ChatStore(project: project).save([conversation], selectedID: conversation.id)
        let terminal = TerminalWorkspace(frame: .zero)
        let workspace = ProjectWorkspace(terminal: terminal)
        workspace.beforeChatStart = { _, _ in throw AppError.message("Offline split test prohibits execution") }
        let window = SplitFixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 850), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = ThemeSurface(Theme.background)
        workspace.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(workspace)
        NSLayoutConstraint.activate([workspace.topAnchor.constraint(equalTo: host.topAnchor), workspace.bottomAnchor.constraint(equalTo: host.bottomAnchor), workspace.leadingAnchor.constraint(equalTo: host.leadingAnchor), workspace.trailingAnchor.constraint(equalTo: host.trailingAnchor)])
        window.contentView = host; workspace.select(project: project); host.layoutSubtreeIfNeeded()
        let chat = all(workspace).compactMap { $0 as? ProjectChatView }.first!
        let input = all(chat).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "对话输入" }!
        let draft = "继续检查错误处理"
        input.string = draft; chat.textDidChange(Notification(name: NSText.didChangeNotification))
        check(workspace.visibleSections == [.chat] && workspace.displayedSections == [.chat], "new projects begin with a single usable chat")
        check(workspace.splitActive(adding: .files, axis: .right), "files open beside the chat")
        workspace.layoutSubtreeIfNeeded()
        check(workspace.visibleSections == [.chat, .files] && workspace.displayedSections.count == 2, "both sides remain visible at desktop size")
        let files = all(workspace).compactMap { $0 as? ProjectFilesView }.first!
        files.openFile("main.rs")
        let fileDeadline = Date().addingTimeInterval(3)
        func hasRustSource() -> Bool { all(files).compactMap { $0 as? NSTextView }.contains { $0.string.contains("Hello from Rust") } }
        while !hasRustSource(), Date() < fileDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        check(hasRustSource(), "a Rust file opens in the split file editor without running code")
        workspace.showSection(.files)
        check((window.firstResponder as? NSView)?.isDescendant(of: files) == true, "explicit file navigation moves keyboard input to its editor")
        check(workspace.splitActive(adding: .terminal, axis: .down), "the right column can split vertically for a terminal")
        check(window.firstResponder !== input, "opening an empty terminal pane does not leave typing directed at chat")
        // Feed display text only. No shell, cargo command or PTY process starts.
        let terminalFixture = TerminalSessionView(title: "离线示例", directory: root.path)
        terminalFixture.terminal.feed(text: "\u{001B}[2m# 离线界面示例 · 未执行命令\u{001B}[0m\r\n$ cargo check\r\n\u{001B}[32m    Checking\u{001B}[0m sample-project v0.1.0\r\n\u{001B}[32m    Finished\u{001B}[0m dev profile\r\n\r\n$ ")
        let terminalTab = NSTabViewItem(identifier: "offline-split-fixture"); terminalTab.label = "离线示例"; terminalTab.view = terminalFixture
        terminal.tabs.addTabViewItem(terminalTab); terminal.emptyState.isHidden = true
        workspace.showSection(.chat)
        check(workspace.splitActive(adding: .git, axis: .down), "a fourth unique section can occupy the lower left")
        let git = all(workspace).compactMap { $0 as? ProjectGitView }.first!
        check((window.firstResponder as? NSView)?.isDescendant(of: git) == true, "explicit Git navigation moves keyboard input to its change list")
        let gitFiles = all(git).compactMap { $0 as? NSTableView }.first!
        let gitDeadline = Date().addingTimeInterval(4)
        while gitFiles.numberOfRows == 0, Date() < gitDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check(gitFiles.numberOfRows == 1, "the Git pane lists the local Rust fixture")
        gitFiles.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let difference = all(git).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "文件差异" }!
        while !difference.string.contains("Hello from Rust"), Date() < gitDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check(difference.string.contains("Hello from Rust"), "the Git pane loads a real local diff without remote access")
        workspace.layoutSubtreeIfNeeded()
        check(Set(workspace.visibleSections.map(\.rawValue)) == Set(0...3) && workspace.displayedSections.count == 4, "all four workspace capabilities can coexist")
        workspace.showSection(.files)
        let paneTitles = all(workspace).compactMap { $0 as? NSTextField }.filter { $0.accessibilityLabel() == "窗格标题" }.map(\.stringValue)
        check(workspace.selectedSection == .files && paneTitles.contains("比较文件和改动"), "pane headers use the actual conversation title while focusing another pane")
        check(all(workspace).compactMap { $0 as? ProjectChatView }.count == 1 && all(workspace).compactMap { $0 as? TerminalWorkspace }.count == 1, "splitting never duplicates a chat runtime or terminal host")
        check(input.string == draft && input.window === window, "draft input survives mounting into a nested pane")
        check(!terminal.hasRunning && !workspace.hasRunning && !terminalFixture.session.running, "opening panes and rendering sample output starts no terminal or Claude processes")
        let panes = all(workspace).compactMap { $0 as? WorkspacePaneView }
        check(panes.allSatisfy { $0.bounds.width >= 340 && $0.bounds.height >= 280 }, "desktop panes respect usable minimum sizes")
        let divider = all(workspace).compactMap { $0 as? WorkspaceDividerView }.first!
        divider.setPosition(600, ofDividerAt: 0)
        let afterDrag = WorkspacePaneLayout.load(projectID: project.id)
        if case .split(_, _, let ratio, _, _) = afterDrag.root {
            check(abs(ratio - 600 / 1432) < 0.02, "divider dragging persists its actual split ratio")
        } else { check(false, "split layout remains present after dragging") }
        workspace.showSection(.chat)
        workspace.togglePaneMaximization(.chat); workspace.layoutSubtreeIfNeeded()
        check(workspace.visibleSections.count == 4 && workspace.displayedSections == [.chat], "maximizing hides siblings without deleting their layout")
        workspace.togglePaneMaximization(.chat); workspace.layoutSubtreeIfNeeded()
        check(workspace.displayedSections.count == 4 && input.string == draft, "restoring maximized panes preserves the original draft")
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        try ChatUITests.snapshot(host, name: "workspace-four-panes")
        window.makeFirstResponder(input)
        window.setContentSize(NSSize(width: 640, height: 850)); workspace.layoutSubtreeIfNeeded()
        check(workspace.isSinglePanePresentation && workspace.displayedSections == [.chat] && workspace.visibleSections.count == 4, "a narrow window temporarily focuses one pane without losing the split layout")
        check(window.firstResponder === input, "temporarily focusing a narrow pane preserves keyboard input")
        workspace.togglePaneMaximization(.chat)
        check(workspace.isSinglePanePresentation && workspace.visibleSections.count == 4, "explicit maximization keeps the saved multi-pane layout")
        workspace.togglePaneMaximization(.chat)
        check(all(workspace).compactMap { $0 as? NSButton }.contains { $0.accessibilityLabel() == "窗格操作：比较文件和改动" }, "narrow panes keep their compact operations menu")
        try ChatUITests.snapshot(host, name: "workspace-compact-focus")
        window.setContentSize(NSSize(width: 1440, height: 850)); workspace.layoutSubtreeIfNeeded()
        check(workspace.displayedSections.count == 4, "widening the window automatically restores the saved split arrangement")
        check(window.firstResponder === input, "restoring the split layout preserves the active text responder")
        workspace.showSection(.git)
        let commit = all(git).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "提交说明" }!
        let commitDeadline = Date().addingTimeInterval(4)
        while !commit.isEnabled, Date() < commitDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        check(window.makeFirstResponder(commit) && window.firstResponder is NSTextView, "the commit field is editable after its local Git refresh")
        guard let commitEditor = window.firstResponder as? NSTextView else { return checks }
        commitEditor.insertText("Keep commit draft", replacementRange: commitEditor.selectedRange())
        commitEditor.setSelectedRange(NSRange(location: 5, length: 6))
        window.setContentSize(NSSize(width: 640, height: 850)); workspace.layoutSubtreeIfNeeded()
        check(commit.currentEditor() === window.firstResponder && (window.firstResponder as? NSTextView)?.selectedRange() == NSRange(location: 5, length: 6), "compact layout preserves a shared field editor and its selected range")
        window.setContentSize(NSSize(width: 1440, height: 850)); workspace.layoutSubtreeIfNeeded()
        check(commit.currentEditor() === window.firstResponder && commit.stringValue == "Keep commit draft", "restored split preserves the unfinished Git commit field")
        guard let restoredCommitEditor = window.firstResponder as? NSTextView else { check(false, "restored commit field must accept text"); return checks }
        restoredCommitEditor.insertText("changed", replacementRange: restoredCommitEditor.selectedRange())
        check(restoredCommitEditor.string == "Keep changed draft", "typing continues at the same selected range after a split resize")
        workspace.showSection(.files)
        let originalLayout = WorkspacePaneLayout.load(projectID: project.id)
        workspace.select(project: other); workspace.layoutSubtreeIfNeeded()
        check(workspace.visibleSections == [.chat], "another project begins with its own independent layout")
        workspace.select(project: project); workspace.layoutSubtreeIfNeeded()
        check(workspace.selectedSection == .files && workspace.visibleSections.count == 4, "switching projects restores active pane and layout")
        check(all(workspace).contains { $0 === chat } && input.string == draft, "switching projects retains the same live draft view")
        check(WorkspacePaneLayout.load(projectID: project.id) == originalLayout, "project switching retains divider ratios")
        let reopened = ProjectWorkspace(terminal: TerminalWorkspace(frame: .zero)); reopened.select(project: project)
        check(reopened.visibleSections.count == 4 && reopened.selectedSection == .files, "a reopened workspace restores its persisted layout")
        // Move the exact live objects, with an unfinished editor selection.
        workspace.showSection(.chat); window.makeFirstResponder(input)
        input.setSelectedRange(NSRange(location: 3, length: 4))
        let liveChat = chat, liveFiles = files, liveTerminal = terminal
        let beforeRearrange = WorkspacePaneLayout.load(projectID: project.id)
        let dragPanes = all(workspace).compactMap { $0 as? WorkspacePaneView }
        let sourcePane = dragPanes.first { $0.section == 0 }!, targetPane = dragPanes.first { $0.section == 1 }!
        host.layoutSubtreeIfNeeded(); sourcePane.layoutSubtreeIfNeeded()
        let dragHandle = all(sourcePane.header).compactMap { $0 as? WorkspacePaneDragHandle }.first
        check(dragHandle != nil && (dragHandle?.bounds.width ?? 0) >= 24 && (dragHandle?.bounds.height ?? 0) >= 28,
              "the pane drag handle is visible and has a comfortably sized hit area: \(String(describing: dragHandle?.bounds))")
        check(sourcePane.header.bounds.height >= 40, "larger drag controls fit inside the pane title bar")
        check(sourcePane.header.acceptsFirstMouse(for: nil), "pane title accepts the first drag in an inactive window")
        check(targetPane.acceptsDrag(source: sourcePane.header), "a local pane accepts a matching same-project source")
        check(!sourcePane.acceptsDrag(source: sourcePane.header), "dragging into the source pane is rejected")
        let foreignHeader = WorkspacePaneHeader(section: 0, title: "Other project")
        foreignHeader.context = UUID()
        check(!targetPane.acceptsDrag(source: foreignHeader), "another project or detached source cannot rearrange the layout")
        check(!workspace.rearrangePane(.chat, relativeTo: .chat, position: .top) && WorkspacePaneLayout.load(projectID: project.id) == beforeRearrange,
              "rejected live moves preserve saved layout and selection")
        check(workspace.rearrangePane(.files, relativeTo: .chat, position: .center), "live center drop swaps pane content owners")
        check(all(workspace).contains { $0 === liveChat } && all(workspace).contains { $0 === liveFiles } && all(workspace).contains { $0 === liveTerminal }, "rearranging retains chat, editor and terminal view identities")
        check(input.string == draft && input.selectedRange() == NSRange(location: 3, length: 4) && window.firstResponder === input, "pane movement preserves draft, insertion range and keyboard focus")
        check(!targetPane.acceptsDrag(source: sourcePane.header), "a source from an obsolete render cannot be reused")
        check(workspace.rearrangePane(.files, relativeTo: .chat, position: .center), "a second center drop can restore the original arrangement")
        try ChatUITests.snapshot(host, name: "workspace-draggable-panes")
        workspace.closePane(.git); workspace.layoutSubtreeIfNeeded()
        check(workspace.visibleSections == [.chat, .files, .terminal] && input.string == draft, "closing one pane leaves its neighbors and draft intact")
        workspace.showSection(.chat); workspace.resetLayout(); workspace.layoutSubtreeIfNeeded()
        check(workspace.visibleSections == [.chat] && input.string == draft, "closing other panes preserves the selected chat")
        // Only top-level tool navigation uses the companion layout policy.
        workspace.showSection(.files)
        workspace.openSectionFromNavigation(.files); workspace.layoutSubtreeIfNeeded()
        check(workspace.visibleSections == [.chat, .files], "clicking a single existing tool also restores chat on its left")
        workspace.showSection(.chat); workspace.resetLayout()
        workspace.openSectionFromNavigation(.files); workspace.layoutSubtreeIfNeeded()
        check(workspace.visibleSections == [.chat, .files] && workspace.selectedSection == .files, "top Files navigation opens to the right while retaining chat")
        workspace.togglePaneMaximization(.chat)
        workspace.openSectionFromNavigation(.files); workspace.layoutSubtreeIfNeeded()
        check(workspace.displayedSections == [.chat, .files] && !workspace.isSinglePanePresentation, "top tool navigation restores the companion layout from a maximized conversation")
        workspace.openSectionFromNavigation(.git); workspace.layoutSubtreeIfNeeded()
        check(workspace.visibleSections == [.chat, .git] && workspace.selectedSection == .git, "top Git navigation reuses the companion pane")
        workspace.openSectionFromNavigation(.terminal); workspace.layoutSubtreeIfNeeded()
        check(workspace.visibleSections == [.chat, .terminal] && workspace.selectedSection == .terminal, "top Terminal navigation reuses the companion pane without starting a process")
        workspace.openSectionFromNavigation(.chat)
        check(workspace.visibleSections == [.chat, .terminal] && workspace.selectedSection == .chat, "top Chat navigation focuses the preserved conversation")
        workspace.openSectionFromNavigation(.files)
        check(workspace.visibleSections == [.chat, .files] && input.string == draft, "a focused chat is never replaced by tool navigation")
        workspace.showSection(.chat); _ = workspace.splitActive(adding: .git, axis: .down)
        let customSections = Set(workspace.visibleSections)
        workspace.openSectionFromNavigation(.files)
        check(Set(workspace.visibleSections) == customSections && workspace.selectedSection == .files, "selecting an existing tool preserves a custom layout")
        workspace.openSectionFromNavigation(.terminal)
        check(Set(workspace.visibleSections) == Set([.chat, .git, .terminal]), "a new tool replaces only the focused tool inside a custom layout")
        check(input.string == draft && !terminal.hasRunning && !workspace.hasRunning, "navigation and drag tests preserve drafts and start no execution")
        check(!window.isVisible, "split workspace validation stays offscreen")
        return checks
    }
    private enum SectionIndex {
        static let chat = ProjectWorkspace.Section.chat.rawValue
        static let files = ProjectWorkspace.Section.files.rawValue
    }
}
