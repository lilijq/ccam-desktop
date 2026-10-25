import AppKit


final class ClosureButton: NSButton {
    var actionBlock: (() -> Void)?
    var cornerRadius: CGFloat = 9
    var surfaceColor: NSColor? { didSet { refreshSurface() } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshSurface() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshSurface() }
    private func refreshSurface() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = surfaceColor?.cgColor }
        needsDisplay = true
    }
    override var bezelColor: NSColor? { didSet { if bezelColor != nil { contentTintColor = Theme.onPrimary } } }
    convenience init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.target = self; self.action = #selector(invoke)
        actionBlock = action
        bezelStyle = .rounded; focusRingType = .exterior
        font = Theme.font(size: 13, weight: .medium)
        controlSize = .large
        contentTintColor = Theme.text
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); imagePosition = .imageLeading }
    }
    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + (isBordered ? 6 : 0), height: max(34, base.height))
    }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: cornerRadius, yRadius: cornerRadius).fill() }
    override func draw(_ dirtyRect: NSRect) {
        guard isBordered else { super.draw(dirtyRect); return }
        let primary = bezelColor != nil
        let fill = primary ? Theme.primary : Theme.button
        (isEnabled ? (isHighlighted ? fill.blended(withFraction: 0.12, of: .black)! : fill) : Theme.disabledButton).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: cornerRadius, yRadius: cornerRadius).fill()
        let foreground = isEnabled ? (primary ? Theme.onPrimary : Theme.text) : Theme.muted
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let titleText = NSAttributedString(string: title, attributes: [.font: font ?? Theme.font(size: 13, weight: .medium), .foregroundColor: foreground, .paragraphStyle: paragraph])
        let iconWidth: CGFloat = image == nil ? 0 : 16
        let gap: CGFloat = image == nil || title.isEmpty ? 0 : 5
        let textWidth = min(titleText.size().width, max(0, bounds.width - 22 - iconWidth - gap))
        let x = (bounds.width - textWidth - iconWidth - gap) / 2
        if let image {
            let colored = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                let scale = min(rect.width / max(1, image.size.width), rect.height / max(1, image.size.height))
                let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: NSRect(x: (rect.width-size.width)/2, y: (rect.height-size.height)/2, width: size.width, height: size.height))
                foreground.setFill(); rect.fill(using: .sourceAtop); return true
            }
            colored.draw(in: NSRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16))
        }
        titleText.draw(in: NSRect(x: x + iconWidth + gap, y: (bounds.height - titleText.size().height) / 2, width: textWidth, height: titleText.size().height))
    }
    @objc func invoke() { actionBlock?() }
}

func label(_ text: String, size: CGFloat = 13, color: NSColor = Theme.text, weight: NSFont.Weight = .regular) -> NSTextField {
    let result = NSTextField(wrappingLabelWithString: text)
    result.font = Theme.font(size: size, weight: weight)
    result.textColor = color
    result.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return result
}

func column(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
    let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
    return stack
}

func row(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
    let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = spacing
    return stack
}

final class TopAlignedStack: NSStackView { override var isFlipped: Bool { true } }

private final class FlexibleSpace: NSView {}

func spacer() -> NSView {
    let v = FlexibleSpace(); v.setContentHuggingPriority(.init(1), for: .horizontal); return v
}

/// Reflows actual controls, rather than shrinking their labels until they are unreadable.
final class AdaptiveRow: NSStackView {
    var breakpoint: CGFloat = 620
    private var narrow: Bool?
    private var stretch: [NSLayoutConstraint] = []
    override func layout() {
        guard bounds.width > 0 else { super.layout(); return }
        let next = bounds.width < breakpoint
        if next != narrow {
            narrow = next
            NSLayoutConstraint.deactivate(stretch); stretch = []
            orientation = next ? .vertical : .horizontal
            alignment = next ? .leading : .centerY
            for child in arrangedSubviews {
                if child is FlexibleSpace { child.isHidden = next }
                else if next { stretch.append(child.widthAnchor.constraint(equalTo: widthAnchor)) }
            }
            NSLayoutConstraint.activate(stretch)
        }
        super.layout()
    }
}
func adaptiveRow(_ views: [NSView], spacing: CGFloat = 10, breakpoint: CGFloat = 620) -> NSStackView {
    let stack = AdaptiveRow(views: views); stack.breakpoint = breakpoint
    stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
    return stack
}
func divider() -> NSView {
    let line = ThemeSurface(Theme.border)
    line.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return line
}

func fillWidth(_ child: NSView, in stack: NSStackView) {
    stack.addArrangedSubview(child); child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
}

final class Card: ThemeSurface {
    init(_ content: NSView, padding: CGFloat = 18) {
        super.init(Theme.panel, border: Theme.border, radius: 12)
        content.translatesAutoresizingMaskIntoConstraints = false; addSubview(content)
        NSLayoutConstraint.activate([content.topAnchor.constraint(equalTo: topAnchor, constant: padding), content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding), content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding), content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding)])
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class QuotaIndicator: NSProgressIndicator {
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 0, y: max(0, (bounds.height - 6) / 2), width: bounds.width, height: 6)
        Theme.sidebar.setFill(); NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let fraction = min(1, max(0, doubleValue / 100))
        guard fraction > 0 else { return }
        (fraction <= 0.1 ? Theme.warning : Theme.accent).setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: 6), xRadius: 3, yRadius: 3).fill()
    }
}

func textArea(_ text: String, height: CGFloat = 250) -> NSScrollView {
    let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
    scroll.drawsBackground = false
    let view = NSTextView(); view.isEditable = false; view.isSelectable = true
    view.font = .monospacedSystemFont(ofSize: 12, weight: .regular); view.textColor = Theme.text
    view.backgroundColor = Theme.panel; view.textContainerInset = NSSize(width: 14, height: 14)
    view.string = text; view.isVerticallyResizable = true; view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
    scroll.documentView = view
    scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
    return scroll
}

func showError(_ error: String, window: NSWindow?) {
    let alert = NSAlert(); alert.messageText = "操作未完成"; alert.informativeText = error; alert.alertStyle = .warning
    if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
}

/// Friendly presentation stays independent from the command arguments used internally.
enum OperationLabels {
    static func title(_ spec: ActionSpec) -> String {
        switch spec.title {
        case "Remote Control": return "远程连接"
        case "全部命令帮助", "指定命令帮助": return "功能使用说明"
        case "添加本地 stdio MCP": return "添加本地 MCP 服务"
        case "查看快捷命令": return "查看快捷启动入口"
        case "设置快捷命令": return "设置快捷启动入口"
        case "删除快捷命令": return "删除快捷启动入口"
        default: return spec.title
        }
    }
    static func detail(_ spec: ActionSpec) -> String {
        if spec.command.prefix(2).elementsEqual(["group", "remove"]) {
            return "移除指定共享组。组内仍有成员时，可选择同时让成员退出；执行前可以预览影响范围。"
        }
        if spec.command.first == "migrate" {
            return "选择要复制的设置、记忆、扩展、MCP 或历史记录，先预览迁移计划，再确认执行。"
        }
        if spec.title == "添加远程 MCP" {
            return "连接 HTTP 或 SSE MCP 服务。需要授权头或其他连接配置时，可使用“通过 JSON 添加 MCP”。"
        }
        if spec.command.first == "completion" { return "生成并保存补全脚本，不会自动修改终端配置。" }
        if spec.command == ["usage", "--watch"] { return "持续刷新账号额度，切换页面时仍可运行；完成后点击停止。" }
        if spec.command == ["pick", "--wait"] { return "没有可用账号时等待额度恢复，可以随时停止等待。" }
        if spec.command.first == "help" { return "按功能分类查找操作，在表单中填写信息并选择选项。每项操作都提供本地使用说明。" }
        if spec.detail.contains("--") { return "填写所需信息并选择选项，确认后执行。" }
        return spec.detail.replacingOccurrences(of: "在内置终端中创建账号", with: "创建独立账号")
            .replacingOccurrences(of: "在内置终端", with: "在项目工作区")
            .replacingOccurrences(of: "快捷启动命令", with: "快捷启动入口")
            .replacingOccurrences(of: "快捷命令", with: "快捷启动入口")
            .replacingOccurrences(of: "CCAM", with: "系统")
    }
    static func fieldLabel(_ field: FieldSpec) -> String {
        switch field.key {
        case "shortcut": return "快捷启动名称"
        case "args": return "服务启动参数（JSON 数组）"
        case "executable": return "服务启动程序"
        case "stdin": return "事件数据（JSON）"
        default: return field.label == "共享项目" ? "共享内容" : field.label
        }
    }
    static func placeholder(_ field: FieldSpec) -> String {
        if field.key == "args" || field.key == "json" || field.key == "key" { return field.placeholder }
        if field.placeholder.contains("--") { return "请填写相应内容" }
        return field.placeholder
    }
    static func formError(_ error: Error) -> String {
        let message = error.localizedDescription
        if message.contains("--") || message.localizedCaseInsensitiveContains("ccam ") {
            return "请检查填写的信息与配置格式，然后重试。"
        }
        return message
    }
}

final class FormWindow: NSWindowController {
    let spec: ActionSpec
    let projectDirectory: String
    let onRun: ([String], Bool, String?) -> Void
    var fields: [String: NSTextField] = [:]
    var options: [(NSButton, [String])] = []
    var retained = true
    init(spec: ActionSpec, directory: String, suggestions: [String: [String]] = [:], onConfigureLogin: ((String?) -> Void)? = nil, onRun: @escaping ([String], Bool, String?) -> Void) {
        self.spec = spec; self.projectDirectory = directory; self.onRun = onRun
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.windowWidth(620), height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = OperationLabels.title(spec); window.appearance = nil; window.backgroundColor = Theme.background
        super.init(window: window)
        let help = ClosureButton("详情", symbol: "info.circle") { [weak self] in
            let a = NSAlert(); a.messageText = OperationLabels.title(spec)
            a.informativeText = OperationLabels.detail(spec) + "\n\n位置：" + directory
            if let window = self?.window { a.beginSheetModal(for: window) }
        }
        let body = column([row([label(OperationLabels.title(spec), size: 24, weight: .semibold), spacer(), help])], spacing: 18)
        let formFields = spec.fields.filter { $0.key != "extra" }
        for field in formFields {
            let title = label(OperationLabels.fieldLabel(field) + (field.required ? " · 必填" : ""), size: 12, color: Theme.muted)
            let input: NSTextField
            if let values = suggestions[field.key], !values.isEmpty {
                let combo = NSComboBox(); combo.addItems(withObjectValues: values); combo.completes = true; input = combo
            } else { input = NSTextField() }
            input.stringValue = field.initial; input.placeholderString = OperationLabels.placeholder(field)
            input.font = ["args", "json", "stdin"].contains(field.key) ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
            input.heightAnchor.constraint(equalToConstant: 30).isActive = true
            fields[field.key] = input
            let line = column([title, input], spacing: 5)
            input.widthAnchor.constraint(equalTo: line.widthAnchor).isActive = true
            if field.key == "folder" {
                line.addArrangedSubview(ClosureButton("选择文件夹…", symbol: "folder") { [weak self, weak input] in
                    guard let self else { return }
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                    panel.beginSheetModal(for: self.window!) { response in if response == .OK { input?.stringValue = panel.url?.path ?? "" } }
                })
            }
            fillWidth(line, in: body)
        }
        var availableOptions = spec.options.filter { !$0.1.contains("--json") }
        if spec.command.prefix(2).elementsEqual(["group", "remove"]), !availableOptions.contains(where: { $0.1.contains("--leave") }) {
            availableOptions.append(("同时让组内成员退出共享组", ["--leave"]))
        }
        if spec.command.first == "migrate", availableOptions.isEmpty {
            availableOptions = [("设置", ["--settings"]), ("全局记忆", ["--memory"]), ("扩展", ["--extensions"]), ("MCP", ["--mcp"]), ("对话历史", ["--history"])]
        }
        for (title, arguments) in availableOptions {
            let checkbox = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            options.append((checkbox, arguments)); body.addArrangedSubview(checkbox)
        }
        if ["login", "add"].contains(spec.command.first ?? ""), spec.title != "新增 API 账号", let configure = onConfigureLogin {
            body.addArrangedSubview(ClosureButton("Chrome 账号锁", symbol: "lock") { [weak self] in
                let name = self?.fields["account"]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                configure(name?.isEmpty == false ? name : nil)
            })
        }
        let actions = adaptiveRow([ClosureButton("取消") { [weak self] in self?.close() }, spacer()])
        if spec.dryRun { actions.addArrangedSubview(ClosureButton("预览变更", symbol: "eye") { [weak self] in self?.submit(preview: true) }) }
        let run = ClosureButton(spec.launchesClaude ? "开始会话" : "确认执行", symbol: "play.fill") { [weak self] in self?.submit(preview: false) }
        run.bezelColor = Theme.accent; actions.addArrangedSubview(run); fillWidth(actions, in: body)
        let container = NSView(); container.addSubview(body); body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([body.topAnchor.constraint(equalTo: container.topAnchor, constant: 24), body.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24), body.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24), body.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24)])
        window.contentView = container
        window.minSize = NSSize(width: 390, height: 240)
        window.setContentSize(NSSize(width: Theme.windowWidth(620), height: max(220, body.fittingSize.height + 48)))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func submit(preview: Bool) {
        do {
            let values = fields.mapValues { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let serverArguments = values["args"], !serverArguments.isEmpty {
                guard let decoded = try? JSONSerialization.jsonObject(with: Data(serverArguments.utf8)), decoded is [String] else {
                    throw AppError.message("服务启动参数应为 JSON 字符串数组，每一项填写一个参数。")
                }
            }
            var args = try spec.arguments(values)
            for (option, arguments) in options where option.state == .on { args += arguments }
            if spec.options.contains(where: { $0.1.contains("--json") }), !args.contains("--json") { args.append("--json") }
            let stdin = spec.stdinKey.flatMap { values[$0] }
            if let stdin { _ = try JSONSerialization.jsonObject(with: Data(stdin.utf8)) }
            if preview { args.insert("--dry-run", at: 0) }
            onRun(args, spec.launchesClaude && !preview, preview ? nil : stdin)
            if !preview { close() }
        } catch { showError(OperationLabels.formError(error), window: window) }
    }
}

