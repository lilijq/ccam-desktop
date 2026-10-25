import AppKit

extension AppDelegate {
    func projectsPage() {
        if let error = projectStoreError {
            header("项目", "")
            fillWidth(column([label("项目列表读取失败", size: 17, color: Theme.warning, weight: .semibold), label(error, size: 13, color: Theme.muted), label("原文件已保留。修复后重新打开应用。", size: 12, color: Theme.muted)]), in: content)
            return
        }
        let active = projectStore?.activeProjects ?? []
        let archived = projectStore?.archivedProjects ?? []
        if active.isEmpty && (!showArchivedProjects || archived.isEmpty) {
            func centered(_ view: NSView) -> NSView {
                let left = spacer(), right = spacer()
                let line = row([left, view, right])
                left.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
                return line
            }
            let canvas = NSView()
            let title = label("从一个项目开始", size: 30, weight: .medium); title.alignment = .center
            let hint = label("选择文件夹，开始对话。", size: 14, color: Theme.muted); hint.alignment = .center
            let add = ClosureButton("选择文件夹", symbol: "folder.badge.plus") { [weak self] in self?.chooseProject() }
            add.bezelColor = Theme.primary; add.contentTintColor = Theme.onPrimary
            add.heightAnchor.constraint(equalToConstant: 40).isActive = true
            let body = column([], spacing: 14)
            for view in [title, hint, centered(add)] { fillWidth(view, in: body) }
            body.setCustomSpacing(24, after: hint)
            if !archived.isEmpty {
                let restore = ClosureButton("查看已归档项目") { [weak self] in self?.showArchivedProjects = true; self?.render() }
                restore.isBordered = false
                fillWidth(centered(restore), in: body)
            }
            body.translatesAutoresizingMaskIntoConstraints = false; canvas.addSubview(body)
            fillWidth(canvas, in: content)
            let height = canvas.heightAnchor.constraint(equalTo: contentScroll.contentView.heightAnchor, constant: -40)
            height.priority = .init(490)
            let width = body.widthAnchor.constraint(equalToConstant: 480); width.priority = .init(490)
            NSLayoutConstraint.activate([
                height, width, canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
                body.centerXAnchor.constraint(equalTo: canvas.centerXAnchor), body.centerYAnchor.constraint(equalTo: canvas.centerYAnchor, constant: -24),
                body.leadingAnchor.constraint(greaterThanOrEqualTo: canvas.leadingAnchor, constant: 16), body.trailingAnchor.constraint(lessThanOrEqualTo: canvas.trailingAnchor, constant: -16)
            ])
            return
        }
        header("项目", "", action: ClosureButton("添加项目", symbol: "plus") { [weak self] in self?.chooseProject() })
        let archiveToggle = NSButton(checkboxWithTitle: "显示已归档", target: self, action: #selector(toggleArchived(_:)))
        archiveToggle.state = showArchivedProjects ? .on : .off; archiveToggle.font = Theme.font(size: 12)
        fillWidth(row([spacer(), archiveToggle]), in: content)
        let records = active + (showArchivedProjects ? archived : [])
        let list = column([], spacing: 18)
        for (index, record) in records.enumerated() {
            if index > 0 {
                let divider = ThemeSurface(Theme.border); divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
                fillWidth(divider, in: list)
            }
            fillWidth(projectListRow(record), in: list)
        }
        fillWidth(list, in: content)
    }
    private func projectPathLabel(_ path: String, size: CGFloat) -> NSTextField {
        let field = label(path, size: size, color: Theme.muted)
        field.maximumNumberOfLines = 1; field.lineBreakMode = .byTruncatingMiddle; field.toolTip = path
        return field
    }
    private func projectListRow(_ record: ProjectRecord) -> NSView {
        let title = row([label(record.name, size: 15, weight: .semibold)], spacing: 8)
        if record.archived { title.addArrangedSubview(label("已归档", size: 11, color: Theme.muted)) }
        else if record.id == currentProject?.id { title.addArrangedSubview(label("当前", size: 11, color: Theme.accent)) }
        title.addArrangedSubview(spacer())
        let info = column([], spacing: 5)
        fillWidth(title, in: info); fillWidth(projectPathLabel(record.path, size: 11), in: info)
        let running = terminalWorkspace.runningCount(for: record.id.uuidString) + projectWorkspace.runningCount(for: record.id)
        if running > 0 { fillWidth(label("\(running) 个任务进行中", size: 11, color: Theme.success), in: info) }
        info.setContentHuggingPriority(.defaultLow, for: .horizontal)
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tools = row([], spacing: 7)
        if record.archived {
            tools.addArrangedSubview(ClosureButton("恢复项目", symbol: "arrow.uturn.backward") { [weak self] in self?.archiveProject(record, archived: false) })
        } else {
            tools.addArrangedSubview(ClosureButton("打开项目") { [weak self] in self?.showProjectWorkspace(record) })
        }
        let more = ClosureButton("", symbol: "ellipsis") {}
        more.setAccessibilityLabel("项目操作：" + record.name); more.toolTip = "项目操作"
        more.actionBlock = { [weak self, weak more] in guard let more else { return }; self?.projectActionsMenu(record, sender: more) }
        tools.addArrangedSubview(more)
        if isCompact {
            let result = column([], spacing: 10)
            fillWidth(info, in: result); fillWidth(row([tools, spacer()]), in: result)
            return result
        }
        return row([info, tools], spacing: 18)
    }
    private func projectActionsMenu(_ record: ProjectRecord, sender: NSView) {
        let menu = NSMenu()
        var actions: [(String, Int)] = []
        if !record.archived {
            actions += [("新对话", 3), ("查看文件", 4), ("查看 Git", 5), ("开发终端", 6), ("继续终端任务", 7), ("新建终端任务", 8)]
        }
        actions += [("在 Finder 中打开", 0), ("重命名项目", 1), (record.archived ? "恢复项目" : "归档项目", 2)]
        for (title, tag) in actions {
            let item = NSMenuItem(title: title, action: #selector(projectMenuAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = record.id.uuidString; item.tag = tag; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
    @objc private func projectMenuAction(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let record = projectStore?.projects.first(where: { $0.id.uuidString == id }) else { return }
        switch item.tag {
        case 0: NSWorkspace.shared.open(URL(fileURLWithPath: record.path))
        case 1: renameProject(record)
        case 2: archiveProject(record, archived: !record.archived)
        case 3: showProjectWorkspace(record, newConversation: true)
        case 4: showProjectWorkspace(record, section: .files)
        case 5: showProjectWorkspace(record, section: .git)
        case 6: openShell(record)
        case 7: startProject(record, continueLast: true)
        case 8: startProject(record, continueLast: false)
        default: break
        }
    }
    @objc func toggleArchived(_ sender: NSButton) { showArchivedProjects = sender.state == .on; render() }
    func chooseProject() {
        guard projectStore != nil else { showError(projectStoreError ?? "项目列表尚未准备好。", window: window); return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "选择项目文件夹"; panel.prompt = "添加项目"
        panel.directoryURL = URL(fileURLWithPath: project)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { if let record = try self.projectStore?.add(directory: url.path) { self.showProjectWorkspace(record) } }
            catch { showError(error.localizedDescription, window: self.window) }
        }
    }
    func selectProject(_ record: ProjectRecord) { showProjectWorkspace(record) }
    func renameProject(_ record: ProjectRecord) {
        let alert = NSAlert(); alert.messageText = "重命名项目"; alert.informativeText = "仅修改显示名称，文件夹名称不变。"
        let input = NSTextField(string: record.name); input.frame = NSRect(x: 0, y: 0, width: 340, height: 28); alert.accessoryView = input
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do { try self.projectStore?.rename(id: record.id, name: input.stringValue); self.render() }
            catch { showError(error.localizedDescription, window: self.window) }
        }
    }
    func archiveProject(_ record: ProjectRecord, archived: Bool) {
        do { try projectStore?.setArchived(id: record.id, archived: archived); render() }
        catch { showError(error.localizedDescription, window: window) }
    }
    func projectPicker() {
        let menu = NSMenu()
        for record in projectStore?.activeProjects ?? [] {
            let item = NSMenuItem(title: record.name, action: #selector(pickProject(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = record.id.uuidString; item.state = record.id == currentProject?.id ? .on : .off; menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let add = NSMenuItem(title: "添加项目…", action: #selector(addProjectMenu), keyEquivalent: ""); add.target = self; menu.addItem(add)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: projectButton.bounds.height + 4), in: projectButton)
    }
    @objc func addProjectMenu() { chooseProject() }
    @objc func pickProject(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let record = projectStore?.projects.first(where: { $0.id.uuidString == id }) else { return }
        selectProject(record)
    }
    func startProject(_ record: ProjectRecord, continueLast: Bool) {
        if !continueLast {
            taskComposers.removeAll { $0.window?.isVisible != true }
            let composer = TaskComposer(project: record) { [weak self] task in try self?.launchProjectTask(record, continueLast: false, initialPrompt: task) }
            taskComposers.append(composer); composer.showWindow(nil)
            return
        }
        do { try launchProjectTask(record, continueLast: true, initialPrompt: nil) }
        catch { showError(OperationPresentation.clean(error.localizedDescription), window: window) }
    }
    func showProjectWorkspace(_ record: ProjectRecord, section: ProjectWorkspace.Section? = nil, newConversation: Bool = false) {
        do { try projectStore?.select(id: record.id) }
        catch { showError(error.localizedDescription, window: window); return }
        terminalWorkspace.filter(projectID: record.id.uuidString)
        terminalWorkspace.setScopeName(record.name)
        projectWorkspace.select(project: record, section: section)
        selected = 2; render()
        if newConversation { projectWorkspace.newConversation() }
        projectWorkspace.focusInput()
    }
    func launchProjectTask(_ record: ProjectRecord, continueLast: Bool, initialPrompt: String?) throws {
            try projectStore?.select(id: record.id)
            let plan = try GlobalPool.prepare(directory: record.path, continueLast: continueLast, initialPrompt: initialPrompt)
            showTerminal(projectID: record.id.uuidString)
            terminalWorkspace.openPool(plan: plan, projectID: record.id.uuidString, projectName: record.name)
    }
}
