import AppKit


enum WorkspaceSplitAxis: String, Codable {
    case right, down
    var title: String { self == .right ? "左右分屏" : "上下分屏" }
    var symbol: String { self == .right ? "rectangle.split.2x1" : "rectangle.split.1x2" }
}

/// Center swaps existing slots; edges insert the moving pane beside its target.
enum WorkspacePaneDropPosition: String, CaseIterable {
    case left, right, top, bottom, center
    var title: String {
        switch self { case .left: return "左侧"; case .right: return "右侧"; case .top: return "上方"; case .bottom: return "下方"; case .center: return "交换位置" }
    }
    static func at(_ point: NSPoint, in bounds: NSRect) -> Self? {
        guard bounds.width > 0, bounds.height > 0, bounds.contains(point) else { return nil }
        let x = (point.x - bounds.minX) / bounds.width, y = (point.y - bounds.minY) / bounds.height
        let distances: [(Self, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, 1 - y), (.bottom, y)]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < 0.26 else { return .center }
        return nearest.0
    }
    func preview(in bounds: NSRect) -> NSRect {
        var rect = bounds.insetBy(dx: 6, dy: 6)
        switch self {
        case .left: rect.size.width /= 2
        case .right: rect.size.width /= 2; rect.origin.x += rect.width
        case .top: rect.size.height /= 2; rect.origin.y += rect.height
        case .bottom: rect.size.height /= 2
        case .center: break
        }
        return rect
    }
}

/// A section is mounted once. Layout changes never own, clone or stop its task.
indirect enum WorkspacePaneNode: Codable, Equatable {
    case pane(Int)
    case split(id: UUID, axis: WorkspaceSplitAxis, ratio: Double, first: WorkspacePaneNode, second: WorkspacePaneNode)

    var sections: [Int] {
        switch self { case .pane(let section): return [section]; case .split(_, _, _, let a, let b): return a.sections + b.sections }
    }
    var structureID: String {
        switch self {
        case .pane(let section): return String(section)
        case .split(let id, let axis, _, let a, let b): return id.uuidString + axis.rawValue + "(" + a.structureID + "," + b.structureID + ")"
        }
    }
    var minimumSize: NSSize {
        switch self {
        case .pane: return NSSize(width: 340, height: 280)
        case .split(_, let axis, _, let a, let b):
            let first = a.minimumSize, second = b.minimumSize
            return axis == .right ? NSSize(width: first.width + second.width + 8, height: max(first.height, second.height)) : NSSize(width: max(first.width, second.width), height: first.height + second.height + 8)
        }
    }
    func replacing(_ section: Int, with replacement: WorkspacePaneNode) -> WorkspacePaneNode {
        switch self {
        case .pane(let value): return value == section ? replacement : self
        case .split(let id, let axis, let ratio, let a, let b):
            return .split(id: id, axis: axis, ratio: ratio, first: a.replacing(section, with: replacement), second: b.replacing(section, with: replacement))
        }
    }
    func removing(_ section: Int) -> WorkspacePaneNode? {
        switch self {
        case .pane(let value): return value == section ? nil : self
        case .split(let id, let axis, let ratio, let a, let b):
            let first = a.removing(section), second = b.removing(section)
            if let first, let second { return .split(id: id, axis: axis, ratio: ratio, first: first, second: second) }
            return first ?? second
        }
    }
    func swapping(_ first: Int, _ second: Int) -> WorkspacePaneNode {
        switch self {
        case .pane(let section): return .pane(section == first ? second : section == second ? first : section)
        case .split(let id, let axis, let ratio, let a, let b):
            return .split(id: id, axis: axis, ratio: ratio, first: a.swapping(first, second), second: b.swapping(first, second))
        }
    }
    func settingRatio(_ value: Double, for target: UUID) -> WorkspacePaneNode {
        switch self {
        case .pane: return self
        case .split(let id, let axis, let ratio, let a, let b):
            return .split(id: id, axis: axis, ratio: id == target ? max(0.05, min(0.95, value)) : ratio, first: a.settingRatio(value, for: target), second: b.settingRatio(value, for: target))
        }
    }
    private func valid(depth: Int) -> Bool {
        guard depth <= 3 else { return false }
        switch self {
        case .pane(let section): return (0...4095).contains(section)
        case .split(_, _, let ratio, let a, let b): return ratio.isFinite && (0.05...0.95).contains(ratio) && a.valid(depth: depth + 1) && b.valid(depth: depth + 1)
        }
    }
    var isValid: Bool { valid(depth: 0) && sections.count <= 4 && Set(sections).count == sections.count }
}

struct WorkspacePaneLayout: Codable, Equatable {
    var root: WorkspacePaneNode = .pane(0)
    var active: Int = 0
    /// 0 is the legacy chat slot; 1...4 stay singleton tools. Further slots are
    /// conversation identities, never extra copies of the tool runtimes.
    var conversationIDs: [Int: String] = [:]
    init(root: WorkspacePaneNode = .pane(0), active: Int = 0, conversationIDs: [Int: String] = [:]) {
        self.root = root; self.active = active; self.conversationIDs = conversationIDs
    }
    private enum CodingKeys: String, CodingKey { case root, active, conversationIDs }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decode(WorkspacePaneNode.self, forKey: .root)
        active = try container.decode(Int.self, forKey: .active)
        conversationIDs = try container.decodeIfPresent([Int: String].self, forKey: .conversationIDs) ?? [:]
    }
    static func isChat(_ pane: Int) -> Bool { pane == 0 || pane >= 5 }
    var isValid: Bool {
        root.isValid && root.sections.contains(active) && conversationIDs.count <= 64
            && conversationIDs.allSatisfy { (0...4095).contains($0.key) && Self.isChat($0.key) && !$0.value.isEmpty && $0.value.count <= 256 }
            && root.sections.filter { $0 >= 5 }.allSatisfy { conversationIDs[$0] != nil }
            && Set(root.sections.compactMap { conversationIDs[$0] }).count == root.sections.compactMap { conversationIDs[$0] }.count
    }
    func pane(for conversationID: String) -> Int? {
        root.sections.first { conversationIDs[$0] == conversationID }
            ?? conversationIDs.first(where: { $0.value == conversationID })?.key
    }
    mutating func bind(_ conversationID: String, to pane: Int) {
        guard Self.isChat(pane), !conversationID.isEmpty else { return }
        for (key, value) in conversationIDs where value == conversationID && key != pane && !root.sections.contains(key) { conversationIDs.removeValue(forKey: key) }
        conversationIDs[pane] = conversationID
    }
    mutating func trimBindings() { conversationIDs = conversationIDs.filter { $0.key == 0 || root.sections.contains($0.key) } }
    func availableChatSlot() -> Int { !root.sections.contains(0) ? 0 : (5...4095).first { !root.sections.contains($0) } ?? 5 }
    mutating func select(_ section: Int) {
        guard (0...4).contains(section) || conversationIDs[section] != nil else { return }
        if !root.sections.contains(section) { root = root.replacing(active, with: .pane(section)) }
        active = section
    }
    @discardableResult mutating func split(adding section: Int, axis: WorkspaceSplitAxis) -> Bool {
        guard ((0...4).contains(section) || conversationIDs[section] != nil), !root.sections.contains(section), root.sections.count < 4 else { return false }
        root = root.replacing(active, with: .split(id: UUID(), axis: axis, ratio: 0.5, first: .pane(active), second: .pane(section)))
        active = section; return true
    }
    @discardableResult mutating func close(_ section: Int) -> Bool {
        guard root.sections.count > 1, root.sections.contains(section), let next = root.removing(section) else { return false }
        root = next
        if active == section { active = next.sections.first ?? 0 }
        return true
    }
    /// Validate the complete result before committing, so rejected drags are no-ops.
    @discardableResult mutating func move(_ section: Int, relativeTo target: Int, position: WorkspacePaneDropPosition) -> Bool {
        guard isValid, section != target, root.sections.contains(section), root.sections.contains(target) else { return false }
        let next: WorkspacePaneNode
        if position == .center { next = root.swapping(section, target) }
        else {
            guard let remaining = root.removing(section) else { return false }
            let axis: WorkspaceSplitAxis = position == .left || position == .right ? .right : .down
            let sourceFirst = position == .left || position == .top
            let pair = WorkspacePaneNode.split(id: UUID(), axis: axis, ratio: 0.5,
                first: .pane(sourceFirst ? section : target), second: .pane(sourceFirst ? target : section))
            next = remaining.replacing(target, with: pair)
        }
        let candidate = Self(root: next, active: section, conversationIDs: conversationIDs)
        guard candidate.isValid else { return false }
        self = candidate; return true
    }
    static func load(projectID: UUID) -> WorkspacePaneLayout {
        guard let data = UserDefaults.standard.data(forKey: key(projectID)), data.count < 16_384,
              let layout = try? JSONDecoder().decode(Self.self, from: data), layout.isValid else { return Self() }
        return layout
    }
    func save(projectID: UUID) {
        guard isValid, let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(projectID))
    }
    static func key(_ projectID: UUID) -> String { "workspace.panes." + projectID.uuidString }
}

final class WorkspacePaneButton: NSButton {
    var invoke: (() -> Void)?
    init(symbol: String, title: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        imagePosition = .imageOnly; isBordered = false; bezelStyle = .regularSquare
        target = self; action = #selector(pressed); focusRingType = .exterior
        contentTintColor = Theme.muted; toolTip = title; setAccessibilityLabel(title)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 28), heightAnchor.constraint(equalToConstant: 28)])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func pressed() { invoke?() }
}

final class WorkspaceMenuItem: NSMenuItem {
    private let invoke: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        invoke = action; super.init(title: title, action: #selector(pressed), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func pressed() { invoke() }
}

/// Native divider dragging, with ratios retained while the window changes size.
final class WorkspaceDividerView: NSSplitView, NSSplitViewDelegate {
    let splitID: UUID
    private let firstMinimum: NSSize
    private let secondMinimum: NSSize
    private var ratio: Double
    private var applying = false
    var onRatioChange: ((UUID, Double) -> Void)?
    override var isFlipped: Bool { true }
    override var dividerThickness: CGFloat { 8 }
    init(id: UUID, axis: WorkspaceSplitAxis, ratio: Double, first: NSView, second: NSView, firstMinimum: NSSize, secondMinimum: NSSize) {
        splitID = id; self.ratio = ratio; self.firstMinimum = firstMinimum; self.secondMinimum = secondMinimum
        super.init(frame: .zero)
        isVertical = axis == .right; dividerStyle = .thin; delegate = self
        addSubview(first); addSubview(second)
        setAccessibilityLabel(axis.title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func drawDivider(in rect: NSRect) {
        Theme.workspaceCanvas.setFill(); rect.fill()
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard subviews.count == 2 else { return }
        applying = true
        let length = isVertical ? bounds.width : bounds.height
        let gap = min(dividerThickness, max(0, length))
        let available = max(0, length - gap)
        let minimum = isVertical ? firstMinimum.width : firstMinimum.height
        let maximum = available - (isVertical ? secondMinimum.width : secondMinimum.height)
        let position = maximum >= minimum ? max(minimum, min(maximum, available * ratio)) : available * ratio
        if isVertical {
            subviews[0].frame = NSRect(x: 0, y: 0, width: position, height: bounds.height)
            subviews[1].frame = NSRect(x: position + gap, y: 0, width: max(0, available - position), height: bounds.height)
        } else {
            subviews[0].frame = NSRect(x: 0, y: 0, width: bounds.width, height: position)
            subviews[1].frame = NSRect(x: 0, y: position + gap, width: bounds.width, height: max(0, available - position))
        }
        applying = false
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        isVertical ? firstMinimum.width : firstMinimum.height
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        (isVertical ? bounds.width - secondMinimum.width : bounds.height - secondMinimum.height) - dividerThickness
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !applying, subviews.count == 2 else { return }
        let available = (isVertical ? bounds.width : bounds.height) - dividerThickness
        guard available > 0 else { return }
        ratio = Double((isVertical ? subviews[0].frame.width : subviews[0].frame.height) / available)
        onRatioChange?(splitID, ratio)
    }
}

/// Window-local dragging deliberately uses event coordinates. No file pasteboard
/// or system drag session is involved; a pane only moves inside its workspace.
final class WorkspacePaneHeader: ThemeSurface {
    let section: Int
    let title: String
    var context: UUID?
    var onDragChanged: ((WorkspacePaneHeader, NSPoint) -> Void)?
    var onDragEnded: ((WorkspacePaneHeader, NSPoint) -> Void)?
    var onDragCancelled: (() -> Void)?
    private var dragMonitor: Any?
    private var startLocation: NSPoint?
    private var startWindowFrame: NSRect?
    private var didDrag = false
    init(section: Int, title: String) {
        self.section = section; self.title = title
        super.init(Theme.workspacePanel)
        toolTip = "拖动排列窗格；边缘分屏，中间交换"
        setAccessibilityLabel("拖动窗格：" + title)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let dragMonitor { NSEvent.removeMonitor(dragMonitor) } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // Controls keep normal click/keyboard behavior; blank header space drags.
        var candidate = hit
        while let view = candidate, view !== self {
            if view is NSButton { return hit }
            candidate = view.superview
        }
        return hit == nil ? nil : self
    }
    override func resetCursorRects() { super.resetCursorRects(); addCursorRect(bounds, cursor: .openHand) }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { cancelDrag() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func mouseDown(with event: NSEvent) {
        cancelDrag()
        guard window != nil, context != nil else { return }
        startLocation = event.locationInWindow; startWindowFrame = window?.frame
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            guard let self, let start = self.startLocation else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.cancelDrag(); return nil }
                return event
            }
            guard event.window === self.window, self.window?.frame == self.startWindowFrame else { self.cancelDrag(); return event }
            let point = event.locationInWindow
            if event.type == .leftMouseDragged {
                if !self.didDrag, hypot(point.x - start.x, point.y - start.y) < 4 { return nil }
                self.didDrag = true; self.onDragChanged?(self, point); return nil
            }
            let moved = self.didDrag
            self.endTracking()
            if moved { self.onDragEnded?(self, point) }
            else { self.onDragCancelled?() }
            return nil
        }
    }
    // The monitor retains the press target even when the pointer crosses a
    // browser, text editor or another panel, without giving those views a drop.
    override func mouseDragged(with event: NSEvent) { }
    override func mouseUp(with event: NSEvent) { cancelDrag() }
    func cancelDrag() {
        let wasTracking = startLocation != nil
        endTracking()
        if wasTracking { onDragCancelled?() }
    }
    private func endTracking() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor); self.dragMonitor = nil }
        startLocation = nil; startWindowFrame = nil; didDrag = false
    }
}

/// Draw the six-dot handle directly so it stays legible on every supported
/// macOS version, without relying on an optional SF Symbols catalog entry.
final class WorkspacePaneDragHandle: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("paneDragHandle")
        toolTip = "拖动窗格；边缘分屏，中间交换"
        setAccessibilityLabel("窗格拖动柄")
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.muted.withAlphaComponent(0.7).setFill()
        for x in [-2.5, 2.5] {
            for y in [-5.0, 0.0, 5.0] {
                NSBezierPath(ovalIn: NSRect(x: bounds.midX + x - 1.25, y: bounds.midY + y - 1.25, width: 2.5, height: 2.5)).fill()
            }
        }
    }
}

private final class WorkspaceDropPreview: NSView {
    var position: WorkspacePaneDropPosition? { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let position else { return }
        let rect = position.preview(in: bounds)
        Theme.text.withAlphaComponent(0.10).setFill(); NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        Theme.text.withAlphaComponent(0.65).setStroke(); let border = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8); border.lineWidth = 1.5; border.stroke()
        let text = NSAttributedString(string: position == .center ? "交换位置" : "移到" + position.title,
            attributes: [.font: Theme.font(size: 12, weight: .medium), .foregroundColor: Theme.text])
        let size = text.size(), center = NSRect(x: rect.midX - size.width / 2 - 10, y: rect.midY - size.height / 2 - 6, width: size.width + 20, height: size.height + 12)
        Theme.panel.setFill(); NSBezierPath(roundedRect: center, xRadius: 6, yRadius: 6).fill()
        text.draw(at: NSPoint(x: center.minX + 10, y: center.minY + 6))
    }
}

final class WorkspacePaneView: ThemeSurface {
    /// A stable layout slot, not a content type; several slots may show chat.
    let section: Int
    let header: WorkspacePaneHeader
    private let titleLabel = label("", size: 13, weight: .semibold)
    private let more = WorkspacePaneButton(symbol: "ellipsis", title: "窗格操作")
    private let preview = WorkspaceDropPreview()
    var dragContext: UUID? { didSet { header.context = dragContext } }
    var onMenu: ((NSView) -> Void)?
    var active = false { didSet {
        strokeColor = active ? Theme.muted.withAlphaComponent(0.45) : Theme.workspaceBorder
        titleLabel.textColor = active ? Theme.text : Theme.muted
    } }
    init(section: Int, title: String, content: NSView, headers: Bool, maximized: Bool, multiple: Bool = true) {
        self.section = section; header = WorkspacePaneHeader(section: section, title: title)
        super.init(Theme.background, border: Theme.workspaceBorder, radius: 12)
        layer?.masksToBounds = true
        setAccessibilityLabel(title + "窗格")
        content.translatesAutoresizingMaskIntoConstraints = false; addSubview(content)
        let contentTop: NSLayoutYAxisAnchor
        if headers {
            header.translatesAutoresizingMaskIntoConstraints = false; addSubview(header)
            titleLabel.stringValue = title; titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.maximumNumberOfLines = 1; titleLabel.toolTip = title
            titleLabel.setAccessibilityLabel("窗格标题")
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let grip = WorkspacePaneDragHandle(frame: .zero)
            grip.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([grip.widthAnchor.constraint(equalToConstant: 32), grip.heightAnchor.constraint(equalToConstant: 32)])
            more.setAccessibilityLabel("窗格操作：" + title); more.toolTip = "窗格操作"
            more.invoke = { [weak self, weak more] in guard let more else { return }; self?.onMenu?(more) }
            let controls = row([grip, titleLabel, spacer(), more], spacing: 4)
            controls.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(controls)
            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: topAnchor, constant: 1), header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1), header.heightAnchor.constraint(equalToConstant: 42),
                controls.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 4), controls.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -7), controls.centerYAnchor.constraint(equalTo: header.centerYAnchor)
            ])
            contentTop = header.bottomAnchor
        } else { contentTop = topAnchor }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentTop, constant: headers ? 1 : 0), content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1), content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1), content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1)
        ])
        preview.frame = bounds; preview.autoresizingMask = [.width, .height]; addSubview(preview)
    }
    required init?(coder: NSCoder) { fatalError() }
    func updateTitle(_ title: String) {
        titleLabel.stringValue = title; titleLabel.toolTip = title
        setAccessibilityLabel(title + "窗格"); more.setAccessibilityLabel("窗格操作：" + title)
    }
    func clearDropPreview() { preview.position = nil }
    func showDropPreview(_ position: WorkspacePaneDropPosition) { preview.position = position }
    func acceptsDrag(source: WorkspacePaneHeader) -> Bool {
        guard let dragContext, source.context == dragContext, source.section != section,
              source.window === window, source.window != nil else { return false }
        return true
    }
}
