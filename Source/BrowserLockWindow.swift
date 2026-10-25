import AppKit

final class BrowserLockWindow: NSWindowController {
    private var store: BrowserLockStore
    private var profiles: [BrowserProfile] = []
    private let account = NSComboBox()
    private let browser = NSPopUpButton()
    private let profile = NSPopUpButton()
    private let status = label("未锁定", size: 12, color: Theme.muted)
    private let onChange: () -> Void
    private var browserPaths: [String] = []
    private var visibleProfiles: [BrowserProfile] = []
    private let browserNames = ["com.google.Chrome": "Google Chrome"]
    private var installedApplications: [String: String] {
        var result: [String: String] = [:]
        for (id, name) in browserNames { if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { result[url.path] = name } }
        return result
    }
    private func browserTitle(_ path: String) -> String {
        installedApplications[path] ?? profiles.first(where: { $0.appPath == path })?.browserName ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
    private var saveButton: ClosureButton!
    private var unlockButton: ClosureButton!

    init(accounts: [String], selected: String?, onChange: @escaping () -> Void) throws {
        store = try BrowserLockStore(); self.onChange = onChange
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.windowWidth(560), height: 400), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Chrome 账号锁"; window.backgroundColor = Theme.background; window.appearance = nil
        window.minSize = NSSize(width: 390, height: 400)
        super.init(window: window)
        account.addItems(withObjectValues: Array(Set(accounts + store.locks.map { $0.account })).sorted())
        account.stringValue = selected ?? accounts.first ?? ""; account.placeholderString = "选择或填写账号"
        account.font = Theme.font(size: 14); profile.font = Theme.font(size: 14)
        account.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        profile.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        profile.cell?.lineBreakMode = .byTruncatingTail
        account.setAccessibilityLabel("CCAM 账号"); profile.setAccessibilityLabel("Chrome 账号")
        account.target = self; account.action = #selector(accountChanged)
        NotificationCenter.default.addObserver(self, selector: #selector(accountChanged), name: NSComboBox.selectionDidChangeNotification, object: account)
        NotificationCenter.default.addObserver(self, selector: #selector(accountChanged), name: NSControl.textDidChangeNotification, object: account)
        browser.target = self; browser.action = #selector(browserChanged)
        profile.target = self; profile.action = #selector(selectionChanged)
        saveButton = ClosureButton("锁定", symbol: "lock.fill") { [weak self] in self?.save() }
        saveButton.bezelColor = Theme.accent; saveButton.contentTintColor = .white
        unlockButton = ClosureButton("解除锁定") { [weak self] in self?.unlock() }
        let help = ClosureButton("详情", symbol: "info.circle") { [weak self] in
            guard let self, let window = self.window else { return }
            let a = NSAlert(); a.messageText = "CCAM 账号 → Chrome 账号"
            a.informativeText = "这里的 Chrome 账号，是右上角头像菜单中的个人资料。登录始终在选定的个人资料中打开；缺失时不会换到其他资料。\n\n系统限制读取名称时，可手动选择 chrome://version 中“个人资料路径”对应的目录，再填头像菜单中的名称或邮箱。\n\n不读取 Cookie 或密码，不改变 Chrome 内已登录的 Google 账号。"
            a.beginSheetModal(for: window)
        }
        let body = column([], spacing: 14)
        fillWidth(row([label("Chrome 账号锁", size: 21, weight: .semibold), spacer(), help]), in: body)
        let fields = column([], spacing: 16)
        for (title, control) in [("CCAM 账号", account as NSView), ("Chrome 账号", profile as NSView)] {
            let field = column([label(title, size: 12, color: Theme.muted, weight: .medium)], spacing: 6)
            fillWidth(control, in: field); control.heightAnchor.constraint(equalToConstant: 32).isActive = true
            fillWidth(field, in: fields)
        }
        fillWidth(status, in: fields)
        fillWidth(Card(fields, padding: 18), in: body)
        fillWidth(row([ClosureButton("手动添加…", symbol: "plus") { [weak self] in self?.chooseManual() }, ClosureButton("刷新", symbol: "arrow.clockwise") { [weak self] in self?.reload() }, spacer()]), in: body)
        fillWidth(row([unlockButton, spacer(), saveButton]), in: body)
        let container = NSView(); body.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(body)
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20), body.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20), body.topAnchor.constraint(equalTo: container.topAnchor, constant: 22), body.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -22)])
        window.contentView = container; window.center()
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    private var accountName: String { account.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func reload() {
        do {
            store = try BrowserLockStore()
            profiles = try BrowserProfileDiscovery.discover(allowedBundleIDs: ["com.google.Chrome"])
            for saved in store.registeredProfiles.filter({ $0.bundleID == "com.google.Chrome" }) {
                if saved.manualSelection == true { profiles.removeAll { $0.id == saved.id }; profiles.append(saved) }
                else if !profiles.contains(where: { $0.id == saved.id }) { profiles.append(saved) }
            }
            rebuildBrowsers()
            restoreSelection()
        } catch {
            profiles = store.registeredProfiles.filter { $0.bundleID == "com.google.Chrome" }
            rebuildBrowsers(selecting: store.binding(account: accountName)?.profile)
            if store.binding(account: accountName)?.profile.manualSelection != true && !profiles.contains(where: { $0.manualSelection == true }) {
                status.stringValue = "无法读取 Chrome 账号，可手动添加"; status.toolTip = error.localizedDescription; status.textColor = Theme.warning
            } else { showStatus() }
            saveButton.isEnabled = !accountName.isEmpty && !visibleProfiles.isEmpty
            unlockButton.isEnabled = store.binding(account: accountName) != nil
        }
    }
    private func rebuildBrowsers(selecting chosen: BrowserProfile? = nil) {
        browserPaths = Array(Set(profiles.map { $0.appPath } + Array(installedApplications.keys))).sorted(); browser.removeAllItems()
        for path in browserPaths { browser.addItem(withTitle: browserTitle(path)) }
        if let chosen, let i = browserPaths.firstIndex(of: chosen.appPath) { browser.selectItem(at: i) }
        rebuildProfiles()
        if let chosen, let i = visibleProfiles.firstIndex(where: { $0.id == chosen.id }) { profile.selectItem(at: i) }
        showStatus()
    }
    private func chooseManual() {
        guard let window else { return }
        guard browserPaths.indices.contains(browser.indexOfSelectedItem) else { showError("请先安装受支持的浏览器。", window: window); return }
        let application = URL(fileURLWithPath: browserPaths[browser.indexOfSelectedItem])
        let folder = NSOpenPanel(); folder.title = "选择 Chrome 个人资料"; folder.message = "选择 chrome://version 中“个人资料路径”对应的目录"
        folder.canChooseFiles = false; folder.canChooseDirectories = true; folder.canCreateDirectories = false; folder.showsHiddenFiles = true; folder.prompt = "选择"
        let locations = ["com.google.Chrome": "Google/Chrome", "com.microsoft.edgemac": "Microsoft Edge", "com.brave.Browser": "BraveSoftware/Brave-Browser", "org.chromium.Chromium": "Chromium"]
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        folder.directoryURL = Bundle(url: application)?.bundleIdentifier.flatMap { locations[$0] }.map { root.appendingPathComponent($0) } ?? root
        folder.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let directory = folder.url else { return }
            let access = directory.startAccessingSecurityScopedResource(); defer { if access { directory.stopAccessingSecurityScopedResource() } }
            do {
                let selected = try BrowserProfileDiscovery.manualProfile(app: application, directory: directory)
                DispatchQueue.main.async { [weak self] in self?.nameProfile(selected) }
            } catch { showError(error.localizedDescription, window: self.window) }
        }
    }
    private func nameProfile(_ selected: BrowserProfile) {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "Chrome 账号名称"; alert.informativeText = "填写头像菜单中的名称或邮箱，仅作显示。"
        let input = NSTextField(string: selected.displayName); input.frame = NSRect(x: 0, y: 0, width: 250, height: 30); alert.accessoryView = input
        alert.addButton(withTitle: "添加"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let named = BrowserProfile(id: selected.id, browserName: selected.browserName, bundleID: selected.bundleID, appPath: selected.appPath, userDataDirectory: selected.userDataDirectory, profileDirectory: selected.profileDirectory, displayName: name, identityHint: nil, manualSelection: true)
            do { try self.store.register(profile: named) }
            catch { showError(error.localizedDescription, window: self.window); return }
            self.profiles.removeAll { $0.id == named.id }; self.profiles.append(named)
            self.rebuildBrowsers(selecting: named)
            self.status.stringValue = "待锁定：" + named.displayName
            self.status.toolTip = named.userDataDirectory + "/" + named.profileDirectory
        }
    }
    @objc private func accountChanged() {
        DispatchQueue.main.async { [weak self] in self?.refreshBinding() }
    }
    @objc private func refreshBinding() {
        do { store = try BrowserLockStore(); restoreSelection() }
        catch { status.stringValue = error.localizedDescription; status.textColor = Theme.warning; saveButton.isEnabled = false; unlockButton.isEnabled = false }
    }
    private func restoreSelection() {
        if let binding = store.binding(account: accountName), let index = browserPaths.firstIndex(of: binding.profile.appPath) { browser.selectItem(at: index) }
        rebuildProfiles()
        if let binding = store.binding(account: accountName), let index = visibleProfiles.firstIndex(where: { $0.id == binding.profile.id }) { profile.selectItem(at: index) }
        showStatus()
    }
    @objc private func browserChanged() { rebuildProfiles(); showStatus() }
    @objc private func selectionChanged() { showStatus() }
    private func rebuildProfiles() {
        let selected = browser.indexOfSelectedItem
        visibleProfiles = browserPaths.indices.contains(selected) ? profiles.filter { $0.appPath == browserPaths[selected] } : []
        profile.removeAllItems()
        for p in visibleProfiles { profile.addItem(withTitle: p.displayName + (p.identityHint.map { " · " + $0 } ?? "")) }
    }
    private func showStatus() {
        saveButton.isEnabled = !accountName.isEmpty && visibleProfiles.indices.contains(profile.indexOfSelectedItem)
        unlockButton.isEnabled = store.binding(account: accountName) != nil
        status.textColor = Theme.muted; status.toolTip = nil
        if let binding = store.binding(account: accountName) {
            do { try BrowserLockStore.validate(profile: binding.profile); status.stringValue = "已锁定：" + binding.profile.displayName; status.textColor = Theme.success }
            catch { status.stringValue = "Chrome 个人资料不可用"; status.textColor = Theme.warning }
        } else { status.stringValue = profiles.isEmpty ? "添加 Chrome 个人资料" : "未锁定" }
    }
    private func save() {
        guard visibleProfiles.indices.contains(profile.indexOfSelectedItem) else { return }
        do {
            try store.lock(account: accountName, profile: visibleProfiles[profile.indexOfSelectedItem])
            onChange(); showStatus()
        } catch { showError(error.localizedDescription, window: window) }
    }
    private func unlock() {
        do { try store.unlock(account: accountName); onChange(); showStatus() }
        catch { showError(error.localizedDescription, window: window) }
    }
}

extension AppDelegate {
    func showBrowserLocks(account: String? = nil) {
        do {
            browserLockWindows.removeAll { $0.window?.isVisible != true }
            let controller = try BrowserLockWindow(accounts: accounts.map { $0.name }, selected: account) { [weak self] in self?.render() }
            browserLockWindows.append(controller); controller.showWindow(nil)
        } catch { showError(error.localizedDescription, window: window) }
    }
}
