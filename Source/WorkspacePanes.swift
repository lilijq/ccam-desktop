import AppKit

enum WorkspaceSplitAxis: String, Codable {
    case right, down
    var title: String { self == .right ? "左右分屏" : "上下分屏" }
    var symbol: String { self == .right ? "rectangle.split.2x1" : "rectangle.split.1x2" }
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
            return axis == .right ? NSSize(width: first.width + second.width + 7, height: max(first.height, second.height)) : NSSize(width: max(first.width, second.width), height: first.height + second.height + 7)
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
        case .pane(let section): return (0...3).contains(section)
        case .split(_, _, let ratio, let a, let b): return ratio.isFinite && (0.05...0.95).contains(ratio) && a.valid(depth: depth + 1) && b.valid(depth: depth + 1)
        }
    }
    var isValid: Bool { valid(depth: 0) && sections.count <= 4 && Set(sections).count == sections.count }
}

struct WorkspacePaneLayout: Codable, Equatable {
    var root: WorkspacePaneNode = .pane(0)
    var active: Int = 0
    var isValid: Bool { root.isValid && root.sections.contains(active) }
    mutating func select(_ section: Int) {
        guard (0...3).contains(section) else { return }
        if !root.sections.contains(section) { root = root.replacing(active, with: .pane(section)) }
        active = section
    }
    @discardableResult mutating func split(adding section: Int, axis: WorkspaceSplitAxis) -> Bool {
        guard (0...3).contains(section), !root.sections.contains(section), root.sections.count < 4 else { return false }
        root = root.replacing(active, with: .split(id: UUID(), axis: axis, ratio: 0.5, first: .pane(active), second: .pane(section)))
        active = section; return true
    }
    @discardableResult mutating func close(_ section: Int) -> Bool {
        guard root.sections.count > 1, root.sections.contains(section), let next = root.removing(section) else { return false }
        root = next
        if active == section { active = next.sections.first ?? 0 }
        return true
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
    override var dividerThickness: CGFloat { 7 }
    init(id: UUID, axis: WorkspaceSplitAxis, ratio: Double, first: NSView, second: NSView, firstMinimum: NSSize, secondMinimum: NSSize) {
        splitID = id; self.ratio = ratio; self.firstMinimum = firstMinimum; self.secondMinimum = secondMinimum
        super.init(frame: .zero)
        isVertical = axis == .right; dividerStyle = .thin; delegate = self
        addSubview(first); addSubview(second)
        setAccessibilityLabel(axis.title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func drawDivider(in rect: NSRect) {
        Theme.background.setFill(); rect.fill()
        Theme.border.setFill()
        let line = isVertical ? NSRect(x: rect.midX - 0.5, y: rect.minY, width: 1, height: rect.height) : NSRect(x: rect.minX, y: rect.midY - 0.5, width: rect.width, height: 1)
        line.fill()
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

final class WorkspacePaneView: NSView {
    let section: Int
    private let header = ThemeSurface(Theme.panel)
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let titleRule = ThemeSurface(Theme.border)
    var onSelect: ((Int) -> Void)?
    var onSplit: ((WorkspaceSplitAxis, NSView) -> Void)?
    var onMaximize: (() -> Void)?
    var onClose: (() -> Void)?
    var active = false { didSet {
        titleRule.surfaceColor = active ? Theme.muted : Theme.border
        picker.contentTintColor = active ? Theme.text : Theme.muted
        picker.selectItem(at: section)
    } }
    init(section: Int, title: String, content: NSView, headers: Bool, maximized: Bool) {
        self.section = section
        super.init(frame: .zero)
        setAccessibilityLabel(title + "窗格")
        content.translatesAutoresizingMaskIntoConstraints = false; addSubview(content)
        let contentTop: NSLayoutYAxisAnchor
        if headers {
            header.translatesAutoresizingMaskIntoConstraints = false; addSubview(header)
            picker.addItems(withTitles: ["对话", "文件", "Git", "终端"]); picker.selectItem(at: section)
            picker.font = Theme.font(size: 12, weight: .medium); picker.isBordered = false; picker.bezelStyle = .regularSquare
            picker.target = self; picker.action = #selector(picked); picker.setAccessibilityLabel("窗格内容：" + title)
            picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let right = WorkspacePaneButton(symbol: WorkspaceSplitAxis.right.symbol, title: "在右侧分屏：" + title)
            let down = WorkspacePaneButton(symbol: WorkspaceSplitAxis.down.symbol, title: "在下方分屏：" + title)
            let maximize = WorkspacePaneButton(symbol: maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", title: maximized ? "恢复分屏" : "放大窗格：" + title)
            let close = WorkspacePaneButton(symbol: "xmark", title: "关闭窗格：" + title)
            right.invoke = { [weak self, weak right] in guard let right else { return }; self?.onSplit?(.right, right) }
            down.invoke = { [weak self, weak down] in guard let down else { return }; self?.onSplit?(.down, down) }
            maximize.invoke = { [weak self] in self?.onMaximize?() }; close.invoke = { [weak self] in self?.onClose?() }
            let controls = row([picker, spacer(), right, down, maximize, close], spacing: 2)
            controls.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(controls)
            titleRule.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(titleRule)
            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor), header.heightAnchor.constraint(equalToConstant: 32),
                controls.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 6), controls.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -3), controls.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                picker.widthAnchor.constraint(greaterThanOrEqualToConstant: 58),
                titleRule.bottomAnchor.constraint(equalTo: header.bottomAnchor), titleRule.leadingAnchor.constraint(equalTo: header.leadingAnchor), titleRule.trailingAnchor.constraint(equalTo: header.trailingAnchor), titleRule.heightAnchor.constraint(equalToConstant: 1)
            ])
            contentTop = header.bottomAnchor
        } else { contentTop = topAnchor }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentTop, constant: headers ? 6 : 0), content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func picked() { onSelect?(picker.indexOfSelectedItem) }
}
