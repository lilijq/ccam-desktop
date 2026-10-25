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
    static func main() throws {
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
        try ChatStore(project: project).save([a, b], selectedID: a.id)
        let view = ProjectChatView(project: project)
        view.beforeStart = { _ in throw AppError.message("Offline UI test prohibits execution") }
        let window = FixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 968, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view
        let pickers = all(view).compactMap { $0 as? NSPopUpButton }
        let model = pickers.first { $0.accessibilityLabel() == "选择模型" }!
        let mode = pickers.first { $0.accessibilityLabel() == "选择权限模式" }!
        let input = all(view).compactMap { $0 as? NSTextView }.first!
        check(model.titleOfSelectedItem == "Sonnet" && mode.titleOfSelectedItem == "计划模式", "saved controls appear on opening")
        model.selectItem(withTitle: "Haiku"); _ = NSApp.sendAction(model.action!, to: model.target, from: model)
        mode.selectItem(withTitle: "允许编辑"); _ = NSApp.sendAction(mode.action!, to: mode.target, from: mode)
        let saved = try ChatStore(project: project).conversations.first { $0.id == a.id }!
        check(saved.options?.model == "haiku" && saved.options?.permissionMode == .acceptEdits && saved.options?.effort == "low", "picker actions persist choices without a request")
        input.string = "unsent draft"; view.textDidChange(Notification(name: NSText.didChangeNotification))
        view.selectConversation(id: b.id)
        check(model.titleOfSelectedItem == "Opus" && mode.titleOfSelectedItem == "允许编辑" && input.string.isEmpty, "switching conversations restores independent controls")
        view.selectConversation(id: a.id)
        check(model.titleOfSelectedItem == "Haiku" && input.string == "unsent draft", "model settings do not lose drafts")
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
            for control in [model as NSView, mode as NSView] + all(view).filter({ $0.accessibilityLabel() == "对话设置与操作" || $0.accessibilityLabel() == "发送消息" || $0.accessibilityLabel() == "添加图片或文件" }) {
                let rect = control.convert(control.bounds, to: view)
                check(rect.minX >= 0 && rect.maxX <= view.bounds.width + 0.5 && rect.minY >= 0, "composer controls fit width \(width)")
            }
            check(!window.isVisible, "layout checks stay offscreen")
        }
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
        sidebar.onConversationActions = { id, _ in actionID = id }
        let more = all(sidebar).compactMap { $0 as? SidebarItemButton }.first { $0.accessibilityLabel() == "对话操作：Alpha" }!
        more.performClick(nil)
        check(actionID == a.id, "visible overflow action targets its conversation")
        check(all(sidebar).contains { $0.accessibilityLabel()?.contains("当前账号 first，5 小时 100%") == true }, "current account quota is accessible")
        check(all(sidebar).contains { $0.accessibilityLabel()?.contains("总剩余，5 小时 2.00份，每周 0.04份") == true }, "both pooled windows are accessible without replacing current quota")
        check(all(sidebar).contains { $0.accessibilityLabel() == "已删除的对话" }, "recovery entry is visible")
        let sidebarWindow = FixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 224, height: 640), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        sidebarWindow.contentView = sidebar
        let projects = (0..<5).map { index in
            ProjectRecord(id: UUID(), name: "Project \(index)", path: root.path, createdAt: Date(), lastOpenedAt: Date(), archived: false)
        }
        sidebar.update(records: projects, currentID: project.id, items: [(a.id, "Alpha"), (b.id, "Beta")], selectedID: a.id, running: false)
        sidebar.layoutSubtreeIfNeeded()
        let historyButton = all(sidebar).compactMap { $0 as? SidebarItemButton }.first { $0.title == "Alpha" }!
        check((historyButton.enclosingScrollView?.contentView.bounds.height ?? 0) >= 72, "short desktop with five projects retains two complete recent-conversation rows")
        let quotaButton = all(sidebar).compactMap { $0 as? SidebarQuotaButton }.first!
        check(quotaButton.bounds.height >= 100 && !quotaButton.isHiddenOrHasHiddenAncestor, "current and total quota remain fully visible in short desktop")
        check(!sidebarWindow.isVisible, "sidebar regression stays offscreen")
        for id in [a.id, b.id] {
            let action = NSMenuItem(); action.tag = 4; action.representedObject = id
            _ = NSApp.sendAction(NSSelectorFromString("conversationAction:"), to: view, from: action)
        }
        check(view.selectedConversationID == nil, "deleting the last conversation leaves an unassigned composer")
        input.string = "keep text before attaching"; view.textDidChange(Notification(name: NSText.didChangeNotification))
        try view.addAttachments([file])
        check(input.string == "keep text before attaching" && view.selectedConversationID != nil, "adding attachments after deleting all conversations preserves unassigned text")
        check(!FileManager.default.fileExists(atPath: called.path), "controls and layout never launch any process")
        print("PASS: \(checks) offline chat UI checks; isolated records, no model requests")
    }
}
