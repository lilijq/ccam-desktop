import AppKit

private final class TopStack: NSStackView { override var isFlipped: Bool { true } }

/// One quiet list surface, with the full row behaving as a native keyboard-accessible button.
private final class FeatureNavigationButton: NSButton {
    private let symbol: String?
    private let separator: Bool
    private let invokeAction: () -> Void
    init(_ title: String, symbol: String? = nil, separator: Bool, action: @escaping () -> Void) {
        self.symbol = symbol; self.separator = separator; self.invokeAction = action
        super.init(frame: .zero)
        self.title = title; self.target = self; self.action = #selector(invoke)
        isBordered = false; setButtonType(.momentaryPushIn); focusRingType = .exterior
        setAccessibilityLabel(title)
        heightAnchor.constraint(equalToConstant: 48).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { invokeAction() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override var intrinsicContentSize: NSSize { NSSize(width: 220, height: 48) }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 5, yRadius: 5).fill() }
    override func draw(_ dirtyRect: NSRect) {
        (isHighlighted ? Theme.accent.withAlphaComponent(0.07) : Theme.panel).setFill(); bounds.fill()
        let start: CGFloat = symbol == nil ? 16 : 47
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 17, weight: .regular)) {
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect); Theme.accent.setFill(); rect.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: 16, y: (bounds.height - 19) / 2, width: 19, height: 19))
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.font(size: 14, weight: .medium), .foregroundColor: Theme.text, .paragraphStyle: paragraph]
        let content = NSAttributedString(string: title, attributes: attributes)
        let size = content.size()
        content.draw(in: NSRect(x: start, y: (bounds.height - size.height) / 2, width: max(0, bounds.width - start - 40), height: size.height))
        if let arrow = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium)) {
            let tinted = NSImage(size: arrow.size, flipped: false) { rect in
                arrow.draw(in: rect); Theme.muted.setFill(); rect.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: bounds.width - 25, y: (bounds.height - 10) / 2, width: 7, height: 10))
        }
        if separator {
            Theme.border.setStroke(); let line = NSBezierPath(); line.lineWidth = 0.5
            line.move(to: NSPoint(x: start, y: 0.5)); line.line(to: NSPoint(x: bounds.width - 16, y: 0.5)); line.stroke()
        }
    }
}

final class CommandCenterView: NSView, NSSearchFieldDelegate {
    let search = NSSearchField()
    private let back = ClosureButton("全部功能", symbol: "chevron.left", action: {})
    private var selectedGroup: String?
    private var compact = true
    private var rebuilding = false
    private let results: NSStackView = {
        let stack = TopStack(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; return stack
    }()
    private let scroll = NSScrollView()
    var onRun: ((ActionSpec) -> Void)?
    var onLoginLock: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = nil
        search.placeholderString = "搜索功能"; search.delegate = self; search.font = Theme.font(size: 13, weight: .regular)
        search.heightAnchor.constraint(equalToConstant: 32).isActive = true
        search.setContentHuggingPriority(.init(1), for: .horizontal)
        back.actionBlock = { [weak self] in self?.showOverview() }
        let loginLock = ClosureButton("Chrome 账号锁", symbol: "lock") { [weak self] in self?.onLoginLock?() }
        let toolbar = column([], spacing: 10)
        fillWidth(row([back, spacer(), loginLock]), in: toolbar); fillWidth(search, in: toolbar)
        toolbar.translatesAutoresizingMaskIntoConstraints = false; addSubview(toolbar)
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
        results.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = results
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor), toolbar.leadingAnchor.constraint(equalTo: leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 18), scroll.bottomAnchor.constraint(equalTo: bottomAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            results.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), results.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor), results.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), results.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        update()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let next = bounds.width < 560
        if compact != next && !rebuilding { compact = next; update() }
    }
    func controlTextDidChange(_ notification: Notification) { update() }
    private func showOverview() { selectedGroup = nil; search.stringValue = ""; update() }
    private func showGroup(_ group: FeatureGroup) { selectedGroup = group.id; search.stringValue = ""; update() }
    func update() {
        guard !rebuilding else { return }
        rebuilding = true; defer { rebuilding = false }
        for view in results.arrangedSubviews { results.removeArrangedSubview(view); view.removeFromSuperview() }
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        back.isHidden = selectedGroup == nil && query.isEmpty
        if !query.isEmpty {
            let matches = FeatureIndex.search(query) { entry in
                OperationLabels.title(entry.spec) + " " + OperationLabels.detail(entry.spec) + " " + (FeatureIndex.groups.first { $0.id == FeatureIndex.groupID(for: entry) }?.title ?? "")
            }
            fillWidth(label("搜索结果", size: 13, color: Theme.muted, weight: .medium), in: results)
            addOperations(matches)
            if matches.isEmpty { fillWidth(label("没有找到相关功能", color: Theme.muted), in: results) }
        } else if let group = FeatureIndex.groups.first(where: { $0.id == selectedGroup }) {
            fillWidth(label(group.title, size: 18, weight: .semibold), in: results)
            addOperations(FeatureIndex.entries(in: group.id))
        } else { addOverview() }
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func addOverview() {
        let entries = FeatureIndex.common
        let columns = compact ? 2 : 4
        let common = column([], spacing: 8)
        for offset in stride(from: 0, to: entries.count, by: columns) {
            let line = row([], spacing: 8); line.distribution = .fillEqually
            for entry in entries[offset..<min(offset + columns, entries.count)] {
                let button = ClosureButton(OperationLabels.title(entry.spec)) { [weak self] in self?.onRun?(entry.spec) }
                button.heightAnchor.constraint(equalToConstant: 34).isActive = true
                button.toolTip = OperationLabels.detail(entry.spec); line.addArrangedSubview(button)
            }
            fillWidth(line, in: common)
        }
        fillWidth(common, in: results); results.setCustomSpacing(20, after: common)
        let list = column([], spacing: 0)
        for (index, group) in FeatureIndex.groups.enumerated() {
            let button = FeatureNavigationButton(group.title, symbol: group.symbol, separator: index < FeatureIndex.groups.count - 1) { [weak self] in self?.showGroup(group) }
            button.setAccessibilityLabel("打开" + group.title); fillWidth(button, in: list)
        }
        fillWidth(Card(list, padding: 0), in: results)
    }
    private func addOperations(_ entries: [CommandEntry]) {
        guard !entries.isEmpty else { return }
        let list = column([], spacing: 0)
        for (index, entry) in entries.enumerated() {
            let button = FeatureNavigationButton(OperationLabels.title(entry.spec), separator: index < entries.count - 1) { [weak self] in self?.onRun?(entry.spec) }
            button.toolTip = OperationLabels.detail(entry.spec)
            button.setAccessibilityLabel("打开" + OperationLabels.title(entry.spec))
            fillWidth(button, in: list)
        }
        fillWidth(Card(list, padding: 0), in: results)
    }
}
