import AppKit

final class TaskComposer: NSWindowController {
    let input = NSTextView()
    private let onStart: (String) throws -> Void
    init(project: ProjectRecord, onStart: @escaping (String) throws -> Void) {
        self.onStart = onStart
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.windowWidth(660), height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "新任务"; window.appearance = nil; window.backgroundColor = Theme.background
        super.init(window: window)
        let scroll = ThemeScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.borderType = .noBorder
        scroll.drawsBackground = true; scroll.backgroundColor = Theme.panel; scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8; scroll.layer?.borderWidth = 1; scroll.strokeColor = Theme.border; scroll.layer?.masksToBounds = true
        input.isEditable = true; input.isRichText = false; input.isAutomaticQuoteSubstitutionEnabled = false; input.isAutomaticDashSubstitutionEnabled = false
        input.font = Theme.font(size: 14); input.textColor = Theme.text; input.backgroundColor = Theme.panel; input.insertionPointColor = Theme.accent
        input.textContainerInset = NSSize(width: 14, height: 14); input.isVerticallyResizable = true; input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]; input.textContainer?.widthTracksTextView = true; scroll.documentView = input
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        input.setAccessibilityLabel("任务内容")
        let start = ClosureButton("开始工作", symbol: "play.fill") { [weak self] in self?.submit() }
        start.bezelColor = Theme.accent; start.contentTintColor = .white; start.keyEquivalent = "\r"; start.keyEquivalentModifierMask = [.command]
        start.font = Theme.font(size: 14, weight: .semibold); start.toolTip = "开始工作（⌘ Return）"
        let cancel = ClosureButton("取消") { [weak self] in self?.close() }
        for button in [cancel, start] { button.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true }
        cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        start.widthAnchor.constraint(greaterThanOrEqualToConstant: 126).isActive = true
        let path = label(project.path, size: 12, color: Theme.muted)
        path.maximumNumberOfLines = 1; path.lineBreakMode = .byTruncatingMiddle; path.toolTip = project.path
        let projectInfo = column([], spacing: 4)
        fillWidth(label(project.name, size: 14, weight: .medium), in: projectInfo); fillWidth(path, in: projectInfo)
        let heading = column([], spacing: 10)
        fillWidth(label("这次要完成什么？", size: 25, weight: .semibold), in: heading); fillWidth(projectInfo, in: heading)
        let body = column([], spacing: 14)
        fillWidth(heading, in: body)
        let editor = column([], spacing: 8)
        fillWidth(label("任务内容", size: 12, color: Theme.muted, weight: .medium), in: editor); fillWidth(scroll, in: editor)
        fillWidth(editor, in: body)
        fillWidth(label("自动续做已启用", size: 12, color: Theme.success), in: body)
        fillWidth(row([spacer(), cancel, start], spacing: 10), in: body)
        let container = NSView(); body.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(body)
        NSLayoutConstraint.activate([body.topAnchor.constraint(equalTo: container.topAnchor, constant: 20), body.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20), body.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20), body.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20)])
        window.contentView = container; window.minSize = NSSize(width: 390, height: 480); window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func showWindow(_ sender: Any?) { super.showWindow(sender); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(input) }
    private func submit() {
        let task = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { showError("请填写要完成的任务。", window: window); return }
        guard !task.contains("\0") else { showError("任务内容包含无法处理的字符。", window: window); return }
        do { try onStart(task); close() }
        catch { showError(OperationPresentation.clean(error.localizedDescription), window: window) }
    }
}
