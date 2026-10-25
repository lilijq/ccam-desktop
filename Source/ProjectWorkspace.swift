import AppKit

private final class WorkspaceSectionButton: NSButton {
    var chosen = false { didSet { state = chosen ? .on : .off; needsDisplay = true } }
    var invoke: (() -> Void)?
    init(_ title: String, symbol: String) {
        super.init(frame: .zero)
        self.title = ""; image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imagePosition = .imageOnly; contentTintColor = Theme.muted
        target = self; action = #selector(pressed); isBordered = false; focusRingType = .exterior
        toolTip = title; setAccessibilityLabel(title)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 36, height: 34) }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 8, yRadius: 8).fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if chosen { Theme.panel.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill() }
        contentTintColor = chosen ? Theme.text : Theme.muted
        super.draw(dirtyRect)
    }
    @objc private func pressed() { invoke?() }
}

/// One project owns its drafts and views; the global account pool owns execution.
final class ProjectWorkspace: NSView {
    enum Section: Int, CaseIterable {
        case chat, files, git, terminal, web
        var title: String { ["对话", "文件", "Git", "终端", "网页"][rawValue] }
        var symbol: String { ["bubble.left", "doc.text", "arrow.triangle.branch", "terminal", "globe"][rawValue] }
    }
    private final class Workspace {
        let project: ProjectRecord
        let makeWeb: (ProjectRecord) -> ProjectWebView
        let makeChat: (ProjectRecord, String) -> ProjectChatView
        var chatViews: [String: ProjectChatView] = [:]
        var history: [(id: String, title: String)] = []
        var historyError: String?
        var lastChatID: String?
        var filesView: ProjectFilesView?
        var gitView: ProjectGitView?
        var webView: ProjectWebView?
        var web: ProjectWebView { if webView == nil { webView = makeWeb(project) }; return webView! }
        var files: ProjectFilesView { if filesView == nil { filesView = ProjectFilesView(directory: project.path) }; return filesView! }
        var git: ProjectGitView { if gitView == nil { gitView = ProjectGitView(directory: project.path) }; return gitView! }
        var layout: WorkspacePaneLayout
        let dragContext = UUID()
        var maximized = false
        var preferredChatID: String? {
            layout.conversationIDs[layout.active] ?? lastChatID
                ?? layout.root.sections.compactMap { layout.conversationIDs[$0] }.first ?? layout.conversationIDs[0]
        }
        var chatView: ProjectChatView? { preferredChatID.flatMap { chatViews[$0] } }
        var section: Section { WorkspacePaneLayout.isChat(layout.active) ? .chat : Section(rawValue: layout.active) ?? .chat }
        init(_ project: ProjectRecord, makeWeb: @escaping (ProjectRecord) -> ProjectWebView, makeChat: @escaping (ProjectRecord, String) -> ProjectChatView) {
            self.project = project; self.makeWeb = makeWeb; self.makeChat = makeChat; layout = .load(projectID: project.id)
            do {
                let store = try ChatStore(project: project)
                history = store.conversations.filter { $0.deletedAt == nil }.map { ($0.id, $0.title) }
                if layout.conversationIDs[0] == nil {
                    let id = try store.selectedID ?? ProjectChatView.createConversation(project: project)
                    layout.bind(id, to: 0)
                    if !history.contains(where: { $0.id == id }) { history.insert((id, "新对话"), at: 0) }
                }
            } catch { historyError = error.localizedDescription }
            lastChatID = layout.conversationIDs[layout.active] ?? layout.root.sections.compactMap { layout.conversationIDs[$0] }.first ?? layout.conversationIDs[0]
        }
        func chat(_ id: String) -> ProjectChatView {
            if let cached = chatViews[id] {
                // A previously missing binding can be restored from another
                // pane. Retry only failed startup, never replace a live runtime.
                if !(cached.boundConversationUnavailable && cached.selectedConversationID == nil && history.contains(where: { $0.id == id })) { return cached }
            }
            let view = makeChat(project, id); chatViews[id] = view; return view
        }
        func updateHistory(from view: ProjectChatView) {
            var items = view.historyItems
            if view.boundConversationUnavailable, let store = try? ChatStore(project: project) {
                items = store.conversations.filter { $0.deletedAt == nil }.map { ($0.id, $0.title) }
            }
            // Each bound runtime is authoritative for its own in-flight title.
            for (id, chat) in chatViews {
                if chat.boundConversationUnavailable {
                    if chat.selectedConversationID != nil { items.removeAll { $0.id == id } }
                    continue
                }
                if let title = chat.historyItems.first(where: { $0.id == id })?.title {
                    if let index = items.firstIndex(where: { $0.id == id }) { items[index].title = title }
                    else { items.insert((id, title), at: 0) }
                }
            }
            history = items
        }
    }
    private let webViewFactory: (ProjectRecord) -> ProjectWebView
    private let chatViewFactory: (ProjectRecord, String) -> ProjectChatView
    private let terminal: TerminalWorkspace
    private let sectionButtons = Section.allCases.map { WorkspaceSectionButton($0.title, symbol: $0.symbol) }
    private let sectionRow = NSStackView()
    private let splitButton = WorkspacePaneButton(symbol: "rectangle.split.2x1", title: "分屏布局")
    /// Hosted by the app's top bar; the workspace itself contains only content.
    var sectionControl: NSView { sectionRow }
    private let body = ThemeSurface(Theme.workspaceCanvas)
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
    private var storeObservation: NSObjectProtocol?
    private var rendering = false
    private var compact = false
    var visibleSections: [Section] { current?.layout.root.sections.map { WorkspacePaneLayout.isChat($0) ? .chat : Section(rawValue: $0) ?? .chat } ?? [.terminal] }
    var displayedSections: [Section] { panes.map { WorkspacePaneLayout.isChat($0.section) ? .chat : Section(rawValue: $0.section) ?? .chat } }
    var isSinglePanePresentation: Bool { compact || current?.maximized == true }
    var onInteractiveTask: ((ProjectRecord, ChatTerminalTarget) throws -> Void)?
    var onReturnFromTerminal: ((ProjectRecord, ChatTerminalTarget, @escaping (Result<ChatTerminalTarget, Error>) -> Void) -> Void)?
    var beforeChatStart: ((ProjectRecord, [String]) throws -> Void)?
    var onStateChange: (() -> Void)?
    var onTurnFinished: (() -> Void)?
    var onConfigureProxy: (() -> Void)?
    var hasRunning: Bool { workspaces.values.contains { $0.chatViews.values.contains { $0.hasRunning } } }
    var hasUnsavedChanges: Bool { workspaces.values.contains { $0.filesView?.hasUnsavedChanges == true } }
    var selectedSection: Section { current?.section ?? .terminal }
    var historyItems: [(id: String, title: String)] { current?.history ?? [] }
    var selectedConversationID: String? { current?.preferredChatID }
    var selectedAccountName: String? { current?.chatView?.selectedAccountName }
    var visibleConversationIDs: [String] { current.map { workspace in workspace.layout.root.sections.compactMap { workspace.layout.conversationIDs[$0] } } ?? [] }
    func runningCount(for projectID: UUID) -> Int { workspaces[projectID]?.chatViews.values.filter { $0.hasRunning }.count ?? 0 }
    func conversationIsRunning(projectID: UUID, id: String) -> Bool { workspaces[projectID]?.chatViews[id]?.hasRunning == true }
    func canSplitConversation(id: String) -> Bool {
        guard let current, current.history.contains(where: { $0.id == id }) else { return false }
        return visibleConversationIDs.contains(id) || current.layout.root.sections.count < 4
    }

    /// Only expanded, unmounted projects read their local history. Streaming
    /// updates use the existing view's in-memory metadata, never re-read JSON.
    func sidebarGroups(records: [ProjectRecord], expandedIDs: Set<UUID>) -> [SidebarProjectGroup] {
        historyCache = historyCache.filter { id, _ in records.contains { $0.id == id } }
        return records.map { project in
            if let workspace = workspaces[project.id] {
                let running = Set(workspace.chatViews.filter { $0.value.hasRunning }.map(\.key))
                return SidebarProjectGroup(project: project, items: expandedIDs.contains(project.id) ? workspace.history : [],
                    selectedID: workspace.preferredChatID, running: !running.isEmpty,
                    visibleIDs: Set(workspace.layout.root.sections.compactMap { workspace.layout.conversationIDs[$0] }), runningIDs: running, error: workspace.historyError)
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

    init(terminal: TerminalWorkspace, webViewFactory: @escaping (ProjectRecord) -> ProjectWebView = { ProjectWebView(project: $0) },
         chatViewFactory: @escaping (ProjectRecord, String) -> ProjectChatView = { ProjectChatView(project: $0, conversationID: $1) }) {
        self.terminal = terminal; self.webViewFactory = webViewFactory; self.chatViewFactory = chatViewFactory
        super.init(frame: .zero)
        sectionRow.orientation = .horizontal; sectionRow.alignment = .centerY; sectionRow.spacing = 2
        sectionRow.setAccessibilityLabel("项目工作区")
        for (index, button) in sectionButtons.enumerated() {
            sectionRow.addArrangedSubview(button)
            button.invoke = { [weak self] in
                guard let self else { return }
                self.openSectionFromNavigation(Section(rawValue: index) ?? .chat)
            }
        }
        sectionRow.addArrangedSubview(splitButton)
        splitButton.invoke = { [weak self] in self?.showLayoutMenu() }
        body.translatesAutoresizingMaskIntoConstraints = false; addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor), body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor), body.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        storeObservation = NotificationCenter.default.addObserver(forName: ChatStore.didChange, object: nil, queue: .main) { [weak self] notification in
            guard let self, let changed = notification.object as? ChatStore,
                  let workspace = self.workspaces[changed.project.id],
                  let fresh = try? ChatStore(project: workspace.project) else { return }
            workspace.history = fresh.conversations.filter { $0.deletedAt == nil }.map { ($0.id, $0.title) }
            if self.current === workspace { self.updatePaneSelection() }
            self.onStateChange?()
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.window, !self.isHiddenOrHasHiddenAncestor else { return event }
            for pane in self.panes where pane.bounds.contains(pane.convert(event.locationInWindow, from: nil)) {
                let point = pane.header.convert(event.locationInWindow, from: nil)
                if pane.header.bounds.contains(point), pane.header.hitTest(pane.convert(event.locationInWindow, from: nil)) === pane.header { break }
                self.activatePane(pane.section); break
            }
            return event
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let storeObservation { NotificationCenter.default.removeObserver(storeObservation) }
    }
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
            let workspace = workspaces[project.id] ?? Workspace(project, makeWeb: webViewFactory, makeChat: chatViewFactory)
            workspaces[project.id] = workspace; current = workspace
            // Materialize only visible/selected conversations. Other records stay
            // lightweight; already-created runtimes remain alive when hidden.
            for id in Set(workspace.layout.root.sections.compactMap { workspace.layout.conversationIDs[$0] } + [workspace.preferredChatID].compactMap { $0 }) {
                configureChat(workspace.chat(id), workspace: workspace)
            }
            if let section { selectSection(section, in: workspace) }
        } else { current = nil }
        if changedProject { terminal.filter(projectID: project?.id.uuidString); terminal.setScopeName(project?.name) }
        displaySection()
    }
    private func configureChat(_ chat: ProjectChatView, workspace: Workspace) {
        let project = workspace.project
        if current === workspace, let id = chat.boundConversationID,
           panes.contains(where: { workspace.layout.conversationIDs[$0.section] == id && !chat.isDescendant(of: $0) }) { renderID = "" }
        chat.onTerminalFallback = { [weak self] target in try self?.onInteractiveTask?(project, target) }
        chat.onReturnFromTerminal = { [weak self] target, completion in
            guard let handler = self?.onReturnFromTerminal else { completion(.failure(AppError.message("终端状态不可用，请重新打开应用。"))); return }
            handler(project, target, completion)
        }
        chat.onShowTerminal = { [weak self] in self?.openSectionFromNavigation(.terminal) }
        chat.webMCPArguments = { [weak self, weak workspace] in
            guard let self, let workspace else { return [] }
            self.configureWeb(workspace.web, workspace: workspace); return try workspace.web.mcpArguments()
        }
        chat.beforeStart = { [weak self] arguments in try self?.beforeChatStart?(project, arguments) }
        chat.onStateChange = { [weak self, weak workspace, weak chat] in
            guard let self, let workspace, let chat else { return }
            workspace.updateHistory(from: chat)
            if self.current === workspace { self.updatePaneSelection() }
            self.onStateChange?()
        }
        chat.onTurnFinished = { [weak self] in self?.onTurnFinished?() }
        chat.onNewConversationRequested = { [weak self, weak workspace, weak chat] in
            guard let self, let workspace, let chat, self.current === workspace else { return }
            if let id = chat.boundConversationID, let pane = workspace.layout.pane(for: id), workspace.layout.root.sections.contains(pane) { self.activatePane(pane) }
            self.newConversation()
        }
        workspace.updateHistory(from: chat)
    }
    private func selectSection(_ section: Section, in workspace: Workspace) {
        if section == .chat {
            let chats = workspace.layout.root.sections.filter(WorkspacePaneLayout.isChat)
            if let existing = chats.first(where: { workspace.layout.conversationIDs[$0] == workspace.lastChatID }) ?? chats.first {
                workspace.layout.active = existing
            } else {
                if let id = workspace.lastChatID { workspace.layout.bind(id, to: 0) }
                workspace.layout.select(0)
            }
            workspace.lastChatID = workspace.layout.conversationIDs[workspace.layout.active]
        } else { workspace.layout.select(section.rawValue) }
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
            + root.sections.map { current?.layout.conversationIDs[$0] ?? "" }.joined(separator: "|")
        if renderID != key {
            let previousResponder = window?.firstResponder as? NSView
            let fieldEditor = previousResponder as? NSTextView
            let previousField = fieldEditor?.isFieldEditor == true ? fieldEditor?.delegate as? NSTextField : nil
            let fieldSelection = previousField == nil ? nil : fieldEditor?.selectedRange()
            let refreshGit = root.sections.contains(Section.git.rawValue) && (!renderID.hasPrefix(current?.project.id.uuidString ?? "terminal") || !panes.contains { $0.section == Section.git.rawValue })
            panes.forEach { $0.header.cancelDrag(); $0.clearDropPreview() }
            mounted?.removeFromSuperview()
            mounted = nil; panes = []; renderID = key
            let view = makeLayout(root, headers: current != nil)
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
    private func content(for paneID: Int) -> NSView {
        guard let current else { return paneID == Section.terminal.rawValue ? terminal : empty }
        if WorkspacePaneLayout.isChat(paneID) {
            guard let id = current.layout.conversationIDs[paneID] else { return empty }
            let chat = current.chat(id); configureChat(chat, workspace: current); return chat
        }
        switch Section(rawValue: paneID) ?? .chat {
        case .chat: return empty
        case .files: return current.files
        case .git: return current.git
        case .terminal: return terminal
        case .web: configureWeb(current.web, workspace: current); return current.web
        }
    }
    private func paneTitle(_ paneID: Int) -> String {
        guard WorkspacePaneLayout.isChat(paneID) else { return Section(rawValue: paneID)?.title ?? "对话" }
        guard let current, let id = current.layout.conversationIDs[paneID] else { return "对话不可用" }
        guard let title = current.history.first(where: { $0.id == id })?.title else { return "对话不可用" }
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新对话" : title
    }
    private func configureWeb(_ web: ProjectWebView, workspace: Workspace) {
        web.onConfigureProxy = { [weak self] in self?.onConfigureProxy?() }
        web.onReveal = { [weak self, weak workspace] in
            guard let self, let workspace, self.current === workspace else { return }
            if !self.visibleSections.contains(.web) {
                self.openSectionFromNavigation(.web)
            }
        }
    }
    private func makeLayout(_ node: WorkspacePaneNode, headers: Bool) -> NSView {
        switch node {
        case .pane(let value):
            let pane = WorkspacePaneView(section: value, title: paneTitle(value), content: content(for: value), headers: headers, maximized: current?.maximized == true, multiple: (current?.layout.root.sections.count ?? 1) > 1)
            pane.dragContext = current?.dragContext
            pane.onMenu = { [weak self] anchor in self?.showPaneMenu(value, from: anchor) }
            pane.header.onDragChanged = { [weak self] source, point in self?.updatePaneDrag(source: source, point: point) }
            pane.header.onDragEnded = { [weak self] source, point in self?.finishPaneDrag(source: source, point: point) }
            pane.header.onDragCancelled = { [weak self] in self?.panes.forEach { $0.clearDropPreview() } }
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
    private func paneDropTarget(source: WorkspacePaneHeader, point: NSPoint) -> (WorkspacePaneView, WorkspacePaneDropPosition)? {
        guard let current, source.context == current.dragContext,
              source.window === window, window != nil,
              panes.contains(where: { $0.header === source }),
              body.bounds.contains(body.convert(point, from: nil)) else { return nil }
        for pane in panes where pane.acceptsDrag(source: source) {
            if let position = WorkspacePaneDropPosition.at(pane.convert(point, from: nil), in: pane.bounds) {
                return (pane, position)
            }
        }
        return nil
    }
    private func updatePaneDrag(source: WorkspacePaneHeader, point: NSPoint) {
        panes.forEach { $0.clearDropPreview() }
        if let (pane, position) = paneDropTarget(source: source, point: point) { pane.showDropPreview(position) }
    }
    private func finishPaneDrag(source: WorkspacePaneHeader, point: NSPoint) {
        defer { panes.forEach { $0.clearDropPreview() } }
        guard let (pane, position) = paneDropTarget(source: source, point: point) else { return }
        _ = rearrangePaneID(source.section, relativeTo: pane.section, position: position)
    }
    private func updatePaneSelection() {
        for pane in panes { pane.active = pane.section == current?.layout.active; pane.updateTitle(paneTitle(pane.section)) }
        for (index, button) in sectionButtons.enumerated() { button.chosen = index == selectedSection.rawValue }
    }
    private func activatePane(_ section: Int) {
        guard let current, current.layout.root.sections.contains(section), current.layout.active != section else { return }
        current.layout.active = section
        if let id = current.layout.conversationIDs[section] { current.lastChatID = id }
        current.layout.save(projectID: current.project.id)
        updatePaneSelection(); onStateChange?()
    }
    func showSection(_ section: Section) {
        if let current { selectSection(section, in: current) }; displaySection()
        focusSelectedPane()
    }
    /// Tools remain companion panes. Multiple conversations are never replaced
    /// by tool navigation; a full four-chat layout asks the user to free space.
    func openSectionFromNavigation(_ section: Section) {
        guard let current else { showSection(section); return }
        if section == .chat { showSection(.chat); return }
        let ids = current.layout.root.sections
        if ids.contains(section.rawValue), ids.count > 1 {
            current.maximized = false; showSection(section); return
        }
        let tools = ids.filter { !WorkspacePaneLayout.isChat($0) }
        if ids.count == 1, !tools.isEmpty {
            if let id = current.lastChatID { current.layout.bind(id, to: 0) }
            current.layout.root = .split(id: UUID(), axis: .right, ratio: 0.5, first: .pane(0), second: .pane(section.rawValue))
            current.layout.active = section.rawValue
        } else if let replace = tools.contains(current.layout.active) ? current.layout.active : tools.last {
            current.layout.root = current.layout.root.replacing(replace, with: .pane(section.rawValue)); current.layout.active = section.rawValue
        } else if ids.count < 4 {
            // Wrap all conversations on the left, with one shared companion tool.
            current.layout.root = .split(id: UUID(), axis: .right, ratio: ids.count > 1 ? 0.66 : 0.5,
                first: current.layout.root, second: .pane(section.rawValue)); current.layout.active = section.rawValue
        } else { showError("已显示 4 个面板，请先关闭一个面板再打开工具。", window: window); return }
        current.maximized = false; displaySection(); focusSelectedPane()
    }
    @discardableResult func rearrangePaneID(_ source: Int, relativeTo target: Int, position: WorkspacePaneDropPosition) -> Bool {
        guard let current, current.layout.move(source, relativeTo: target, position: position) else { return false }
        current.maximized = false
        if let id = current.layout.conversationIDs[source] { current.lastChatID = id }
        displaySection(); return true
    }
    @discardableResult func rearrangePane(_ source: Section, relativeTo target: Section, position: WorkspacePaneDropPosition) -> Bool {
        rearrangePaneID(paneID(for: source), relativeTo: paneID(for: target), position: position)
    }
    private func paneID(for section: Section) -> Int {
        guard section == .chat, let current else { return section.rawValue }
        if WorkspacePaneLayout.isChat(current.layout.active) { return current.layout.active }
        return current.layout.root.sections.first { current.layout.conversationIDs[$0] == current.lastChatID }
            ?? current.layout.root.sections.first(where: WorkspacePaneLayout.isChat) ?? 0
    }
    private func focusSelectedPane() {
        let selected = content(for: current?.layout.active ?? Section.terminal.rawValue)
        switch selectedSection {
        case .chat: (selected as? ProjectChatView)?.focusInput()
        case .files: current?.files.focus()
        case .git: current?.git.focus()
        case .terminal: terminal.focus()
        case .web: current?.web.focus()
        }
        if let responder = window?.firstResponder as? NSView, responder !== selected, !responder.isDescendant(of: selected) { window?.makeFirstResponder(nil) }
    }
    @discardableResult func splitActive(adding section: Section, axis: WorkspaceSplitAxis) -> Bool {
        guard let current else { return false }
        if section == .chat {
            guard let id = current.layout.conversationIDs[0] else { return false }
            return splitConversation(id: id, axis: axis)
        }
        guard current.layout.split(adding: section.rawValue, axis: axis) else { return false }
        current.maximized = false; displaySection(); focusSelectedPane(); return true
    }
    @discardableResult func splitConversation(id: String, axis: WorkspaceSplitAxis = .right) -> Bool {
        guard let current, canSplitConversation(id: id) else { return false }
        if let pane = current.layout.pane(for: id), current.layout.root.sections.contains(pane) {
            current.layout.active = pane; current.lastChatID = id; current.maximized = false
            displaySection(); focusSelectedPane(); return true
        }
        let slot = current.layout.pane(for: id) ?? current.layout.availableChatSlot()
        var next = current.layout; next.bind(id, to: slot)
        guard next.split(adding: slot, axis: axis), next.isValid else { return false }
        current.layout = next; current.lastChatID = id; current.maximized = false
        configureChat(current.chat(id), workspace: current)
        displaySection(); focusSelectedPane(); return true
    }
    @discardableResult func splitNewConversation(axis: WorkspaceSplitAxis = .right) -> Bool {
        guard let current, current.layout.root.sections.count < 4 else { return false }
        do {
            let id = try ProjectChatView.createConversation(project: current.project)
            current.history.insert((id, "新对话"), at: 0)
            return splitConversation(id: id, axis: axis)
        } catch { showError(error.localizedDescription, window: window); return false }
    }
    func closePaneID(_ pane: Int) {
        guard let current, current.layout.close(pane) else { return }
        current.layout.trimBindings(); current.maximized = false; displaySection(); focusSelectedPane()
    }
    func closePane(_ section: Section) { closePaneID(paneID(for: section)) }
    func closeConversationPane(id: String) {
        guard let current, let pane = current.layout.pane(for: id) else { return }; closePaneID(pane)
    }
    private func maximizePaneID(_ pane: Int) {
        guard let current, current.layout.root.sections.count > 1, current.layout.root.sections.contains(pane) else { return }
        current.layout.active = pane; current.maximized.toggle(); displaySection(); focusSelectedPane()
    }
    func togglePaneMaximization(_ section: Section) { maximizePaneID(paneID(for: section)) }
    func resetLayout() {
        guard let current else { return }
        current.layout.root = .pane(current.layout.active); current.layout.trimBindings(); current.maximized = false; displaySection(); focusSelectedPane()
    }
    private func availableSections() -> [Section] { Section.allCases.filter { $0 != .chat && !(current?.layout.root.sections.contains($0.rawValue) ?? false) } }
    private func menuItem(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> NSMenuItem {
        let item = WorkspaceMenuItem(title, action: action)
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }
    private func splitMenu(_ axis: WorkspaceSplitAxis) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        guard let current else { return menu }
        if current.layout.root.sections.count >= 4 {
            let item = NSMenuItem(title: "最多显示 4 个面板", action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item); return menu
        }
        menu.addItem(menuItem("新对话", symbol: "square.and.pencil") { [weak self] in _ = self?.splitNewConversation(axis: axis) })
        let others = current.history.filter { !visibleConversationIDs.contains($0.id) }
        if !others.isEmpty {
            let existing = NSMenuItem(title: "已有对话", action: nil, keyEquivalent: ""), list = NSMenu()
            for item in others { list.addItem(menuItem(item.title.isEmpty ? "新对话" : item.title) { [weak self] in _ = self?.splitConversation(id: item.id, axis: axis) }) }
            existing.submenu = list; menu.addItem(existing)
        }
        if !availableSections().isEmpty { menu.addItem(.separator()) }
        for section in availableSections() { menu.addItem(menuItem(section.title, symbol: section.symbol) { [weak self] in _ = self?.splitActive(adding: section, axis: axis) }) }
        return menu
    }
    private func showPaneMenu(_ paneID: Int, from anchor: NSView) {
        guard let current else { return }; activatePane(paneID)
        let menu = NSMenu(); menu.autoenablesItems = false
        for axis in [WorkspaceSplitAxis.right, .down] {
            let item = NSMenuItem(title: axis.title, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: axis.symbol, accessibilityDescription: nil); item.submenu = splitMenu(axis); menu.addItem(item)
        }
        let others = current.layout.root.sections.filter { $0 != paneID }
        if !others.isEmpty {
            menu.addItem(.separator())
            let move = NSMenuItem(title: "移动面板", action: nil, keyEquivalent: ""), destinations = NSMenu()
            for target in others {
                let item = NSMenuItem(title: paneTitle(target), action: nil, keyEquivalent: ""), positions = NSMenu()
                for position in WorkspacePaneDropPosition.allCases {
                    positions.addItem(menuItem(position == .center ? "交换位置" : "移到" + position.title) { [weak self] in _ = self?.rearrangePaneID(paneID, relativeTo: target, position: position) })
                }
                item.submenu = positions; destinations.addItem(item)
            }
            move.submenu = destinations; menu.addItem(move)
            menu.addItem(menuItem(current.maximized ? "恢复分屏" : "放大面板") { [weak self] in self?.maximizePaneID(paneID) })
            menu.addItem(menuItem("关闭面板") { [weak self] in self?.closePaneID(paneID) })
        }
        if let id = current.layout.conversationIDs[paneID] {
            menu.addItem(.separator())
            menu.addItem(menuItem("对话管理…") { [weak self, weak anchor] in guard let self, let anchor else { return }; self.showConversationActions(id: id, from: anchor) })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.minY), in: anchor)
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
            menu.addItem(menuItem(current?.maximized == true ? "恢复分屏" : "放大当前面板") { [weak self] in guard let self, let active = self.current?.layout.active else { return }; self.maximizePaneID(active) })
            menu.addItem(menuItem("关闭其他面板") { [weak self] in self?.resetLayout() })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: splitButton.bounds.minY), in: splitButton)
    }
    func selectConversation(id: String) {
        guard let current, current.history.contains(where: { $0.id == id }) else { return }
        if let pane = current.layout.pane(for: id), current.layout.root.sections.contains(pane) { current.layout.active = pane }
        else {
            let slot = WorkspacePaneLayout.isChat(current.layout.active) ? current.layout.active : current.layout.root.sections.first(where: WorkspacePaneLayout.isChat) ?? 0
            current.layout.bind(id, to: slot)
            if !current.layout.root.sections.contains(slot) { current.layout.root = current.layout.root.replacing(current.layout.active, with: .pane(slot)) }
            current.layout.active = slot
        }
        current.lastChatID = id; current.maximized = false
        configureChat(current.chat(id), workspace: current); displaySection(); focusSelectedPane()
    }
    /// A background terminal updates the chat that created it, independently of
    /// whichever project or conversation the user is currently viewing.
    func recordTerminalState(projectID: UUID, target: ChatTerminalTarget, uncertain: Bool) throws {
        guard let id = target.conversationID, let chat = workspaces[projectID]?.chatViews[id] else {
            throw AppError.message("原聊天工作区不可用，暂未更新终端会话身份。")
        }
        try chat.recordTerminalState(target: target, uncertain: uncertain)
    }
    func newConversation() {
        guard let current else { return }
        do {
            let id = try ProjectChatView.createConversation(project: current.project)
            current.history.insert((id, "新对话"), at: 0); selectConversation(id: id)
        } catch { showError(error.localizedDescription, window: window) }
    }
    func showConversationActions(id: String, from sender: NSView) {
        guard let current, current.history.contains(where: { $0.id == id }) else { return }
        let chat = current.chat(id); configureChat(chat, workspace: current)
        let menu = chat.conversationActionsMenu(id: id, from: sender) ?? NSMenu()
        menu.autoenablesItems = false
        menu.insertItem(.separator(), at: 0)
        for (index, axis) in [WorkspaceSplitAxis.right, .down].enumerated() {
            let item = menuItem(axis == .right ? "在右侧打开" : "在下方打开", symbol: axis.symbol) { [weak self] in _ = self?.splitConversation(id: id, axis: axis) }
            item.isEnabled = canSplitConversation(id: id)
            if !item.isEnabled { item.toolTip = "已显示 4 个面板，请先关闭一个面板。" }
            menu.insertItem(item, at: index)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }
    /// Recovery belongs to the project document, even when every mounted
    /// conversation is deleted and no bound runtime could be initialized.
    func deletedConversationsMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        guard let current else { return menu }
        do {
            let store = try ChatStore(project: current.project)
            let deleted = store.conversations.filter { $0.deletedAt != nil }
            if deleted.isEmpty {
                let item = NSMenuItem(title: "没有已删除的对话", action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item)
            }
            for conversation in deleted {
                menu.addItem(menuItem(conversation.title.isEmpty ? "新对话" : conversation.title, symbol: "arrow.uturn.backward") { [weak self, weak current] in
                    guard let self, let current else { return }
                    do {
                        let fresh = try ChatStore(project: current.project)
                        var items = fresh.conversations
                        guard let index = items.firstIndex(where: { $0.id == conversation.id && $0.deletedAt != nil }) else { return }
                        items[index].deletedAt = nil; items[index].updatedAt = Date()
                        try fresh.save(items, selectedID: fresh.selectedID, preserveSelection: true)
                        current.history = items.filter { $0.deletedAt == nil }.map { ($0.id, $0.title) }
                        if self.current === current, self.visibleConversationIDs.contains(conversation.id) { self.selectConversation(id: conversation.id) }
                        self.onStateChange?()
                    } catch { showError(error.localizedDescription, window: self.window) }
                })
            }
        } catch {
            let item = NSMenuItem(title: "无法读取已删除的对话", action: nil, keyEquivalent: ""); item.toolTip = error.localizedDescription; item.isEnabled = false; menu.addItem(item)
        }
        return menu
    }
    func showDeletedConversations(from sender: NSView) {
        deletedConversationsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }
    func focusInput() { focusSelectedPane() }
    func stopAll() { workspaces.values.forEach { $0.chatViews.values.forEach { $0.stop() } } }
}
