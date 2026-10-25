import AppKit

private final class ChatDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class ChatInputView: NSTextView {
    var onSubmit: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            onSubmit?()
        } else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let placeholder = NSAttributedString(string: "描述任务，或继续提问…", attributes: [
            .font: Theme.font(size: 15), .foregroundColor: Theme.muted
        ])
        placeholder.draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height))
    }
}

/// Presentation only. A retained project view owns its input and scroll position;
/// the chat controller owns process, account, and conversation state.
final class ProjectChatView: NSView, NSTextViewDelegate {
    let project: ProjectRecord
    var onTerminalFallback: ((ChatTerminalTarget) throws -> Void)? { didSet { updateControls() } }
    var onShowTerminal: (() -> Void)? { didSet { updateControls() } }
    var onStateChange: (() -> Void)?
    var beforeStart: (([String]) throws -> Void)?
    var hasRunning: Bool { runtime?.hasRunning ?? false }
    var historyItems: [(id: String, title: String)] {
        (runtime?.conversations ?? []).map { conversation in
            let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return (conversation.id, title.isEmpty ? "新对话" : title)
        }
    }
    var selectedConversationID: String? { runtime?.selectedID }

    private let permissionPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = label("", size: 12, color: Theme.muted)
    private let history = ThemeScrollView()
    private let document = ChatDocumentView()
    private let messages = column([], spacing: 20)
    private let emptyState = column([], spacing: 12)
    private let input = ChatInputView()
    private let composer = ThemeSurface(Theme.panel, border: Theme.border, radius: 18)
    private var stateLine: NSStackView!
    private var collapsedState: NSLayoutConstraint!
    private var sendButton: ClosureButton!
    private var stopButton: ClosureButton!
    private var fallbackButton: ClosureButton!
    private var drafts: [String: String] = [:]
    private var modes: [String: String] = [:]
    private var expandedTools: Set<String> = []
    private var renderedSignature = ""
    private var rendering = false
    private var renderRevision = 0
    private var runtime: ChatRuntime?
    private var startupError: String?
    private var displayedID: String?

    init(project: ProjectRecord) {
        self.project = project
        super.init(frame: .zero)
        buildInterface()
        do {
            let controller = try ChatRuntime(project: project)
            runtime = controller
            controller.onChange = { [weak self] in self?.refresh() }
            controller.beforeStart = { [weak self] arguments in try self?.beforeStart?(arguments) }
            if controller.selectedID == nil { controller.createConversation() }
        } catch { startupError = OperationPresentation.clean(error.localizedDescription) }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildInterface() {
        history.hasVerticalScroller = true; history.hasHorizontalScroller = false
        history.autohidesScrollers = true
        history.drawsBackground = false; history.borderType = .noBorder
        history.documentView = document
        history.translatesAutoresizingMaskIntoConstraints = false; addSubview(history)
        document.translatesAutoresizingMaskIntoConstraints = false
        messages.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(messages)
        messages.setContentHuggingPriority(.required, for: .vertical)
        let naturalWidth = messages.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -32)
        // Below NSWindow's size-stay-put priority: a capped reading column
        // must never pull a wider user-sized window back down to its own width.
        naturalWidth.priority = .init(490)
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: history.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: history.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: history.contentView.widthAnchor),
            messages.topAnchor.constraint(equalTo: document.topAnchor, constant: 32),
            messages.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            messages.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 16),
            messages.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -16),
            messages.widthAnchor.constraint(lessThanOrEqualToConstant: 760), naturalWidth,
            messages.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28)
        ])

        let greeting = label("今天想完成什么？", size: 28, weight: .medium)
        greeting.alignment = .center
        let hint = label("描述任务，开始对话。", size: 14, color: Theme.muted)
        hint.alignment = .center
        fillWidth(greeting, in: emptyState); fillWidth(hint, in: emptyState)
        emptyState.translatesAutoresizingMaskIntoConstraints = false; addSubview(emptyState)
        let greetingWidth = emptyState.widthAnchor.constraint(equalTo: history.contentView.widthAnchor, constant: -48)
        greetingWidth.priority = .init(490)
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: history.contentView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: history.centerYAnchor, constant: -36),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            emptyState.widthAnchor.constraint(lessThanOrEqualToConstant: 760), greetingWidth
        ])

        input.isRichText = false; input.font = Theme.font(size: 15)
        input.textColor = Theme.text; input.drawsBackground = false; input.insertionPointColor = Theme.text
        input.textContainerInset = NSSize(width: 1, height: 10)
        input.isVerticallyResizable = true; input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]; input.textContainer?.widthTracksTextView = true
        input.isAutomaticQuoteSubstitutionEnabled = false; input.isAutomaticDashSubstitutionEnabled = false
        input.isAutomaticSpellingCorrectionEnabled = false; input.delegate = self
        input.setAccessibilityLabel("对话输入"); input.onSubmit = { [weak self] in self?.send() }
        let editor = ThemeScrollView(); editor.documentView = input
        editor.hasVerticalScroller = true; editor.hasHorizontalScroller = false
        editor.drawsBackground = false; editor.borderType = .noBorder
        editor.heightAnchor.constraint(equalToConstant: 66).isActive = true

        permissionPicker.addItems(withTitles: ["询问权限", "允许编辑", "只做计划"])
        for (item, value) in zip(permissionPicker.itemArray, ["default", "acceptEdits", "plan"]) { item.representedObject = value }
        permissionPicker.font = Theme.font(size: 12)
        permissionPicker.isBordered = false
        permissionPicker.setAccessibilityLabel("本轮权限模式")
        permissionPicker.toolTip = "询问权限：保留标准权限检查。允许编辑：允许修改项目文件。只做计划：分析和规划。"
        permissionPicker.target = self; permissionPicker.action = #selector(permissionChanged)
        sendButton = ClosureButton("", symbol: "arrow.up") { [weak self] in self?.send() }
        sendButton.imagePosition = .imageOnly; sendButton.bezelColor = Theme.primary
        sendButton.contentTintColor = Theme.onPrimary; sendButton.toolTip = "发送（⌘ Return）"
        sendButton.setAccessibilityLabel("发送消息")
        stopButton = ClosureButton("", symbol: "stop.fill") { [weak self] in self?.stop() }
        stopButton.imagePosition = .imageOnly; stopButton.bezelColor = Theme.primary
        stopButton.contentTintColor = Theme.onPrimary; stopButton.toolTip = "停止当前任务"
        stopButton.setAccessibilityLabel("停止当前任务")
        for button in [sendButton!, stopButton!] {
            button.cornerRadius = 17
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        }
        stopButton.isHidden = true
        let controls = row([permissionPicker, spacer(), stopButton, sendButton], spacing: 6)
        let composerBody = column([], spacing: 0)
        fillWidth(editor, in: composerBody); fillWidth(controls, in: composerBody)
        composerBody.translatesAutoresizingMaskIntoConstraints = false; composer.addSubview(composerBody)
        composer.translatesAutoresizingMaskIntoConstraints = false; addSubview(composer)
        let composerWidth = composer.widthAnchor.constraint(equalTo: history.contentView.widthAnchor, constant: -32)
        composerWidth.priority = .init(490)
        NSLayoutConstraint.activate([
            composerBody.topAnchor.constraint(equalTo: composer.topAnchor, constant: 6),
            composerBody.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 14),
            composerBody.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -14),
            composerBody.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -14),
            composer.centerXAnchor.constraint(equalTo: history.contentView.centerXAnchor),
            composer.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            composer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            composer.widthAnchor.constraint(lessThanOrEqualToConstant: 760), composerWidth
        ])

        fallbackButton = ClosureButton("在终端继续", symbol: "terminal") { [weak self] in
            guard let self, let runtime = self.runtime, !runtime.hasRunning else { return }
            if runtime.currentConversationTransferred {
                // The terminal may have changed accounts since handoff. Its live
                // owner is the only safe target; never relaunch the old native ID.
                self.onShowTerminal?()
            } else if let handoff = self.onTerminalFallback {
                do {
                    try handoff(runtime.terminalFallback)
                    runtime.markTransferredToTerminal()
                    self.refresh()
                } catch { showError(OperationPresentation.clean(error.localizedDescription), window: self.window) }
            }
        }
        fallbackButton.isBordered = false; fallbackButton.font = Theme.font(size: 12)
        fallbackButton.isHidden = true
        status.maximumNumberOfLines = 1; status.lineBreakMode = .byTruncatingTail
        stateLine = row([status, spacer(), fallbackButton], spacing: 8)
        stateLine.translatesAutoresizingMaskIntoConstraints = false; addSubview(stateLine)
        collapsedState = stateLine.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            history.topAnchor.constraint(equalTo: topAnchor),
            history.leadingAnchor.constraint(equalTo: leadingAnchor),
            history.trailingAnchor.constraint(equalTo: trailingAnchor),
            history.bottomAnchor.constraint(equalTo: stateLine.topAnchor, constant: -8),
            stateLine.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -10),
            composer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
            stateLine.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
            stateLine.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            stateLine.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        ])
    }

    func focusInput() { window?.makeFirstResponder(input) }

    func stop() { runtime?.stop() }

    func newConversation() {
        guard let runtime else { return }
        guard !runtime.hasRunning else {
            showError("请先停止当前任务，再新建对话。", window: window); return
        }
        confirmNewConversation { [weak self] in
            guard let self, let runtime = self.runtime, !runtime.hasRunning else { return }
            self.saveDraft(); runtime.createConversation(); self.refresh(); self.focusInput()
        }
    }

    private func refresh() {
        guard !rendering else { return }
        rendering = true
        defer { rendering = false }
        let selectedID = runtime?.selectedID
        let changedConversation = displayedID != selectedID
        if changedConversation {
            saveDraft(); displayedID = selectedID
            input.string = selectedID.flatMap { drafts[$0] } ?? ""
            input.needsDisplay = true
            let selectedMode = selectedID.flatMap { modes[$0] } ?? "default"
            if let item = permissionPicker.itemArray.first(where: { $0.representedObject as? String == selectedMode }) {
                permissionPicker.select(item)
            }
        }
        let visible = (runtime?.currentMessages ?? []).map { message in
            DisplayMessage(id: message.id, role: message.role, text: message.text,
                           title: message.toolName.map(toolTitle), isError: message.role == "error")
        }
        displayMessages(visible, conversationID: selectedID ?? "", scrollToEnd: changedConversation)
        updateControls()
        onStateChange?()
    }

    private func updateControls() {
        guard sendButton != nil else { return }
        let active = hasRunning
        let needsInteraction = runtime?.needsTerminalInteraction ?? false
        let transferred = runtime?.currentConversationTransferred ?? false
        sendButton.isEnabled = runtime != nil && !active && !transferred && !input.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isHidden = active
        stopButton.isHidden = !active
        permissionPicker.isEnabled = runtime != nil && !active && !transferred
        input.isEditable = runtime != nil && !transferred
        fallbackButton.title = transferred ? "打开终端" : "在终端继续"
        fallbackButton.isHidden = transferred ? onShowTerminal == nil : (!needsInteraction || onTerminalFallback == nil)
        fallbackButton.isEnabled = !active
        status.stringValue = startupError ?? (transferred ? "已转到终端" : runtime?.stateText ?? "")
        status.toolTip = status.stringValue
        status.textColor = startupError != nil || needsInteraction ? Theme.warning : Theme.muted
        let idleStates = ["可以开始新任务", "继续这段对话", "已完成，可以继续提问", "已停止，已保存这段对话"]
        let needsStatus = !status.stringValue.isEmpty && !idleStates.contains(status.stringValue)
        let showsState = active || needsInteraction || transferred || startupError != nil || needsStatus
        status.isHidden = !showsState; stateLine.isHidden = !showsState; collapsedState.isActive = !showsState
        emptyState.isHidden = !(runtime?.currentMessages.isEmpty == true && !active && startupError == nil)
    }

    private func saveDraft() {
        guard let displayedID else { return }
        drafts[displayedID] = input.string
        modes[displayedID] = permissionPicker.selectedItem?.representedObject as? String ?? "default"
    }

    func textDidChange(_ notification: Notification) {
        guard !rendering else { return }
        saveDraft(); input.needsDisplay = true; updateControls()
    }

    func selectConversation(id: String) {
        guard let runtime, !runtime.hasRunning, runtime.conversations.contains(where: { $0.id == id }) else { return }
        saveDraft(); runtime.select(id: id); refresh()
    }

    @objc private func permissionChanged() { saveDraft() }

    private func send() {
        guard let runtime, !runtime.hasRunning, !runtime.currentConversationTransferred else { return }
        let text = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let rawMode = permissionPicker.selectedItem?.representedObject as? String ?? "default"
        let mode = ChatPermissionMode(rawValue: rawMode) ?? .default
        let userMessages = runtime.currentMessages.filter { $0.role == "user" }.count
        runtime.send(text: text, permissionMode: mode)
        if runtime.hasRunning || runtime.currentMessages.filter({ $0.role == "user" }).count > userMessages {
            input.string = ""; input.needsDisplay = true
            if let id = runtime.selectedID { drafts[id] = ""; modes[id] = rawMode }
        }
        refresh(); focusInput()
    }

    private func toolTitle(_ name: String) -> String {
        switch name {
        case "Read": return "读取文件"
        case "Write": return "写入文件"
        case "Edit", "MultiEdit": return "编辑文件"
        case "Bash": return "执行项目操作"
        case "Grep", "Glob": return "查找项目内容"
        case "WebSearch": return "搜索资料"
        case "WebFetch": return "读取网页"
        case "Task", "Agent": return "协作任务"
        case "TodoWrite": return "更新计划"
        case "AskUserQuestion": return "需要你的回答"
        default: return name
        }
    }

    private func addMessage(id: String, role: String, text: String, title: String?, isError: Bool = false) {
        if role == "tool" {
            let expanded = expandedTools.contains(id)
            let name = title ?? "工具操作"
            let toggle = ClosureButton(name, symbol: expanded ? "chevron.down" : "chevron.right") { [weak self] in
                guard let self else { return }
                if self.expandedTools.contains(id) { self.expandedTools.remove(id) } else { self.expandedTools.insert(id) }
                self.renderedSignature = ""; self.refresh()
            }
            toggle.isBordered = false; toggle.contentTintColor = isError ? Theme.warning : Theme.muted
            toggle.font = Theme.font(size: 12, weight: .medium)
            toggle.setAccessibilityLabel((expanded ? "折叠" : "展开") + name)
            let body = column([toggle], spacing: 7)
            if expanded {
                let detail = messageText(text, color: isError ? Theme.warning : Theme.muted)
                fillWidth(detail, in: body)
            }
            fillWidth(body, in: messages)
            return
        }
        let body = column([], spacing: 8)
        let content = messageText(text, color: isError ? Theme.warning : (role == "notice" ? Theme.muted : Theme.text))
        fillWidth(content, in: body)
        if role == "user" {
            let surface = ThemeSurface(Theme.panel, radius: 14)
            body.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(body)
            NSLayoutConstraint.activate([
                body.topAnchor.constraint(equalTo: surface.topAnchor, constant: 14),
                body.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
                body.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16),
                body.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -14)
            ])
            fillWidth(surface, in: messages)
        } else { fillWidth(body, in: messages) }
    }

    private func messageText(_ text: String, color: NSColor) -> NSTextField {
        let field = label(text.isEmpty ? "…" : text, size: 15, color: color)
        field.isSelectable = true; field.maximumNumberOfLines = 0; field.lineBreakMode = .byWordWrapping
        let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = 22; paragraph.maximumLineHeight = 22; paragraph.paragraphSpacing = 8
        field.attributedStringValue = NSAttributedString(string: field.stringValue, attributes: [
            .font: Theme.font(size: 15), .foregroundColor: color, .paragraphStyle: paragraph
        ])
        return field
    }

    private struct DisplayMessage {
        let id: String
        let role: String
        let text: String
        let title: String?
        let isError: Bool
    }

    private func displayMessages(_ items: [DisplayMessage], conversationID: String, scrollToEnd: Bool = false) {
        let signature = conversationID + items.map { $0.id + $0.role + $0.text + ($0.title ?? "") + String($0.isError) }.joined(separator: "\u{1e}")
            + expandedTools.sorted().joined(separator: "\u{1f}")
        guard signature != renderedSignature else { return }
        renderedSignature = signature
        let previousOffset = history.contentView.bounds.origin.y
        let followsOutput = scrollToEnd || document.bounds.height - history.contentView.bounds.maxY < 80
        for view in messages.arrangedSubviews { messages.removeArrangedSubview(view); view.removeFromSuperview() }
        for message in items {
            if message.role == "user", let previous = messages.arrangedSubviews.last { messages.setCustomSpacing(32, after: previous) }
            addMessage(id: message.id, role: message.role, text: message.text, title: message.title, isError: message.isError)
        }
        renderRevision += 1
        let revision = renderRevision
        needsLayout = true; layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.renderRevision == revision else { return }
            self.layoutSubtreeIfNeeded()
            let maximum = max(0, self.document.bounds.height - self.history.contentView.bounds.height)
            self.history.contentView.scroll(to: NSPoint(x: 0, y: followsOutput ? maximum : min(previousOffset, maximum)))
            self.history.reflectScrolledClipView(self.history.contentView)
        }
    }

    private func confirmNewConversation(then create: @escaping () -> Void) {
        guard !input.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { create(); return }
        let alert = NSAlert(); alert.messageText = "当前内容尚未发送"
        alert.informativeText = "草稿会保留在当前对话中。"
        alert.addButton(withTitle: "保留草稿并新建"); alert.addButton(withTitle: "取消")
        if let window {
            alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { create() } }
        } else if alert.runModal() == .alertFirstButtonReturn { create() }
    }
}
