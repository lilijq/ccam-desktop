import AppKit

/// Manual collapse is independent of the temporary narrow-window presentation.
enum WindowSidebarPresentation {
    case expanded, rail, compact
    static let preferenceKey = "workspace.sidebar.collapsed"
    static func resolve(width: CGFloat, collapsed: Bool) -> Self {
        width < 780 ? .compact : (collapsed ? .rail : .expanded)
    }
    var width: CGFloat {
        switch self { case .expanded: return 224; case .rail: return 56; case .compact: return 0 }
    }
}

/// Only the empty, dedicated title strip moves the native window. Editors and
/// interactive browser content never inherit window-background dragging.
final class WindowDragSurface: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "拖动窗口，双击缩放"
        setAccessibilityLabel("窗口拖动区域")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) }
        else { window?.performDrag(with: event) }
    }
}

final class WorkspaceSidebarRail: NSView {
    var onExpand: (() -> Void)?
    var onNewConversation: (() -> Void)?
    var onProjects: ((NSView) -> Void)?
    var onQuota: (() -> Void)?
    var onManage: ((NSView) -> Void)?
    let expandButton = SidebarItemButton("", symbol: "sidebar.left") {}
    let newButton = SidebarItemButton("", symbol: "square.and.pencil") {}
    let projectsButton = SidebarItemButton("", symbol: "folder") {}
    let manageButton = SidebarItemButton("", symbol: "gearshape") {}
    let quotaView = SidebarQuotaView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityLabel("收起的侧边栏")
        expandButton.handler = { [weak self] in self?.onExpand?() }
        newButton.handler = { [weak self] in self?.onNewConversation?() }
        projectsButton.handler = { [weak self] in guard let self else { return }; self.onProjects?(self.projectsButton) }
        manageButton.handler = { [weak self] in guard let self else { return }; self.onManage?(self.manageButton) }
        quotaView.handler = { [weak self] in self?.onQuota?() }
        for (button, name, tip) in [
            (expandButton, "展开侧边栏", "展开侧边栏（⌃ ⌘ S）"),
            (newButton, "新对话", "新对话"),
            (projectsButton, "项目与对话", "项目与对话"),
            (manageButton, "管理与设置", "管理与设置（⌘ ,）")
        ] {
            button.setAccessibilityLabel(name); button.toolTip = tip; button.quiet = true
            button.translatesAutoresizingMaskIntoConstraints = false; addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                button.heightAnchor.constraint(equalToConstant: 36)
            ])
        }
        quotaView.currentButton.ringOnly = true; quotaView.totalButton.ringOnly = true
        quotaView.translatesAutoresizingMaskIntoConstraints = false; addSubview(quotaView)
        NSLayoutConstraint.activate([
            expandButton.topAnchor.constraint(equalTo: topAnchor, constant: 48),
            newButton.topAnchor.constraint(equalTo: expandButton.bottomAnchor, constant: 12),
            projectsButton.topAnchor.constraint(equalTo: newButton.bottomAnchor, constant: 4),
            manageButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            quotaView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            quotaView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            quotaView.bottomAnchor.constraint(equalTo: manageButton.topAnchor, constant: -6)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func updateQuota(_ summary: QuotaSummary, readFailed: Bool = false) { quotaView.update(summary, readFailed: readFailed) }
}
