import AppKit

private final class PaneFixtureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

enum PaneContentUITests {
    static func run() throws -> Int {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            count += 1
            if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        func settle(_ view: NSView) {
            for _ in 0..<4 { view.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }
        func inside(_ view: NSView, _ parent: NSView) -> Bool {
            let r = view.convert(view.bounds, to: parent)
            return r.minX >= -0.5 && r.minY >= -0.5 && r.maxX <= parent.bounds.width + 0.5 && r.maxY <= parent.bounds.height + 0.5
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccam-pane-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Local fixture only: no remote is configured and no Claude process runs.
        let git = Process(); git.executableURL = URL(fileURLWithPath: "/usr/bin/git"); git.arguments = ["init", "-q", root.path]
        try git.run(); git.waitUntilExit(); check(git.terminationStatus == 0, "local Git fixture initializes")
        try "fn main() { println!(\"offline\"); }\n".write(to: root.appendingPathComponent("a-long-rust-file-name-that-must-stay-inside-a-small-pane.rs"), atomically: true, encoding: .utf8)
        let gitView = ProjectGitView(directory: root.path)
        let gitWindow = PaneFixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 242), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        gitWindow.contentView = gitView
        let table = all(gitView).compactMap { $0 as? NSTableView }.first!
        let deadline = Date().addingTimeInterval(4)
        while table.numberOfRows == 0 && Date() < deadline { settle(gitView) }
        check(table.numberOfRows == 1, "Git lists a local modified file without remote access")
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        for size in [NSSize(width: 340, height: 242), NSSize(width: 600, height: 400), NSSize(width: 900, height: 300)] {
            gitWindow.setContentSize(size); settle(gitView)
            let input = all(gitView).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "提交说明" }!
            let diff = all(gitView).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "文件差异" }!
            check(inside(input, gitView) && input.bounds.height >= 30, "Git commit input remains usable at \(size)")
            check(inside(diff.enclosingScrollView!, gitView) && diff.enclosingScrollView!.bounds.height >= 39, "Git diff remains visible at \(size)")
            check(inside(table.enclosingScrollView!, gitView) && table.enclosingScrollView!.bounds.height >= 28, "Git file list remains scrollable at \(size)")
            let controls = all(gitView).compactMap { $0 as? NSButton }.filter { ["暂存所选文件", "取消暂存所选文件", "刷新 Git 状态"].contains($0.accessibilityLabel() ?? "") }
            check(controls.count == 3 && controls.allSatisfy { inside($0, gitView) }, "Git icon actions fit at \(size)")
            check(gitWindow.makeFirstResponder(input) && gitWindow.firstResponder is NSTextView, "Git commit field receives focus at \(size)")
        }
        gitWindow.setContentSize(NSSize(width: 340, height: 242)); settle(gitView)
        try ChatUITests.snapshot(gitView, name: "git-small-pane")

        let terminal = TerminalWorkspace(frame: .zero)
        terminal.setScopeName("An exceptionally long project name that must not hide terminal actions")
        let session = TerminalSessionView(title: "Offline terminal", directory: root.path)
        session.showNotice("正在连接可用账号。项目上下文会保留，额度耗尽后自动续做。")
        session.terminal.feed(text: "$ cargo check\r\n    Checking sample v0.1.0\r\n    Finished dev profile\r\n")
        let tab = NSTabViewItem(identifier: "offline"); tab.label = "Offline terminal"; tab.view = session
        terminal.tabs.addTabViewItem(tab); terminal.emptyState.isHidden = true
        let terminalWindow = PaneFixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 242), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        terminalWindow.contentView = terminal
        for size in [NSSize(width: 340, height: 242), NSSize(width: 600, height: 400)] {
            terminalWindow.setContentSize(size); settle(terminal)
            let controls = all(terminal).compactMap { $0 as? NSButton }.filter { ["新任务", "粘贴", "中断", "更多会话操作", "显示全部项目的终端"].contains($0.accessibilityLabel() ?? "") }
            check(controls.count == 5 && controls.allSatisfy { inside($0, terminal) }, "terminal actions remain accessible at \(size)")
            check(inside(session.terminal, terminal) && session.terminal.bounds.height > 90, "terminal retains readable content space at \(size)")
            check(terminalWindow.makeFirstResponder(session.terminal) && terminalWindow.firstResponder === session.terminal, "terminal receives keyboard focus at \(size)")
        }
        terminalWindow.setContentSize(NSSize(width: 340, height: 242)); settle(terminal)
        try ChatUITests.snapshot(terminal, name: "terminal-small-pane")
        check(!session.session.running && terminal.sessions.isEmpty, "terminal layout checks launch no process")
        check(!gitWindow.isVisible && !terminalWindow.isVisible, "pane checks stay offscreen")
        return count
    }
}
