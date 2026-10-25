import AppKit
import Darwin

private final class OperationLinkStack: NSStackView { override var isFlipped: Bool { true } }

/// A native operation panel. PTY interaction remains available through explicit form controls;
/// shell commands and unfiltered terminal output are never placed in its result view.
final class OperationWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let session = PTYSession()
    private let presentation = OperationPresentation()
    private let arguments: [String]
    private let directory: String
    private let initialInput: String?
    private let onFinish: (Bool) -> Void
    private let openLink: (URL) throws -> Void
    private let isCompletion: Bool
    private let stateLabel = label("准备处理…", size: 14, color: Theme.accent, weight: .semibold)
    private let promptLabel = label("", size: 12, color: Theme.muted)
    private let input = NSTextField()
    private let resultView = NSTextView()
    private let progress = NSProgressIndicator()
    private let linksStack = OperationLinkStack()
    private let linksContainer = NSScrollView()
    private var linksHeight: NSLayoutConstraint!
    private var responseRow: NSStackView!
    private var confirmButton: ClosureButton!
    private var cancelButton: ClosureButton!
    private var continueButton: ClosureButton!
    private var doneButton: ClosureButton!
    private var exportButton: ClosureButton!
    private var started = false
    private var completed = false
    private var cancelled = false
    private var closeAfterExit = false
    private var finishDelivered = false
    private var lastSubmittedByteCount: Int?
    private var currentAffirmative: String?
    private var shownLinks: [OperationLink] = []
    private var renderedText = ""
    private var succeeded = false
    var isRunning: Bool { started && !completed }

    init(title: String, detail: String, args: [String], directory: String, initialInput: String? = nil, openLink: @escaping (URL) throws -> Void, onFinish: @escaping (Bool) -> Void) {
        arguments = args; self.directory = directory; self.initialInput = initialInput; self.onFinish = onFinish; self.openLink = openLink
        isCompletion = args.first == "completion"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.windowWidth(740), height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.backgroundColor = Theme.background; window.appearance = nil
        window.minSize = NSSize(width: 390, height: 680)
        super.init(window: window)
        window.delegate = self
        let body = column([], spacing: 14)
        let help = ClosureButton("详情", symbol: "info.circle") { [weak self] in
            guard let window = self?.window else { return }
            let a = NSAlert(); a.messageText = title; a.informativeText = OperationPresentation.clean(detail) + "\n\n位置：" + directory; a.beginSheetModal(for: window)
        }
        fillWidth(row([label(title, size: 21, weight: .semibold), spacer(), help]), in: body)
        progress.style = .spinning; progress.controlSize = .small; progress.isIndeterminate = true
        fillWidth(row([progress, stateLabel, spacer()]), in: body)

        let scroll = ThemeScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = true; scroll.backgroundColor = Theme.panel
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 9; scroll.layer?.borderWidth = 1; scroll.strokeColor = Theme.border
        resultView.isEditable = false; resultView.isSelectable = true; resultView.font = Theme.font(size: 14)
        resultView.textColor = Theme.text; resultView.backgroundColor = Theme.panel
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        resultView.defaultParagraphStyle = paragraph
        resultView.textContainerInset = NSSize(width: 16, height: 16)
        resultView.isVerticallyResizable = true; resultView.isHorizontallyResizable = false
        resultView.autoresizingMask = [.width]; resultView.textContainer?.widthTracksTextView = true
        scroll.documentView = resultView
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        fillWidth(scroll, in: body)
        linksStack.orientation = .vertical; linksStack.alignment = .leading; linksStack.spacing = 6
        linksStack.translatesAutoresizingMaskIntoConstraints = false
        linksContainer.documentView = linksStack; linksContainer.hasVerticalScroller = true; linksContainer.drawsBackground = false
        NSLayoutConstraint.activate([linksStack.leadingAnchor.constraint(equalTo: linksContainer.contentView.leadingAnchor), linksStack.trailingAnchor.constraint(equalTo: linksContainer.contentView.trailingAnchor), linksStack.topAnchor.constraint(equalTo: linksContainer.contentView.topAnchor), linksStack.widthAnchor.constraint(equalTo: linksContainer.contentView.widthAnchor)])
        linksHeight = linksContainer.heightAnchor.constraint(equalToConstant: 32); linksHeight.isActive = true
        fillWidth(linksContainer, in: body); linksContainer.isHidden = true
        fillWidth(promptLabel, in: body)
        input.placeholderString = "回复或登录回调链接"; input.font = Theme.font(size: 14)
        input.setAccessibilityLabel("回复或登录回调链接")
        input.delegate = self; input.target = self; input.action = #selector(submitInput)
        input.heightAnchor.constraint(equalToConstant: 34).isActive = true
        continueButton = ClosureButton("继续") { [weak self] in self?.submitInput() }
        input.setContentHuggingPriority(.init(1), for: .horizontal)
        input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        responseRow = adaptiveRow([input, continueButton], spacing: 8, breakpoint: 460)
        fillWidth(responseRow, in: body)

        confirmButton = ClosureButton("确认", symbol: "checkmark") { [weak self] in self?.confirm() }
        confirmButton.bezelColor = Theme.accent; confirmButton.contentTintColor = .white; confirmButton.isHidden = true
        cancelButton = ClosureButton("取消") { [weak self] in self?.cancel() }
        let copyButton = ClosureButton("复制结果", symbol: "doc.on.doc") { [weak self] in self?.copyResult() }
        exportButton = ClosureButton("导出脚本…", symbol: "square.and.arrow.down") { [weak self] in self?.exportScript() }
        exportButton.isHidden = !isCompletion; exportButton.isEnabled = false
        doneButton = ClosureButton("完成") { [weak self] in self?.close() }; doneButton.isEnabled = false; doneButton.bezelColor = Theme.accent; doneButton.contentTintColor = .white
        fillWidth(row([copyButton, exportButton, spacer(), cancelButton], spacing: 8), in: body)
        fillWidth(row([confirmButton, spacer(), doneButton], spacing: 8), in: body)
        let container = NSView(); container.addSubview(body); body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([body.topAnchor.constraint(equalTo: container.topAnchor, constant: 22), body.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -22), body.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20), body.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20)])
        window.contentView = container; window.center()
        session.onData = { [weak self] bytes in self?.presentation.append(bytes); self?.updateDisplay() }
        session.onExit = { [weak self] code in self?.finish(code: code) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender); window?.makeKeyAndOrderFront(sender)
        guard !started else { return }
        started = true; progress.startAnimation(nil); stateLabel.stringValue = "正在处理…"
        updateDisplay()
        DispatchQueue.main.async { [weak self] in self?.start() }
    }
    private func start() {
        guard !completed else { return }
        if cancelled { finish(code: -1); return }
        do {
            let environment = try CCAMClient.executionEnvironment(arguments: arguments)
            try session.start(executable: CCAMClient.executable, args: arguments, directory: directory, environment: environment, rows: 36, cols: 110)
            disableInputEcho()
            if let initialInput {
                presentation.hideSubmittedInput(initialInput)
                session.send(initialInput + "\n"); session.eof()
            }
        } catch {
            presentation.append(Array(error.localizedDescription.utf8)); finish(code: -1)
        }
    }
    private func updateDisplay() {
        let snapshot = presentation.snapshot()
        if isCompletion {
            renderedText = succeeded ? "补全脚本已生成。点击“导出脚本”选择保存位置。" : (completed ? (snapshot.text.isEmpty ? "未生成脚本。" : snapshot.text) : "正在生成补全脚本…")
            if completed && !succeeded { renderedText = "脚本未生成，请检查运行环境后重试。" }
        } else {
            renderedText = snapshot.text.isEmpty ? (completed ? (succeeded ? "操作已完成。" : (cancelled ? "操作已取消。" : "操作未完成。")) : "正在等待处理结果…") : snapshot.text
        }
        if resultView.string != renderedText { resultView.string = renderedText; resultView.scrollToEndOfDocument(nil) }
        let submittedWithoutNewOutput = lastSubmittedByteCount == presentation.byteCount
        currentAffirmative = isRunning && !cancelled && !submittedWithoutNewOutput ? snapshot.affirmative : nil
        confirmButton.isHidden = currentAffirmative == nil
        if let question = snapshot.question, currentAffirmative != nil {
            stateLabel.stringValue = "等待你的确认"
            promptLabel.stringValue = question
        } else if isRunning && !cancelled {
            stateLabel.stringValue = "正在处理…"
            promptLabel.stringValue = ""
        }
        input.isEnabled = isRunning && !cancelled; continueButton.isEnabled = input.isEnabled
        cancelButton.isEnabled = isRunning && !cancelled
        responseRow.isHidden = completed; cancelButton.isHidden = completed; doneButton.isHidden = !completed
        promptLabel.isHidden = promptLabel.stringValue.isEmpty
        if cancelled { confirmButton.isHidden = true }
        let links = isCompletion ? [] : snapshot.links
        if links != shownLinks {
            for view in linksStack.arrangedSubviews { linksStack.removeArrangedSubview(view); view.removeFromSuperview() }
            for link in links {
                let button = ClosureButton(link.title, symbol: "arrow.up.right") { [weak self] in
                    do { try self?.openLink(link.url) } catch { showError(error.localizedDescription, window: self?.window) }
                }
                button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); button.cell?.lineBreakMode = .byTruncatingMiddle
                button.heightAnchor.constraint(equalToConstant: 30).isActive = true
                fillWidth(button, in: linksStack)
            }
            shownLinks = links; linksContainer.isHidden = links.isEmpty
            linksHeight.constant = max(0, min(66, CGFloat(links.count * 36 - 6)))
        }
    }
    private func send(_ value: String) {
        guard isRunning, session.running, !cancelled else { return }
        guard !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else {
            showError("请一次提交一行回复。", window: window); return
        }
        presentation.hideSubmittedInput(value)
        lastSubmittedByteCount = presentation.byteCount
        disableInputEcho()
        session.send(value + "\n")
        input.stringValue = ""; currentAffirmative = nil; confirmButton.isHidden = true
        stateLabel.stringValue = "正在处理…"; promptLabel.stringValue = "回复已提交，正在等待处理结果。"
    }
    private func disableInputEcho() {
        guard session.master >= 0 else { return }
        var attributes = termios()
        if tcgetattr(session.master, &attributes) == 0 {
            attributes.c_lflag &= ~tcflag_t(ECHO | ECHONL)
            _ = tcsetattr(session.master, TCSANOW, &attributes)
        }
    }
    private func confirm() {
        guard let affirmative = currentAffirmative else { return }
        send(affirmative)
    }
    @objc private func submitInput() {
        // Empty input is intentional: some native prompts ask the user to press Enter.
        send(input.stringValue)
    }
    func cancel(force: Bool = false) {
        guard isRunning, !cancelled else { return }
        cancelled = true; stateLabel.stringValue = "正在取消…"; stateLabel.textColor = Theme.warning
        input.isEnabled = false; continueButton.isEnabled = false; confirmButton.isHidden = true; cancelButton.isEnabled = false
        if session.running { session.stop(force: force) } else { finish(code: -1) }
    }
    private func finish(code: Int32) {
        guard !completed else { return }
        completed = true; succeeded = !cancelled && code == 0
        progress.stopAnimation(nil)
        let hasIssues = presentation.snapshot().hasIssues
        stateLabel.stringValue = cancelled ? "已取消" : (succeeded ? (hasIssues ? "部分结果需要处理" : "已完成") : "处理失败")
        stateLabel.textColor = succeeded && !hasIssues ? Theme.success : Theme.warning
        doneButton.isEnabled = true; exportButton.isEnabled = succeeded && isCompletion
        promptLabel.stringValue = cancelled ? "操作已停止。" : (succeeded ? "处理结果已更新。" : "请查看上方说明，调整后重试。")
        updateDisplay()
        if !finishDelivered { finishDelivered = true; onFinish(succeeded && !hasIssues) }
        if closeAfterExit { close() }
    }
    private func copyResult() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(renderedText, forType: .string)
    }
    private func exportScript() {
        guard isCompletion, succeeded else { return }
        let panel = NSSavePanel()
        let shell = arguments.last(where: { ["zsh", "bash", "powershell"].contains($0) }) ?? "zsh"
        panel.nameFieldStringValue = shell == "powershell" ? "ccam-completion.ps1" : "ccam-completion.\(shell)"
        panel.title = "保存补全脚本"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try self.presentation.plainOutput.write(to: url, atomically: true, encoding: .utf8)
                self.stateLabel.stringValue = "脚本已保存"
            } catch { showError("无法保存脚本：" + OperationPresentation.clean(error.localizedDescription), window: window) }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isRunning else { return true }
        if cancelled { closeAfterExit = true; return false }
        let alert = NSAlert(); alert.messageText = "停止当前操作？"; alert.informativeText = "关闭窗口将停止尚未结束的处理。"
        alert.addButton(withTitle: "继续处理"); alert.addButton(withTitle: "停止并关闭")
        alert.beginSheetModal(for: sender) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.closeAfterExit = true; self?.cancel() }
        }
        return false
    }
}
