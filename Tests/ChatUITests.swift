import AppKit
import ImageIO
import UniformTypeIdentifiers

private final class FixtureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@main struct ChatUITests {
    static var checks = 0
    static func check(_ ok: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !ok() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
    static func snapshot(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["CCAM_UI_SNAPSHOT_DIR"], !directory.isEmpty else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError.message("Unable to render offline UI fixture") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("Unable to encode offline UI fixture") }
        try png.write(to: root.appendingPathComponent(name + ".png"))
    }
    static func main() throws {
        if let code = GlobalPool.handleHelperInvocation() { exit(code) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccam-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = root.appendingPathComponent("no-network-ccam")
        let called = root.appendingPathComponent("unexpected-process")
        try ("#!/bin/sh\ntouch " + Shell.quote(called.path) + "\nexit 99\n").write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        setenv("CCAM_EXECUTABLE", stub.path, 1)
        setenv("CCAM_DESKTOP_DATA_DIR", root.appendingPathComponent("data").path, 1)
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); NSApp.appearance = NSAppearance(named: .darkAqua)
        let project = ProjectRecord(id: UUID(), name: "Offline UI", path: root.path, createdAt: Date(), lastOpenedAt: Date(), archived: false)
        let a = ChatConversation(id: UUID().uuidString, title: "Alpha", projectID: project.id.uuidString, directory: root.path, options: ChatOptions(model: "sonnet", permissionMode: .plan, effort: "low"))
        let b = ChatConversation(id: UUID().uuidString, title: "Beta", projectID: project.id.uuidString, directory: root.path, options: ChatOptions(model: "opus", permissionMode: .acceptEdits))
        let c = ChatConversation(id: UUID().uuidString, title: "Terminal handoff", projectID: project.id.uuidString, directory: root.path,
                                 sessionID: UUID().uuidString, account: "first", transferredToTerminal: true)
        try ChatStore(project: project).save([a, b, c], selectedID: a.id)
        let view = ProjectChatView(project: project)
        view.beforeStart = { _ in throw AppError.message("Offline UI test prohibits execution") }
        let window = FixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 968, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view
        let pickers = all(view).compactMap { $0 as? NSPopUpButton }
        let model = pickers.first { $0.accessibilityLabel() == "选择模型" }!
        let effort = pickers.first { $0.accessibilityLabel() == "选择思考强度" }!
        let mode = pickers.first { $0.accessibilityLabel() == "选择权限模式" }!
        let input = all(view).compactMap { $0 as? NSTextView }.first!
        check(model.titleOfSelectedItem == "Sonnet" && effort.titleOfSelectedItem == "低" && mode.titleOfSelectedItem == "计划模式", "saved controls appear on opening")
        check(!all(view).contains { $0.accessibilityLabel() == "对话设置与操作" }, "conversation management is absent from the composer")
        model.selectItem(withTitle: "Haiku"); _ = NSApp.sendAction(model.action!, to: model.target, from: model)
        mode.selectItem(withTitle: "允许编辑"); _ = NSApp.sendAction(mode.action!, to: mode.target, from: mode)
        let saved = try ChatStore(project: project).conversations.first { $0.id == a.id }!
        check(saved.options?.model == "haiku" && saved.options?.permissionMode == .acceptEdits && saved.options?.effort == "low", "picker actions persist choices without a request")
        for (title, value) in [("很高", "xhigh"), ("最高", "max"), ("默认强度", ""), ("低", "low"), ("中", "medium"), ("高", "high")] {
            effort.selectItem(withTitle: title); _ = NSApp.sendAction(effort.action!, to: effort.target, from: effort)
            let settings = try ChatStore(project: project).conversations.first { $0.id == a.id }!.options!
            check((settings.effort ?? "") == value && settings.model == "haiku" && settings.permissionMode == .acceptEdits,
                  "visible effort picker saves \(title) without changing model or permission mode")
        }
        input.string = "unsent draft"; view.textDidChange(Notification(name: NSText.didChangeNotification))
        view.selectConversation(id: b.id)
        check(model.titleOfSelectedItem == "Opus" && effort.titleOfSelectedItem == "默认强度" && mode.titleOfSelectedItem == "允许编辑" && input.string.isEmpty, "switching conversations restores independent controls")
        view.selectConversation(id: a.id)
        check(model.titleOfSelectedItem == "Haiku" && effort.titleOfSelectedItem == "高" && input.string == "unsent draft", "model and effort settings do not lose drafts")
        model.selectItem(withTitle: "默认模型"); _ = NSApp.sendAction(model.action!, to: model.target, from: model)
        let reset = try ChatStore(project: project).conversations.first { $0.id == a.id }!
        check(reset.options?.model == nil, "default model can clear an override")
        mode.selectItem(withTitle: "Auto 模式"); _ = NSApp.sendAction(mode.action!, to: mode.target, from: mode)
        let automatic = try ChatStore(project: project).conversations.first { $0.id == a.id }!
        check(automatic.options?.permissionMode == .auto, "Auto menu choice persists without executing a task")
        let file = root.appendingPathComponent("notes.txt")
        try "offline attachment".write(to: file, atomically: true, encoding: .utf8)
        try view.addAttachments([file])
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let png = NSMutableData()
        let imageWriter = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(imageWriter, context.makeImage()!, nil); precondition(CGImageDestinationFinalize(imageWriter))
        try view.addImageAttachment(data: png as Data, name: "capture.png")
        let attached = try ChatStore(project: project).conversations.first { $0.id == a.id }!
        check(attached.draftAttachments?.count == 2 && input.string == "unsent draft", "file and clipboard-image staging preserve text and persist metadata")
        check(all(view).contains { $0.accessibilityLabel() == "预览附件：capture.png" }, "image thumbnail exposes a preview action")
        view.selectConversation(id: b.id)
        check(!all(view).contains { $0.accessibilityLabel() == "预览附件：capture.png" }, "draft attachments never leak to a different conversation")
        view.selectConversation(id: a.id)
        check(all(view).contains { $0.accessibilityLabel() == "预览附件：capture.png" }, "draft attachments return with their conversation")
        let remove = all(view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "移除附件：capture.png" }!
        remove.performClick(nil)
        let removed = try ChatStore(project: project).conversations.first { $0.id == a.id }!
        check(removed.draftAttachments?.count == 1, "remove button updates the persisted draft")
        let imageURL = try ChatAttachmentStore(project: project).url(for: attached.draftAttachments!.first { $0.isImage }!)
        check(!FileManager.default.fileExists(atPath: imageURL.path), "unreferenced removed draft copy is cleaned locally")
        for width in [968.0, 640.0, 358.0] {
            window.setContentSize(NSSize(width: width, height: 700)); view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03)); view.layoutSubtreeIfNeeded()
            for control in [model as NSView, effort as NSView, mode as NSView] + all(view).filter({ $0.accessibilityLabel() == "发送消息" || $0.accessibilityLabel() == "添加图片或文件" }) {
                let rect = control.convert(control.bounds, to: view)
                check(rect.minX >= 0 && rect.maxX <= view.bounds.width + 0.5 && rect.minY >= 0, "composer controls fit width \(width)")
            }
            let modelRect = model.convert(model.bounds, to: view), effortRect = effort.convert(effort.bounds, to: view), modeRect = mode.convert(mode.bounds, to: view)
            check(modelRect.maxX <= effortRect.minX && effortRect.maxX <= modeRect.minX && mode.bounds.width >= 74,
                  "model, effort and permission remain ordered and readable at width \(width)")
            let point = input.convert(NSPoint(x: 20, y: 20), to: view)
            check(input.bounds.height >= 40 && view.hitTest(point) === input, "composer receives clicks without an overlapping view at width \(width)")
            check(window.makeFirstResponder(input) && window.firstResponder === input, "composer accepts keyboard focus at width \(width)")
            check(!window.isVisible, "layout checks stay offscreen")
        }
        var returnedTarget: ChatTerminalTarget?
        var completeReturn: ((Result<ChatTerminalTarget, Error>) -> Void)?
        view.onReturnFromTerminal = { target, completion in returnedTarget = target; completeReturn = completion }
        view.selectConversation(id: c.id)
        let send = all(view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "发送消息" }!
        let returnButton = all(view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "返回聊天" }!
        check(input.isEditable && input.isSelectable && window.firstResponder === input, "terminal handoff still permits focusing and drafting")
        input.insertText("draft after terminal", replacementRange: NSRange(location: 0, length: 0))
        view.textDidChange(Notification(name: NSText.didChangeNotification))
        check(input.string == "draft after terminal" && !send.isEnabled && !returnButton.isHidden, "terminal handoff keeps drafts editable with an explicit safe return action")
        check(!effort.isEnabled && !model.isEnabled, "terminal handoff disables model and effort changes together")
        try snapshot(view, name: "terminal-handoff-compact")
        returnButton.performClick(nil)
        check(returnedTarget?.sessionID == c.sessionID && !returnButton.isEnabled && !send.isEnabled, "handback waits for the exact terminal session to finish")
        view.selectConversation(id: b.id)
        completeReturn?(.success(returnedTarget!))
        check(view.selectedConversationID == b.id, "asynchronous terminal handback does not switch the user's newly selected conversation")
        view.selectConversation(id: c.id)
        let restored = try ChatStore(project: project).conversations.first { $0.id == c.id }!
        check(!restored.transferredToTerminal && restored.sessionID == c.sessionID && restored.account == c.account, "handback restores the original account and session")
        check(input.string == "draft after terminal" && send.isEnabled && model.isEnabled && effort.isEnabled && returnButton.isHidden, "draft, model and effort controls and Send recover after handback")
        try snapshot(view, name: "chat-restored-compact")
        window.setContentSize(NSSize(width: 968, height: 700)); view.layoutSubtreeIfNeeded()
        try snapshot(view, name: "chat-restored-desktop")
        view.selectConversation(id: a.id)

        var decisions: [String] = []
        let approval = ChatApprovalCard(title: "执行项目操作", detail: "git -C example status --short\n完整操作可在此阅读", actionTitle: "允许一次", canApprove: true,
                                        approve: { decisions.append("allow") }, deny: { decisions.append("deny") })
        let approvalWindow = FixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 326, height: 170), styleMask: [.titled], backing: .buffered, defer: false)
        approvalWindow.contentView = approval; approval.layoutSubtreeIfNeeded()
        check(decisions.isEmpty && approval.detailView.string.contains("git -C example status"), "approval shows the complete operation and never decides while rendering")
        for button in [approval.approveButton, approval.denyButton] {
            let rect = button.convert(button.bounds, to: approval)
            check(rect.minX >= 0 && rect.maxX <= approval.bounds.width, "approval decisions fit a compact composer")
        }
        approval.approveButton.performClick(nil); approval.denyButton.performClick(nil)
        check(decisions == ["allow", "deny"], "approval buttons deliver distinct explicit decisions")
        check(!approvalWindow.isVisible, "approval fixture stays offscreen")
        try snapshot(approval, name: "approval-compact")
        let unavailable = ChatApprovalCard(title: "无法读取计划", detail: "计划内容缺失", actionTitle: "同意计划", canApprove: false, approve: {}, deny: {})
        check(!unavailable.approveButton.isEnabled && unavailable.denyButton.isEnabled, "an unreadable plan cannot be approved")
        let questionForm = ChatQuestionForm(questions: [
            ChatApprovalQuestion(question: "选择范围", header: "范围", options: [.init(label: "当前项目", description: "仅当前文件夹"), .init(label: "所有项目", description: "多个仓库")], multiSelect: false),
            ChatApprovalQuestion(question: "需要检查哪些内容", header: "检查", options: [.init(label: "代码", description: ""), .init(label: "文档", description: "")], multiSelect: true)
        ], width: 300)
        check(questionForm.answers == nil, "questions require an explicit answer to each item")
        let choices = all(questionForm).compactMap { $0 as? NSButton }
        choices.first { $0.title == "当前项目" }!.performClick(nil)
        choices.first { $0.title == "代码" }!.performClick(nil)
        choices.first { $0.title == "文档" }!.performClick(nil)
        check(questionForm.answers?["选择范围"] == "当前项目" && questionForm.answers?["需要检查哪些内容"] == "代码, 文档", "single and multiple choices preserve exact question keys")
        let customAnswer = all(questionForm).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "其他回答：选择范围" }!
        customAnswer.stringValue = "指定子目录"; questionForm.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: customAnswer))
        check(questionForm.answers?["选择范围"] == "指定子目录", "a typed single-choice answer replaces the previously selected option")
        choices.first { $0.title == "所有项目" }!.performClick(nil)
        check(questionForm.answers?["选择范围"] == "所有项目" && customAnswer.stringValue.isEmpty, "a selected single-choice option clears the previous custom answer")
        let questionScroll = ThemeScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        questionScroll.hasVerticalScroller = true; questionScroll.autohidesScrollers = true; questionScroll.documentView = questionForm
        questionForm.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            questionForm.topAnchor.constraint(equalTo: questionScroll.contentView.topAnchor), questionForm.leadingAnchor.constraint(equalTo: questionScroll.contentView.leadingAnchor),
            questionForm.widthAnchor.constraint(equalTo: questionScroll.contentView.widthAnchor)
        ])
        let questionWindow = FixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        questionWindow.contentView = questionScroll; questionScroll.layoutSubtreeIfNeeded()
        check(questionForm.bounds.height > questionScroll.contentView.bounds.height, "long question forms retain scrollable height")
        check(customAnswer.bounds.width > 200 && customAnswer.convert(customAnswer.bounds, to: questionForm).maxX <= questionForm.bounds.width,
              "question answers fit the sheet's compact width")
        try snapshot(questionScroll, name: "questions-compact")
        let sidebar = WorkspaceSidebar(frame: NSRect(x: 0, y: 0, width: 224, height: 700))
        sidebar.update(records: [project], currentID: project.id, items: [(a.id, "Alpha"), (b.id, "Beta")], selectedID: a.id, running: false)
        let quotaAccounts = try JSONDecoder().decode([Account].self, from: Data(#"[{"name":"first","default":true},{"name":"second"}]"#.utf8))
        let quotaUsage = ["first", "second"].map { name in
            AccountUsage(name: name, status: "ok", error: nil,
                         windows: [UsageWindow(label: "5 小时额度", used: 0, reset: nil), UsageWindow(label: "每周额度", used: 98, reset: nil)],
                         raw: ["source": "cache", "at": ISO8601DateFormatter().string(from: Date())])
        }
        sidebar.updateQuota(QuotaSummary.make(accounts: quotaAccounts, usage: quotaUsage))
        var actionID: String?
        sidebar.onConversationActions = { _, id, _ in actionID = id }
        let more = all(sidebar).compactMap { $0 as? SidebarItemButton }.first { $0.accessibilityLabel() == "对话操作：Alpha" }!
        more.performClick(nil)
        check(actionID == a.id, "visible overflow action targets its conversation")
        check(all(sidebar).contains { $0.accessibilityLabel()?.hasPrefix("当前账号额度") == true && $0.toolTip?.contains("100%") == true }, "current account quota is accessible")
        check(all(sidebar).contains { $0.accessibilityLabel()?.hasPrefix("账号池总额度") == true && $0.toolTip?.contains("2.00份") == true && $0.toolTip?.contains("0.04份") == true }, "both pooled windows are accessible without replacing current quota")
        check(all(sidebar).contains { $0.accessibilityLabel() == "已删除的对话：" + project.name }, "project recovery entry is visible")
        let sidebarWindow = FixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 224, height: 640), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        sidebarWindow.contentView = sidebar
        let projects = [project] + (0..<4).map { index in
            ProjectRecord(id: UUID(), name: "Project \(index)", path: root.path, createdAt: Date(), lastOpenedAt: Date(), archived: false)
        }
        sidebar.update(records: projects, currentID: project.id, items: [(a.id, "Alpha"), (b.id, "Beta")], selectedID: a.id, running: false)
        sidebar.layoutSubtreeIfNeeded()
        let historyButton = all(sidebar).compactMap { $0 as? SidebarItemButton }.first { $0.title == "Alpha" }!
        check((historyButton.enclosingScrollView?.contentView.bounds.height ?? 0) >= 72, "short desktop with five projects retains two complete recent-conversation rows")
        let currentMore = all(sidebar).compactMap { $0 as? SidebarItemButton }.first { $0.accessibilityLabel() == "对话操作：Alpha" }!
        check(historyButton.bounds.width > 130 && abs(historyButton.bounds.width + currentMore.bounds.width - historyButton.superview!.bounds.width) <= 1,
              "conversation title expands into all space beside its overflow action")
        let quotaButton = all(sidebar).compactMap { $0 as? SidebarQuotaView }.first!
        check(quotaButton.bounds.height == 64 && !quotaButton.isHiddenOrHasHiddenAncestor, "current and total quota remain fully visible in short desktop")
        check(!sidebarWindow.isVisible, "sidebar regression stays offscreen")
        for id in [a.id, b.id, c.id] {
            let action = NSMenuItem(); action.tag = 4; action.representedObject = id
            _ = NSApp.sendAction(NSSelectorFromString("conversationAction:"), to: view, from: action)
        }
        check(view.selectedConversationID == nil, "deleting the last conversation leaves an unassigned composer")
        let previousProxy = UserDefaults.standard.object(forKey: ExecutionProxy.defaultsKey)
        UserDefaults.standard.set("http://127.0.0.1:1", forKey: ExecutionProxy.defaultsKey)
        defer {
            if let previousProxy { UserDefaults.standard.set(previousProxy, forKey: ExecutionProxy.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: ExecutionProxy.defaultsKey) }
        }
        input.string = "  keep text before attaching\n"; view.textDidChange(Notification(name: NSText.didChangeNotification))
        send.performClick(nil)
        check(view.selectedConversationID == nil && input.string == "  keep text before attaching\n" && !view.hasRunning,
              "failed startup restores an unassigned draft exactly, including whitespace")
        try view.addAttachments([file])
        check(input.string == "  keep text before attaching\n" && view.selectedConversationID != nil, "adding attachments after deleting all conversations preserves unassigned text")
        let attachmentDraftID = view.selectedConversationID
        send.performClick(nil)
        let failedDraft = try ChatStore(project: project).conversations.first { $0.id == attachmentDraftID }!
        check(input.string == "  keep text before attaching\n" && failedDraft.draftAttachments?.count == 1 && failedDraft.messages.isEmpty,
              "failed startup preserves text and attachments without adding a duplicate user message")
        let handbackProject = ProjectRecord(id: UUID(), name: "Background handback", path: root.path, createdAt: Date(), lastOpenedAt: Date(), archived: false)
        let handbackConversation = ChatConversation(id: UUID().uuidString, title: "Terminal task", projectID: handbackProject.id.uuidString, directory: root.path,
                                                   sessionID: UUID().uuidString, account: "first", transferredToTerminal: true)
        try ChatStore(project: handbackProject).save([handbackConversation], selectedID: handbackConversation.id)
        let otherProject = ProjectRecord(id: UUID(), name: "Other project", path: root.path, createdAt: Date(), lastOpenedAt: Date(), archived: false)
        let workspace = ProjectWorkspace(terminal: TerminalWorkspace(frame: .zero))
        workspace.select(project: handbackProject); workspace.select(project: otherProject)
        let otherConversation = workspace.selectedConversationID
        let uncertainTarget = ChatTerminalTarget(directory: root.path, sessionID: handbackConversation.sessionID, account: "first", ticket: nil,
                                                 conversationID: handbackConversation.id)
        try workspace.recordTerminalState(projectID: handbackProject.id, target: uncertainTarget, uncertain: true)
        let uncertainRuntime = try ChatRuntime(project: handbackProject)
        check(!uncertainRuntime.terminalFallback.canResume, "unverified terminal handoff remains blocked after reopening its chat")
        do {
            try uncertainRuntime.restoreFromTerminal(conversationID: handbackConversation.id, account: "first", sessionID: handbackConversation.sessionID)
            check(false, "uncertain handback must not restore the old account and session")
        } catch { check(true, "uncertain handback rejects recovery instead of guessing the old account") }
        let latestSession = UUID().uuidString
        let verifiedTarget = ChatTerminalTarget(directory: root.path, sessionID: latestSession, account: "second", ticket: nil, conversationID: handbackConversation.id)
        try workspace.recordTerminalState(projectID: handbackProject.id, target: verifiedTarget, uncertain: false)
        let reopenedRuntime = try ChatRuntime(project: handbackProject)
        check(reopenedRuntime.terminalFallback.canResume && reopenedRuntime.terminalFallback.account == "second" && reopenedRuntime.terminalFallback.sessionID == latestSession,
              "verified handoff identity survives closing and reopening the application")
        check(workspace.selectedConversationID == otherConversation, "background terminal identity updates never change the foreground conversation")
        check(!FileManager.default.fileExists(atPath: called.path), "controls and layout never launch any process")
        checks += try TerminalProxyUITests.run()
        checks += try WorkspaceSidebarUITests.run()
        checks += try SidebarGaugeUITests.run()
        checks += try AccountRefreshUITests.run()
        checks += try TurnQuotaRefreshUITests.run()
        checks += try TranslationUITests.run()
        checks += try MarkdownUITests.run()
        checks += try WorkspaceSplitUITests.run()
        checks += try MultiConversationWorkspaceUITests.run()
        checks += try WindowChromeUITests.run()
        checks += try PaneContentUITests.run()
        checks += try MultiRepositoryGitUITests.run()
        checks += try ProjectFilesUITests.run(root: root)
        checks += try ProjectFilePreviewUITests.run()
        check(!FileManager.default.fileExists(atPath: called.path), "split and file workflows never invoke CCAM")
        print("PASS: \(checks) offline chat UI checks; isolated records, no model requests")
    }
}
