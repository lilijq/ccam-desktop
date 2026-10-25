import AppKit
import UniformTypeIdentifiers
import Quartz

private final class ChatDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Keep native menu, keyboard and accessibility behavior while making the
/// selected model and mode read as one quiet line of conversation controls.
private final class ComposerMenuButton: NSPopUpButton {
    var showsMode = false
    var showsEffort = false
    private var hovering = false
    private var tracking: NSTrackingArea?

    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        isBordered = false; focusRingType = .exterior
        font = Theme.font(size: 12, weight: .medium)
    }
    required init?(coder: NSCoder) { fatalError() }
    // AppKit's pop-up bezel has invisible alignment overhangs. This control
    // draws its own bounds, so adjacent model/effort/mode hit areas must not overlap.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 1, dy: 1) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 7, yRadius: 7).fill() }
    override func draw(_ dirtyRect: NSRect) {
        let mode = selectedItem?.representedObject as? String ?? "default"
        let activeMode = showsMode && mode != "default"
        if hovering || isHighlighted || activeMode {
            (hovering || isHighlighted ? Theme.border : Theme.button).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
        let color = isEnabled ? Theme.text : Theme.muted
        var x: CGFloat = 8
        var text = titleOfSelectedItem ?? ""
        if showsEffort && mode.isEmpty { text = "思考" }
        if showsMode {
            text = ["default": "默认", "plan": "计划", "auto": "Auto", "acceptEdits": "编辑"][mode] ?? text
            let symbol = ["default": "hand.raised", "plan": "list.bullet.clipboard", "auto": "sparkle", "acceptEdits": "pencil"][mode] ?? "hand.raised"
            if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [color])) {
                let scale = min(13 / max(1, icon.size.width), 13 / max(1, icon.size.height))
                let size = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
                icon.draw(in: NSRect(x: x + (13-size.width)/2, y: (bounds.height-size.height)/2, width: size.width, height: size.height))
            }
            x += 18
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let value = NSAttributedString(string: text, attributes: [.font: font ?? Theme.font(size: 12), .foregroundColor: color, .paragraphStyle: paragraph])
        value.draw(in: NSRect(x: x, y: (bounds.height-value.size().height)/2, width: max(0, bounds.width-x-20), height: value.size().height))
        let arrow = NSBezierPath(); arrow.lineWidth = 1.25; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
        let direction: CGFloat = isFlipped ? 1 : -1
        arrow.move(to: NSPoint(x: bounds.width-14, y: bounds.midY-direction*1.5))
        arrow.line(to: NSPoint(x: bounds.width-11, y: bounds.midY+direction*1.5))
        arrow.line(to: NSPoint(x: bounds.width-8, y: bounds.midY-direction*1.5))
        Theme.muted.setStroke(); arrow.stroke()
    }
}

private final class ChatInputView: NSTextView {
    var onSubmit: (() -> Void)?
    var onAttachment: ((NSPasteboard) -> Bool)?
    var placeholder = "描述任务，或继续提问…" { didSet { needsDisplay = true } }
    override func paste(_ sender: Any?) {
        if isEditable, onAttachment?(NSPasteboard.general) == true { return }
        super.paste(sender)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isEditable, AttachmentPasteboard.recognizes(sender.draggingPasteboard) { return .copy }
        return super.draggingEntered(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if isEditable, onAttachment?(sender.draggingPasteboard) == true { return true }
        return super.performDragOperation(sender)
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            onSubmit?()
        } else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let placeholder = NSAttributedString(string: self.placeholder, attributes: [
            .font: Theme.font(size: 15), .foregroundColor: Theme.muted
        ])
        placeholder.draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height))
    }
}

/// Approval stays beside the composer, with the complete operation readable
/// before an explicit decision; reusable tool grants are scoped to this project.
final class ChatApprovalCard: ThemeSurface {
    let approveButton: ClosureButton
    let denyButton: ClosureButton
    let detailView = NSTextView()
    let rememberChoice = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    init(title: String, detail: String, actionTitle: String, canApprove: Bool,
         approve: @escaping () -> Void, deny: @escaping () -> Void, rememberTool: String? = nil, approveRemembering: ((Bool) -> Void)? = nil) {
        approveButton = ClosureButton(actionTitle, symbol: "checkmark", action: approve)
        denyButton = ClosureButton("拒绝", symbol: "xmark", action: deny)
        super.init(Theme.panel, border: Theme.border, radius: 12)
        let heading = label(title, size: 13, weight: .medium)
        heading.maximumNumberOfLines = 1; heading.lineBreakMode = .byTruncatingTail; heading.toolTip = title
        detailView.isEditable = false; detailView.isSelectable = true; detailView.isRichText = false
        detailView.string = detail; detailView.font = Theme.font(size: 12); detailView.textColor = Theme.text
        detailView.drawsBackground = false; detailView.textContainerInset = NSSize(width: 0, height: 4)
        detailView.isVerticallyResizable = true; detailView.isHorizontallyResizable = false
        detailView.autoresizingMask = [.width]; detailView.textContainer?.widthTracksTextView = true
        detailView.setAccessibilityLabel("待确认操作详情")
        let scroll = ThemeScrollView(); scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = detailView
        scroll.heightAnchor.constraint(equalToConstant: 72).isActive = true
        approveButton.isEnabled = canApprove
        approveButton.bezelColor = Theme.primary; approveButton.contentTintColor = Theme.onPrimary
        approveButton.setAccessibilityLabel(actionTitle); denyButton.setAccessibilityLabel("拒绝这次操作")
        rememberChoice.title = "记住此项目的 " + (rememberTool ?? "") + " 权限"
        rememberChoice.font = Theme.font(size: 11); rememberChoice.state = .on
        rememberChoice.toolTip = "此项目内后续调用同一工具将自动允许；包括不同命令或文件。可在权限模式菜单中清除。"
        rememberChoice.setAccessibilityLabel(rememberChoice.title)
        rememberChoice.isHidden = rememberTool == nil
        if let approveRemembering {
            approveButton.actionBlock = { [weak self] in approveRemembering(self?.rememberChoice.state == .on) }
        }
        let actions = row([spacer(), denyButton, approveButton], spacing: 8)
        let body = column([], spacing: 6)
        for view in [heading, scroll, rememberChoice, actions] { fillWidth(view, in: body) }
        body.translatesAutoresizingMaskIntoConstraints = false; addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor, constant: 12), body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class ChatQuestionForm: NSView, NSTextFieldDelegate {
    private let questions: [ChatApprovalQuestion]
    private var choices: [[NSButton]] = []
    private var custom: [NSTextField] = []
    var onChange: (() -> Void)?
    override var isFlipped: Bool { true }

    init(questions: [ChatApprovalQuestion], width: CGFloat) {
        self.questions = questions
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        let body = column([], spacing: 20); body.translatesAutoresizingMaskIntoConstraints = false; addSubview(body)
        for (index, question) in questions.enumerated() {
            let group = column([], spacing: 6)
            let heading = label(question.question, size: 13, weight: .medium)
            fillWidth(heading, in: group)
            var buttons: [NSButton] = []
            for option in question.options {
                let button = NSButton(title: option.label, target: self, action: #selector(selectOption(_:)))
                button.setButtonType(question.multiSelect ? .switch : .radio)
                button.tag = index; button.font = Theme.font(size: 12)
                (button.cell as? NSButtonCell)?.wraps = true
                button.setAccessibilityLabel(option.label); button.toolTip = option.description
                fillWidth(button, in: group); buttons.append(button)
                if !option.description.isEmpty { fillWidth(label(option.description, size: 11, color: Theme.muted), in: group) }
            }
            choices.append(buttons)
            let field = NSTextField(string: ""); field.placeholderString = "填写其他回答…"
            field.font = Theme.font(size: 12); field.delegate = self; field.tag = index
            field.setAccessibilityLabel("其他回答：" + question.question)
            custom.append(field); fillWidth(field, in: group); fillWidth(group, in: body)
        }
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor, constant: 4), body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func selectOption(_ sender: NSButton) {
        let index = sender.tag
        if !questions[index].multiSelect {
            for button in choices[index] { button.state = button === sender ? .on : .off }
            custom[index].stringValue = ""
        }
        onChange?()
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if !questions[field.tag].multiSelect, !field.stringValue.isEmpty { choices[field.tag].forEach { $0.state = .off } }
        onChange?()
    }
    var answers: [String: String]? {
        var result: [String: String] = [:]
        for (index, question) in questions.enumerated() {
            var values = choices[index].filter { $0.state == .on }.map(\.title)
            let text = custom[index].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { values.append(text) }
            guard !values.isEmpty else { return nil }
            result[question.question] = values.joined(separator: ", ")
        }
        return result
    }
}

/// Presentation only. A retained project view owns its input and scroll position;
/// the chat controller owns process, account, and conversation state.
final class ProjectChatView: NSView, NSTextViewDelegate {
    let project: ProjectRecord
    let boundConversationID: String?
    var onNewConversationRequested: (() -> Void)?
    var boundConversationUnavailable: Bool { boundConversationID != nil && (runtime == nil || runtime?.boundConversationUnavailable == true) }
    var onTerminalFallback: ((ChatTerminalTarget) throws -> Void)? { didSet { updateControls() } }
    var onShowTerminal: (() -> Void)? { didSet { updateControls() } }
    var onReturnFromTerminal: ((ChatTerminalTarget, @escaping (Result<ChatTerminalTarget, Error>) -> Void) -> Void)? { didSet { updateControls() } }
    var onStateChange: (() -> Void)?
    var onTurnFinished: (() -> Void)?
    var beforeStart: (([String]) throws -> Void)?
    var webMCPArguments: (() throws -> [String])?
    var hasRunning: Bool { (runtime?.hasRunning ?? false) || outgoingTranslationID != nil }
    var historyItems: [(id: String, title: String)] {
        (runtime?.activeConversations ?? []).map { conversation in
            let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return (conversation.id, title.isEmpty ? "新对话" : title)
        }
    }
    var selectedConversationID: String? { runtime?.selectedID }
    var selectedAccountName: String? { runtime?.currentConversation?.account }

    private let permissionPicker = ComposerMenuButton(frame: .zero, pullsDown: false)
    private let modelPicker = ComposerMenuButton(frame: .zero, pullsDown: false)
    private let effortPicker = ComposerMenuButton(frame: .zero, pullsDown: false)
    private let status = label("", size: 12, color: Theme.muted)
    private let history = ThemeScrollView()
    private let document = ChatDocumentView()
    private let messages = column([], spacing: 20)
    private let emptyState = column([], spacing: 12)
    private let input = ChatInputView()
    private let composer = ThemeSurface(Theme.panel, border: Theme.border, radius: 18)
    private let approvalArea = column([], spacing: 0)
    private var approvalSignature = ""
    private var collapsedApproval: NSLayoutConstraint!
    private var questionSheet: NSAlert?
    private var questionApprovalID: String?
    private var stateLine: NSStackView!
    private var collapsedState: NSLayoutConstraint!
    private var sendButton: ClosureButton!
    private var stopButton: ClosureButton!
    private var fallbackButton: ClosureButton!
    private var returnButton: ClosureButton!
    private var returningConversationID: String?
    private weak var conversationActionsAnchor: NSView?
    private var conversationPresentingWindow: NSWindow? { window ?? conversationActionsAnchor?.window }
    private var attachButton: ClosureButton!
    private let attachments = AttachmentStrip()
    private var attachmentHeight: NSLayoutConstraint!
    private var attachmentSignature = ""
    private var previewPopover: NSPopover?
    private var drafts: [String: String] = [:]
    private var expandedTools: Set<String> = []
    private var expandedProcesses: Set<String> = []
    private var renderedSignature = ""
    private var rendering = false
    private var renderRevision = 0
    private var runtime: ChatRuntime?
    private var startupError: String?
    private var displayedID: String?
    private let translator: ChatTranslating
    private var translationButton: ClosureButton!
    private var retryTranslationButton: ClosureButton!
    private var outgoingTranslationID: UUID?
    private var outgoingTranslation: TranslationRequest?
    private var translationStatus: String?
    private var translationFailed = false
    private struct TranslationRetryDraft {
        let conversationID: String?
        let text: String
        let attachmentIDs: [String]
        let options: ChatOptions
    }
    private var translationRetryDraft: TranslationRetryDraft?
    private var streamingReplies: [String: StreamingReplyTranslation] = [:]
    private var replyRequests: [String: TranslationRequest] = [:]
    private var replyRequestIDs: [String: UUID] = [:]
    private var replyErrors: [String: String] = [:]
    private var expandedTranslations: Set<String> = []
    private var expandedSentTexts: Set<String> = []

    static func createConversation(project: ProjectRecord) throws -> String {
        try ChatStore(project: project).createConversation()
    }

    init(project: ProjectRecord, conversationID: String? = nil, translator: ChatTranslating = LocalTranslator.shared, controller: ChatRuntime? = nil) {
        self.project = project; self.translator = translator
        self.boundConversationID = conversationID ?? controller?.boundConversationID
        super.init(frame: .zero)
        buildInterface()
        registerForDraggedTypes([.fileURL, .png, .tiff])
        do {
            let controller = try controller ?? ChatRuntime(project: project, conversationID: conversationID)
            if let boundConversationID, controller.selectedID != boundConversationID {
                throw AppError.message("对话面板与会话不匹配，未打开其他对话。")
            }
            runtime = controller
            controller.onChange = { [weak self] in self?.refresh() }
            controller.onTurnFinished = { [weak self] in
                self?.translateCompletedReplies()
                self?.onTurnFinished?()
            }
            controller.webMCPArguments = { [weak self] in try self?.webMCPArguments?() ?? [] }
            controller.beforeStart = { [weak self] arguments in try self?.beforeStart?(arguments) }
            if controller.selectedID == nil, boundConversationID == nil { controller.createConversation() }
        } catch { startupError = OperationPresentation.clean(error.localizedDescription) }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        outgoingTranslation?.cancel()
        replyRequests.values.forEach { $0.cancel() }
        streamingReplies.values.forEach { $0.cancel() }
    }

    private func buildInterface() {
        history.hasVerticalScroller = true; history.hasHorizontalScroller = false
        history.autohidesScrollers = true
        history.drawsBackground = false; history.borderType = .noBorder
        history.wantsLayer = true; document.wantsLayer = true
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
        input.textContainerInset = NSSize(width: 3, height: 10)
        input.isVerticallyResizable = true; input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]; input.textContainer?.widthTracksTextView = true
        input.isAutomaticQuoteSubstitutionEnabled = false; input.isAutomaticDashSubstitutionEnabled = false
        input.isAutomaticSpellingCorrectionEnabled = false; input.delegate = self
        input.setAccessibilityLabel("对话输入"); input.onSubmit = { [weak self] in self?.send() }
        input.registerForDraggedTypes([.fileURL, .png, .tiff, .string])
        input.onAttachment = { [weak self] board in self?.receiveAttachments(board) ?? false }
        let editor = ThemeScrollView(); editor.documentView = input
        editor.hasVerticalScroller = true; editor.hasHorizontalScroller = false
        editor.drawsBackground = false; editor.borderType = .noBorder
        editor.heightAnchor.constraint(equalToConstant: 68).isActive = true

        modelPicker.addItems(withTitles: ["默认模型", "Sonnet", "Opus", "Haiku", "自定义…"])
        for (item, value) in zip(modelPicker.itemArray, ["", "sonnet", "opus", "haiku", "__custom__"]) { item.representedObject = value }
        modelPicker.setAccessibilityLabel("选择模型")
        modelPicker.toolTip = "选择本次对话的模型；切换后保留上下文，发送时生效。"
        modelPicker.target = self; modelPicker.action = #selector(modelChanged)
        effortPicker.addItems(withTitles: ["默认强度", "低", "中", "高", "很高", "最高"])
        for (item, value) in zip(effortPicker.itemArray, ["", "low", "medium", "high", "xhigh", "max"]) { item.representedObject = value }
        effortPicker.showsEffort = true
        effortPicker.setAccessibilityLabel("选择思考强度")
        effortPicker.target = self; effortPicker.action = #selector(effortChanged)
        permissionPicker.addItems(withTitles: ["默认模式", "计划模式", "Auto 模式", "允许编辑"])
        for (item, value) in zip(permissionPicker.itemArray, ["default", "plan", "auto", "acceptEdits"]) { item.representedObject = value }
        permissionPicker.menu?.addItem(.separator())
        let clearPermissions = NSMenuItem(title: "清除记住的权限", action: nil, keyEquivalent: "")
        clearPermissions.tag = 99; permissionPicker.menu?.addItem(clearPermissions)
        permissionPicker.showsMode = true
        for (picker, width) in [(modelPicker, 86.0), (effortPicker, 64.0), (permissionPicker, 74.0)] {
            picker.widthAnchor.constraint(equalToConstant: width).isActive = true
            picker.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
        permissionPicker.setAccessibilityLabel("选择权限模式")
        permissionPicker.toolTip = "默认：在聊天中逐次确认操作。计划：先分析和规划，修改前确认。Auto：自动评估操作权限，可用性由模型和服务决定。允许编辑：自动允许文件编辑。"
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
        attachButton = ClosureButton("", symbol: "paperclip") { [weak self] in self?.chooseAttachments() }
        attachButton.isBordered = false; attachButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        attachButton.setAccessibilityLabel("添加图片或文件"); attachButton.toolTip = "添加图片或文件；也可以拖入文件或粘贴截图"
        let controls = row([attachButton, modelPicker, effortPicker, permissionPicker, spacer(), stopButton, sendButton], spacing: 3)
        translationButton = ClosureButton("中→EN") { [weak self] in self?.showTranslationMenu() }
        translationButton.font = Theme.font(size: 10, weight: .semibold)
        translationButton.cornerRadius = 7
        translationButton.widthAnchor.constraint(equalToConstant: 62).isActive = true
        translationButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        editor.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let inputRow = row([editor, translationButton], spacing: 8); inputRow.alignment = .top
        let composerBody = column([], spacing: 0)
        attachmentHeight = attachments.heightAnchor.constraint(equalToConstant: 0); attachmentHeight.isActive = true
        attachments.isHidden = true
        fillWidth(attachments, in: composerBody); fillWidth(inputRow, in: composerBody); fillWidth(controls, in: composerBody)
        composerBody.translatesAutoresizingMaskIntoConstraints = false; composer.addSubview(composerBody)
        composer.translatesAutoresizingMaskIntoConstraints = false; addSubview(composer)
        let composerWidth = composer.widthAnchor.constraint(equalTo: history.contentView.widthAnchor, constant: -32)
        composerWidth.priority = .init(490)
        NSLayoutConstraint.activate([
            composerBody.topAnchor.constraint(equalTo: composer.topAnchor, constant: 12),
            composerBody.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 12),
            composerBody.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -12),
            composerBody.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -12),
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
                    try runtime.transferToTerminal(start: handoff)
                    self.refresh()
                } catch { showError(OperationPresentation.clean(error.localizedDescription), window: self.window) }
            }
        }
        fallbackButton.isBordered = false; fallbackButton.font = Theme.font(size: 12)
        fallbackButton.isHidden = true
        returnButton = ClosureButton("返回聊天", symbol: "arrow.uturn.backward") { [weak self] in self?.returnFromTerminal() }
        returnButton.font = Theme.font(size: 12); returnButton.isHidden = true
        returnButton.setAccessibilityLabel("返回聊天")
        returnButton.toolTip = "结束该对话的终端任务，保留上下文并恢复聊天。"
        retryTranslationButton = ClosureButton("重试翻译", symbol: "arrow.clockwise") { [weak self] in self?.send() }
        retryTranslationButton.font = Theme.font(size: 12)
        retryTranslationButton.setAccessibilityLabel("重试翻译")
        retryTranslationButton.toolTip = "重新翻译输入框中的草稿，成功后发送。"
        retryTranslationButton.isHidden = true
        status.maximumNumberOfLines = 1; status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stateLine = row([status, spacer(), retryTranslationButton, returnButton, fallbackButton], spacing: 8)
        stateLine.translatesAutoresizingMaskIntoConstraints = false; addSubview(stateLine)
        approvalArea.translatesAutoresizingMaskIntoConstraints = false; addSubview(approvalArea)
        collapsedApproval = approvalArea.heightAnchor.constraint(equalToConstant: 0); collapsedApproval.isActive = true
        collapsedState = stateLine.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            history.topAnchor.constraint(equalTo: topAnchor),
            history.leadingAnchor.constraint(equalTo: leadingAnchor),
            history.trailingAnchor.constraint(equalTo: trailingAnchor),
            history.bottomAnchor.constraint(equalTo: approvalArea.topAnchor, constant: -8),
            approvalArea.bottomAnchor.constraint(equalTo: stateLine.topAnchor, constant: -8),
            approvalArea.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
            approvalArea.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            stateLine.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -10),
            composer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
            stateLine.leadingAnchor.constraint(equalTo: composer.leadingAnchor),
            stateLine.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            stateLine.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        ])
    }

    func focusInput() { window?.makeFirstResponder(input) }

    func recordTerminalState(target: ChatTerminalTarget, uncertain: Bool) throws {
        guard let runtime, let id = target.conversationID,
              GlobalPool.sameDirectory(target.directory, project.path) else {
            throw AppError.message("无法确认终端对应的聊天记录，暂未更新会话身份。")
        }
        try runtime.recordTerminalState(conversationID: id, account: target.account, sessionID: target.sessionID,
                                        ticket: target.ticket, uncertain: uncertain)
    }

    private func returnFromTerminal() {
        guard let runtime, runtime.currentConversationTransferred, !runtime.hasRunning,
              let id = runtime.selectedID, returningConversationID == nil,
              let handback = onReturnFromTerminal else { return }
        saveDraft(); returningConversationID = id; updateControls()
        handback(runtime.terminalFallback) { [weak self] result in
            guard let self, self.returningConversationID == id else { return }
            self.returningConversationID = nil
            do {
                let target = try result.get()
                guard target.canResume, GlobalPool.sameDirectory(target.directory, self.project.path) else {
                    throw AppError.message("无法确认终端里的原会话，暂未恢复发送。")
                }
                try self.runtime?.restoreFromTerminal(conversationID: id, account: target.account, sessionID: target.sessionID, ticket: target.ticket)
                self.refresh(); if self.runtime?.selectedID == id { self.focusInput() }
            } catch { self.updateControls(); showError(OperationPresentation.clean(error.localizedDescription), window: self.window) }
        }
    }

    func stop() {
        if outgoingTranslationID != nil {
            cancelOutgoingTranslation()
            translationStatus = "已取消翻译，草稿已保留"; translationFailed = false
            refresh(); focusInput()
        } else { runtime?.stop() }
    }

    private func cancelOutgoingTranslation() {
        translationRetryDraft = nil
        outgoingTranslationID = nil
        let request = outgoingTranslation; outgoingTranslation = nil
        request?.cancel()
    }

    private func cancelReplyTranslations() {
        streamingReplies.values.forEach { $0.cancel() }; streamingReplies.removeAll()
        replyRequestIDs.removeAll()
        let requests = replyRequests; replyRequests.removeAll()
        requests.values.forEach { $0.cancel() }
    }


    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        !hasRunning && runtime?.currentConversationTransferred != true && AttachmentPasteboard.recognizes(sender.draggingPasteboard) ? .copy : []
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggingEntered(sender) == .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { receiveAttachments(sender.draggingPasteboard) }

    private func chooseAttachments() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.title = "添加图片或文件"; panel.prompt = "添加"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            do { try self.addAttachments(panel.urls) }
            catch { showError(error.localizedDescription, window: self.window) }
        }
    }

    /// Local staging only; the runtime does not send a request until Send is pressed.
    func addAttachments(_ urls: [URL]) throws {
        guard let runtime, !hasRunning, !runtime.currentConversationTransferred else { throw AppError.message("请等待本轮完成，再添加附件。") }
        let store = ChatAttachmentStore(project: project)
        let added = try store.stageFiles(urls, existing: runtime.currentAttachments)
        do { try runtime.setDraftAttachments(runtime.currentAttachments + added) }
        catch { for item in added { try? store.removeDraftCopy(item) }; throw error }
        focusInput()
    }

    func addImageAttachment(data: Data, name: String = "截图.png") throws {
        guard let runtime, !hasRunning, !runtime.currentConversationTransferred else { throw AppError.message("请等待本轮完成，再添加附件。") }
        let store = ChatAttachmentStore(project: project)
        let added = try store.stageImage(data: data, name: name, existing: runtime.currentAttachments)
        do { try runtime.setDraftAttachments(runtime.currentAttachments + [added]) }
        catch { try? store.removeDraftCopy(added); throw error }
        focusInput()
    }

    private func receiveAttachments(_ pasteboard: NSPasteboard) -> Bool {
        guard let content = AttachmentPasteboard.read(pasteboard) else { return false }
        do {
            switch content {
            case .files(let urls): try addAttachments(urls)
            case .image(let data): try addImageAttachment(data: data)
            }
        } catch { showError(error.localizedDescription, window: window) }
        return true
    }

    private func refreshAttachments() {
        let items = runtime?.currentAttachments ?? []
        let signature = (runtime?.selectedID ?? "") + items.map(\.id).joined()
        guard signature != attachmentSignature else { return }; attachmentSignature = signature
        attachmentHeight.constant = items.isEmpty ? 0 : AttachmentStrip.preferredHeight; attachments.isHidden = items.isEmpty
        attachments.show(items, store: ChatAttachmentStore(project: project), remove: { [weak self] id in
            guard let self, let runtime = self.runtime else { return }
            let removed = runtime.currentAttachments.first { $0.id == id }
            do {
                try runtime.setDraftAttachments(runtime.currentAttachments.filter { $0.id != id })
                let referenced = runtime.conversations.contains { conversation in
                    (conversation.draftAttachments ?? []).contains { $0.id == id } || conversation.messages.contains { ($0.attachments ?? []).contains { $0.id == id } }
                }
                if !referenced, let removed { try? ChatAttachmentStore(project: self.project).removeDraftCopy(removed) }
            }
            catch { showError(error.localizedDescription, window: self.window) }
        }, preview: { [weak self] item, sender in self?.previewAttachment(item, from: sender) })
    }

    private func previewAttachment(_ attachment: ChatAttachment, from sender: NSView) {
        do {
            let url = try ChatAttachmentStore(project: project).url(for: attachment)
            let width = max(300, min(560, (window?.contentView?.bounds.width ?? 600) - 40))
            guard let preview = QLPreviewView(frame: NSRect(x: 0, y: 0, width: width, height: 400), style: .normal) else { return }
            preview.autostarts = true; preview.previewItem = url as NSURL
            let controller = NSViewController(); controller.view = preview
            let popover = NSPopover(); popover.behavior = .transient; popover.contentViewController = controller
            popover.contentSize = NSSize(width: width, height: 400); previewPopover = popover
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: sender.isFlipped ? .minY : .maxY)
        } catch { showError(error.localizedDescription, window: window) }
    }

    func newConversation() {
        if boundConversationID != nil { onNewConversationRequested?(); return }
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
        if boundConversationUnavailable {
            cancelOutgoingTranslation(); cancelReplyTranslations()
            translationStatus = nil; translationFailed = false
        }
        if changedConversation {
            cancelOutgoingTranslation(); cancelReplyTranslations()
            translationStatus = nil; translationFailed = false
            let unassignedDraft = displayedID == nil ? input.string : ""
            saveDraft(); displayedID = selectedID
            input.string = selectedID.flatMap { drafts[$0] } ?? unassignedDraft
            if let selectedID, !unassignedDraft.isEmpty { drafts[selectedID] = input.string }
            input.needsDisplay = true
        }
        refreshOptions()
        refreshAttachments()
        refreshApprovals()
        updateStreamingReplies()
        let visible = (runtime?.currentMessages ?? []).map { message in
            DisplayMessage(id: message.id, role: message.role, text: message.text,
                           title: message.toolName.map(toolTitle), isError: message.role == "error", attachments: message.attachments ?? [],
                           originalText: message.originalText, translatedText: streamingReplies[message.id]?.preview ?? message.translatedText)
        }
        displayMessages(visible, conversationID: selectedID ?? "", scrollToEnd: changedConversation)
        updateControls()
        onStateChange?()
    }

    private func refreshApprovals() {
        let pending = runtime?.pendingApprovals ?? []
        if let id = questionApprovalID, !pending.contains(where: { $0.id == id }), let sheet = questionSheet {
            questionApprovalID = nil; questionSheet = nil
            if let parent = sheet.window.sheetParent { parent.endSheet(sheet.window, returnCode: .abort) }
        }
        let signature = pending.map(\.id).joined(separator: "|")
        guard signature != approvalSignature else { return }
        approvalSignature = signature
        for view in approvalArea.arrangedSubviews { approvalArea.removeArrangedSubview(view); view.removeFromSuperview() }
        collapsedApproval.isActive = pending.isEmpty
        approvalArea.isHidden = pending.isEmpty
        guard let request = pending.first else { return }
        let count = pending.count > 1 ? " · \(pending.count) 项待确认" : ""
        let title: String, actionTitle: String
        switch request.kind {
        case .tool: title = toolTitle(request.toolName) + count; actionTitle = "允许"
        case .question: title = "需要你的回答" + count; actionTitle = "回答问题"
        case .plan: title = "确认执行计划" + count; actionTitle = "同意计划"
        }
        let details = [request.reason, request.inputDescription].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let card = ChatApprovalCard(title: title, detail: details, actionTitle: actionTitle, canApprove: request.canApprove, approve: { [weak self] in
            guard let self else { return }
            if request.kind == .question { self.showQuestion(request) }
            else { self.respondToApproval(id: request.id, allow: true) }
        }, deny: { [weak self] in self?.respondToApproval(id: request.id, allow: false) },
            rememberTool: runtime?.mayRemember(request) == true ? request.toolName : nil,
            approveRemembering: request.kind == .tool ? { [weak self] remember in
                self?.respondToApproval(id: request.id, allow: true, remember: remember && self?.runtime?.mayRemember(request) == true)
            } : nil)
        fillWidth(card, in: approvalArea)
    }

    private func respondToApproval(id: String, allow: Bool, remember: Bool = false) {
        guard let runtime else { return }
        do {
            if allow { try runtime.approve(id: id, remember: remember) } else { try runtime.deny(id: id) }
        } catch { showError(OperationPresentation.clean(error.localizedDescription), window: window) }
        refresh()
    }

    private func showQuestion(_ request: ChatApproval) {
        guard let window, questionSheet == nil, request.canApprove else { return }
        let alert = NSAlert(); alert.messageText = "需要你的回答"
        alert.addButton(withTitle: "提交回答"); alert.addButton(withTitle: "稍后回答")
        let width = max(260, min(540, window.contentView!.bounds.width - 70))
        let form = ChatQuestionForm(questions: request.questions, width: width)
        let scroll = ThemeScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 300))
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.documentView = form; form.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), form.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            form.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        form.layoutSubtreeIfNeeded()
        scroll.frame.size.height = min(340, max(120, form.fittingSize.height))
        alert.accessoryView = scroll; alert.buttons[0].isEnabled = false
        form.onChange = { [weak form, weak alert] in alert?.buttons.first?.isEnabled = form?.answers != nil }
        questionSheet = alert; questionApprovalID = request.id
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.questionSheet = nil; self.questionApprovalID = nil
            guard response == .alertFirstButtonReturn, let answers = form.answers,
                  self.runtime?.pendingApprovals.contains(where: { $0.id == request.id }) == true else { return }
            do { try self.runtime?.answer(id: request.id, answers: answers) }
            catch { showError(OperationPresentation.clean(error.localizedDescription), window: self.window) }
            self.refresh()
        }
    }

    private func updateControls() {
        guard sendButton != nil else { return }
        let active = hasRunning
        let needsInteraction = runtime?.needsTerminalInteraction ?? false
        let transferred = runtime?.currentConversationTransferred ?? false
        let available = runtime != nil && !boundConversationUnavailable
        if let retry = translationRetryDraft,
           retry.conversationID != runtime?.selectedID || retry.text != input.string ||
           retry.attachmentIDs != runtime?.currentAttachments.map(\.id) || retry.options != runtime?.currentOptions {
            translationRetryDraft = nil
        }
        let canRetryTranslation = translationRetryDraft != nil && !active && !transferred && (runtime?.currentOptions.translateToEnglish ?? true)
        retryTranslationButton.isHidden = !canRetryTranslation
        retryTranslationButton.isEnabled = canRetryTranslation
        sendButton.isEnabled = available && !active && !transferred && (!input.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || runtime?.currentAttachments.isEmpty == false)
        sendButton.isHidden = active
        stopButton.isHidden = !active
        permissionPicker.isEnabled = available && !active && !transferred
        modelPicker.isEnabled = permissionPicker.isEnabled
        effortPicker.isEnabled = permissionPicker.isEnabled
        attachButton.isEnabled = available && !active && !transferred
        translationButton.isEnabled = available && !active && !transferred
        stopButton.setAccessibilityLabel(outgoingTranslationID == nil ? "停止当前任务" : "取消翻译")
        stopButton.toolTip = outgoingTranslationID == nil ? "停止当前任务" : "取消翻译，保留草稿"
        // A terminal handoff owns execution, not the user's draft. Keep typing
        // available while requiring an explicit, completed handback to Send.
        input.isEditable = available
        input.isSelectable = true
        input.placeholder = boundConversationUnavailable ? "这段对话已删除" : transferred ? "可以先写草稿，返回聊天后发送…" : "描述任务，或继续提问…"
        fallbackButton.title = transferred ? "打开终端" : "在终端继续"
        fallbackButton.isHidden = transferred ? onShowTerminal == nil : (!needsInteraction || onTerminalFallback == nil)
        fallbackButton.isEnabled = !active && returningConversationID == nil
        returnButton.isHidden = !transferred || onReturnFromTerminal == nil
        returnButton.isEnabled = !active && returningConversationID == nil
        returnButton.title = returningConversationID == runtime?.selectedID ? "正在返回…" : "返回聊天"
        status.stringValue = startupError ?? translationStatus ?? (transferred ? "终端中 · 可写草稿" : runtime?.stateText ?? "")
        status.toolTip = status.stringValue
        status.textColor = startupError != nil || needsInteraction || translationFailed ? Theme.warning : Theme.muted
        let idleStates = ["可以开始新任务", "继续这段对话", "已完成，可以继续提问", "已停止，已保存这段对话"]
        let needsStatus = !status.stringValue.isEmpty && !idleStates.contains(status.stringValue)
        let showsState = active || needsInteraction || transferred || startupError != nil || needsStatus
        status.isHidden = !showsState; stateLine.isHidden = !showsState; collapsedState.isActive = !showsState
        emptyState.isHidden = boundConversationUnavailable || !(runtime?.currentMessages.isEmpty == true && !active && startupError == nil)
    }

    private func saveDraft() {
        guard let displayedID else { return }
        drafts[displayedID] = input.string
    }

    func textDidChange(_ notification: Notification) {
        guard !rendering else { return }
        cancelOutgoingTranslation(); translationStatus = nil; translationFailed = false
        saveDraft(); input.needsDisplay = true; updateControls(); onStateChange?()
    }

    func selectConversation(id: String) {
        guard boundConversationID == nil || boundConversationID == id else { return }
        guard let runtime, !runtime.hasRunning, runtime.activeConversations.contains(where: { $0.id == id }) else { return }
        saveDraft(); runtime.select(id: id); refresh(); focusInput()
    }

    func reloadConversationIndex() { runtime?.reloadConversationIndex() }

    private func refreshOptions() {
        permissionPicker.itemArray.first { $0.tag == 99 }?.title = "清除记住的权限（\(runtime?.rememberedTools.count ?? 0)）"
        let settings = runtime?.currentOptions ?? ChatOptions()
        if let item = permissionPicker.itemArray.first(where: { $0.representedObject as? String == settings.permissionMode.rawValue }) { permissionPicker.select(item) }
        if let item = effortPicker.itemArray.first(where: { $0.representedObject as? String == (settings.effort ?? "") }) { effortPicker.select(item) }
        effortPicker.toolTip = "思考强度：" + (settings.effort == nil ? "默认（由模型决定）" : effortPicker.titleOfSelectedItem ?? "默认") + "。发送时生效，可用性由模型决定。"
        if let custom = modelPicker.itemArray.first(where: { $0.tag == 99 }) { modelPicker.menu?.removeItem(custom) }
        let model = settings.model ?? ""
        if let item = modelPicker.itemArray.first(where: { $0.representedObject as? String == model }) { modelPicker.select(item) }
        else {
            let item = NSMenuItem(title: String(model.prefix(32)), action: nil, keyEquivalent: "")
            item.representedObject = model; item.tag = 99
            modelPicker.menu?.insertItem(item, at: 4); modelPicker.select(item)
        }
        let enabled = settings.translateToEnglish ?? true
        translationButton.isBordered = enabled
        translationButton.state = enabled ? .on : .off
        let automatic = settings.autoTranslateReplies ?? true
        translationButton.title = enabled ? "中→EN" : "翻译"
        translationButton.setAccessibilityLabel("翻译设置")
        translationButton.toolTip = "中文转英文发送：" + (enabled ? "开" : "关") + "；自动显示中文：" + (automatic ? "开" : "关") + "。在本机翻译，保留原文。\n～内容～ 或 ～～内容～～ 内不翻译，结果去掉标记，支持换行。"
        translationButton.needsDisplay = true
        modelPicker.needsDisplay = true; effortPicker.needsDisplay = true; permissionPicker.needsDisplay = true
    }

    func translationSettingsMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let settings = runtime?.currentOptions ?? ChatOptions()
        for (title, enabled, tag) in [("中文输入转英文发送", settings.translateToEnglish ?? true, 0),
                                      ("回复自动显示中文", settings.autoTranslateReplies ?? true, 1)] {
            let item = NSMenuItem(title: title, action: #selector(translationPreferenceChanged(_:)), keyEquivalent: "")
            item.target = self; item.tag = tag; item.state = enabled ? .on : .off
            item.isEnabled = runtime != nil && !hasRunning && runtime?.currentConversationTransferred != true
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let setup = NSMenuItem(title: "本机翻译组件…", action: #selector(showTranslationSetup), keyEquivalent: "")
        setup.target = self; menu.addItem(setup)
        return menu
    }

    @objc private func showTranslationSetup() { TranslationSetup.show(from: window) }

    private func showTranslationMenu() {
        guard !hasRunning else { return }
        translationSettingsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: translationButton.bounds.height + 4), in: translationButton)
    }

    @objc private func translationPreferenceChanged(_ item: NSMenuItem) {
        guard let runtime, !hasRunning, !runtime.currentConversationTransferred else { return }
        translationRetryDraft = nil
        do {
            if item.tag == 0 { try runtime.setTranslationEnabled(!(runtime.currentOptions.translateToEnglish ?? true)) }
            else {
                let enabled = !(runtime.currentOptions.autoTranslateReplies ?? true)
                try runtime.setAutomaticReplyTranslation(enabled)
                if enabled { translateLatestReplies() }
            }
            translationStatus = nil; translationFailed = false
        } catch { translationStatus = OperationPresentation.clean(error.localizedDescription); translationFailed = true }
        renderedSignature = ""; refresh()
    }

    private func saveOptions(model: String?) {
        guard let runtime else { return }
        let mode = ChatPermissionMode(rawValue: permissionPicker.selectedItem?.representedObject as? String ?? "default") ?? .default
        do { try runtime.updateOptions(model: model, permissionMode: mode, effort: runtime.currentOptions.effort) }
        catch { showError(error.localizedDescription, window: window) }
        refreshOptions()
    }

    @objc private func permissionChanged() {
        if permissionPicker.selectedItem?.tag == 99 {
            do { try runtime?.clearRememberedPermissions() }
            catch { showError(error.localizedDescription, window: window) }
            refreshOptions(); return
        }
        saveOptions(model: runtime?.currentOptions.model)
    }

    @objc private func modelChanged() {
        let model = modelPicker.selectedItem?.representedObject as? String ?? ""
        guard model == "__custom__" else { saveOptions(model: model.isEmpty ? nil : model); return }
        guard let window else { refreshOptions(); return }
        let alert = NSAlert(); alert.messageText = "自定义模型"
        alert.informativeText = "填写服务支持的模型 ID。发送时生效，不会在这里发起请求。"
        let field = NSTextField(string: runtime?.currentOptions.model ?? "")
        field.placeholderString = "模型 ID"; field.frame = NSRect(x: 0, y: 0, width: 320, height: 28); alert.accessoryView = field
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn { self.saveOptions(model: field.stringValue) }
            else { self.refreshOptions() }
        }
        window.makeFirstResponder(field)
    }

    func showConversationActions(id: String, from sender: NSView) {
        conversationActionsAnchor = sender
        conversationActionsMenu(id: id, from: sender)?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    func conversationActionsMenu(id: String, from sender: NSView? = nil) -> NSMenu? {
        if let sender { conversationActionsAnchor = sender }
        guard let runtime, !runtime.hasRunning else { return nil }
        let menu = NSMenu()
        func add(_ title: String, tag: Int, symbol: String) {
            let item = NSMenuItem(title: title, action: #selector(conversationAction(_:)), keyEquivalent: "")
            item.target = self; item.tag = tag; item.representedObject = id
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        add("新对话", tag: 0, symbol: "square.and.pencil")
        if runtime.activeConversations.contains(where: { $0.id == id }) {
            add("重命名", tag: 1, symbol: "pencil")
            add("导出对话…", tag: 2, symbol: "square.and.arrow.up")
            add("复制对话", tag: 3, symbol: "doc.on.doc")
            menu.addItem(.separator())
            add("删除对话", tag: 4, symbol: "trash")
        }
        menu.addItem(.separator())
        add("已删除的对话", tag: 5, symbol: "arrow.uturn.backward")
        return menu
    }

    @objc private func effortChanged() {
        guard let runtime, let value = effortPicker.selectedItem?.representedObject as? String else { return }
        do { try runtime.updateOptions(model: runtime.currentOptions.model, permissionMode: runtime.currentOptions.permissionMode, effort: value.isEmpty ? nil : value) }
        catch { showError(error.localizedDescription, window: window) }
        refreshOptions()
    }

    @objc private func conversationAction(_ item: NSMenuItem) {
        guard let runtime, !runtime.hasRunning, let id = item.representedObject as? String else { return }
        if item.tag == 0 { newConversation(); return }
        if item.tag == 5 { showDeletedConversations(from: conversationActionsAnchor ?? self); return }
        guard let conversation = runtime.activeConversations.first(where: { $0.id == id }) else { return }
        switch item.tag {
        case 1: renameConversation(conversation)
        case 2: exportConversation(conversation)
        case 3:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown(conversation), forType: .string)
        case 4:
            saveDraft()
            do { try runtime.deleteConversation(id: id); refresh() }
            catch { showError(error.localizedDescription, window: conversationPresentingWindow) }
        default: break
        }
    }

    private func renameConversation(_ conversation: ChatConversation) {
        guard let window = conversationPresentingWindow else { return }
        let alert = NSAlert(); alert.messageText = "重命名对话"
        let field = NSTextField(string: conversation.title)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 28); alert.accessoryView = field
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do { try self.runtime?.renameConversation(id: conversation.id, title: field.stringValue) }
            catch { showError(error.localizedDescription, window: self.conversationPresentingWindow) }
        }
        window.makeFirstResponder(field)
    }

    func showDeletedConversations(from sender: NSView) {
        guard let runtime else { return }
        conversationActionsAnchor = sender
        let menu = NSMenu(); menu.autoenablesItems = false
        let heading = NSMenuItem(title: runtime.deletedConversations.isEmpty ? "没有已删除的对话" : "选择对话恢复", action: nil, keyEquivalent: "")
        heading.isEnabled = false; menu.addItem(heading)
        for conversation in runtime.deletedConversations {
            let item = NSMenuItem(title: conversation.title.isEmpty ? "新对话" : conversation.title, action: #selector(restoreConversation(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = conversation.id; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func restoreConversation(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        do { try runtime?.restoreConversation(id: id); refresh() }
        catch { showError(error.localizedDescription, window: conversationPresentingWindow) }
    }

    private func markdown(_ conversation: ChatConversation) -> String {
        let roles = ["user": "你", "assistant": "Claude", "tool": "工具", "error": "提示"]
        return "# " + conversation.title + "\n\n" + conversation.messages.map { message in
            let body: String
            if let original = message.originalText { body = original + "\n\n### 已发送英文\n\n" + message.text }
            else if let translated = message.translatedText { body = translated + "\n\n### 英文原文\n\n" + message.text }
            else { body = message.text }
            return "## " + (message.toolName ?? roles[message.role] ?? message.role) + "\n\n" + body + (message.attachments ?? []).map { "\n\n附件：" + $0.name + "（" + $0.formattedSize + "）" }.joined()
        }.joined(separator: "\n\n") + "\n"
    }

    private func exportConversation(_ conversation: ChatConversation) {
        guard let window = conversationPresentingWindow else { return }
        let panel = NSSavePanel(); panel.title = "导出对话"; panel.prompt = "导出"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let safeTitle = conversation.title.components(separatedBy: CharacterSet(charactersIn: "/:\n\r")).joined(separator: " ")
        panel.nameFieldStringValue = String(safeTitle.prefix(80)) + ".md"
        let text = markdown(conversation)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { showError(error.localizedDescription, window: self?.conversationPresentingWindow) }
        }
    }

    private func send() {
        guard let runtime, !hasRunning, !runtime.currentConversationTransferred else { return }
        let rawInput = input.string
        let text = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !runtime.currentAttachments.isEmpty else { return }
        translationStatus = nil; translationFailed = false; translationRetryDraft = nil
        guard runtime.currentOptions.translateToEnglish ?? true else {
            sendPrepared(text: text, originalText: nil, draft: rawInput); return
        }
        let source = text.isEmpty ? "Please review the attached files." : text
        let needsTranslation = source.contains("～") || source.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0x20000...0x3134F).contains($0.value) }
        guard needsTranslation else {
            sendPrepared(text: source, originalText: text.isEmpty ? "请查看附件。" : text, draft: rawInput); return
        }
        let requestID = UUID(), conversationID = runtime.selectedID
        let attachmentIDs = runtime.currentAttachments.map(\.id)
        let options = runtime.currentOptions
        outgoingTranslationID = requestID; translationStatus = "正在翻译…"
        updateControls(); onStateChange?()
        let request = translator.translate(source, from: .chinese, to: .english) { [weak self] result in
            guard let self, self.outgoingTranslationID == requestID else { return }
            self.outgoingTranslationID = nil; self.outgoingTranslation = nil
            guard let runtime = self.runtime, runtime.selectedID == conversationID, !runtime.hasRunning,
                  !runtime.currentConversationTransferred, self.input.string == rawInput,
                  runtime.currentAttachments.map(\.id) == attachmentIDs, runtime.currentOptions == options else {
                self.translationStatus = "内容已更改，请重新发送"; self.translationFailed = false
                self.refresh(); return
            }
            do {
                let translated = try result.get().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !translated.isEmpty else { throw AppError.message("翻译结果为空，请重试。") }
                self.sendPrepared(text: translated, originalText: text, draft: rawInput)
            } catch {
                self.translationStatus = "翻译未完成：" + OperationPresentation.clean(error.localizedDescription)
                self.translationRetryDraft = TranslationRetryDraft(conversationID: conversationID, text: rawInput, attachmentIDs: attachmentIDs, options: options)
                self.translationFailed = true; self.refresh(); self.focusInput()
            }
        }
        // A test or cached translator may complete synchronously.
        if outgoingTranslationID == requestID { outgoingTranslation = request }
    }

    private func sendPrepared(text: String, originalText: String?, draft: String) {
        guard let runtime else { return }
        translationStatus = nil; translationFailed = false; translationRetryDraft = nil
        if runtime.send(text: text, originalText: originalText) {
            input.string = ""; input.needsDisplay = true
            if let id = runtime.selectedID { drafts[id] = "" }
        } else {
            input.string = draft; input.needsDisplay = true
            if let id = runtime.selectedID { drafts[id] = draft }
        }
        refresh(); focusInput()
    }

    private func processMessageIDs(_ items: [(String, String)]) -> Set<String> {
        var result = Set<String>(), sawTool = false
        for (id, role) in items.reversed() {
            if role == "user" { sawTool = false }
            else if role == "tool" { sawTool = true; result.insert(id) }
            else if role == "assistant" && sawTool { result.insert(id) }
        }
        return result
    }

    private func updateStreamingReplies() {
        guard let runtime, runtime.currentOptions.autoTranslateReplies ?? true,
              let conversationID = runtime.selectedID,
              let lastUser = runtime.currentMessages.lastIndex(where: { $0.role == "user" }) else { return }
        let processIDs = processMessageIDs(runtime.currentMessages.map { ($0.id, $0.role) })
        for id in processIDs { streamingReplies.removeValue(forKey: id)?.cancel() }
        for message in runtime.currentMessages.suffix(from: lastUser + 1) where message.role == "assistant" && !message.text.isEmpty && !processIDs.contains(message.id) {
            if streamingReplies[message.id] == nil && runtime.hasRunning && message.translatedText == nil && replyErrors[message.id] == nil {
                let stream = StreamingReplyTranslation(translator: translator)
                streamingReplies[message.id] = stream
                stream.onChange = { [weak self, weak stream] in
                    guard let self, let stream, self.runtime?.selectedID == conversationID,
                          self.streamingReplies[message.id] === stream else { return }
                    if let error = stream.error {
                        self.replyErrors[message.id] = error.localizedDescription
                        self.streamingReplies[message.id] = nil
                    } else if stream.finished {
                        self.streamingReplies[message.id] = nil
                        do { try self.runtime?.saveTranslation(messageID: message.id, sourceText: stream.source, text: stream.translated) }
                        catch { self.replyErrors[message.id] = error.localizedDescription }
                    }
                    self.renderedSignature = ""; self.refresh()
                }
            }
            streamingReplies[message.id]?.update(message.text, complete: runtime.isAssistantComplete(message.id))
        }
    }

    private func translateCompletedReplies() {
        guard let runtime, runtime.currentOptions.autoTranslateReplies ?? true,
              runtime.stateText.hasPrefix("已完成") || runtime.stateText.hasPrefix("本轮结束") else { return }
        translateLatestReplies()
    }

    private func translateLatestReplies() {
        guard let runtime, !runtime.hasRunning,
              let lastUser = runtime.currentMessages.lastIndex(where: { $0.role == "user" }) else { return }
        let processIDs = processMessageIDs(runtime.currentMessages.map { ($0.id, $0.role) })
        for message in runtime.currentMessages.suffix(from: lastUser + 1) where message.role == "assistant" && !processIDs.contains(message.id) && !message.text.isEmpty && message.translatedText == nil && streamingReplies[message.id] == nil && replyErrors[message.id] == nil {
            beginReplyTranslation(id: message.id, source: message.text, revealTranslation: false)
        }
    }

    private func translateReply(id: String, source: String) {
        guard let runtime,
              runtime.currentMessages.contains(where: { $0.id == id && $0.role == "assistant" && $0.text == source }) else { return }
        if runtime.currentMessages.first(where: { $0.id == id })?.translatedText != nil || streamingReplies[id] != nil {
            if expandedTranslations.contains(id) { expandedTranslations.remove(id) } else { expandedTranslations.insert(id) }
            renderedSignature = ""; refresh(); return
        }
        guard !runtime.hasRunning else { return }
        beginReplyTranslation(id: id, source: source, revealTranslation: !(runtime.currentOptions.autoTranslateReplies ?? true))
    }

    private func beginReplyTranslation(id: String, source: String, revealTranslation: Bool) {
        guard let runtime, let conversationID = runtime.selectedID, replyRequestIDs[id] == nil else { return }
        let token = UUID(); replyRequestIDs[id] = token; replyErrors[id] = nil
        renderedSignature = ""; refresh()
        let request = translator.translate(source, from: .english, to: .chinese) { [weak self] result in
            guard let self, self.replyRequestIDs[id] == token else { return }
            self.replyRequestIDs[id] = nil; self.replyRequests[id] = nil
            guard self.runtime?.selectedID == conversationID else { return }
            do {
                let translated = try result.get().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !translated.isEmpty else { throw AppError.message("翻译结果为空，请重试。") }
                try self.runtime?.saveTranslation(messageID: id, sourceText: source, text: translated)
                if revealTranslation { self.expandedTranslations.insert(id) }
            } catch { self.replyErrors[id] = OperationPresentation.clean(error.localizedDescription) }
            self.renderedSignature = ""; self.refresh()
        }
        if replyRequestIDs[id] == token { replyRequests[id] = request }
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

    private func addMessage(id: String, role: String, text: String, title: String?, isError: Bool = false, attachments: [ChatAttachment] = [], originalText: String? = nil, translatedText: String? = nil) {
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
                let detail = ChatMarkdown.field(NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: isError ? Theme.warning : Theme.muted]))
                fillWidth(detail, in: body)
            }
            fillWidth(body, in: messages)
            return
        }
        let body = column([], spacing: 8)
        if !attachments.isEmpty {
            let strip = AttachmentStrip(); strip.heightAnchor.constraint(equalToConstant: AttachmentStrip.preferredHeight).isActive = true
            strip.setAccessibilityLabel("消息附件")
            strip.show(attachments, store: ChatAttachmentStore(project: project), remove: nil, preview: { [weak self] item, sender in self?.previewAttachment(item, from: sender) })
            fillWidth(strip, in: body)
        }
        let showsChinese = role == "assistant" && (runtime?.currentOptions.autoTranslateReplies ?? true) && translatedText != nil
        let shownText = role == "user" ? originalText ?? text : showsChinese ? translatedText! : text
        let content = messageText(shownText, color: isError ? Theme.warning : (role == "notice" ? Theme.muted : Theme.text))
        fillWidth(content, in: body)
        if role == "user", originalText != nil {
            let expanded = expandedSentTexts.contains(id)
            let sent = ClosureButton(expanded ? "收起英文" : "已用英文发送", symbol: "character.bubble") { [weak self] in
                guard let self else { return }
                if self.expandedSentTexts.contains(id) { self.expandedSentTexts.remove(id) } else { self.expandedSentTexts.insert(id) }
                self.renderedSignature = ""; self.refresh()
            }
            sent.isBordered = false; sent.font = Theme.font(size: 11)
            sent.setAccessibilityLabel(expanded ? "收起发送的英文" : "查看发送的英文")
            body.addArrangedSubview(sent)
            if expanded { fillWidth(messageText(text, color: Theme.muted), in: body) }
        }
        if role == "assistant", !isError, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let pending = replyRequestIDs[id] != nil
            let streaming = streamingReplies[id] != nil
            let expanded = expandedTranslations.contains(id)
            let translate = ClosureButton(pending ? "翻译中…" : "", symbol: "character.bubble") { [weak self] in self?.translateReply(id: id, source: text) }
            translate.isBordered = false; translate.font = Theme.font(size: 11)
            translate.isEnabled = !pending && (runtime?.hasRunning != true || streaming || translatedText != nil)
            translate.toolTip = showsChinese ? (expanded ? "收起英文原文" : "查看英文原文") : (expanded ? "收起中文翻译" : "在本机翻译为中文，保留英文原文")
            translate.setAccessibilityLabel(pending ? "正在翻译回复" : showsChinese ? (expanded ? "收起英文原文" : "查看英文原文") : (expanded ? "收起中文翻译" : "翻译回复为中文"))
            if !pending { translate.widthAnchor.constraint(equalToConstant: 30).isActive = true }
            let copy = ClosureButton("", symbol: "doc.on.doc") { }
            copy.actionBlock = { [weak copy, weak self] in
                ChatOriginalCopy.write(self?.runtime?.currentMessages.first { $0.id == id }?.text ?? text)
                copy?.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "已复制")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak copy] in
                    copy?.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制原文")
                }
            }
            copy.isBordered = false; copy.widthAnchor.constraint(equalToConstant: 30).isActive = true
            copy.setAccessibilityLabel("复制原文"); copy.toolTip = "复制完整原文（包含 Markdown 与代码）"
            let retranslate = ClosureButton("", symbol: "arrow.clockwise") { [weak self] in
                self?.beginReplyTranslation(id: id, source: text, revealTranslation: false)
            }
            retranslate.isBordered = false; retranslate.widthAnchor.constraint(equalToConstant: 30).isActive = true
            retranslate.isEnabled = runtime?.hasRunning != true && !pending
            retranslate.setAccessibilityLabel("重新翻译原文"); retranslate.toolTip = "用当前本机模型重新翻译，失败时保留现有内容"
            retranslate.isHidden = translatedText == nil
            let footer = row([translate, copy, retranslate], spacing: 8)
            if let error = replyErrors[id] {
                let detail = label(error, size: 11, color: Theme.warning); detail.maximumNumberOfLines = 2; detail.toolTip = error
                footer.addArrangedSubview(detail)
            }
            footer.addArrangedSubview(spacer()); fillWidth(footer, in: body)
            if expanded, let translatedText {
                let translation = column([label(showsChinese ? "英文原文" : "中文", size: 10, color: Theme.muted), messageText(showsChinese ? text : translatedText, color: Theme.text)], spacing: 6)
                let pane = ThemeSurface(Theme.panel, radius: 8)
                translation.translatesAutoresizingMaskIntoConstraints = false; pane.addSubview(translation)
                NSLayoutConstraint.activate([translation.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 12), translation.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -12), translation.topAnchor.constraint(equalTo: pane.topAnchor, constant: 10), translation.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -10)])
                fillWidth(pane, in: body)
            }
        }
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

    private func messageText(_ text: String, color: NSColor) -> NSView {
        ChatMarkdownView(text.isEmpty ? "…" : text, color: color)
    }

    private struct DisplayMessage {
        let id: String
        let role: String
        let text: String
        let title: String?
        let isError: Bool
        let attachments: [ChatAttachment]
        let originalText: String?
        let translatedText: String?
    }

    private func displayMessages(_ items: [DisplayMessage], conversationID: String, scrollToEnd: Bool = false) {
        let messageSignatures = items.map { item in
            [item.id, item.role, (item.role == "assistant" && item.translatedText != nil && (runtime?.currentOptions.autoTranslateReplies ?? true) && !expandedTranslations.contains(item.id)) ? "" : item.text, item.title ?? "", String(item.isError), item.attachments.map(\.id).joined(), item.originalText ?? "", item.translatedText ?? ""].joined(separator: "\u{1e}")
        }
        let signature = ([conversationID] + messageSignatures + [
            expandedTools.sorted().joined(), expandedProcesses.sorted().joined(), expandedTranslations.sorted().joined(), expandedSentTexts.sorted().joined(),
            replyRequestIDs.keys.sorted().joined(), String(runtime?.hasRunning ?? false), String(runtime?.currentOptions.autoTranslateReplies ?? true)
        ]).joined(separator: "\u{1f}")
        guard signature != renderedSignature else { return }
        renderedSignature = signature
        let previousOffset = history.contentView.bounds.origin.y
        let followsOutput = scrollToEnd || document.bounds.height - history.contentView.bounds.maxY < 80
        for view in messages.arrangedSubviews { messages.removeArrangedSubview(view); view.removeFromSuperview() }
        let processIDs = processMessageIDs(items.map { ($0.id, $0.role) })
        var turn = "initial", toolsByTurn: [String: [DisplayMessage]] = [:], turnForID: [String: String] = [:]
        for item in items {
            if item.role == "user" { turn = item.id }
            turnForID[item.id] = turn
            if processIDs.contains(item.id) { toolsByTurn[turn, default: []].append(item) }
        }
        var shownProcesses = Set<String>()
        for message in items {
            if processIDs.contains(message.id) {
                let key = turnForID[message.id] ?? "initial"
                guard shownProcesses.insert(key).inserted else { continue }
                let operations = toolsByTurn[key] ?? []
                let expanded = expandedProcesses.contains(key)
                let toggle = ClosureButton("执行过程 · \(operations.filter { $0.role == "tool" }.count) 项", symbol: expanded ? "chevron.down" : "chevron.right") { [weak self] in
                    guard let self else { return }
                    if self.expandedProcesses.contains(key) { self.expandedProcesses.remove(key) } else { self.expandedProcesses.insert(key) }
                    self.renderedSignature = ""; self.refresh()
                }
                toggle.isBordered = false; toggle.font = Theme.font(size: 11); toggle.contentTintColor = Theme.muted
                toggle.setAccessibilityLabel(expanded ? "折叠执行过程" : "展开执行过程")
                fillWidth(row([toggle, spacer()], spacing: 0), in: messages)
                if expanded {
                    for operation in operations { addMessage(id: operation.id, role: operation.role, text: operation.text, title: operation.title, isError: operation.isError, translatedText: operation.translatedText) }
                }
                continue
            }
            if message.role == "user", let previous = messages.arrangedSubviews.last { messages.setCustomSpacing(32, after: previous) }
            addMessage(id: message.id, role: message.role, text: message.text, title: message.title, isError: message.isError, attachments: message.attachments, originalText: message.originalText, translatedText: message.translatedText)
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


enum ChatOriginalCopy {
    static func write(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
    }
}
