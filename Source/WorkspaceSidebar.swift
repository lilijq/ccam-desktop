import AppKit

/// Native buttons keep keyboard and accessibility behavior while drawing quiet,
/// left-aligned navigation without the system accent-color bezel.
final class SidebarItemButton: NSButton {
    var handler: (() -> Void)?
    var onSecondaryClick: ((NSView) -> Void)?
    var selected = false { didSet { needsDisplay = true } }
    var symbol: String?
    var rowHeight: CGFloat = 36
    var contentInset: CGFloat = 12
    var drawsSelection = true
    var quiet = false
    var contextual = false
    var contextActive = false { didSet { needsDisplay = true } }
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
    override var intrinsicContentSize: NSSize { NSSize(width: 120, height: rowHeight) }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
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
        let focused = window?.firstResponder === self
        guard !contextual || contextActive || hovering || focused || isHighlighted else { return }
        if (selected && drawsSelection) || hovering || isHighlighted {
            (selected && drawsSelection ? Theme.button : Theme.panel).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        let color = isEnabled && (!quiet || selected || hovering || focused) ? Theme.text : Theme.muted
        var x = contentInset
        if let symbol, let source = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                let scale = min(rect.width / max(1, source.size.width), rect.height / max(1, source.size.height))
                let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
                source.draw(in: NSRect(x: (16-size.width)/2, y: (16-size.height)/2, width: size.width, height: size.height))
                color.setFill(); rect.fill(using: .sourceAtop); return true
            }
            icon.draw(in: NSRect(x: title.isEmpty ? (bounds.width-16)/2 : x, y: (bounds.height-16)/2, width: 16, height: 16)); x += 22
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

/// Two genuine buttons with circular indicators: quota is read-only.
/// Each row has its own tooltip and keyboard activation, and never starts a refresh.
final class SidebarQuotaGaugeButton: NSButton {
    enum Scope { case current, total }
    let scope: Scope
    var snapshot: QuotaGaugeSnapshot? { didSet { needsDisplay = true } }
    var readFailed = false { didSet { needsDisplay = true } }
    var handler: (() -> Void)?
    private var hovering = false
    private var tracking: NSTrackingArea?
    init(scope: Scope) {
        self.scope = scope
        super.init(frame: .zero)
        title = scope == .current ? "当前" : "全部"
        target = self; action = #selector(invoke); isBordered = false; focusRingType = .exterior
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityHelp("显示 5 小时剩余额度。按下进入账号与额度。")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 196, height: 32) }
    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 1, dy: 1) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 6, yRadius: 6).fill() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    var ringRect: NSRect { NSRect(x: 8, y: (bounds.height - 22) / 2, width: 22, height: 22) }
    var percentageRect: NSRect { NSRect(x: max(85, bounds.width - 88), y: (bounds.height - 18) / 2, width: min(76, max(0, bounds.width - 97)), height: 18) }
    var displayedPercentage: String {
        guard let remaining = snapshot?.remainingFraction, remaining.isFinite else { return "--" }
        let amount = max(0, min(100, remaining * 100))
        let number = amount > 0 && amount < 1 ? "<1%" : String(format: "%.0f%%", floor(amount + 1e-9))
        // Partial coverage is a lower bound, never a precise total balance.
        if (snapshot?.knownFraction ?? 0) < 1 {
            return amount > 0 && amount < 1 ? ">0%" : "≥" + number
        }
        return number
    }
    enum Tone { case healthy, low, critical, unknown }
    var tone: Tone {
        guard let value = snapshot?.remainingFraction, value.isFinite,
              (snapshot?.knownFraction ?? 0) >= 1 else { return .unknown }
        if value > 0.5 { return .healthy }
        if value > 0.2 { return .low }
        return .critical
    }
    private var gaugeColor: NSColor {
        switch tone { case .healthy: return Theme.success; case .low: return Theme.warning; case .critical: return Theme.danger; case .unknown: return Theme.muted }
    }
    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlighted {
            Theme.panel.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let label = NSAttributedString(string: title, attributes: [.font: Theme.font(size: 11, weight: .medium), .foregroundColor: Theme.muted])
        label.draw(at: NSPoint(x: 42, y: (bounds.height - label.size().height) / 2))
        let style = NSMutableParagraphStyle(); style.alignment = .right
        NSAttributedString(string: displayedPercentage, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: gaugeColor, .paragraphStyle: style]).draw(in: percentageRect)
        if snapshot?.stale == true || readFailed {
            let icon = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
            let badge = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
                icon?.draw(in: rect); Theme.muted.setFill(); rect.fill(using: .sourceAtop); return true
            }
            badge.draw(in: NSRect(x: 72, y: (bounds.height - 10) / 2, width: 10, height: 10))
        }
        let ring = ringRect, center = NSPoint(x: ring.midX, y: ring.midY), radius = ring.width / 2
        let origin: CGFloat = isFlipped ? -90 : 90
        let direction: CGFloat = isFlipped ? 1 : -1
        let known = CGFloat(max(0, min(1, snapshot?.knownFraction ?? 0)))
        func arc(_ start: CGFloat, _ end: CGFloat) -> NSBezierPath {
            let path = NSBezierPath(); path.lineWidth = 2.5; path.lineCapStyle = .round
            path.appendArc(withCenter: center, radius: radius, startAngle: origin + direction * start * 360, endAngle: origin + direction * end * 360, clockwise: !isFlipped)
            return path
        }
        if known > 0 {
            Theme.border.setStroke(); arc(0, known).stroke()
        }
        if known < 1 {
            let unknown = arc(known + (known > 0 ? min(0.02, (1 - known) / 4) : 0), 1)
            unknown.lineWidth = 1.5; unknown.setLineDash([1, 4], count: 2, phase: 0)
            Theme.muted.withAlphaComponent(0.6).setStroke(); unknown.stroke()
        }
        guard let remaining = snapshot?.remainingFraction else { return }
        let fraction = CGFloat(max(0, min(Double(known), remaining)))
        if fraction > 0 {
            gaugeColor.setStroke(); arc(0, fraction).stroke()
        }
        let angle = (origin + direction * fraction * 360) * .pi / 180
        let endpoint = NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        let thumb = NSBezierPath(ovalIn: NSRect(x: endpoint.x - 2, y: endpoint.y - 2, width: 4, height: 4))
        if snapshot?.stale == true || readFailed {
            (hovering ? Theme.panel : Theme.sidebar).setFill(); thumb.fill()
            gaugeColor.setStroke(); thumb.lineWidth = 1; thumb.stroke()
        } else { gaugeColor.setFill(); thumb.fill() }
    }
    func update(_ value: QuotaGaugeSnapshot, readFailed: Bool) {
        snapshot = value; self.readFailed = readFailed
        let prefix = readFailed ? "本机读取失败，保留旧缓存。\n" : ""
        toolTip = prefix + value.tooltip + "\n点击进入账号与额度"
        setAccessibilityLabel((scope == .current ? "当前账号额度" : "账号池总额度") + "，剩余 " + displayedPercentage + "。" + prefix + value.tooltip)
    }
    @objc private func invoke() { handler?() }
}

final class SidebarQuotaView: NSView {
    var handler: (() -> Void)?
    let currentButton = SidebarQuotaGaugeButton(scope: .current)
    let totalButton = SidebarQuotaGaugeButton(scope: .total)
    init(compact: Bool = false) {
        super.init(frame: .zero)
        for button in [currentButton, totalButton] {
            button.translatesAutoresizingMaskIntoConstraints = false; addSubview(button)
            button.handler = { [weak self] in self?.handler?() }
            NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo: leadingAnchor), button.trailingAnchor.constraint(equalTo: trailingAnchor), button.heightAnchor.constraint(equalToConstant: 32)])
        }
        NSLayoutConstraint.activate([currentButton.topAnchor.constraint(equalTo: topAnchor), totalButton.topAnchor.constraint(equalTo: currentButton.bottomAnchor), totalButton.bottomAnchor.constraint(equalTo: bottomAnchor)])
        update(QuotaSummary.make(accounts: [], usage: []))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 196, height: 64) }
    func update(_ value: QuotaSummary, readFailed: Bool = false) {
        currentButton.update(value.currentGauge, readFailed: readFailed)
        totalButton.update(value.totalGauge, readFailed: readFailed)
    }
}

/// The whole row exposes contextual controls; selection belongs to a conversation,
/// while its owning project is identified through type weight and the folder icon.
private final class SidebarNavigationRow: NSStackView {
    var selected = false { didSet { updateAccessories(); needsDisplay = true } }
    var accessories: [SidebarItemButton] = [] { didSet { updateAccessories() } }
    private var hovering = false
    private var tracking: NSTrackingArea?
    init(_ views: [NSView]) {
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; distribution = .fill; spacing = 0
        for view in views { addArrangedSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(tracking!)
    }
    private func updateAccessories() { for accessory in accessories { accessory.contextActive = hovering || selected } }
    override func mouseEntered(with event: NSEvent) { hovering = true; updateAccessories() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateAccessories() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        Theme.button.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

private final class SidebarBranchGuide: NSView {
    var last = false
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let line = NSBezierPath(); line.lineWidth = 1
        line.move(to: NSPoint(x: 32.5, y: bounds.maxY))
        line.line(to: NSPoint(x: 32.5, y: last ? bounds.midY : bounds.minY))
        Theme.border.withAlphaComponent(0.7).setStroke(); line.stroke()
    }
}

struct SidebarProjectGroup {
    let project: ProjectRecord
    var items: [(id: String, title: String)] = []
    var selectedID: String? = nil
    var running = false
    var error: String? = nil
}

final class WorkspaceSidebar: NSView {
    var onNewConversation: (() -> Void)?
    var onAddProject: (() -> Void)?
    var onProjects: (() -> Void)?
    var onProject: ((ProjectRecord) -> Void)?
    var onConversation: ((ProjectRecord, String) -> Void)?
    var onConversationActions: ((ProjectRecord, String, NSView) -> Void)?
    var onDeletedConversations: ((ProjectRecord, NSView) -> Void)?
    var onExpansionChange: (() -> Void)?
    var onQuota: (() -> Void)?
    var onManage: ((NSView) -> Void)?
    private let projects = TopAlignedStack()
    private var newButton: SidebarItemButton!
    private var signature = ""
    private var currentID: UUID?
    private var groups: [SidebarProjectGroup] = []
    private(set) var expandedProjectIDs = Set<UUID>()
    private var actionAnchors: [String: NSView] = [:]
    private var deletedAnchors: [UUID: NSView] = [:]
    let manageButton = SidebarItemButton("", symbol: "gearshape") {}
    private let quotaView = SidebarQuotaView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        let mark = NSImageView(image: NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "账号接力")!)
        mark.contentTintColor = Theme.text; mark.widthAnchor.constraint(equalToConstant: 20).isActive = true; mark.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let brand = row([mark, label("CCAM", size: 15, weight: .semibold), spacer()], spacing: 9)
        newButton = SidebarItemButton("新对话", symbol: "square.and.pencil") { [weak self] in self?.onNewConversation?() }
        newButton.rowHeight = 34; newButton.contentInset = 8
        let projectHeading = SidebarItemButton("项目") { [weak self] in self?.onProjects?() }
        projectHeading.font = Theme.font(size: 11, weight: .medium); projectHeading.quiet = true; projectHeading.rowHeight = 28; projectHeading.contentInset = 8
        projectHeading.toolTip = "管理项目"
        let add = SidebarItemButton("", symbol: "plus") { [weak self] in self?.onAddProject?() }
        add.rowHeight = 28; add.quiet = true
        add.setAccessibilityLabel("添加项目"); add.toolTip = "添加项目"; add.widthAnchor.constraint(equalToConstant: 32).isActive = true
        let projectTitle = row([projectHeading, spacer(), add], spacing: 0)
        let top = column([], spacing: 8)
        for view in [brand, newButton!, projectTitle] { fillWidth(view, in: top) }
        top.setCustomSpacing(18, after: brand); top.setCustomSpacing(20, after: newButton)
        top.translatesAutoresizingMaskIntoConstraints = false; addSubview(top)
        let projectScroll = makeList(projects)
        projectScroll.setAccessibilityLabel("项目与对话")
        projectScroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(projectScroll)
        manageButton.setAccessibilityLabel("管理与设置"); manageButton.toolTip = "管理与设置（⌘ ,）"
        manageButton.handler = { [weak self] in guard let self else { return }; self.onManage?(self.manageButton) }
        quotaView.handler = { [weak self] in self?.onQuota?() }
        manageButton.quiet = true
        let footer = column([], spacing: 6)
        fillWidth(quotaView, in: footer)
        fillWidth(row([manageButton, spacer()], spacing: 0), in: footer)
        footer.translatesAutoresizingMaskIntoConstraints = false; addSubview(footer)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor, constant: 54), top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            brand.heightAnchor.constraint(equalToConstant: 24),
            projectScroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 4), projectScroll.leadingAnchor.constraint(equalTo: top.leadingAnchor), projectScroll.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            projectScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -18), projectScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            manageButton.widthAnchor.constraint(equalToConstant: 30), manageButton.heightAnchor.constraint(equalToConstant: 36)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Selection opens its project once; token updates do not undo a manual collapse.
    func prepareProjects(_ records: [ProjectRecord], currentID: UUID?) {
        expandedProjectIDs.formIntersection(Set(records.map(\.id)))
        if self.currentID != currentID, let currentID { expandedProjectIDs.insert(currentID) }
        self.currentID = currentID
    }
    func revealProject(_ id: UUID) { expandedProjectIDs.insert(id) }
    func conversationActionAnchor(projectID: UUID, conversationID: String) -> NSView? {
        actionAnchors[projectID.uuidString + ":" + conversationID]
    }
    func deletedConversationAnchor(projectID: UUID) -> NSView? { deletedAnchors[projectID] }
    func updateQuota(_ summary: QuotaSummary, readFailed: Bool = false) {
        quotaView.update(summary, readFailed: readFailed)
    }
    private func makeList(_ stack: NSStackView) -> NSScrollView {
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8; stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = stack
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        return scroll
    }
    func update(groups: [SidebarProjectGroup], currentID: UUID?) {
        prepareProjects(groups.map(\.project), currentID: currentID)
        self.groups = groups
        let next = String(describing: groups.map { ($0.project.id, $0.project.name, $0.items.map { [$0.id, $0.title] }, $0.selectedID, $0.running, $0.error) })
            + (currentID?.uuidString ?? "") + expandedProjectIDs.map(\.uuidString).sorted().joined()
        guard next != signature else { return }; signature = next
        let focusID = (window?.firstResponder as? SidebarItemButton)?.identifier
        newButton.isEnabled = !(groups.first { $0.project.id == currentID }?.running ?? false)
        for view in projects.arrangedSubviews { projects.removeArrangedSubview(view); view.removeFromSuperview() }
        actionAnchors.removeAll(); deletedAnchors.removeAll()
        for group in groups {
            let project = group.project, expanded = expandedProjectIDs.contains(project.id)
            let container = column([], spacing: 2)
            let disclosure = SidebarItemButton("", symbol: expanded ? "chevron.down" : "chevron.right") { [weak self] in
                guard let self else { return }
                if self.expandedProjectIDs.contains(project.id) { self.expandedProjectIDs.remove(project.id) }
                else { self.expandedProjectIDs.insert(project.id) }
                self.update(groups: self.groups, currentID: self.currentID)
                self.onExpansionChange?()
            }
            disclosure.widthAnchor.constraint(equalToConstant: 20).isActive = true
            disclosure.setAccessibilityLabel((expanded ? "收起项目：" : "展开项目：") + project.name)
            disclosure.identifier = NSUserInterfaceItemIdentifier("disclosure:" + project.id.uuidString)
            disclosure.toolTip = expanded ? "收起对话" : "展开对话"
            disclosure.rowHeight = 32; disclosure.quiet = true
            let button = SidebarItemButton(project.name, symbol: group.running ? "circle.dotted" : "folder") { [weak self] in self?.onProject?(project) }
            button.identifier = NSUserInterfaceItemIdentifier("project:" + project.id.uuidString)
            button.selected = project.id == currentID; button.drawsSelection = false
            button.quiet = true; button.font = Theme.font(size: 13, weight: .medium)
            button.rowHeight = 32; button.contentInset = 4
            button.setContentHuggingPriority(.init(1), for: .horizontal)
            button.toolTip = project.path + (group.running ? " · 对话运行中" : "")
            let projectRow = SidebarNavigationRow([disclosure, button])
            if expanded {
                let deleted = SidebarItemButton("", symbol: "trash") {}
                deleted.rowHeight = 32; deleted.contextual = true; deleted.quiet = true
                deleted.widthAnchor.constraint(equalToConstant: 28).isActive = true; deleted.isEnabled = !group.running
                deleted.setAccessibilityLabel("已删除的对话：" + project.name); deleted.toolTip = "已删除的对话"
                deleted.identifier = NSUserInterfaceItemIdentifier("deleted:" + project.id.uuidString)
                deleted.handler = { [weak self, weak deleted] in guard let deleted else { return }; self?.onDeletedConversations?(project, deleted) }
                deletedAnchors[project.id] = deleted; projectRow.addArrangedSubview(deleted); projectRow.accessories = [deleted]
            }
            fillWidth(projectRow, in: container)
            if expanded {
                for (index, item) in group.items.enumerated() {
                    let title = item.title.isEmpty ? "新对话" : item.title
                    let conversation = SidebarItemButton(title) { [weak self] in self?.onConversation?(project, item.id) }
                    conversation.identifier = NSUserInterfaceItemIdentifier("conversation:" + project.id.uuidString + ":" + item.id)
                    conversation.selected = project.id == currentID && item.id == group.selectedID
                    conversation.drawsSelection = false; conversation.rowHeight = 32; conversation.contentInset = 12
                    conversation.font = Theme.font(size: 12); conversation.quiet = !conversation.selected
                    conversation.isEnabled = !group.running; conversation.setContentHuggingPriority(.init(1), for: .horizontal)
                    conversation.onSecondaryClick = { [weak self] sender in self?.onConversationActions?(project, item.id, sender) }
                    let more = SidebarItemButton("", symbol: "ellipsis") {}
                    more.rowHeight = 32; more.contextual = true; more.quiet = true
                    more.widthAnchor.constraint(equalToConstant: 28).isActive = true; more.isEnabled = !group.running
                    more.setAccessibilityLabel("对话操作：" + title); more.toolTip = "重命名、导出或删除"
                    more.identifier = NSUserInterfaceItemIdentifier("actions:" + project.id.uuidString + ":" + item.id)
                    more.handler = { [weak self, weak more] in guard let more else { return }; self?.onConversationActions?(project, item.id, more) }
                    actionAnchors[project.id.uuidString + ":" + item.id] = more
                    let historyRow = SidebarNavigationRow([conversation, more]); historyRow.selected = conversation.selected; historyRow.accessories = [more]
                    let indent = SidebarBranchGuide(); indent.last = index == group.items.count - 1
                    indent.widthAnchor.constraint(equalToConstant: 40).isActive = true
                    indent.heightAnchor.constraint(equalToConstant: 32).isActive = true
                    let nested = row([indent, historyRow], spacing: 0); nested.distribution = .fill
                    historyRow.setContentHuggingPriority(.init(1), for: .horizontal)
                    fillWidth(nested, in: container)
                }
                if group.items.isEmpty {
                    let text = label(group.error == nil ? "还没有对话" : "无法读取对话", size: 11, color: group.error == nil ? Theme.muted : Theme.warning)
                    text.toolTip = group.error
                    let indent = NSView(); indent.widthAnchor.constraint(equalToConstant: 52).isActive = true
                    fillWidth(row([indent, text, spacer()], spacing: 0), in: container)
                }
            }
            fillWidth(container, in: projects)
        }
        if groups.isEmpty { fillWidth(label("添加一个项目开始", size: 12, color: Theme.muted), in: projects) }
        if let focusID {
            func descendant(_ view: NSView) -> NSView? {
                if view.identifier == focusID { return view }
                return view.subviews.lazy.compactMap(descendant).first
            }
            if let replacement = descendant(projects) { window?.makeFirstResponder(replacement) }
        }
    }
    /// Compatibility for callers with a single project's loaded history.
    func update(records: [ProjectRecord], currentID: UUID?, items: [(id: String, title: String)], selectedID: String?, running: Bool) {
        update(groups: records.map { SidebarProjectGroup(project: $0, items: $0.id == currentID ? items : [], selectedID: $0.id == currentID ? selectedID : nil, running: $0.id == currentID && running) }, currentID: currentID)
    }
}
