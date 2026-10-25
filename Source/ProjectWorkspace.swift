import AppKit

private final class WorkspaceSectionButton: NSButton {
    var chosen = false { didSet { state = chosen ? .on : .off; needsDisplay = true } }
    var invoke: (() -> Void)?
    init(_ title: String) {
        super.init(frame: .zero)
        self.title = title; target = self; action = #selector(pressed)
        isBordered = false; focusRingType = .exterior
        font = Theme.font(size: 13, weight: .medium)
        setAccessibilityLabel(title)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 54, height: 34) }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 6, yRadius: 6).fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let foreground = isEnabled && chosen ? Theme.text : Theme.muted
        let text = NSAttributedString(string: title, attributes: [.font: font ?? Theme.font(size: 13), .foregroundColor: foreground.withAlphaComponent(isEnabled ? 1 : 0.5)])
        text.draw(at: NSPoint(x: (bounds.width - text.size().width) / 2, y: (bounds.height - text.size().height) / 2 + 1))
        if chosen {
            Theme.text.setFill()
            NSBezierPath(roundedRect: NSRect(x: (bounds.width - 20) / 2, y: isFlipped ? bounds.height - 3 : 1, width: 20, height: 2), xRadius: 1, yRadius: 1).fill()
        }
    }
    @objc private func pressed() { invoke?() }
}

/// One project owns its drafts and views; the global account pool owns execution.
final class ProjectWorkspace: NSView {
    enum Section: Int { case chat, files, git, terminal }
    private final class Workspace {
        let project: ProjectRecord
        var chatView: ProjectChatView?
        var filesView: ProjectFilesView?
        var gitView: ProjectGitView?
        var chat: ProjectChatView { if chatView == nil { chatView = ProjectChatView(project: project) }; return chatView! }
        var files: ProjectFilesView { if filesView == nil { filesView = ProjectFilesView(directory: project.path) }; return filesView! }
        var git: ProjectGitView { if gitView == nil { gitView = ProjectGitView(directory: project.path) }; return gitView! }
        var section: Section = .chat
        init(_ project: ProjectRecord) { self.project = project }
    }
    private let terminal: TerminalWorkspace
    private let sectionButtons = ["对话", "文件", "Git", "终端"].map(WorkspaceSectionButton.init)
    private let sectionRow = NSStackView()
    /// Hosted by the app's top bar; the workspace itself contains only content.
    var sectionControl: NSView { sectionRow }
    private let body = NSView()
    private let empty = column([label("选择一个项目", size: 24, weight: .semibold), label("从顶部选择项目文件夹。", color: Theme.muted)], spacing: 10)
    private var workspaces: [UUID: Workspace] = [:]
    private var current: Workspace?
    private var mounted: NSView?
    private var mountedConstraints: [NSLayoutConstraint] = []
    var onInteractiveTask: ((ProjectRecord, ChatTerminalTarget) throws -> Void)?
    var beforeChatStart: ((ProjectRecord, [String]) throws -> Void)?
    var onStateChange: (() -> Void)?
    var hasRunning: Bool { workspaces.values.contains { $0.chatView?.hasRunning == true } }
    var hasUnsavedChanges: Bool { workspaces.values.contains { $0.filesView?.hasUnsavedChanges == true } }
    var selectedSection: Section { current?.section ?? .terminal }
    var historyItems: [(id: String, title: String)] { current?.chatView?.historyItems ?? [] }
    var selectedConversationID: String? { current?.chatView?.selectedConversationID }
    func runningCount(for projectID: UUID) -> Int { workspaces[projectID]?.chatView?.hasRunning == true ? 1 : 0 }

    init(terminal: TerminalWorkspace) {
        self.terminal = terminal
        super.init(frame: .zero)
        sectionRow.orientation = .horizontal; sectionRow.alignment = .centerY; sectionRow.spacing = 2
        sectionRow.setAccessibilityLabel("项目工作区")
        for (index, button) in sectionButtons.enumerated() {
            sectionRow.addArrangedSubview(button)
            button.invoke = { [weak self] in
                guard let self else { return }
                self.current?.section = Section(rawValue: index) ?? .chat
                self.displaySection()
            }
        }
        body.translatesAutoresizingMaskIntoConstraints = false; addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor), body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor), body.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func select(project: ProjectRecord?, section: Section? = nil) {
        let changedProject = current?.project.id != project?.id
        if let project {
            let workspace = workspaces[project.id] ?? Workspace(project)
            workspaces[project.id] = workspace; current = workspace
            workspace.chat.onTerminalFallback = { [weak self] target in try self?.onInteractiveTask?(project, target) }
            workspace.chat.onShowTerminal = { [weak self] in
                self?.current?.section = .terminal; self?.displaySection()
            }
            workspace.chat.beforeStart = { [weak self] arguments in try self?.beforeChatStart?(project, arguments) }
            workspace.chat.onStateChange = { [weak self] in self?.onStateChange?() }
            if let section { workspace.section = section }
        } else { current = nil }
        if changedProject {
            terminal.filter(projectID: project?.id.uuidString)
            terminal.setScopeName(project?.name)
        }
        displaySection()
    }
    private func displaySection() {
        let section = selectedSection
        for (index, button) in sectionButtons.enumerated() {
            button.chosen = index == section.rawValue; button.isEnabled = current != nil || index == 3
        }
        let view: NSView
        switch section {
        case .chat: view = current?.chat ?? empty
        case .files: view = current?.files ?? empty
        case .git: view = current?.git ?? empty
        case .terminal: view = terminal
        }
        if mounted !== view {
            NSLayoutConstraint.deactivate(mountedConstraints)
            mounted?.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(view)
            mountedConstraints = [view.topAnchor.constraint(equalTo: body.topAnchor), view.bottomAnchor.constraint(equalTo: body.bottomAnchor), view.leadingAnchor.constraint(equalTo: body.leadingAnchor), view.trailingAnchor.constraint(equalTo: body.trailingAnchor)]
            NSLayoutConstraint.activate(mountedConstraints); mounted = view
            if section == .git { current?.git.refresh() }
        }
        if section == .terminal { terminal.focus() }
        onStateChange?()
    }
    func selectConversation(id: String) {
        guard let current, !current.chat.hasRunning, current.chat.historyItems.contains(where: { $0.id == id }) else { return }
        current.chat.selectConversation(id: id); current.section = .chat; displaySection()
    }
    func newConversation() { current?.section = .chat; displaySection(); current?.chat.newConversation() }
    func focusInput() { if selectedSection == .chat { current?.chat.focusInput() } }
    func stopAll() { workspaces.values.forEach { $0.chatView?.stop() } }
}
