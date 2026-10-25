import AppKit

private final class MultiGitFixtureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

enum MultiRepositoryGitUITests {
    static func run() throws -> Int {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ title: String) {
            count += 1
            if !value() { fputs("FAIL: \(title)\n", stderr); exit(1) }
        }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        func git(_ directory: URL, _ arguments: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = directory; process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            if process.terminationStatus != 0 { throw ProjectGitError.message("Unable to create offline Git fixture") }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ccam-multi-git-" + UUID().uuidString)
        let alpha = root.appendingPathComponent("app"), beta = root.appendingPathComponent("services/api")
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath().path
        let preferenceKey = "git.selectedRepository." + Data(canonical.utf8).base64EncodedString()
        defer { try? fm.removeItem(at: root); UserDefaults.standard.removeObject(forKey: preferenceKey) }
        for (folder, branch) in [(alpha, "app-main"), (beta, "api-main")] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try git(folder, ["init", "-q"])
            try git(folder, ["symbolic-ref", "HEAD", "refs/heads/" + branch])
            try git(folder, ["config", "--local", "user.name", "Offline Fixture"])
            try git(folder, ["config", "--local", "user.email", "fixture@example.invalid"])
            try git(folder, ["config", "--local", "commit.gpgsign", "false"])
            try git(folder, ["config", "--local", "core.hooksPath", folder.appendingPathComponent(".git/empty-hooks").path])
        }
        try "APP-CONTENT\n".write(to: alpha.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try "API-CONTENT\n".write(to: beta.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        let view = ProjectGitView(directory: root.path)
        let window = MultiGitFixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view
        let picker = all(view).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "选择 Git 仓库" }!
        let table = all(view).compactMap { $0 as? NSTableView }.first!
        let input = all(view).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "提交说明" }!
        let diff = all(view).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "文件差异" }!
        let branch = all(view).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Git 分支" }!
        let status = all(view).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Git 状态" }!
        func button(_ name: String) -> NSButton { all(view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == name || $0.title == name }! }
        func wait(_ title: String, until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)); view.layoutSubtreeIfNeeded() }
            check(condition(), title)
        }
        func select(_ title: String) {
            picker.selectItem(withTitle: title)
            _ = NSApp.sendAction(picker.action!, to: picker.target, from: picker)
        }
        wait("parent project discovers both child repositories") { picker.isEnabled && table.numberOfRows == 1 }
        check(picker.itemTitles == ["app", "services/api"] && branch.stringValue == "app-main", "repository picker uses relative paths and defaults to first child without changing project root")
        check(picker.toolTip?.contains("2 个仓库") == true, "repository picker discloses repository count and selected directory")
        check(!fm.fileExists(atPath: root.appendingPathComponent(".git").path), "discovery does not initialize a repository in the parent folder")
        input.stringValue = "App draft"
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        // Switching immediately after queueing the old repository's diff ensures
        // same-named files cannot leak across a repository-generation boundary.
        select("services/api")
        check(table.numberOfRows == 0 && diff.string.isEmpty && input.stringValue.isEmpty && !button("暂存所选文件").isEnabled,
              "switching repository clears old files, diff, action state and unrelated commit draft immediately")
        wait("selected child repository loads its own branch") { picker.isEnabled && branch.stringValue == "api-main" && table.numberOfRows == 1 }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        wait("same-named file diff belongs to selected API repository") { diff.string.contains("+API-CONTENT") }
        check(!diff.string.contains("APP-CONTENT"), "stale queued diff cannot appear under a different selected repository")
        input.stringValue = "API draft"
        select("app")
        wait("returning to app restores its state") { picker.isEnabled && branch.stringValue == "app-main" }
        check(input.stringValue == "App draft" && table.selectedRow == 0, "each repository restores its commit draft and selected file")
        wait("app selection restores app diff") { diff.string.contains("+APP-CONTENT") }
        select("services/api")
        wait("returning to API restores independent draft") { picker.isEnabled && input.stringValue == "API draft" && table.selectedRow == 0 }
        button("暂存所选文件").performClick(nil)
        check(!picker.isEnabled && !button("提交").isEnabled, "a write operation locks repository switching and commit actions")
        wait("staging refreshes only the selected repository") { picker.isEnabled && button("提交").isEnabled }
        let alphaClient = try ProjectGitClient(directory: alpha.path), betaClient = try ProjectGitClient(directory: beta.path)
        let alphaState = try alphaClient.status(), betaState = try betaClient.status()
        check(alphaState.files.allSatisfy(\.untracked) && betaState.files.first?.staged == true, "staging affects API index without touching same-named app file")
        check(input.stringValue == "API draft", "staging keeps the selected repository's commit draft")
        button("提交").performClick(nil)
        wait("commit completes in selected repository") { picker.isEnabled && table.numberOfRows == 0 && input.stringValue.isEmpty }
        let committedBeta = try betaClient.status(), unchangedAlpha = try alphaClient.status()
        check(committedBeta.hasHead && !unchangedAlpha.hasHead, "commit creates history only in the selected child repository")
        select("app")
        wait("app remains unchanged after other repository commit") { picker.isEnabled && table.numberOfRows == 1 }
        check(input.stringValue == "App draft" && button("暂存所选文件").isEnabled, "other repository's draft and untracked file survive the selected commit")
        wait("app diff is ready for desktop snapshot") { diff.string.contains("+APP-CONTENT") }
        window.setContentSize(NSSize(width: 920, height: 500)); view.layoutSubtreeIfNeeded()
        try ChatUITests.snapshot(view, name: "git-multiple-repositories")
        for size in [NSSize(width: 340, height: 242), NSSize(width: 620, height: 400), NSSize(width: 920, height: 500)] {
            window.setContentSize(size)
            for _ in 0..<4 { view.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            func inside(_ control: NSView) -> Bool {
                let rect = control.convert(control.bounds, to: view)
                return rect.minX >= -0.5 && rect.minY >= -0.5 && rect.maxX <= view.bounds.width + 0.5 && rect.maxY <= view.bounds.height + 0.5
            }
            check(inside(picker) && picker.bounds.width >= 99 && inside(input) && input.bounds.height >= 30,
                  "repository picker and commit input fit desktop pane \(size)")
            check(inside(diff.enclosingScrollView!) && diff.enclosingScrollView!.bounds.height >= 39 && inside(table.enclosingScrollView!) && table.enclosingScrollView!.bounds.height >= 28,
                  "multi-repository Git preserves readable diff and file surfaces at \(size)")
        }
        window.setContentSize(NSSize(width: 340, height: 242)); view.layoutSubtreeIfNeeded()
        try ChatUITests.snapshot(view, name: "git-multiple-repositories-compact")
        // The previously chosen repository is no longer usable. An attempted
        // operation must fail before Git can find a different parent repository.
        try fm.removeItem(at: alpha.appendingPathComponent(".git"))
        button("暂存所选文件").performClick(nil)
        wait("deleted repository invalidates its action state") { picker.isEnabled && table.numberOfRows == 0 && !input.isEnabled }
        check(!button("暂存所选文件").isEnabled && !button("提交").isEnabled && diff.string.isEmpty,
              "invalid repository leaves no stale files or enabled write controls")
        button("刷新 Git 状态").performClick(nil)
        wait("refresh finds remaining repo without silently switching targets") { picker.isEnabled && picker.titleOfSelectedItem == "选择仓库…" }
        check(table.numberOfRows == 0 && status.stringValue.contains("选择其他仓库"), "missing selection asks for an explicit replacement repository")
        select("services/api")
        wait("user can explicitly select the surviving repository") { picker.isEnabled && branch.stringValue == "api-main" }
        check(picker.titleOfSelectedItem == "services/api" && UserDefaults.standard.string(forKey: preferenceKey) == betaClient.directory.path,
              "selected repository is remembered per canonical project path")
        check(!window.isVisible, "multi-repository UI verification stays offscreen")
        return count
    }
}
