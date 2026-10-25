import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var isCompact = false
    private var sidebarView: NSView!
    private var sidebarWidth: NSLayoutConstraint!
    private var mainLeading: NSLayoutConstraint!
    private var mainTrailing: NSLayoutConstraint!
    private var compactNavigation: ClosureButton!
    private let poolSummary = label("正在读取账号", size: 12, color: Theme.muted)
    private var workspaceSidebar: WorkspaceSidebar!
    private var compactManage: SidebarItemButton!
    private var mainBottom: NSLayoutConstraint!
    private var managementPopover: NSPopover?
    private var compactShell = false
    private weak var appearanceSelector: NSPopUpButton?
    var content = NSStackView()
    var accounts: [Account] = []
    var usage: [AccountUsage] = []
    var accountsError: String?
    var usageError: String?
    var refreshing = false
    var lastRefresh: Date?
    var selected = 0
    var renderedPage = -1
    var generation = 0
    var timer: Timer?
    var forms: [FormWindow] = []
    var taskComposers: [TaskComposer] = []
    var operationWindows: [OperationWindow] = []
    var browserLockWindows: [BrowserLockWindow] = []
    let terminalWorkspace = TerminalWorkspace(frame: .zero)
    lazy var projectWorkspace = ProjectWorkspace(terminal: terminalWorkspace)
    var contentScroll: NSScrollView!
    var commandCenter: CommandCenterView?
    private var commandCenterHeight: NSLayoutConstraint?
    var projectStore: ProjectStore?
    var projectStoreError: String?
    var showArchivedProjects = false
    var project: String { projectStore?.currentProject?.path ?? FileManager.default.homeDirectoryForCurrentUser.path }
    var currentProject: ProjectRecord? { projectStore?.currentProject }
    let projectButton = ClosureButton("添加项目…", symbol: "folder") { }
    var stableDirectory: String { FileManager.default.homeDirectoryForCurrentUser.path }
    var terminalProject: ProjectRecord? {
        let id = terminalWorkspace.filteredProjectID ?? terminalWorkspace.current?.projectID
        if let id { return projectStore?.projects.first { $0.id.uuidString == id } }
        return currentProject
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { projectStore = try ProjectStore(legacyDirectory: UserDefaults.standard.string(forKey: "projectDirectory")) }
        catch { projectStoreError = error.localizedDescription }
        NSApp.appearance = Theme.appearance
        if currentProject != nil { selected = 2 }
        makeMenu(); makeWindow(); refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, UserDefaults.standard.object(forKey: "autoRefresh") as? Bool != false else { return }
            self.refresh()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(didActivate), name: NSApplication.didBecomeActiveNotification, object: nil)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--screenshot-output"), i + 1 < args.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.capture(to: args[i + 1]) }
        }
    }
    @objc func didActivate() { if lastRefresh.map({ Date().timeIntervalSince($0) > 15 }) ?? true { refresh() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminalWorkspace.hasRunning || projectWorkspace.hasRunning || projectWorkspace.hasUnsavedChanges || operationWindows.contains(where: { $0.isRunning }) else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "退出工作台？"; alert.informativeText = "正在运行的任务将停止，未保存的文件修改将丢失。对话记录会保留。"; alert.addButton(withTitle: "返回工作台"); alert.addButton(withTitle: "退出")
        if alert.runModal() == .alertSecondButtonReturn { projectWorkspace.stopAll(); terminalWorkspace.stopAll(); operationWindows.forEach { $0.cancel(force: true) }; return .terminateNow }; return .terminateCancel
    }
    func makeMenu() {
        let main = NSMenu()
        let app = NSMenuItem(); let appMenu = NSMenu(); app.submenu = appMenu
        let about = NSMenuItem(title: "关于 CCAM Desktop", action: #selector(aboutApp), keyEquivalent: ""); about.target = self; appMenu.addItem(about)
        let management = NSMenuItem(title: "管理与设置…", action: #selector(managementMenu), keyEquivalent: ","); management.target = self; appMenu.addItem(management)
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "隐藏 CCAM Desktop", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 CCAM Desktop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); main.addItem(app)
        let edit = NSMenuItem(); let editMenu = NSMenu(title: "编辑"); edit.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"); main.addItem(edit)
        let view = NSMenuItem(); let viewMenu = NSMenu(title: "显示"); view.submenu = viewMenu
        let reload = NSMenuItem(title: "刷新", action: #selector(refreshMenu), keyEquivalent: "r"); reload.target = self; viewMenu.addItem(reload)
        viewMenu.addItem(.separator())
        let desktop = NSMenuItem(title: "桌面布局", action: #selector(desktopLayout), keyEquivalent: "1"); desktop.target = self; viewMenu.addItem(desktop)
        let compact = NSMenuItem(title: "紧凑布局", action: #selector(compactLayout), keyEquivalent: "2"); compact.target = self; viewMenu.addItem(compact)
        viewMenu.addItem(.separator())
        for (index, mode) in AppearanceMode.allCases.enumerated() {
            let item = NSMenuItem(title: mode.title, action: #selector(appearanceMenu(_:)), keyEquivalent: "")
            item.target = self; item.tag = 100 + index; item.state = mode == Theme.mode ? .on : .off; viewMenu.addItem(item)
        }
        main.addItem(view)
        NSApp.mainMenu = main
    }
    @objc func refreshMenu() { refresh(); render() }
    @objc func aboutApp() { let a = NSAlert(); a.messageText = "CCAM Desktop 2.1"; a.informativeText = "本地原生 macOS 工作台\n适配 CCAM 0.11.0\n第三方界面，与 CCAM / Anthropic 无隶属关系。"; a.beginSheetModal(for: window) }

    @objc func desktopLayout() { window.setContentSize(NSSize(width: 1240, height: 820)); window.center(); updateWindowLayout() }
    @objc func compactLayout() { window.setContentSize(NSSize(width: 390, height: 800)); window.center(); updateWindowLayout() }
    func windowDidResize(_ notification: Notification) { updateWindowLayout() }
    private func updateWindowLayout() {
        guard let window, sidebarWidth != nil else { return }
        let width = window.contentView?.bounds.width ?? 1240
        let shell = width < 780
        let compact = (width - (shell ? 32 : 272)) < 620
        sidebarWidth.constant = shell ? 0 : 224
        sidebarView.isHidden = shell
        mainLeading.constant = shell ? 16 : 24
        mainTrailing.constant = shell ? -16 : -24
        mainBottom.constant = shell ? -50 : 0
        compactManage.isHidden = !shell
        compactNavigation.isHidden = !shell
        compactShell = shell
        commandCenterHeight?.constant = max(380, (window.contentView?.bounds.height ?? 820) - 190)
        if compact != isCompact { isCompact = compact; if renderedPage >= 0 { render() } }
    }
    private func navigate(to index: Int) {
        selected = index
        if index == 2 { projectWorkspace.select(project: currentProject) }
        render()
    }
    private func navigationMenu() {
        let menu = NSMenu()
        let create = NSMenuItem(title: "新对话", action: #selector(newConversationMenu), keyEquivalent: "")
        create.target = self
        create.isEnabled = currentProject.map { projectWorkspace.runningCount(for: $0.id) == 0 } ?? true
        menu.addItem(create)
        for record in projectStore?.activeProjects ?? [] {
            let item = NSMenuItem(title: record.name, action: #selector(pickProject(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = record.id.uuidString
            item.state = currentProject?.id == record.id ? .on : .off
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil); menu.addItem(item)
        }
        let projects = NSMenuItem(title: "管理项目…", action: #selector(selectNavigation(_:)), keyEquivalent: "")
        projects.target = self; projects.tag = 0; menu.addItem(projects)
        if !projectWorkspace.historyItems.isEmpty {
            menu.addItem(.separator())
            for conversation in projectWorkspace.historyItems {
                let item = NSMenuItem(title: conversation.title.isEmpty ? "新对话" : conversation.title, action: #selector(selectSidebarConversation(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = conversation.id
                item.state = projectWorkspace.selectedConversationID == conversation.id ? .on : .off
                item.isEnabled = currentProject.map { projectWorkspace.runningCount(for: $0.id) == 0 } ?? false
                menu.addItem(item)
            }
        }
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: compactNavigation.bounds.height + 4), in: compactNavigation)
    }
    @objc private func newConversationMenu() { newSidebarConversation() }
    @objc private func selectSidebarConversation(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        projectWorkspace.selectConversation(id: id); selected = 2; render()
    }
    @objc private func selectNavigation(_ item: NSMenuItem) { navigate(to: item.tag) }
    private func updatePoolSummary() {
        let available = usage.filter { !$0.needsLogin && $0.error == nil && !$0.windows.isEmpty && $0.windows.allSatisfy { $0.used < 100 } }.count
        if refreshing && accounts.isEmpty { poolSummary.stringValue = "正在读取账号" }
        else if accountsError != nil || usageError != nil { poolSummary.stringValue = "账号状态待刷新" }
        else if accounts.isEmpty { poolSummary.stringValue = "添加账号后开始任务" }
        else { poolSummary.stringValue = "\(accounts.count) 个账号，\(available) 个额度可用" }
    }
    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "CCAM Desktop"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 390, height: 640); window.backgroundColor = Theme.background; window.delegate = self
        let root = ThemeSurface(Theme.background); window.contentView = root
        let side = ThemeSurface(Theme.sidebar); side.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(side); sidebarView = side
        workspaceSidebar = WorkspaceSidebar(frame: .zero); workspaceSidebar.translatesAutoresizingMaskIntoConstraints = false; side.addSubview(workspaceSidebar)
        workspaceSidebar.onNewConversation = { [weak self] in self?.newSidebarConversation() }
        workspaceSidebar.onAddProject = { [weak self] in self?.chooseProject() }
        workspaceSidebar.onProjects = { [weak self] in self?.navigate(to: 0) }
        workspaceSidebar.onHistory = { [weak self] in self?.navigate(to: 3) }
        workspaceSidebar.onProject = { [weak self] project in self?.showProjectWorkspace(project) }
        workspaceSidebar.onConversation = { [weak self] id in
            guard let self else { return }; self.projectWorkspace.selectConversation(id: id); self.selected = 2; self.render()
        }
        workspaceSidebar.onManage = { [weak self] sender in self?.showManagement(from: sender) }
        compactManage = SidebarItemButton("", symbol: "gearshape") { [weak self] in guard let self else { return }; self.showManagement(from: self.compactManage) }
        compactManage.setAccessibilityLabel("管理与设置"); compactManage.toolTip = "管理与设置"; compactManage.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(compactManage)
        let main = NSView(); main.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(main)
        projectButton.actionBlock = { [weak self] in self?.projectPicker() }
        projectButton.isBordered = false; projectButton.font = Theme.font(size: 14, weight: .medium)
        projectButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); projectButton.lineBreakMode = .byTruncatingMiddle
        compactNavigation = ClosureButton("", symbol: "sidebar.left") { [weak self] in self?.navigationMenu() }
        compactNavigation.isBordered = false; compactNavigation.setAccessibilityLabel("项目导航"); compactNavigation.toolTip = "项目导航"; compactNavigation.widthAnchor.constraint(equalToConstant: 32).isActive = true
        let context = row([compactNavigation, projectButton, spacer()], spacing: 6)
        let top = adaptiveRow([context, projectWorkspace.sectionControl], spacing: 12, breakpoint: 620)
        top.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(top)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(scroll); contentScroll = scroll
        projectWorkspace.translatesAutoresizingMaskIntoConstraints = false; projectWorkspace.isHidden = true; main.addSubview(projectWorkspace)
        projectWorkspace.onStateChange = { [weak self] in self?.updateSidebar() }
        projectWorkspace.onInteractiveTask = { [weak self] record, target in
            guard let self else { return }
            let plan = try GlobalPool.prepareChatTerminal(target: target)
            self.showTerminal(projectID: record.id.uuidString)
            self.terminalWorkspace.openPool(plan: plan, projectID: record.id.uuidString, projectName: record.name)
        }
        projectWorkspace.beforeChatStart = { [weak self] record, arguments in try self?.checkBrowserSettings(directory: record.path, arguments: arguments) }
        terminalWorkspace.onNewShell = { [weak self] in guard let self else { return }; self.openShell(self.terminalProject) }
        terminalWorkspace.onNewTask = { [weak self] in guard let self else { return }; if let record = self.terminalProject { self.startProject(record, continueLast: false) } else { self.chooseProject() } }
        terminalWorkspace.onFinished = { [weak self] in self?.refresh() }
        terminalWorkspace.beforeManagedStart = { [weak self] directory, args in try self?.checkBrowserSettings(directory: directory, arguments: args) }
        content = TopAlignedStack(); content.orientation = .vertical; content.alignment = .leading; content.distribution = .fill; content.spacing = 20; content.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 28, right: 0); content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        sidebarWidth = side.widthAnchor.constraint(equalToConstant: 224)
        mainLeading = main.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: 24)
        mainTrailing = main.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24)
        mainBottom = main.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor), side.topAnchor.constraint(equalTo: root.topAnchor), side.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebarWidth,
            workspaceSidebar.leadingAnchor.constraint(equalTo: side.leadingAnchor), workspaceSidebar.widthAnchor.constraint(equalToConstant: 224), workspaceSidebar.topAnchor.constraint(equalTo: side.topAnchor), workspaceSidebar.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            compactManage.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), compactManage.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10), compactManage.widthAnchor.constraint(equalToConstant: 36), compactManage.heightAnchor.constraint(equalToConstant: 36),
            mainLeading, mainTrailing, main.topAnchor.constraint(equalTo: root.topAnchor, constant: 36), mainBottom,
            top.topAnchor.constraint(equalTo: main.topAnchor), top.leadingAnchor.constraint(equalTo: main.leadingAnchor), top.trailingAnchor.constraint(equalTo: main.trailingAnchor), top.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 14), scroll.leadingAnchor.constraint(equalTo: main.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: main.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: main.bottomAnchor),
            projectWorkspace.topAnchor.constraint(equalTo: scroll.topAnchor), projectWorkspace.bottomAnchor.constraint(equalTo: scroll.bottomAnchor), projectWorkspace.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), projectWorkspace.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor), content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        projectWorkspace.select(project: currentProject)
        updateWindowLayout(); render(); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func updateSidebar() {
        workspaceSidebar?.update(records: projectStore?.activeProjects ?? [], currentID: currentProject?.id,
                                 items: projectWorkspace.historyItems, selectedID: projectWorkspace.selectedConversationID,
                                 running: currentProject.map { projectWorkspace.runningCount(for: $0.id) > 0 } ?? false)
    }
    private func newSidebarConversation() {
        guard let project = currentProject else { chooseProject(); return }
        showProjectWorkspace(project, newConversation: true)
    }
    @objc private func managementMenu() { showManagement(from: compactShell ? compactManage : workspaceSidebar.manageButton) }
    private func showManagement(from sender: NSView) {
        if managementPopover?.isShown == true { managementPopover?.close(); return }
        updatePoolSummary()
        let popover = NSPopover(); popover.behavior = .transient; popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let controller = NSViewController(); let surface = ThemeSurface(Theme.panel)
        controller.view = surface; popover.contentViewController = controller; managementPopover = popover
        controller.preferredContentSize = NSSize(width: 256, height: 330)
        NSLayoutConstraint.activate([surface.widthAnchor.constraint(equalToConstant: 256), surface.heightAnchor.constraint(equalToConstant: 330)])
        let stack = column([], spacing: 3)
        let status = label(poolSummary.stringValue, size: 11, color: Theme.muted)
        status.maximumNumberOfLines = 1; status.lineBreakMode = .byTruncatingTail; status.toolTip = status.stringValue
        let refresh = SidebarItemButton("", symbol: "arrow.clockwise") { [weak self] in self?.managementPopover?.close(); self?.refresh() }
        refresh.setAccessibilityLabel("刷新额度"); refresh.toolTip = "刷新额度"; refresh.widthAnchor.constraint(equalToConstant: 32).isActive = true
        fillWidth(row([status, spacer(), refresh], spacing: 4), in: stack)
        func item(_ title: String, _ symbol: String, _ action: @escaping () -> Void) {
            let button = SidebarItemButton(title, symbol: symbol) { [weak self] in self?.managementPopover?.close(); action() }
            fillWidth(button, in: stack)
        }
        item("账号与额度", "person.2") { [weak self] in self?.navigate(to: 1) }
        item("Chrome 账号锁", "lock") { [weak self] in self?.showBrowserLocks() }
        item("全部功能", "square.grid.2x2") { [weak self] in self?.navigate(to: 4) }
        item("后台会话", "clock") { [weak self] in self?.navigate(to: 3) }
        let line = ThemeSurface(Theme.border); line.heightAnchor.constraint(equalToConstant: 1).isActive = true; fillWidth(line, in: stack)
        let appearance = NSPopUpButton(); appearance.addItems(withTitles: AppearanceMode.allCases.map { $0.title })
        appearance.selectItem(at: AppearanceMode.allCases.firstIndex(of: Theme.mode) ?? 0)
        appearance.font = Theme.font(size: 12); appearance.isBordered = false; appearance.setAccessibilityLabel("外观")
        appearance.target = self; appearance.action = #selector(changeAppearance(_:))
        fillWidth(row([label("外观", size: 12, color: Theme.muted), spacer(), appearance]), in: stack)
        item("设置", "gearshape") { [weak self] in self?.navigate(to: 5) }
        item("关于 CCAM", "info.circle") { [weak self] in self?.aboutApp() }
        stack.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -10)])
        popover.contentSize = NSSize(width: 256, height: 330)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }
    func refresh() {
        guard !refreshing else { return }; refreshing = true; updatePoolSummary()
        let group = DispatchGroup()
        group.enter(); CCAMClient.read(["list", "--json"], directory: FileManager.default.homeDirectoryForCurrentUser.path) { [weak self] result in
            defer { group.leave() }; guard let self else { return }
            do {
                guard result.succeeded else { throw AppError.message(result.output) }
                self.accounts = try JSONDecoder().decode([Account]?.self, from: Data(result.output.utf8)) ?? []; self.accountsError = nil
                self.terminalWorkspace.accountNames = self.accounts.map { $0.name }
            } catch { self.accountsError = error.localizedDescription }
        }
        group.enter(); CCAMClient.read(["usage", "--json"], directory: FileManager.default.homeDirectoryForCurrentUser.path) { [weak self] result in
            defer { group.leave() }; guard let self else { return }
            do {
                guard result.succeeded else { throw AppError.message(result.output) }
                self.usage = try AccountUsage.parse(Data(result.output.utf8)); self.usageError = nil
            } catch { self.usageError = error.localizedDescription }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }; self.refreshing = false; self.lastRefresh = Date()
            self.updatePoolSummary()
            if self.selected == 0 || self.selected == 1 { self.render() }
        }
        if selected == 0 || selected == 1 { render() }
    }
    func render() {
        updatePoolSummary()
        let changedPage = renderedPage != selected
        renderedPage = selected
        defer {
            if changedPage {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let scroll = self.content.enclosingScrollView else { return }
                    self.content.layoutSubtreeIfNeeded()
                    let y = self.content.isFlipped ? 0 : max(0, self.content.bounds.height - scroll.contentView.bounds.height)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }
        projectButton.title = currentProject?.name ?? "添加项目…"
        generation += 1
        for view in content.arrangedSubviews { content.removeArrangedSubview(view); view.removeFromSuperview() }
        contentScroll.isHidden = selected == 2
        projectWorkspace.isHidden = selected != 2
        projectWorkspace.sectionControl.isHidden = selected != 2
        if selected == 2 { projectWorkspace.select(project: currentProject); updateSidebar(); return }
        updateSidebar()
        switch selected {
        case 0: projectsPage()
        case 1: dashboard()
        case 3:
            header("会话记录", "")
            if let currentProject {
                fillWidth(Card(row([label(currentProject.name, size: 16, weight: .semibold), spacer(), ClosureButton("继续项目任务", symbol: "play.fill") { [weak self] in self?.startProject(currentProject, continueLast: true) }])), in: content)
            }
            readPanel(["agents", "--all", "--json"], height: 330)
            addActions([Catalog.positional("连接后台会话", "按会话 ID 或名称连接到已有后台会话。", ["attach"], [Catalog.field("会话 ID / 名称", "id", "例如 49ec0028")], launch: true)])
        case 4: commandCenterPage()
        default: settingsPage()
        }
    }

    func header(_ title: String, _ subtitle: String, action: NSView? = nil) {
        fillWidth(row([label(title, size: isCompact ? 23 : 28, weight: .semibold), spacer()] + (action.map { [$0] } ?? [])), in: content)
        if !subtitle.isEmpty { fillWidth(label(subtitle, size: 12, color: Theme.muted), in: content) }
    }
    func dashboard() {
        header("账号与额度", "", action: ClosureButton("添加账号", symbol: "plus") { [weak self] in self?.addAccount() })
        let known = usage.filter { !$0.windows.isEmpty && !$0.needsLogin && $0.error == nil }.count
        fillWidth(adaptiveRow([label("\(known) 个账号已读取额度", size: 12, color: Theme.muted), spacer(), ClosureButton("Chrome 账号锁", symbol: "lock") { [weak self] in self?.showBrowserLocks() }]), in: content)
        if let error = accountsError ?? usageError { fillWidth(Card(label("读取提示：" + OperationPresentation.clean(error), size: 12, color: Theme.warning)), in: content) }
        if accounts.isEmpty { fillWidth(Card(column([label(refreshing ? "正在读取账号…" : "还没有账号", size: 20), label("添加或导入账号", color: Theme.muted)])), in: content) }
        for account in accounts { fillWidth(accountCard(account), in: content) }
    }
    func accountCard(_ account: Account) -> NSView {
        let info = usage.first { $0.name == account.name }
        let text = column([], spacing: 13)
        let title = row([label(account.name, size: 19, weight: .semibold)])

        title.addArrangedSubview(spacer()); title.addArrangedSubview(label(info?.statusText ?? "尚未读取", size: 11, color: info?.needsLogin == true ? Theme.warning : Theme.muted)); fillWidth(title, in: text)
        let identity = [account.email.flatMap { $0.isEmpty ? nil : $0 }, account.plan, account.groups?.joined(separator: ", ")].compactMap { $0 }.joined(separator: "  ·  ")
        fillWidth(label(identity.isEmpty ? "身份待同步" : identity, size: 11, color: Theme.muted), in: text)
        if let info, !info.windows.isEmpty {
            if let at = info.measuredAt { fillWidth(label((info.cached ? "缓存记录" : "数据记录") + "：" + resetText(at), size: 10, color: Theme.muted), in: text) }
            for window in info.windows {
                let progress = QuotaIndicator(); progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 100; progress.doubleValue = min(100, max(0, 100-window.used)); progress.style = .bar; progress.setAccessibilityLabel(window.label + "剩余额度"); progress.toolTip = String(format: "已用 %.0f%%", window.used)
                let amount = String(format: "剩余 %.0f%%", max(0, 100-window.used))
                fillWidth(row([label(window.label, size: 11, color: Theme.muted), spacer(), label(amount, size: 11, color: window.used >= 90 ? Theme.warning : Theme.accent)]), in: text)
                fillWidth(progress, in: text)
                if let reset = window.reset { fillWidth(label("重置：" + resetText(reset), size: 10, color: Theme.muted), in: text) }
            }
        } else {
            let missing: String
            if info?.status == "expired" { missing = "登录已过期，请重新登录" }
            else if info?.needsLogin == true { missing = "登录后读取额度" }
            else if info?.status == "api" { missing = "API 用量由服务商计费" }
            else { missing = "暂无额度数据" }
            fillWidth(label(missing, size: 12, color: Theme.muted), in: text)
        }
        if let error = info?.error { fillWidth(label(OperationPresentation.clean(error), size: 11, color: Theme.warning), in: text) }
        let actions = adaptiveRow([], spacing: 8, breakpoint: 440)
        actions.addArrangedSubview(ClosureButton("登录", symbol: "person.crop.circle.badge.checkmark") { [weak self] in guard let self else { return }; self.run(["login", account.name], directory: self.stableDirectory, title: "登录 " + account.name, detail: "在浏览器完成账号登录。") })
        let binding = try? BrowserLockStore().binding(account: account.name)
        let lockTitle = binding.map { $0.profile.displayName } ?? "Chrome 账号锁"
        actions.addArrangedSubview(ClosureButton(lockTitle, symbol: binding == nil ? "lock.open" : "lock.fill") { [weak self] in self?.showBrowserLocks(account: account.name) })
        actions.addArrangedSubview(spacer())
        actions.addArrangedSubview(ClosureButton("管理…", symbol: "ellipsis") { [weak self] in self?.accountMenu(account) })
        fillWidth(actions, in: text)
        return Card(text)
    }
    func resetText(_ text: String) -> String {
        let formatter = ISO8601DateFormatter()
        var date = formatter.date(from: text)
        if date == nil { formatter.formatOptions.insert(.withFractionalSeconds); date = formatter.date(from: text) }
        guard let date else { return text }
        return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }
    func addAccount() {
        present(ActionSpec(title: "添加账号", detail: "创建独立账号配置并在浏览器登录。默认加入 default 共享组。API 账号也可在功能中心创建。", command: ["add"], fields: [Catalog.field("账号名称", "account", "例如 work"), Catalog.field("快捷命令", "shortcut", "例如 ccwork", required: false)], build: { v in var a = ["add", v["account"]!]; if let s = v["shortcut"], !s.isEmpty { a += ["--shortcut", s] }; return a }))
    }
    func accountMenu(_ account: Account) {
        let name = account.name
        let items = [
            ActionSpec(title: "手动使用此账号继续", detail: "在当前项目目录打开该账号的最近对话。", command: [name, "--continue"], launchesClaude: true),
            ActionSpec(title: "选择历史会话", detail: "在内置终端打开 Claude Code 的会话选择器。", command: [name, "--resume"], launchesClaude: true),
            Catalog.positional("重命名账号", "修改账号名称；macOS 登录目录路径由 CCAM 保留。", ["rename", name], [Catalog.field("新名称", "new", "work")]),
            Catalog.positional("设置快捷命令", "创建或修改此账号的启动命令。", ["shortcut", name], [Catalog.field("快捷命令", "shortcut", "ccwork")]),
            ActionSpec(title: "删除快捷命令", detail: "移除启动链接，不移除账号。", command: ["shortcut", name, "--remove"]),
            ActionSpec(title: "查看共享来源", detail: "查看此账号共享哪些内容。", command: ["share", name]),
            ActionSpec(title: "查看账号扩展", detail: "查看此账号加载的扩展及问题。", command: ["ext", name]),
            ActionSpec(title: "退出登录", detail: "CCAM 会撤销登录，并清除此账号的 MCP 授权。运行中的会话也可能受影响。", command: ["logout", name]),
            ActionSpec(title: "移除账号", detail: "CCAM 先退出登录，再将账号目录移到自己的回收目录；导入账号按 CCAM 规则处理。", command: ["remove", name])
        ]
        let menu = NSMenu()
        for (index, spec) in items.enumerated() { let item = NSMenuItem(title: spec.title, action: #selector(menuAction(_:)), keyEquivalent: ""); item.target = self; item.representedObject = ActionBox(spec); item.tag = index; menu.addItem(item) }
        if let dir = account.dir { let item = NSMenuItem(title: "在 Finder 查看配置目录", action: #selector(revealFolder(_:)), keyEquivalent: ""); item.target = self; item.representedObject = dir; menu.addItem(item) }
        menu.popUp(positioning: nil, at: window.mouseLocationOutsideOfEventStream, in: window.contentView)
    }
    @objc func menuAction(_ sender: NSMenuItem) { if let box = sender.representedObject as? ActionBox { present(box.spec) } }
    @objc func revealFolder(_ sender: NSMenuItem) { if let path = sender.representedObject as? String { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } }
    func toolsPage(_ title: String, subtitle: String, read: [String], actions: [ActionSpec]) { header(title, subtitle); readPanel(read); addActions(actions) }
    func readPanel(_ args: [String], height: CGFloat = 185) {
        let panel = textArea("正在读取…", height: height); fillWidth(panel, in: content)
        let token = generation
        CCAMClient.read(args, directory: stableDirectory) { [weak self, weak panel] result in
            guard self?.generation == token, let text = panel?.documentView as? NSTextView else { return }
            let presentation = OperationPresentation()
            presentation.append(Array(result.output.utf8))
            text.string = result.output.isEmpty ? "暂无内容" : presentation.snapshot().text
            if !result.succeeded { text.textColor = Theme.warning }
        }
    }
    func addActions(_ specs: [ActionSpec]) {
        for spec in specs {
            let text = column([label(spec.title, size: 14, weight: .medium), label(spec.detail, size: 11, color: Theme.muted)], spacing: 6)
            let line = adaptiveRow([text, spacer(), ClosureButton("打开") { [weak self] in self?.present(spec) }])
            fillWidth(Card(line, padding: 15), in: content)
        }
    }
    func settingsPage() {
        header("设置", "")
        let settings = column([], spacing: 20)
        func addSetting(_ view: NSView) {
            if !settings.arrangedSubviews.isEmpty {
                let line = ThemeSurface(Theme.border); line.heightAnchor.constraint(equalToConstant: 1).isActive = true; fillWidth(line, in: settings)
            }
            fillWidth(view, in: settings)
        }
        let appearance = NSPopUpButton()
        appearance.addItems(withTitles: AppearanceMode.allCases.map { $0.title })
        appearance.selectItem(at: AppearanceMode.allCases.firstIndex(of: Theme.mode) ?? 0)
        appearance.target = self; appearance.action = #selector(changeAppearance(_:))
        appearance.setAccessibilityLabel("外观")
        appearance.font = Theme.font(size: 13)
        appearanceSelector = appearance
        addSetting(row([label("外观", size: 14), spacer(), appearance]))
        addSetting(row([label("Chrome 账号锁", size: 14), spacer(), ClosureButton("管理", symbol: "lock") { [weak self] in self?.showBrowserLocks() }]))
        let location = label(CCAMClient.executable, size: 11, color: Theme.muted)
        location.lineBreakMode = .byTruncatingMiddle
        addSetting(column([row([label("CCAM", size: 14), spacer(), ClosureButton("更换…") { [weak self] in
            guard let self else { return }; let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.showsHiddenFiles = true
            p.beginSheetModal(for: self.window) { response in
                guard response == .OK, let path = p.url?.path else { return }
                guard FileManager.default.isExecutableFile(atPath: path) else { showError("请选择可执行文件。", window: self.window); return }
                UserDefaults.standard.set(path, forKey: "ccamPath"); self.render(); self.refresh()
            }
        }]), location], spacing: 8))
        let toggle = NSButton(checkboxWithTitle: "每分钟刷新额度", target: self, action: #selector(toggleRefresh(_:)))
        toggle.state = UserDefaults.standard.object(forKey: "autoRefresh") as? Bool == false ? .off : .on
        addSetting(toggle)
        addSetting(row([label("本地数据", size: 14), spacer(), ClosureButton("详情") { [weak self] in
            guard let self else { return }
            let alert = NSAlert(); alert.messageText = "本地数据"
            alert.informativeText = "账号与凭据由 CCAM / Claude Code 管理。项目列表与浏览器锁保存在本机，不读取浏览器 Cookie。\n\n项目不绑定额度。自动续做保留项目目录与对话。开发终端和外部程序不受本应用登录锁控制。\n\n数据位置：" + ProjectStore.defaultURL.deletingLastPathComponent().path
            alert.beginSheetModal(for: self.window)
        }]))
        let version = label("CCAM Desktop 2.1", size: 12, color: Theme.muted)
        addSetting(version)
        fillWidth(settings, in: content)
    }
    @objc func changeAppearance(_ sender: NSPopUpButton) {
        guard AppearanceMode.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        Theme.select(AppearanceMode.allCases[sender.indexOfSelectedItem])
        updateAppearanceMenu()
    }
    @objc private func appearanceMenu(_ sender: NSMenuItem) {
        let index = sender.tag - 100
        guard AppearanceMode.allCases.indices.contains(index) else { return }
        Theme.select(AppearanceMode.allCases[index]); updateAppearanceMenu()
    }
    private func updateAppearanceMenu() {
        appearanceSelector?.selectItem(at: AppearanceMode.allCases.firstIndex(of: Theme.mode) ?? 0)
        for menu in NSApp.mainMenu?.items.compactMap({ $0.submenu }) ?? [] {
            for item in menu.items where (100..<103).contains(item.tag) {
                item.state = AppearanceMode.allCases[item.tag - 100] == Theme.mode ? .on : .off
            }
        }
    }
    @objc func toggleRefresh(_ sender: NSButton) { UserDefaults.standard.set(sender.state == .on, forKey: "autoRefresh") }
    func present(_ spec: ActionSpec) {
        forms.removeAll { $0.window?.isVisible != true }
        let names = accounts.map { $0.name }
        let groups = Array(Set(accounts.flatMap { $0.groups ?? [] })).sorted()
        let suggestions = spec.command.first == "add" ? [:] : ["account": names, "group": groups]
        let context = spec.launchesClaude ? currentProject : nil
        let directory = context?.path ?? stableDirectory
        let form = FormWindow(spec: spec, directory: directory, suggestions: suggestions, onConfigureLogin: { [weak self] name in self?.showBrowserLocks(account: name) }) { [weak self] args, launchesClaude, input in
            guard let self else { return }
            if launchesClaude { self.launchSession(args, directory: directory, context: context, title: spec.title) }
            else { self.run(args, initialInput: input, directory: directory, context: context, title: OperationLabels.title(spec), detail: OperationLabels.detail(spec)) }
        }
        forms.append(form); form.showWindow(nil)
    }
    func commandCenterPage() {
        header("功能中心", "")
        let center = commandCenter ?? CommandCenterView(frame: .zero)
        center.onRun = { [weak self] spec in self?.present(spec) }
        center.onLoginLock = { [weak self] in self?.showBrowserLocks() }
        if commandCenter == nil { commandCenterHeight = center.heightAnchor.constraint(equalToConstant: max(380, window.contentView!.bounds.height - 190)); commandCenterHeight?.isActive = true }
        fillWidth(center, in: content); commandCenter = center
    }
    func showTerminal(projectID: String? = nil) {
        if let projectID, let record = projectStore?.projects.first(where: { $0.id.uuidString == projectID && !$0.archived }), record.directoryExists {
            do { try projectStore?.select(id: record.id) } catch { showError(error.localizedDescription, window: window) }
        }
        terminalWorkspace.filter(projectID: projectID)
        terminalWorkspace.setScopeName(projectID.flatMap { id in projectStore?.projects.first { $0.id.uuidString == id }?.name })
        projectWorkspace.select(project: currentProject, section: .terminal)
        selected = 2; render(); window.makeKeyAndOrderFront(nil)
        terminalWorkspace.layoutSubtreeIfNeeded()
    }
    func run(_ args: [String], initialInput: String? = nil, directory: String? = nil, context: ProjectRecord? = nil, title: String = "处理操作", detail: String = "正在处理你的请求。") {
        var stagedRename: BrowserLock?
        do {
            try BrowserRouting.preflight(args)
            if args.first == "login" || (args.first == "add" && !args.contains("--api") && !args.contains("--no-login")) {
                try checkBrowserSettings(directory: directory ?? stableDirectory, account: BrowserRouting.explicitAccount(args))
            }
            if args.first == "rename", args.count == 3 {
                let store = try BrowserLockStore()
                if let old = store.binding(account: args[1]) {
                    guard store.binding(account: args[2]) == nil else { throw AppError.message("新账号名称已有登录锁，请先处理该锁。") }
                    // Stage the destination first: a failed disk write can never leave a renamed account unlocked.
                    try store.stageRename(old: args[1], new: args[2]); stagedRename = old
                }
            }
        } catch { showError(error.localizedDescription, window: window); return }
        operationWindows.removeAll { !$0.isRunning && $0.window?.isVisible != true }
        let account = BrowserRouting.explicitAccount(args)
        let operation = OperationWindow(title: title, detail: detail, args: args, directory: directory ?? stableDirectory, initialInput: initialInput, openLink: { url in
            if account != nil || BrowserRouting.isLoginLink(url) { try BrowserRouting.open(url: url, account: account) }
            else { NSWorkspace.shared.open(url) }
        }) { [weak self] succeeded in
            if let old = stagedRename {
                // An interrupted process may already have committed the rename.
                // Reconcile the actual account list; uncertain outcomes retain both locks.
                CCAMClient.read(["list", "--json"], directory: self?.stableDirectory ?? "/") { result in
                    guard result.succeeded, let data = result.output.data(using: .utf8), let rows = try? JSONDecoder().decode([Account].self, from: data) else { return }
                    let names = Set(rows.map { $0.name })
                    let cleanup = names.contains(args[2]) && !names.contains(old.account) ? old.account : (names.contains(old.account) && !names.contains(args[2]) ? args[2] : nil)
                    guard let cleanup else { return }
                    do { let store = try BrowserLockStore(); if store.binding(account: cleanup)?.profile == old.profile { try store.unlock(account: cleanup) } }
                    catch { showError("登录锁更新失败：" + error.localizedDescription, window: self?.window) }
                }
            }
            self?.refresh()
        }
        operationWindows.append(operation)
        operation.showWindow(nil)
    }
    func launchSession(_ args: [String], directory: String, context: ProjectRecord?, title: String) {
        showTerminal(projectID: context?.id.uuidString)
        terminalWorkspace.open(executable: CCAMClient.executable, args: args, directory: directory, title: title, projectID: context?.id.uuidString, projectName: context?.name)
    }
    func checkBrowserSettings(directory: String, arguments: [String] = [], account: String? = nil) throws {
        let store = try BrowserLockStore()
        guard !store.locks.isEmpty else { return }
        if let account, store.binding(account: account) == nil { return }
        if !arguments.isEmpty && accounts.isEmpty && refreshing { throw AppError.message("账号正在加载，请稍后重试。") }
        let environment = CCAMClient.environment
        guard let helper = environment["BROWSER"], URL(fileURLWithPath: helper).lastPathComponent == "CCAMBrowser", FileManager.default.isExecutableFile(atPath: helper) else { throw AppError.message("登录锁组件缺失，请重新打开完整应用。") }
        let paths = accounts.filter { record in
            account.map { record.name == $0 } ?? (store.binding(account: record.name) != nil)
        }.compactMap { $0.dir }
        let claudeArgs = arguments.firstIndex(of: "--").map { Array(arguments.suffix(from: $0 + 1)) } ?? arguments
        try BrowserSettingsGuard.validate(directory: directory, profileDirectories: paths, environment: environment, claudeArguments: claudeArgs)
    }
    func openShell(_ record: ProjectRecord? = nil) {
        let context = record ?? currentProject
        let directory = context?.path ?? project
        showTerminal(projectID: context?.id.uuidString)
        terminalWorkspace.open(executable: "/bin/zsh", args: ["-l"], directory: directory, title: "开发终端", projectID: context?.id.uuidString, projectName: context?.name)
    }
    func capture(to path: String) {
        guard let view = window.contentView else { return }; view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
    }
}

final class ActionBox: NSObject { let spec: ActionSpec; init(_ spec: ActionSpec) { self.spec = spec } }
