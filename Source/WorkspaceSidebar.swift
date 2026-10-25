import AppKit

/// Native buttons keep keyboard and accessibility behavior while drawing quiet,
/// left-aligned navigation without the system accent-color bezel.
final class SidebarItemButton: NSButton {
    var handler: (() -> Void)?
    var onSecondaryClick: ((NSView) -> Void)?
    var selected = false { didSet { needsDisplay = true } }
    var symbol: String?
    private var hovering = false
    private var tracking: NSTrackingArea?
    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.symbol = symbol; self.handler = action
        super.init(frame: .zero)
        self.title = title; target = self; self.action = #selector(invoke)
        font = Theme.font(size: 13); isBordered = false; focusRingType = .exterior
        toolTip = title; setAccessibilityLabel(title)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 36) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 8, yRadius: 8).fill() }
    override func draw(_ dirtyRect: NSRect) {
        if selected || hovering || isHighlighted {
            (selected ? Theme.button : Theme.panel).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        let color = isEnabled ? Theme.text : Theme.muted
        var x: CGFloat = 12
        if let symbol, let source = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                let scale = min(rect.width / max(1, source.size.width), rect.height / max(1, source.size.height))
                let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
                source.draw(in: NSRect(x: (16-size.width)/2, y: (16-size.height)/2, width: size.width, height: size.height))
                color.setFill(); rect.fill(using: .sourceAtop); return true
            }
            icon.draw(in: NSRect(x: title.isEmpty ? (bounds.width-16)/2 : x, y: (bounds.height-16)/2, width: 16, height: 16)); x += 26
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: title, attributes: [.font: font ?? Theme.font(size: 13), .foregroundColor: color, .paragraphStyle: paragraph])
        text.draw(in: NSRect(x: x, y: (bounds.height-text.size().height)/2, width: max(0, bounds.width-x-12), height: text.size().height))
    }
    @objc private func invoke() { handler?() }
    override func rightMouseDown(with event: NSEvent) {
        if let onSecondaryClick { onSecondaryClick(self) } else { super.rightMouseDown(with: event) }
    }
}

final class SidebarQuotaButton: NSButton {
    var summary = QuotaSummary.make(accounts: [], usage: []) { didSet { needsDisplay = true } }
    var cacheOverride: String? { didSet { needsDisplay = true } }
    var handler: (() -> Void)?
    private let compact: Bool
    private var hovering = false
    private var tracking: NSTrackingArea?
    init(compact: Bool = false) {
        self.compact = compact
        super.init(frame: .zero)
        title = "剩余额度"; isBordered = false; target = self; action = #selector(invoke)
        focusRingType = .exterior
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: compact ? 300 : 196, height: compact ? 64 : 100) }
    override var isFlipped: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 1, dy: 1) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 8, yRadius: 8).fill() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlighted {
            Theme.panel.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        let inset: CGFloat = 8
        let numberWidth: CGFloat = compact ? min(92, (bounds.width - 100) / 2) : 55
        let weekX = bounds.width - inset - numberWidth
        let fiveX = weekX - numberWidth - 3
        let labelWidth = max(28, fiveX - inset - 4)
        func text(_ string: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat = 11,
                  color: NSColor = Theme.muted, numeric: Bool = false, strong: Bool = false) {
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            style.alignment = numeric ? .right : .left
            let font = numeric ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: strong ? .semibold : .medium)
                : Theme.font(size: size, weight: strong ? .medium : .regular)
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
                .draw(in: NSRect(x: x, y: y, width: width, height: 17))
        }
        if !compact {
            text("剩余额度", x: inset, y: 7, width: labelWidth)
            text("5 小时", x: fiveX, y: 7, width: numberWidth, numeric: true)
            text("每周", x: weekX, y: 7, width: numberWidth, numeric: true)
        }
        let currentY: CGFloat = compact ? 3 : 30, totalY: CGFloat = compact ? 24 : 54
        let fivePrefix = compact ? "5h " : "", weekPrefix = compact ? "周 " : ""
        text(summary.currentAccountName ?? "当前", x: inset, y: currentY, width: labelWidth, color: Theme.text)
        text(fivePrefix + summary.currentFiveHour, x: fiveX, y: currentY, width: numberWidth, size: 12, color: Theme.text, numeric: true)
        text(weekPrefix + summary.currentWeekly, x: weekX, y: currentY, width: numberWidth, size: 12, color: Theme.text, numeric: true)
        text("总剩余", x: inset, y: totalY, width: labelWidth, color: Theme.text, strong: true)
        text(fivePrefix + summary.totalFiveHour, x: fiveX, y: totalY, width: numberWidth, size: 12, color: Theme.text, numeric: true, strong: true)
        text(weekPrefix + summary.totalWeekly, x: weekX, y: totalY, width: numberWidth, size: 12, color: Theme.text, numeric: true, strong: true)
        let caption = summary.poolCoverage + (compact ? "   " + (cacheOverride ?? summary.cacheLabel) : "")
        text(caption, x: inset, y: compact ? 46 : 78, width: bounds.width - 2 * inset, size: 10)
    }
    func update(_ value: QuotaSummary, readFailed: Bool = false) {
        summary = value; cacheOverride = readFailed ? "本机读取失败，保留旧缓存" : nil
        toolTip = value.tooltip
        setAccessibilityLabel("可用额度，当前账号 " + (value.currentAccountName ?? "未知")
            + "，5 小时 " + value.currentFiveHour + "，每周 " + value.currentWeekly
            + "；总剩余，5 小时 " + value.totalFiveHour + "，每周 " + value.totalWeekly
            + "。" + value.poolCoverage + "。" + (cacheOverride ?? value.cacheLabel))
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    @objc private func invoke() { handler?() }
}

final class WorkspaceSidebar: NSView {
    var onNewConversation: (() -> Void)?
    var onAddProject: (() -> Void)?
    var onProjects: (() -> Void)?
    var onHistory: (() -> Void)?
    var onProject: ((ProjectRecord) -> Void)?
    var onConversation: ((String) -> Void)?
    var onConversationActions: ((String, NSView) -> Void)?
    var onDeletedConversations: ((NSView) -> Void)?
    var onQuota: (() -> Void)?
    var onManage: ((NSView) -> Void)?
    private let projects = TopAlignedStack()
    private let history = TopAlignedStack()
    private var newButton: SidebarItemButton!
    private var projectHeight: NSLayoutConstraint!
    private var projectCount = 1
    private var signature = ""
    let manageButton = SidebarItemButton("", symbol: "gearshape") {}
    private let quotaButton = SidebarQuotaButton()
    private let quotaCache = label("仅本机缓存", size: 10, color: Theme.muted)
    override init(frame: NSRect) {
        super.init(frame: frame)
        let mark = NSImageView(image: NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "账号接力")!)
        mark.contentTintColor = Theme.text; mark.widthAnchor.constraint(equalToConstant: 20).isActive = true; mark.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let brand = row([mark, label("CCAM", size: 16, weight: .semibold), spacer()], spacing: 9)
        newButton = SidebarItemButton("新对话", symbol: "square.and.pencil") { [weak self] in self?.onNewConversation?() }
        let projectHeading = SidebarItemButton("项目") { [weak self] in self?.onProjects?() }
        projectHeading.font = Theme.font(size: 12, weight: .medium)
        let add = SidebarItemButton("", symbol: "plus") { [weak self] in self?.onAddProject?() }
        add.setAccessibilityLabel("添加项目"); add.toolTip = "添加项目"; add.widthAnchor.constraint(equalToConstant: 32).isActive = true
        let projectTitle = row([projectHeading, spacer(), add], spacing: 0)
        let historyHeading = SidebarItemButton("最近对话") { [weak self] in self?.onHistory?() }
        historyHeading.font = Theme.font(size: 12, weight: .medium)
        historyHeading.toolTip = "查看后台会话记录"; historyHeading.setAccessibilityLabel("最近对话与后台会话记录")
        let deleted = SidebarItemButton("", symbol: "trash") {}
        deleted.setAccessibilityLabel("已删除的对话"); deleted.toolTip = "已删除的对话"; deleted.widthAnchor.constraint(equalToConstant: 28).isActive = true
        deleted.handler = { [weak self, weak deleted] in guard let deleted else { return }; self?.onDeletedConversations?(deleted) }
        let historyTitle = row([historyHeading, spacer(), deleted], spacing: 0)
        let projectScroll = makeList(projects), historyScroll = makeList(history)
        let top = column([], spacing: 8)
        for view in [brand, newButton!, projectTitle, projectScroll, historyTitle] { fillWidth(view, in: top) }
        top.setCustomSpacing(24, after: brand); top.setCustomSpacing(22, after: newButton)
        projectHeight = projectScroll.heightAnchor.constraint(equalToConstant: 40); projectHeight.isActive = true
        top.translatesAutoresizingMaskIntoConstraints = false; addSubview(top)
        historyScroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(historyScroll)
        manageButton.setAccessibilityLabel("管理与设置"); manageButton.toolTip = "管理与设置（⌘ ,）"
        manageButton.handler = { [weak self] in guard let self else { return }; self.onManage?(self.manageButton) }
        quotaButton.handler = { [weak self] in self?.onQuota?() }
        quotaCache.maximumNumberOfLines = 1; quotaCache.lineBreakMode = .byTruncatingTail
        let footer = column([], spacing: 4)
        fillWidth(divider(), in: footer)
        fillWidth(quotaButton, in: footer)
        fillWidth(row([manageButton, quotaCache, spacer()], spacing: 6), in: footer)
        footer.setCustomSpacing(9, after: footer.arrangedSubviews[0])
        footer.translatesAutoresizingMaskIntoConstraints = false; addSubview(footer)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor, constant: 54), top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            brand.heightAnchor.constraint(equalToConstant: 24),
            historyScroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 4), historyScroll.leadingAnchor.constraint(equalTo: top.leadingAnchor), historyScroll.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            historyScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -18), historyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18), footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            manageButton.widthAnchor.constraint(equalToConstant: 30), manageButton.heightAnchor.constraint(equalToConstant: 36)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        updateProjectHeight()
        super.layout()
    }
    private func updateProjectHeight() {
        guard projectHeight != nil else { return }
        // Keep recent conversations usable when the persistent quota area grows.
        let visibleRows = min(5, max(1, Int((bounds.height - 520) / 39)))
        let height = CGFloat(min(visibleRows, max(1, projectCount))) * 39
        if projectHeight.constant != height { projectHeight.constant = height }
    }
    func updateQuota(_ summary: QuotaSummary, readFailed: Bool = false) {
        quotaButton.update(summary, readFailed: readFailed)
        quotaCache.stringValue = readFailed ? "本机读取失败，保留旧缓存" : summary.cacheLabel
        quotaCache.toolTip = summary.tooltip
        quotaButton.needsDisplay = true
    }
    private func makeList(_ stack: NSStackView) -> NSScrollView {
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 3; stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = stack
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        return scroll
    }
    func update(records: [ProjectRecord], currentID: UUID?, items: [(id: String, title: String)], selectedID: String?, running: Bool) {
        let next = records.map { $0.id.uuidString + $0.name }.joined() + (currentID?.uuidString ?? "") + items.map { $0.id + $0.title }.joined() + (selectedID ?? "") + String(running)
        guard next != signature else { return }; signature = next
        newButton.isEnabled = !running
        for stack in [projects, history] { for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() } }
        for project in records {
            let button = SidebarItemButton(project.name, symbol: "folder") { [weak self] in self?.onProject?(project) }
            button.selected = project.id == currentID; fillWidth(button, in: projects)
        }
        if records.isEmpty { fillWidth(label("添加一个项目开始", size: 12, color: Theme.muted), in: projects) }
        projectCount = records.count; updateProjectHeight()
        for item in items {
            let button = SidebarItemButton(item.title.isEmpty ? "新对话" : item.title) { [weak self] in self?.onConversation?(item.id) }
            button.selected = item.id == selectedID; button.isEnabled = !running
            button.onSecondaryClick = { [weak self] sender in self?.onConversationActions?(item.id, sender) }
            let more = SidebarItemButton("", symbol: "ellipsis") {}
            more.widthAnchor.constraint(equalToConstant: 28).isActive = true; more.isEnabled = !running
            more.setAccessibilityLabel("对话操作：" + item.title); more.toolTip = "重命名、导出或删除"
            more.handler = { [weak self, weak more] in guard let more else { return }; self?.onConversationActions?(item.id, more) }
            fillWidth(row([button, more], spacing: 0), in: history)
        }
        if items.isEmpty { fillWidth(label("还没有对话", size: 12, color: Theme.muted), in: history) }
    }
}
