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
    enum Section: Int, CaseIterable {
        case chat, files, git, terminal
        var title: String { ["对话", "文件", "Git", "终端"][rawValue] }
        var symbol: String { ["bubble.left", "doc.text", "arrow.triangle.branch", "terminal"][rawValue] }
    }
    private final class Workspace {
        let project: ProjectRecord
        var chatView: ProjectChatView?
        var filesView: ProjectFilesView?
        var gitView: ProjectGitView?
        var chat: ProjectChatView { if chatView == nil { chatView = ProjectChatView(project: project) }; return chatView! }
        var files: ProjectFilesView { if filesView == nil { filesView = ProjectFilesView(directory: project.path) }; return filesView! }
        var git: ProjectGitView { if gitView == nil { gitView = ProjectGitView(directory: project.path) }; return gitView! }
        var layout: WorkspacePaneLayout
        var maximized = false
        var section: Section {
            get { Section(rawValue: layout.active) ?? .chat }
            set { layout.select(newValue.rawValue) }
        }
        init(_ project: ProjectRecord) { self.project = project; layout = .load(projectID: project.id) }
    }
    private let terminal: TerminalWorkspace
    private let sectionButtons = ["对话", "文件", "Git", "终端"].map(WorkspaceSectionButton.init)
    private let sectionRow = NSStackView()
    private let splitButton = WorkspacePaneButton(symbol: "rectangle.split.2x1", title: "分屏布局")
    /// Hosted by the app's top bar; the workspace itself contains only content.
    var sectionControl: NSView { sectionRow }
    private let body = NSView()
    private let empty = column([label("选择一个项目", size: 24, weight: .semibold), label("从顶部选择项目文件夹。", color: Theme.muted)], spacing: 10)
    private var workspaces: [UUID: Workspace] = [:]
    private struct CachedHistory {
        let stamp: String
        let items: [(id: String, title: String)]
        let selectedID: String?
        let error: String?
    }
    private var historyCache: [UUID: CachedHistory] = [:]
    private var current: Workspace?
    private var mounted: NSView?
    private var renderID = ""
    private var panes: [WorkspacePaneView] = []
    private var clickMonitor: Any?
    private var rendering = false
    private var compact = false
    var visibleSections: [Section] { current?.layout.root.sections.compactMap(Section.init(rawValue:)) ?? [.terminal] }
    var displayedSections: [Section] { panes.compactMap { Section(rawValue: $0.section) } }
    var isSinglePanePresentation: Bool { compact || current?.maximized == true }
    var onInteractiveTask: ((ProjectRecord, ChatTerminalTarget) throws -> Void)?
    var onReturnFromTerminal: ((ProjectRecord, ChatTerminalTarget, @escaping (Result<ChatTerminalTarget, Error>) -> Void) -> Void)?
    var beforeChatStart: ((ProjectRecord, [String]) throws -> Void)?
    var onStateChange: (() -> Void)?
    var hasRunning: Bool { workspaces.values.contains { $0.chatView?.hasRunning == true } }
    var hasUnsavedChanges: Bool { workspaces.values.contains { $0.filesView?.hasUnsavedChanges == true } }
    var selectedSection: Section { current?.section ?? .terminal }
    var historyItems: [(id: String, title: String)] { current?.chatView?.historyItems ?? [] }
    var selectedConversationID: String? { current?.chatView?.selectedConversationID }
    var selectedAccountName: String? { current?.chatView?.selectedAccountName }
    func runningCount(for projectID: UUID) -> Int { workspaces[projectID]?.chatView?.hasRunning == true ? 1 : 0 }

    /// Only expanded, unmounted projects read their local history. Streaming
    /// updates use the existing view's in-memory metadata, never re-read JSON.
    func sidebarGroups(records: [ProjectRecord], expandedIDs: Set<UUID>) -> [SidebarProjectGroup] {
        historyCache = historyCache.filter { id, _ in records.contains { $0.id == id } }
        return records.map { project in
            if let chat = workspaces[project.id]?.chatView {
                return SidebarProjectGroup(project: project, items: expandedIDs.contains(project.id) ? chat.historyItems : [],
                                           selectedID: chat.selectedConversationID, running: chat.hasRunning)
            }
            guard expandedIDs.contains(project.id) else { return SidebarProjectGroup(project: project) }
            let url = ProjectStore.defaultURL.deletingLastPathComponent().appendingPathComponent("chats").appendingPathComponent(project.id.uuidString + ".json")
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate
            let stamp = url.path + project.path + String(describing: modified) + String(describing: attributes?[.size])
            if historyCache[project.id]?.stamp != stamp {
                do {
                    let store = try ChatStore(project: project)
                    let items = store.conversations.filter { $0.deletedAt == nil }.map { (id: $0.id, title: $0.title) }
                    historyCache[project.id] = CachedHistory(stamp: stamp, items: items, selectedID: store.selectedID, error: nil)
                } catch {
                    historyCache[project.id] = CachedHistory(stamp: stamp, items: [], selectedID: nil, error: error.localizedDescription)
                }
            }
            let cached = historyCache[project.id]!
            return SidebarProjectGroup(project: project, items: cached.items, selectedID: cached.selectedID, error: cached.error)
        }
    }

    init(terminal: TerminalWorkspace) {
        self.terminal = terminal
        super.init(frame: .zero)
        sectionRow.orientation = .horizontal; sectionRow.alignment = .centerY; sectionRow.spacing = 2
        sectionRow.setAccessibilityLabel("项目工作区")
        for (index, button) in sectionButtons.enumerated() {
            sectionRow.addArrangedSubview(button)
            button.invoke = { [weak self] in
                guard let self else { return }
                self.showSection(Section(rawValue: index) ?? .chat)
            }
        }
        sectionRow.addArrangedSubview(splitButton)
        splitButton.invoke = { [weak self] in self?.showLayoutMenu() }
        body.translatesAutoresizingMaskIntoConstraints = false; addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor), body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor), body.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.window, !self.isHiddenOrHasHiddenAncestor else { return event }
            for pane in self.panes where pane.bounds.contains(pane.convert(event.locationInWindow, from: nil)) {
                self.activatePane(pane.section); break
            }
            return event
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let clickMonitor { NSEvent.removeMonitor(clickMonitor) } }
    override func layout() {
        super.layout()
        guard !rendering, let current else { return }
        let minimum = current.layout.root.minimumSize
        let shouldCompact = body.bounds.width > 0 && body.bounds.height > 0 && (body.bounds.width < minimum.width || body.bounds.height < minimum.height)
        if shouldCompact != compact { displaySection() }
        mounted?.frame = body.bounds
    }
    func select(project: ProjectRecord?, section: Section? = nil) {
        let changedProject = current?.project.id != project?.id
        if let project {
            let workspace = workspaces[project.id] ?? Workspace(project)
            workspaces[project.id] = workspace; current = workspace
            workspace.chat.onTerminalFallback = { [weak self] target in try self?.onInteractiveTask?(project, target) }
            workspace.chat.onReturnFromTerminal = { [weak self] target, completion in
                guard let handler = self?.onReturnFromTerminal else { completion(.failure(AppError.message("终端状态不可用，请重新打开应用。"))); return }
                handler(project, target, completion)
            }
            workspace.chat.onShowTerminal = { [weak self] in
                self?.showSection(.terminal)
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
        guard !rendering else { return }
        rendering = true; defer { rendering = false }
        let section = selectedSection
        for (index, button) in sectionButtons.enumerated() {
            button.chosen = index == section.rawValue; button.isEnabled = current != nil || index == 3
        }
        splitButton.isEnabled = current != nil
        let minimum = current?.layout.root.minimumSize ?? .zero
        compact = body.bounds.width > 0 && body.bounds.height > 0 && (body.bounds.width < minimum.width || body.bounds.height < minimum.height)
        let singlePresentation = compact || current?.maximized == true
        let root = current.map { singlePresentation ? WorkspacePaneNode.pane($0.layout.active) : $0.layout.root } ?? .pane(Section.terminal.rawValue)
        let key = (current?.project.id.uuidString ?? "terminal") + root.structureID
            + (singlePresentation ? "single" : "multi") + (current?.maximized == true ? "max" : "")
            + String(current?.layout.root.sections.count ?? 1)
        if renderID != key {
            let previousResponder = window?.firstResponder as? NSView
            let fieldEditor = previousResponder as? NSTextView
            let previousField = fieldEditor?.isFieldEditor == true ? fieldEditor?.delegate as? NSTextField : nil
            let fieldSelection = previousField == nil ? nil : fieldEditor?.selectedRange()
            let refreshGit = root.sections.contains(Section.git.rawValue) && (!renderID.hasPrefix(current?.project.id.uuidString ?? "terminal") || !panes.contains { $0.section == Section.git.rawValue })
            mounted?.removeFromSuperview()
            mounted = nil; panes = []; renderID = key
            let view = makeLayout(root, headers: (current?.layout.root.sections.count ?? 1) > 1)
            view.frame = body.bounds; view.autoresizingMask = [.width, .height]
            view.translatesAutoresizingMaskIntoConstraints = true
            body.addSubview(view); mounted = view
            view.layoutSubtreeIfNeeded()
            // Resizing or rearranging panes must not interrupt typing. Restore
            // only a responder that remains mounted; hidden panes never steal it.
            if let previousField, previousField.window === window,
               previousField.isDescendant(of: self), !previousField.isHiddenOrHasHiddenAncestor {
                window?.makeFirstResponder(previousField)
                if let editor = previousField.currentEditor() as? NSTextView, let fieldSelection {
                    let length = (editor.string as NSString).length
                    let start = min(fieldSelection.location, length)
                    editor.setSelectedRange(NSRange(location: start, length: min(fieldSelection.length, length - start)))
                }
            } else if let previousResponder, previousResponder.window === window,
               previousResponder.isDescendant(of: self), !previousResponder.isHiddenOrHasHiddenAncestor {
                window?.makeFirstResponder(previousResponder)
            }
            if refreshGit { current?.git.refresh() }
        }
        updatePaneSelection()
        if let current { current.layout.save(projectID: current.project.id) }
        onStateChange?()
    }
    private func content(for section: Section) -> NSView {
        switch section {
        case .chat: return current?.chat ?? empty
        case .files: return current?.files ?? empty
        case .git: return current?.git ?? empty
        case .terminal: return terminal
        }
    }
    private func makeLayout(_ node: WorkspacePaneNode, headers: Bool) -> NSView {
        switch node {
        case .pane(let value):
            let section = Section(rawValue: value) ?? .chat
            let pane = WorkspacePaneView(section: value, title: section.title, content: content(for: section), headers: headers, maximized: current?.maximized == true)
            pane.onSelect = { [weak self, weak pane] value in
                guard let self, let pane, let section = Section(rawValue: value) else { return }
                self.activatePane(pane.section); self.showSection(section)
            }
            pane.onSplit = { [weak self, weak pane] axis, anchor in
                guard let self, let pane else { return }
                self.activatePane(pane.section); self.showSplitMenu(axis: axis, from: anchor)
            }
            pane.onMaximize = { [weak self] in self?.togglePaneMaximization(section) }
            pane.onClose = { [weak self] in self?.closePane(section) }
            panes.append(pane); return pane
        case .split(let id, let axis, let ratio, let a, let b):
            let split = WorkspaceDividerView(id: id, axis: axis, ratio: ratio, first: makeLayout(a, headers: headers), second: makeLayout(b, headers: headers), firstMinimum: a.minimumSize, secondMinimum: b.minimumSize)
            split.onRatioChange = { [weak self] id, ratio in
                guard let current = self?.current else { return }
                current.layout.root = current.layout.root.settingRatio(ratio, for: id)
                current.layout.save(projectID: current.project.id)
            }
            return split
        }
    }
    private func updatePaneSelection() {
        for pane in panes { pane.active = pane.section == selectedSection.rawValue }
        for (index, button) in sectionButtons.enumerated() { button.chosen = index == selectedSection.rawValue }
    }
    private func activatePane(_ section: Int) {
        guard let current, current.layout.root.sections.contains(section), current.layout.active != section else { return }
        current.layout.active = section; current.layout.save(projectID: current.project.id)
        updatePaneSelection(); onStateChange?()
    }
    func showSection(_ section: Section) {
        current?.section = section; displaySection()
        focusSelectedPane()
    }
    private func focusSelectedPane() {
        let selected = content(for: selectedSection)
        switch selectedSection {
        case .chat: current?.chat.focusInput()
        case .files: current?.files.focus()
        case .git: current?.git.focus()
        case .terminal: terminal.focus()
        }
        // Empty panes have no editor. Do not leave keyboard input directed at
        // a different, still-visible pane after an explicit navigation action.
        if let responder = window?.firstResponder as? NSView,
           responder !== selected, !responder.isDescendant(of: selected) {
            window?.makeFirstResponder(nil)
        }
    }
    @discardableResult func splitActive(adding section: Section, axis: WorkspaceSplitAxis) -> Bool {
        guard let current, current.layout.split(adding: section.rawValue, axis: axis) else { return false }
        current.maximized = false; displaySection(); focusSelectedPane(); return true
    }
    func closePane(_ section: Section) {
        guard let current, current.layout.close(section.rawValue) else { return }
        current.maximized = false; displaySection(); focusSelectedPane()
    }
    func togglePaneMaximization(_ section: Section) {
        guard let current, current.layout.root.sections.count > 1 else { return }
        current.section = section; current.maximized.toggle(); displaySection(); focusSelectedPane()
    }
    func resetLayout() {
        guard let current else { return }
        current.layout.root = .pane(current.layout.active); current.maximized = false; displaySection(); focusSelectedPane()
    }
    private func availableSections() -> [Section] {
        Section.allCases.filter { !(current?.layout.root.sections.contains($0.rawValue) ?? false) }
    }
    private func menuItem(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> NSMenuItem {
        let item = WorkspaceMenuItem(title, action: action)
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }
    private func splitMenu(_ axis: WorkspaceSplitAxis) -> NSMenu {
        let menu = NSMenu()
        let available = availableSections()
        if available.isEmpty {
            let item = NSMenuItem(title: "已显示全部窗格", action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item)
        }
        for section in available {
            menu.addItem(menuItem(section.title, symbol: section.symbol) { [weak self] in _ = self?.splitActive(adding: section, axis: axis) })
        }
        return menu
    }
    private func showSplitMenu(axis: WorkspaceSplitAxis, from anchor: NSView) {
        splitMenu(axis).popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.minY), in: anchor)
    }
    private func showLayoutMenu() {
        guard current != nil else { return }
        let menu = NSMenu()
        for axis in [WorkspaceSplitAxis.right, .down] {
            let item = NSMenuItem(title: axis.title, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: axis.symbol, accessibilityDescription: nil); item.submenu = splitMenu(axis); menu.addItem(item)
        }
        if visibleSections.count > 1 {
            menu.addItem(.separator())
            menu.addItem(menuItem(current?.maximized == true ? "恢复分屏" : "放大当前窗格", symbol: "arrow.up.left.and.arrow.down.right") { [weak self] in guard let self else { return }; self.togglePaneMaximization(self.selectedSection) })
            menu.addItem(menuItem("关闭其他窗格", symbol: "rectangle") { [weak self] in self?.resetLayout() })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: splitButton.bounds.minY), in: splitButton)
    }
    func selectConversation(id: String) {
        guard let current, !current.chat.hasRunning, current.chat.historyItems.contains(where: { $0.id == id }) else { return }
        current.chat.selectConversation(id: id); showSection(.chat)
    }
    /// A background terminal updates the chat that created it, independently of
    /// whichever project or conversation the user is currently viewing.
    func recordTerminalState(projectID: UUID, target: ChatTerminalTarget, uncertain: Bool) throws {
        guard let chat = workspaces[projectID]?.chatView else {
            throw AppError.message("原聊天工作区不可用，暂未更新终端会话身份。")
        }
        try chat.recordTerminalState(target: target, uncertain: uncertain)
    }
    func newConversation() { showSection(.chat); current?.chat.newConversation() }
    func showConversationActions(id: String, from sender: NSView) { current?.chat.showConversationActions(id: id, from: sender) }
    func showDeletedConversations(from sender: NSView) { current?.chat.showDeletedConversations(from: sender) }
    func focusInput() { focusSelectedPane() }
    func stopAll() { workspaces.values.forEach { $0.chatView?.stop() } }
}
