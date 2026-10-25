import AppKit
import SwiftTerm

final class TerminalSessionView: NSView, TerminalViewDelegate {
    let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 450))
    let session = PTYSession()
    let status = label("准备启动", size: 11, color: Theme.muted)
    let activity = label("工作会话", size: 12, color: Theme.accent)
    let activityBackground = ThemeSurface(Theme.accent.withAlphaComponent(0.08), radius: 8)
    private let failureMessage = label("", size: 13, color: Theme.muted)
    private let failurePanel = ThemeSurface(Theme.panel, border: Theme.border, radius: 10)
    private var isManagedLaunch = false
    private var hasUserInput = false
    private var diagnostic = OperationPresentation()
    private var commandFilter = TerminalCommandFilter()
    private var shellConfiguration: ExecutionProxy.ShellConfiguration?
    private var launchCancelled = false
    var chatConversationID: String?
    var chatReturnTarget: ChatTerminalTarget?
    var chatReturnIdentityUncertain = false
    var onChatReturnStateChanged: ((ChatTerminalTarget, Bool) throws -> Void)?
    private(set) var chatReturnPersistenceError: String?
    var accountNames: [String] = []
    var onExit: (() -> Void)?
    var onTitle: ((String) -> Void)?
    var onProcessStarted: ((Int32) -> Void)?
    var onProcessExit: ((Int32) -> Void)?
    var onUserStop: (() -> Void)?
    var onInterrupt: (() -> Void)?
    var title: String
    let directory: String
    let projectID: String?
    let projectName: String?
    let environmentOverrides: [String: String]
    let environmentExclusions: [String]
    var beforeManagedStart: ((String, [String]) throws -> Void)?
    var beforeShellStart: ((String) throws -> Void)?
    private(set) var isWaiting = false
    init(title: String, directory: String, projectID: String? = nil, projectName: String? = nil, environmentOverrides: [String: String] = [:], environmentExclusions: [String] = []) {
        self.title = title; self.directory = directory
        self.projectID = projectID; self.projectName = projectName; self.environmentOverrides = environmentOverrides
        self.environmentExclusions = environmentExclusions
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        terminal.terminalDelegate = self
        terminal.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.appearance = NSAppearance(named: .darkAqua)
        terminal.nativeBackgroundColor = Theme.color(0x101010)
        terminal.nativeForegroundColor = Theme.color(0xF2F2F2)
        terminal.caretColor = NSColor(calibratedRed: 0.56, green: 0.68, blue: 1, alpha: 1); terminal.optionAsMetaKey = false
        terminal.wantsLayer = true; terminal.layer?.cornerRadius = 8; terminal.layer?.masksToBounds = true
        terminal.getTerminal().changeHistorySize(10000)
        let detail = label(projectName.map { "\($0) · \(directory)" } ?? directory, size: 11, color: Theme.muted)
        detail.maximumNumberOfLines = 1; detail.lineBreakMode = .byTruncatingMiddle; detail.toolTip = directory
        status.maximumNumberOfLines = 1; status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let footer = row([status, detail], spacing: 8); footer.translatesAutoresizingMaskIntoConstraints = false
        activity.font = Theme.font(size: 12, weight: .medium)
        activity.maximumNumberOfLines = 1; activity.lineBreakMode = .byTruncatingTail
        activityBackground.wantsLayer = true
        activityBackground.layer?.cornerRadius = 8
        activityBackground.translatesAutoresizingMaskIntoConstraints = false; activity.translatesAutoresizingMaskIntoConstraints = false
        addSubview(activityBackground); activityBackground.addSubview(activity)
        addSubview(terminal); addSubview(footer); terminal.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([activityBackground.topAnchor.constraint(equalTo: topAnchor, constant: 6), activityBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), activityBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), activity.leadingAnchor.constraint(equalTo: activityBackground.leadingAnchor, constant: 8), activity.trailingAnchor.constraint(equalTo: activityBackground.trailingAnchor, constant: -8), activity.topAnchor.constraint(equalTo: activityBackground.topAnchor, constant: 5), activity.bottomAnchor.constraint(equalTo: activityBackground.bottomAnchor, constant: -5), activityBackground.heightAnchor.constraint(greaterThanOrEqualToConstant: 26), terminal.topAnchor.constraint(equalTo: activityBackground.bottomAnchor, constant: 6), terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), terminal.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6), footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6), footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 18)])
        failurePanel.translatesAutoresizingMaskIntoConstraints = false
        failurePanel.wantsLayer = true; failurePanel.layer?.cornerRadius = 10
        failurePanel.layer?.borderWidth = 1
        let failureContent = column([label("暂时无法继续", size: 20, weight: .semibold), failureMessage], spacing: 12)
        failureContent.translatesAutoresizingMaskIntoConstraints = false; failurePanel.addSubview(failureContent); addSubview(failurePanel)
        NSLayoutConstraint.activate([failurePanel.topAnchor.constraint(equalTo: terminal.topAnchor), failurePanel.leadingAnchor.constraint(equalTo: terminal.leadingAnchor), failurePanel.trailingAnchor.constraint(equalTo: terminal.trailingAnchor), failurePanel.bottomAnchor.constraint(equalTo: terminal.bottomAnchor), failureContent.topAnchor.constraint(equalTo: failurePanel.topAnchor, constant: 24), failureContent.leadingAnchor.constraint(equalTo: failurePanel.leadingAnchor, constant: 24), failureContent.trailingAnchor.constraint(equalTo: failurePanel.trailingAnchor, constant: -24)])
        failurePanel.isHidden = true
        session.onData = { [weak self] bytes in
            guard let self else { return }
            if self.isManagedLaunch { self.diagnostic.append(bytes) }
            let visible = self.isManagedLaunch ? self.commandFilter.append(bytes) : bytes
            self.terminal.feed(byteArray: visible[...])
        }
        session.onExit = { [weak self] code in
            guard let self else { return }
            self.shellConfiguration?.cleanup(); self.shellConfiguration = nil
            if self.isManagedLaunch { let trailing = self.commandFilter.finish(); self.terminal.feed(byteArray: trailing[...]) }
            self.status.stringValue = code == 0 ? "会话已结束" : "会话未正常结束"; self.status.textColor = code == 0 ? Theme.success : Theme.warning
            if code != 0 && self.isManagedLaunch && !self.hasUserInput {
                let summary = self.diagnostic.snapshot().text
                self.failureMessage.stringValue = summary.isEmpty ? "请查看全局账号池中的登录和额度状态，然后从项目重新开始。" : String(summary.prefix(4000))
                self.failurePanel.isHidden = false
            }
            self.onTitle?("✓ " + self.title); self.onExit?(); self.onProcessExit?(code)
        }
    }
    deinit { shellConfiguration?.cleanup() }
    required init?(coder: NSCoder) { fatalError() }
    func start(executable: String, args: [String], initialInput: String? = nil, environmentOverrides: [String: String]? = nil) {
        guard !launchCancelled else { return }
        isWaiting = false; hasUserInput = false; diagnostic = OperationPresentation(); failurePanel.isHidden = true
        commandFilter = TerminalCommandFilter(accountNames: accountNames)
        var env = CCAMClient.environment
        env.merge(environmentOverrides ?? self.environmentOverrides) { _, override in override }
        for key in environmentExclusions { env.removeValue(forKey: key) }
        isManagedLaunch = executable == CCAMClient.executable || env["CCAM_DESKTOP_EVENT_DIR"] != nil
        if !isManagedLaunch { env["BROWSER"] = ProcessInfo.processInfo.environment["BROWSER"] }
        env.removeValue(forKey: "NO_COLOR"); env.removeValue(forKey: "CLICOLOR")
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"; env["TERM_PROGRAM"] = "CCAMDesktop"
        // Prevent inherited terminal-size variables from overriding the actual PTY size.
        env.removeValue(forKey: "LINES"); env.removeValue(forKey: "COLUMNS")
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        layoutSubtreeIfNeeded()
        do {
            let proxy = try ExecutionProxy.resolve(environment: env)
            env = proxy.environment
            var launchArguments = args
            if executable == "/bin/zsh" {
                try beforeShellStart?(directory)
                shellConfiguration?.cleanup()
                let configuration = try ExecutionProxy.makeShellConfiguration(state: proxy)
                shellConfiguration = configuration; env = configuration.environment; launchArguments = configuration.arguments
            }
            if isManagedLaunch { try beforeManagedStart?(directory, args) }
            try session.start(executable: executable, args: launchArguments, directory: directory, environment: env, rows: terminal.getTerminal().rows, cols: terminal.getTerminal().cols)
            status.stringValue = "代理 " + proxy.endpoint; status.textColor = Theme.accent; onTitle?(title)
            if !isManagedLaunch { showNotice("开发终端 · 代理已固定") }
            onProcessStarted?(session.pid)
            if let initialInput { session.send(initialInput + "\n"); session.eof() }
            if !isHiddenOrHasHiddenAncestor { window?.makeFirstResponder(terminal) }
        } catch {
            shellConfiguration?.cleanup(); shellConfiguration = nil
            failureMessage.stringValue = OperationPresentation.clean(error.localizedDescription); failurePanel.isHidden = false
            status.stringValue = "启动失败"; status.textColor = Theme.warning
            onTitle?("! " + title); onExit?(); onProcessExit?(127)
        }
    }
    func showNotice(_ message: String) {
        activity.stringValue = OperationPresentation.clean(message)
        activity.toolTip = activity.stringValue
        activity.textColor = isWaiting ? Theme.warning : Theme.accent
    }
    /// Updated only from the authenticated SessionStart hook of this exact PTY.
    func captureReturnIdentity(_ plan: PoolLaunch, rootPID: Int32) {
        guard var target = chatReturnTarget, let identity = GlobalPool.readChatIdentity(plan, rootPID: rootPID) else { return }
        guard target.sessionID != identity.sessionID || target.account != identity.account || target.ticket != nil || chatReturnIdentityUncertain || chatReturnPersistenceError != nil else { return }
        target = ChatTerminalTarget(directory: target.directory, sessionID: identity.sessionID, account: identity.account,
                                    ticket: nil, canResume: true, model: target.model, permissionMode: target.permissionMode,
                                    effort: target.effort, conversationID: target.conversationID)
        chatReturnTarget = target; chatReturnIdentityUncertain = false
        persistReturnState()
    }
    func markReturnIdentityUncertain() {
        guard chatReturnTarget != nil else { return }
        chatReturnIdentityUncertain = true; persistReturnState()
    }
    private func persistReturnState() {
        guard let target = chatReturnTarget else { return }
        do { try onChatReturnStateChanged?(target, chatReturnIdentityUncertain); chatReturnPersistenceError = nil }
        catch { chatReturnPersistenceError = error.localizedDescription }
    }
    func setWaiting(_ waiting: Bool) {
        isWaiting = waiting
        if waiting { status.stringValue = "等待可用账号额度…"; status.textColor = Theme.warning }
        else if session.running { status.stringValue = "会话运行中"; status.textColor = Theme.accent }
    }
    func interrupt() { onInterrupt?(); session.interrupt() }
    func sendEOF() { onInterrupt?(); session.eof() }
    func stopByUser(force: Bool = false) { launchCancelled = true; isWaiting = false; onUserStop?(); session.stop(force: force) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { session.resize(rows: newRows, cols: newCols) }
    func setTerminalTitle(source: TerminalView, title: String) { /* Keep the human-readable task title instead of child command lines. */ }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        hasUserInput = true
        if data.contains(3) || data.contains(4) { onInterrupt?() }
        session.send(Array(data))
    }
    func scrolled(source: TerminalView, position: Double) { }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        if isManagedLaunch && BrowserRouting.isLoginLink(url) {
            do { try BrowserRouting.open(url: url, account: nil) }
            catch { showError(error.localizedDescription, window: window) }
        } else { NSWorkspace.shared.open(url) }
    }
    func bell(source: TerminalView) { NSSound.beep() }
    func clipboardCopy(source: TerminalView, content: Data) { /* OSC 52 never writes the clipboard implicitly. */ }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) { }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { }
}

final class TerminalWorkspace: NSView, NSTabViewDelegate {
    var beforeManagedStart: ((String, [String]) throws -> Void)?
    var beforeShellStart: ((String) throws -> Void)?
    let tabs = NSTabView()
    let scopeLabel = label("全部项目的会话", size: 12, color: Theme.muted)
    let emptyState = column([label("开始一个工作会话", size: 20, weight: .semibold), label("选择项目，开始新任务。", size: 13, color: Theme.muted)], spacing: 10)
    func setScopeName(_ name: String?) { scopeLabel.stringValue = name ?? "全部项目的会话"; scopeLabel.toolTip = scopeLabel.stringValue }
    var sessions: [TerminalSessionView] = []
    var accountNames: [String] = []
    private var tabItems: [ObjectIdentifier: NSTabViewItem] = [:]
    private var selectedByFilter: [String: ObjectIdentifier] = [:]
    private var rebuildingTabs = false
    private(set) var filteredProjectID: String?
    var onNewShell: (() -> Void)?
    var onNewTask: (() -> Void)?
    var onFinished: (() -> Void)?
    var current: TerminalSessionView? { tabs.selectedTabViewItem?.view as? TerminalSessionView }
    var hasRunning: Bool { sessions.contains { $0.session.running || $0.isWaiting } }
    private var filterKey: String { filteredProjectID.map { "project:\($0)" } ?? "all" }
    private func matches(_ view: TerminalSessionView, projectID: String?) -> Bool { projectID == nil || view.projectID == projectID }
    func count(for projectID: String?) -> Int {
        sessions.filter { tabItems[ObjectIdentifier($0)] != nil && matches($0, projectID: projectID) }.count
    }
    func runningCount(for projectID: String?) -> Int {
        sessions.filter { ($0.session.running || $0.isWaiting) && matches($0, projectID: projectID) }.count
    }
    func returnToChat(projectID: String, target: ChatTerminalTarget, window: NSWindow,
                      completion: @escaping (Result<ChatTerminalTarget, Error>) -> Void) {
        let related = sessions.filter { $0.projectID == projectID && target.conversationID != nil && $0.chatConversationID == target.conversationID }
        // Older versions did not record the handoff relationship. Do not terminate
        // an unrelated terminal or allow two owners of an unknown live session.
        if related.isEmpty && sessions.contains(where: { $0.projectID == projectID && ($0.session.running || $0.isWaiting) }) {
            completion(.failure(AppError.message("该项目还有终端会话运行。请先结束原会话，再返回聊天。"))); return
        }
        let finish = {
            guard !related.contains(where: { $0.session.running || $0.isWaiting }) else {
                completion(.failure(AppError.message("终端尚未退出，请稍后返回聊天。"))); return
            }
            guard !related.contains(where: { $0.chatReturnIdentityUncertain }) else {
                completion(.failure(AppError.message("终端曾切换账号，但未取得新会话身份。请从终端继续，避免恢复错误的上下文。"))); return
            }
            guard !related.contains(where: { $0.chatReturnPersistenceError != nil }) else {
                completion(.failure(AppError.message("终端上下文尚未保存，暂不能返回聊天。请检查本地数据目录是否可写。"))); return
            }
            completion(.success(related.last?.chatReturnTarget ?? target))
        }
        guard related.contains(where: { $0.session.running || $0.isWaiting }) else {
            // Also cancel a scheduled open() callback that has not spawned yet.
            for view in related { view.stopByUser() }
            finish(); return
        }
        let alert = NSAlert(); alert.messageText = "返回聊天？"
        alert.informativeText = "将结束这段对话的终端执行，保留项目文件与上下文。"
        alert.addButton(withTitle: "结束终端并返回"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { completion(.failure(AppError.message("已保留终端会话。"))); return }
            for view in related { view.stopByUser() }
            let deadline = Date().addingTimeInterval(5)
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
                if !related.contains(where: { $0.session.running || $0.isWaiting }) || Date() >= deadline {
                    timer.invalidate(); finish()
                }
            }
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        func icon(_ title: String, symbol: String, action: @escaping () -> Void) -> ClosureButton {
            let button = ClosureButton("", symbol: symbol, action: action)
            button.toolTip = title; button.setAccessibilityLabel(title)
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            return button
        }
        let newTask = icon("新任务", symbol: "plus") { [weak self] in self?.onNewTask?() }
        newTask.bezelColor = Theme.accent
        let interrupt = icon("中断", symbol: "pause") { [weak self] in self?.current?.interrupt(); self?.focus() }
        interrupt.toolTip = "中断当前工作，保留此会话"
        let more = icon("更多会话操作", symbol: "ellipsis") { }
        more.menu = NSMenu(); more.menu?.autoenablesItems = false
        more.actionBlock = { [weak more] in
            guard let more else { return }
            more.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.minY), in: more)
        }
        func menuAction(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self
            more.menu?.addItem(item)
        }
        menuAction("复制所选内容", #selector(copySelection))
        more.menu?.addItem(.separator())
        menuAction("增大字号", #selector(increaseFont))
        menuAction("减小字号", #selector(decreaseFont))
        more.menu?.addItem(.separator())
        menuAction("结束输入", #selector(endInput))
        menuAction("关闭会话", #selector(closeCurrentSession))
        more.menu?.addItem(.separator())
        menuAction("打开开发终端", #selector(openShell))
        let controls = row([
            newTask,
            icon("粘贴", symbol: "doc.on.clipboard") { [weak self] in self?.current?.terminal.paste(self as Any); self?.focus() },
            interrupt, more
        ], spacing: 6)
        controls.setContentHuggingPriority(.required, for: .horizontal)
        controls.setContentCompressionResistancePriority(.required, for: .horizontal)
        scopeLabel.maximumNumberOfLines = 1; scopeLabel.lineBreakMode = .byTruncatingTail
        let allProjects = icon("显示全部项目的终端", symbol: "square.grid.2x2") { [weak self] in self?.filter(projectID: nil) }
        let toolbar = row([scopeLabel, spacer(), allProjects, controls], spacing: 4)
        toolbar.translatesAutoresizingMaskIntoConstraints = false; addSubview(toolbar)
        emptyState.translatesAutoresizingMaskIntoConstraints = false; addSubview(emptyState)
        tabs.translatesAutoresizingMaskIntoConstraints = false; tabs.delegate = self; tabs.tabViewType = .topTabsBezelBorder; addSubview(tabs, positioned: .below, relativeTo: emptyState)
        tabs.appearance = nil; tabs.font = Theme.font(size: 12, weight: .medium)
        tabs.allowsTruncatedLabels = true; tabs.drawsBackground = false
        NSLayoutConstraint.activate([toolbar.topAnchor.constraint(equalTo: topAnchor), toolbar.leadingAnchor.constraint(equalTo: leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: trailingAnchor), toolbar.heightAnchor.constraint(greaterThanOrEqualToConstant: 32), emptyState.centerXAnchor.constraint(equalTo: centerXAnchor), emptyState.centerYAnchor.constraint(equalTo: tabs.centerYAnchor), emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24), emptyState.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24), emptyState.widthAnchor.constraint(lessThanOrEqualToConstant: 320), tabs.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6), tabs.leadingAnchor.constraint(equalTo: leadingAnchor), tabs.trailingAnchor.constraint(equalTo: trailingAnchor), tabs.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func copySelection() { current?.terminal.copy(self) }
    @objc private func increaseFont() { changeFont(1) }
    @objc private func decreaseFont() { changeFont(-1) }
    @objc private func endInput() { current?.sendEOF(); focus() }
    @objc private func closeCurrentSession() { closeSelected() }
    @objc private func openShell() { onNewShell?() }
    @discardableResult func open(executable: String, args: [String], directory: String, title: String, initialInput: String? = nil, projectID: String? = nil, projectName: String? = nil, environmentOverrides: [String: String] = [:], environmentExclusions: [String] = []) -> TerminalSessionView {
        let view = TerminalSessionView(title: title, directory: directory, projectID: projectID, projectName: projectName, environmentOverrides: environmentOverrides, environmentExclusions: environmentExclusions)
        view.accountNames = accountNames
        view.beforeManagedStart = beforeManagedStart
        view.beforeShellStart = beforeShellStart
        sessions.append(view)
        let identifier = ObjectIdentifier(view)
        let tab = NSTabViewItem(identifier: UUID().uuidString); tab.label = projectName.map { "\($0) · \(title)" } ?? title; tab.view = view
        tabItems[identifier] = tab
        view.onTitle = { [weak tab] text in tab?.label = projectName.map { "\($0) · \(text)" } ?? text }
        view.onExit = { [weak self] in self?.onFinished?() }
        rememberSelection()
        if !matches(view, projectID: filteredProjectID) { filteredProjectID = projectID }
        rebuildTabs(selecting: identifier)
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, self.tabItems[ObjectIdentifier(view)] != nil else { return }
            self.layoutSubtreeIfNeeded(); view.start(executable: executable, args: args, initialInput: initialInput)
        }
        return view
    }
    /// Filtering detaches views only; their PTYs, output buffers and processes stay alive.
    func filter(projectID: String?) {
        guard filteredProjectID != projectID else { return }
        rememberSelection(); filteredProjectID = projectID; rebuildTabs()
    }
    private func rememberSelection() {
        if let current {
            let identifier = ObjectIdentifier(current)
            selectedByFilter[filterKey] = identifier
            if let projectID = current.projectID { selectedByFilter["project:\(projectID)"] = identifier }
        }
    }
    private func rebuildTabs(selecting preferred: ObjectIdentifier? = nil) {
        rebuildingTabs = true
        for tab in tabs.tabViewItems { tabs.removeTabViewItem(tab) }
        let visible = sessions.filter { tabItems[ObjectIdentifier($0)] != nil && matches($0, projectID: filteredProjectID) }
        for view in visible { tabs.addTabViewItem(tabItems[ObjectIdentifier(view)]!) }
        let wanted = preferred ?? selectedByFilter[filterKey]
        if let wanted, let tab = tabItems[wanted], tabs.tabViewItems.contains(where: { $0 === tab }) {
            tabs.selectTabViewItem(tab)
        } else if let tab = tabs.tabViewItems.last { tabs.selectTabViewItem(tab) }
        emptyState.isHidden = !visible.isEmpty
        if filteredProjectID == nil { setScopeName(nil) }
        else if let name = visible.first?.projectName { setScopeName(name) }
        rebuildingTabs = false; rememberSelection(); focus()
    }
    func focus() { if !isHiddenOrHasHiddenAncestor, let current { window?.makeFirstResponder(current.terminal) } }
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard !rebuildingTabs else { return }
        rememberSelection(); DispatchQueue.main.async { [weak self] in self?.focus() }
    }
    func changeFont(_ delta: CGFloat) { guard let terminal = current?.terminal else { return }; terminal.font = .monospacedSystemFont(ofSize: min(24, max(9, terminal.font.pointSize + delta)), weight: .regular); focus() }
    func closeSelected() {
        guard let tab = tabs.selectedTabViewItem, let view = tab.view as? TerminalSessionView else { return }
        if view.session.running || view.isWaiting {
            let alert = NSAlert(); alert.messageText = "结束此工作会话？"; alert.informativeText = "当前会话将停止，其他项目的工作会继续。"; alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "结束会话")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        view.stopByUser()
        let identifier = ObjectIdentifier(view)
        tabItems.removeValue(forKey: identifier)
        selectedByFilter = selectedByFilter.filter { $0.value != identifier }
        rebuildTabs()
        // Retain live sessions until reaped so their monitor and cleanup stay active.
        sessions.removeAll { !$0.session.running && $0 === view }
        view.onExit = { [weak self, weak view] in self?.sessions.removeAll { $0 === view }; self?.onFinished?() }
        onFinished?()
    }
    func stopAll() { sessions.forEach { $0.stopByUser(force: true) } }
}
