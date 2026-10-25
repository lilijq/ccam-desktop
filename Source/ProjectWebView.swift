import AppKit
import WebKit
import Network

struct WebSavedTab: Codable { var id: String; var title: String; var url: String? }
struct WebSavedSession: Codable { var tabs: [WebSavedTab]; var selected: String; var controlEnabled: Bool }

enum WebAddress {
    static func parse(_ input: String) throws -> URL {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 8192, !text.contains(where: { $0.isNewline }) else { throw WebMCP.failure("请输入有效的网址。") }
        if !text.contains("://") {
            if text.contains(":"), !text.hasPrefix("localhost:"), !text.hasPrefix("127.0.0.1:"), !text.hasPrefix("[::1]:") {
                // A bare host:port is allowed; javascript:, data:, file: are not.
                let suffix = text.split(separator: ":", maxSplits: 1).last?.split(separator: "/").first ?? ""
                guard Int(suffix) != nil else { throw WebMCP.failure("仅支持 HTTP 和 HTTPS 网页。") }
            }
            let local = text == "localhost" || text.hasPrefix("localhost:") || text.hasPrefix("localhost/") || text.hasPrefix("127.0.0.1") || text.hasPrefix("[::1]")
            text = (local ? "http://" : "https://") + text
        }
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.port == nil || (1...65535).contains(url.port!) else { throw WebMCP.failure("请输入 HTTP 或 HTTPS 网址，不要在网址中包含密码。") }
        return url
    }
    static func isLocal(_ url: URL) -> Bool { ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "") }
}

/// One project, one browser data store, one authenticated MCP endpoint. UI and
/// tools operate on the exact same WKWebViews; switching panes never clones them.
final class ProjectWebView: NSView, WKNavigationDelegate, WKUIDelegate {
    private final class Tab {
        let id: String
        let web: WKWebView
        var savedURL: String?
        var title: String
        var loaded = false
        var observers: [NSKeyValueObservation] = []
        var pending: ((Result<Void, Error>) -> Void)?
        var navigationSerial = 0
        var policyEpoch = 0
        var snapshotToken: String?
        init(id: String = UUID().uuidString, web: WKWebView, title: String = "新标签", url: String? = nil) {
            self.id = id; self.web = web; self.title = title; savedURL = url
        }
    }
    let project: ProjectRecord
    private let sessionURL: URL
    private let dataStore: WKWebsiteDataStore
    private var tabs: [Tab] = []
    private var selected = ""
    private let address = NSTextField()
    private let tabsRow = NSStackView()
    private let tabsScroll = NSScrollView()
    private let viewport = ThemeSurface(Theme.background)
    private let emptyTitle = label("打开网页", size: 22, weight: .medium)
    private let emptyDetail = label("输入网址，或让 Claude 打开项目页面。", size: 13, color: Theme.muted)
    private lazy var empty = column([emptyTitle, emptyDetail], spacing: 10)
    private let back = WorkspacePaneButton(symbol: "chevron.left", title: "网页后退")
    private let forward = WorkspacePaneButton(symbol: "chevron.right", title: "网页前进")
    private let reload = WorkspacePaneButton(symbol: "arrow.clockwise", title: "刷新网页")
    private let proxyButton = NSButton(title: "代理", target: nil, action: nil)
    private let control = NSButton(title: "Claude", target: nil, action: nil)
    private let status = label("", size: 12, color: Theme.muted)
    private let progress = NSProgressIndicator()
    private var bridge: WebMCPBridge?
    private var defaultsObserver: NSObjectProtocol?
    private let resolveProxy: () throws -> ExecutionProxy.State
    private var endpoint: String?
    private var proxyError: String?
    private(set) var controlEnabled = true
    var onConfigureProxy: (() -> Void)?
    var onReveal: (() -> Void)?
    private var current: Tab? { tabs.first { $0.id == selected } }
    var currentWebView: WKWebView? { current?.web }
    var tabCount: Int { tabs.count }
    var selectedTabID: String { selected }
    var configuredProxy: String? { endpoint }

    init(project: ProjectRecord, sessionURL: URL? = nil, persistent: Bool = true,
         resolveProxy: @escaping () throws -> ExecutionProxy.State = { try ExecutionProxy.resolve(environment: CCAMClient.environment) }) {
        self.project = project; self.resolveProxy = resolveProxy
        self.sessionURL = sessionURL ?? ProjectStore.defaultURL.deletingLastPathComponent().appendingPathComponent("web").appendingPathComponent(project.id.uuidString + ".json")
        if #available(macOS 14.0, *), persistent { dataStore = WKWebsiteDataStore(forIdentifier: project.id) }
        else { dataStore = .nonPersistent() }
        super.init(frame: .zero)
        setAccessibilityLabel("项目网页")
        buildUI(); updateProxy()
        if let data = try? Data(contentsOf: self.sessionURL), data.count < 100_000,
           let saved = try? JSONDecoder().decode(WebSavedSession.self, from: data), saved.tabs.count <= 8,
           Set(saved.tabs.map(\.id)).count == saved.tabs.count {
            controlEnabled = saved.controlEnabled
            for tab in saved.tabs where UUID(uuidString: tab.id) != nil {
                let url = tab.url.flatMap { try? WebAddress.parse($0).absoluteString }
                _ = addTab(id: tab.id, title: String(tab.title.prefix(120)), url: url, save: false)
            }
            if tabs.contains(where: { $0.id == saved.selected }) { selected = saved.selected }
        }
        if tabs.isEmpty { _ = addTab(save: false) }
        showSelected(); updateControl()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.updateProxy() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }; bridge?.stop() }

    private func buildUI() {
        let newTab = WorkspacePaneButton(symbol: "plus", title: "新建网页标签")
        newTab.invoke = { [weak self] in self?.newTab() }
        tabsRow.orientation = .horizontal; tabsRow.spacing = 3; tabsRow.alignment = .centerY
        tabsScroll.drawsBackground = false; tabsScroll.hasHorizontalScroller = true; tabsScroll.scrollerStyle = .overlay
        tabsScroll.documentView = tabsRow
        tabsRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([tabsRow.leadingAnchor.constraint(equalTo: tabsScroll.contentView.leadingAnchor), tabsRow.topAnchor.constraint(equalTo: tabsScroll.contentView.topAnchor), tabsRow.heightAnchor.constraint(equalToConstant: 32)])
        let tabBar = row([tabsScroll, newTab], spacing: 4)
        tabsScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        address.font = Theme.font(size: 13); address.placeholderString = "网址或 localhost:3000"; address.isBezeled = false
        address.drawsBackground = true; address.backgroundColor = Theme.panel; address.textColor = Theme.text
        address.focusRingType = .exterior; address.target = self; address.action = #selector(openAddress)
        address.setAccessibilityLabel("网页地址"); address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        address.lineBreakMode = .byTruncatingMiddle
        let more = WorkspacePaneButton(symbol: "ellipsis", title: "网页更多操作")
        more.invoke = { [weak self, weak more] in guard let more else { return }; self?.showMenu(more) }
        back.invoke = { [weak self] in self?.history(back: true) }; forward.invoke = { [weak self] in self?.history(back: false) }
        reload.invoke = { [weak self] in self?.reloadPage() }
        let navigation = row([back, forward, reload, address, more], spacing: 4)
        proxyButton.isBordered = false; proxyButton.font = Theme.font(size: 12); proxyButton.contentTintColor = Theme.muted
        proxyButton.target = self; proxyButton.action = #selector(configureProxy); proxyButton.setAccessibilityLabel("网页共享代理设置")
        proxyButton.setContentHuggingPriority(.required, for: .horizontal)
        control.isBordered = false; control.font = Theme.font(size: 12); control.target = self; control.action = #selector(toggleControl)
        control.setContentHuggingPriority(.required, for: .horizontal)
        status.lineBreakMode = .byTruncatingTail; status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stateRow = row([proxyButton, status, spacer(), control], spacing: 8)
        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1; progress.style = .bar; progress.isHidden = true
        for view in [tabBar, navigation, stateRow, progress, viewport] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        empty.translatesAutoresizingMaskIntoConstraints = false; viewport.addSubview(empty)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor, constant: 4), tabBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), tabBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), tabBar.heightAnchor.constraint(equalToConstant: 32),
            navigation.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 4), navigation.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), navigation.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), navigation.heightAnchor.constraint(equalToConstant: 36), address.heightAnchor.constraint(equalToConstant: 26),
            stateRow.topAnchor.constraint(equalTo: navigation.bottomAnchor, constant: 2), stateRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), stateRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), stateRow.heightAnchor.constraint(equalToConstant: 26),
            progress.topAnchor.constraint(equalTo: stateRow.bottomAnchor), progress.leadingAnchor.constraint(equalTo: leadingAnchor), progress.trailingAnchor.constraint(equalTo: trailingAnchor), progress.heightAnchor.constraint(equalToConstant: 2),
            viewport.topAnchor.constraint(equalTo: progress.bottomAnchor), viewport.leadingAnchor.constraint(equalTo: leadingAnchor), viewport.trailingAnchor.constraint(equalTo: trailingAnchor), viewport.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: viewport.centerXAnchor), empty.centerYAnchor.constraint(equalTo: viewport.centerYAnchor), empty.leadingAnchor.constraint(greaterThanOrEqualTo: viewport.leadingAnchor, constant: 20), empty.trailingAnchor.constraint(lessThanOrEqualTo: viewport.trailingAnchor, constant: -20)
        ])
    }
    @discardableResult private func addTab(id: String = UUID().uuidString, title: String = "新标签", url: String? = nil, save: Bool = true) -> Tab {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self; web.uiDelegate = self; web.allowsBackForwardNavigationGestures = true
        web.setAccessibilityLabel("网页内容")
        let tab = Tab(id: id, web: web, title: title, url: url)
        tab.observers = [web.observe(\.estimatedProgress) { [weak self] _, _ in self?.updateNavigation() },
                         web.observe(\.isLoading) { [weak self] _, _ in self?.updateNavigation() },
                         web.observe(\.title) { [weak self, weak tab] web, _ in
            guard let self, let tab else { return }; tab.title = String((web.title?.isEmpty == false ? web.title! : "网页").prefix(120)); self.rebuildTabs()
        }]
        tabs.append(tab); selected = id
        if save { persist() }; return tab
    }
    func newTab() {
        guard tabs.count < 8 else { showError("最多打开 8 个标签，请先关闭一个。"); return }
        _ = addTab(); showSelected(); focus()
    }
    func focus() { window?.makeFirstResponder(address) }
    private func rebuildTabs() {
        tabsRow.arrangedSubviews.forEach { tabsRow.removeArrangedSubview($0); $0.removeFromSuperview() }
        for tab in tabs {
            let button = NSButton(title: tab.title, target: nil, action: nil)
            button.isBordered = false; button.font = Theme.font(size: 12, weight: tab.id == selected ? .medium : .regular)
            button.contentTintColor = tab.id == selected ? Theme.text : Theme.muted
            button.lineBreakMode = .byTruncatingTail; button.toolTip = tab.savedURL ?? tab.title
            button.setAccessibilityLabel("网页标签：" + tab.title)
            let close = WorkspacePaneButton(symbol: "xmark", title: "关闭网页标签：" + tab.title)
            close.invoke = { [weak self] in self?.closeTab(tab.id) }
            let action = WebTabAction { [weak self] in self?.selectTab(tab.id) }; button.target = action; button.action = #selector(WebTabAction.clicked)
            // NSControl targets are weak; the container owns the action object.
            let container = WebTabSurface(action: action, selected: tab.id == selected)
            let contents = row([button, close], spacing: 0); contents.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(contents)
            NSLayoutConstraint.activate([contents.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8), contents.trailingAnchor.constraint(equalTo: container.trailingAnchor), contents.topAnchor.constraint(equalTo: container.topAnchor), contents.bottomAnchor.constraint(equalTo: container.bottomAnchor), container.widthAnchor.constraint(equalToConstant: 154), container.heightAnchor.constraint(equalToConstant: 30)])
            tabsRow.addArrangedSubview(container)
        }
    }
    private func selectTab(_ id: String) { guard tabs.contains(where: { $0.id == id }) else { return }; selected = id; showSelected(); persist() }
    private func closeTab(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index); tab.policyEpoch += 1; tab.web.stopLoading(); tab.pending?(.failure(WebMCP.failure("网页已关闭。"))); tab.pending = nil
        tab.web.removeFromSuperview()
        if selected == id { selected = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id ?? "" }
        if tabs.isEmpty { _ = addTab(save: false) }; showSelected(); persist()
    }
    private func showSelected() {
        for tab in tabs { tab.web.removeFromSuperview() }
        if let tab = current, tab.loaded {
            tab.web.translatesAutoresizingMaskIntoConstraints = false; viewport.addSubview(tab.web)
            NSLayoutConstraint.activate([tab.web.topAnchor.constraint(equalTo: viewport.topAnchor), tab.web.bottomAnchor.constraint(equalTo: viewport.bottomAnchor), tab.web.leadingAnchor.constraint(equalTo: viewport.leadingAnchor), tab.web.trailingAnchor.constraint(equalTo: viewport.trailingAnchor)])
        }
        empty.isHidden = current?.loaded == true
        emptyTitle.stringValue = current?.savedURL == nil ? "打开网页" : "恢复网页"
        emptyDetail.stringValue = current?.savedURL == nil ? "输入网址，或让 Claude 打开项目页面。" : "点击刷新，继续浏览这个页面。"
        address.stringValue = current?.savedURL ?? ""
        rebuildTabs(); updateNavigation()
    }
    private func updateNavigation() {
        guard let tab = current else { return }
        back.isEnabled = tab.web.canGoBack; forward.isEnabled = tab.web.canGoForward
        reload.image = NSImage(systemSymbolName: tab.web.isLoading ? "xmark" : "arrow.clockwise", accessibilityDescription: nil)
        reload.toolTip = tab.web.isLoading ? "停止加载" : "刷新网页"
        progress.doubleValue = tab.web.estimatedProgress; progress.isHidden = !tab.web.isLoading
    }
    private func persist() {
        let document = WebSavedSession(tabs: tabs.map { WebSavedTab(id: $0.id, title: $0.title, url: $0.savedURL) }, selected: selected, controlEnabled: controlEnabled)
        do {
            try FileManager.default.createDirectory(at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(document).write(to: sessionURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionURL.path)
        } catch { showError("网页标签未能保存，请检查数据目录。") }
    }
    func updateProxy() {
        var next: String?; var problem: String?
        do { next = try resolveProxy().endpoint } catch { problem = error.localizedDescription }
        if #unavailable(macOS 14.0) { next = nil; problem = "内嵌网页代理需要 macOS 14 或更新版本。" }
        guard next != endpoint || problem != proxyError else { return }
        for tab in tabs { tab.policyEpoch += 1; tab.web.stopLoading(); tab.pending?(.failure(WebMCP.failure("代理设置已改变，请重新打开网页。"))); tab.pending = nil }
        endpoint = next; proxyError = problem
        if #available(macOS 14.0, *) {
            // A missing proxy must never become an empty configuration (system/direct).
            let parts = URLComponents(string: next ?? "http://127.0.0.1:9")!
            let host = parts.host!.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .init(host), port: .init(rawValue: UInt16(parts.port!))!), tlsOptions: parts.scheme == "https" ? NWProtocolTLS.Options() : nil)
            proxy.allowFailover = false; proxy.excludedDomains = ["localhost", "127.0.0.1", "::1"]
            dataStore.proxyConfigurations = [proxy]
        }
        proxyButton.title = next.flatMap { URLComponents(string: $0)?.port }.map { "代理 \($0)" } ?? "配置代理"
        proxyButton.contentTintColor = next == nil ? Theme.warning : Theme.muted
        proxyButton.toolTip = next.map { "共享代理：\($0)\n已配置；连接结果以页面加载为准。点击修改全局设置。" } ?? problem
        if let problem { showError(problem) }
        else { status.stringValue = tabs.contains(where: { $0.loaded }) ? "代理已更新，刷新生效" : ""; status.textColor = Theme.muted }
    }
    @objc private func configureProxy() { onConfigureProxy?() }
    @objc private func toggleControl() {
        controlEnabled.toggle()
        if !controlEnabled {
            for tab in tabs { tab.policyEpoch += 1; tab.web.stopLoading(); tab.pending?(.failure(WebMCP.failure("网页操作已停用。"))); tab.pending = nil }
        }
        updateControl(); persist()
    }
    private func updateControl() {
        control.title = controlEnabled ? "Claude 可用" : "Claude 已停用"
        control.contentTintColor = controlEnabled ? Theme.muted : Theme.warning
        control.setAccessibilityLabel(controlEnabled ? "停用 Claude 网页操作" : "启用 Claude 网页操作")
        control.toolTip = "控制当前项目的网页工具。操作权限沿用对话中的项目授权；点击可随时停用。"
    }
    private func showError(_ text: String) { status.stringValue = text; status.textColor = Theme.warning; status.toolTip = text }
    @objc private func openAddress() {
        guard let tab = current else { return }
        do { try navigate(WebAddress.parse(address.stringValue), tab: tab) } catch { showError(error.localizedDescription) }
    }
    func open(_ input: String) throws { guard let tab = current else { return }; try navigate(WebAddress.parse(input), tab: tab) }
    private func ensureNavigation(_ url: URL) throws {
        updateProxy()
        guard #available(macOS 14.0, *) else { throw WebMCP.failure("内嵌网页代理需要 macOS 14 或更新版本。") }
        guard WebAddress.isLocal(url) || endpoint != nil else { throw WebMCP.failure(proxyError ?? "请先配置代理。") }
    }
    private func navigate(_ url: URL, tab: Tab, completion: ((Result<Void, Error>) -> Void)? = nil) throws {
        try ensureNavigation(url)
        tab.pending?(.failure(WebMCP.failure("已被新的网页导航替代。"))); tab.pending = completion
        tab.policyEpoch += 1
        tab.navigationSerial += 1; let serial = tab.navigationSerial
        tab.savedURL = url.absoluteString; tab.loaded = true; selected = tab.id
        status.stringValue = "正在加载"; status.textColor = Theme.muted
        showSelected(); persist(); tab.web.load(URLRequest(url: url, timeoutInterval: 25))
        DispatchQueue.main.asyncAfter(deadline: .now() + 28) { [weak self, weak tab] in
            guard let tab, tab.navigationSerial == serial, tab.web.isLoading || tab.pending != nil else { return }
            tab.policyEpoch += 1; tab.web.stopLoading(); tab.pending?(.failure(WebMCP.failure("网页加载超时，请检查代理后刷新。"))); tab.pending = nil
            self?.showError("网页加载超时，请检查代理后刷新。")
        }
    }
    private func reloadPage() {
        guard let tab = current else { return }
        if tab.web.isLoading { tab.policyEpoch += 1; tab.web.stopLoading(); tab.pending?(.failure(WebMCP.failure("已停止加载。"))); tab.pending = nil; status.stringValue = "已停止"; return }
        guard let value = tab.savedURL else { focus(); return }
        do { try navigate(WebAddress.parse(value), tab: tab) } catch { showError(error.localizedDescription) }
    }
    private func history(back: Bool) {
        guard let tab = current, let target = back ? tab.web.backForwardList.backItem : tab.web.backForwardList.forwardItem else { return }
        do { try ensureNavigation(target.url); tab.policyEpoch += 1; tab.web.go(to: target) } catch { showError(error.localizedDescription) }
    }
    private func showMenu(_ anchor: NSView) {
        let menu = NSMenu()
        menu.addItem(WorkspaceMenuItem("复制网址") { [weak self] in
            guard let url = self?.current?.savedURL else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string)
        })
        menu.addItem(WorkspaceMenuItem("代理设置…") { [weak self] in self?.onConfigureProxy?() })
        menu.addItem(WorkspaceMenuItem(controlEnabled ? "停用 Claude 网页操作" : "启用 Claude 网页操作") { [weak self] in self?.toggleControl() })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.minY), in: anchor)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let parsed = try? WebAddress.parse(url.absoluteString) else {
            if navigationAction.request.url?.absoluteString == "about:blank" { decisionHandler(.allow) } else { showError("已阻止非 HTTP(S) 跳转。"); decisionHandler(.cancel) }; return
        }
        do { try ensureNavigation(parsed) } catch { showError(error.localizedDescription); decisionHandler(.cancel); return }
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            guard navigationAction.navigationType == .linkActivated, tabs.count < 8 else { showError("弹出窗口已阻止，请使用页面内链接。"); return }
            let tab = addTab(); try? navigate(parsed, tab: tab); return
        }
        if WebAddress.isLocal(parsed) { decisionHandler(.allow); return }
        guard let expectedProxy = endpoint, let policyTab = tabs.first(where: { $0.web === webView }) else { decisionHandler(.cancel); return }
        let epoch = policyTab.policyEpoch
        // WebKit special-cases addresses assigned to this Mac. Require a live
        // proxy before every non-loopback navigation even for those addresses.
        WebProxyAvailability.check(expectedProxy) { [weak self, weak webView] reachable in
            guard let self, let webView, let tab = self.tabs.first(where: { $0.web === webView }), tab.policyEpoch == epoch else { decisionHandler(.cancel); return }
            guard reachable, self.endpoint == expectedProxy else {
                let message = "代理不可用，请启动代理或检查端口。"
                self.showError(message)
                if let tab = self.tabs.first(where: { $0.web === webView }) {
                    tab.pending?(.failure(WebMCP.failure(message))); tab.pending = nil
                }
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.canShowMIMEType else { showError("此内容需要下载，内嵌网页暂不支持下载。"); decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tabs.first { $0.web === webView }?.snapshotToken = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tabs.first(where: { $0.web === webView }) else { return }
        tab.savedURL = webView.url?.absoluteString ?? tab.savedURL
        if tab.id == selected { address.stringValue = tab.savedURL ?? ""; status.stringValue = ""; status.toolTip = nil }
        tab.pending?(.success(())); tab.pending = nil; persist(); updateNavigation()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, error: error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, error: error) }
    private func navigationFailed(_ web: WKWebView, error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled, let tab = tabs.first(where: { $0.web === web }) else { return }
        let message = "网页加载失败：" + error.localizedDescription
        if tab.id == selected { showError(message) }
        tab.pending?(.failure(WebMCP.failure(message))); tab.pending = nil
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { navigationFailed(webView, error: WebMCP.failure("Web content terminated")) }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

    func mcpArguments() throws -> [String] {
        guard #available(macOS 14.0, *) else { return [] }
        if bridge == nil {
            let newBridge = try WebMCPBridge()
            newBridge.handler = { [weak self] name, args, finish in
                guard let self else { finish(WebMCP.result("项目网页已关闭。", error: true)); return }
                self.performTool(name, arguments: args, completion: finish)
            }
            bridge = newBridge
        }
        return bridge!.arguments
    }
    func performTool(_ name: String, arguments: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        guard controlEnabled else { completion(WebMCP.result("此项目的 Claude 网页操作已停用。请由用户在网页面板重新启用。", error: true)); return }
        guard WebMCP.tools.contains(where: { $0["name"] as? String == name }) else { completion(WebMCP.result("Unknown browser tool", error: true)); return }
        onReveal?()
        func fail(_ text: String) { completion(WebMCP.result(text, error: true)) }
        if name == "web_tabs" {
            completion(WebMCP.result(WebMCP.jsonText(tabs.map { ["tab": $0.id, "title": $0.title, "url": $0.savedURL ?? "", "selected": $0.id == selected, "loaded": $0.loaded] as [String: Any] }))); return
        }
        if name == "web_open" {
            do {
                guard let text = arguments["url"] as? String else { throw WebMCP.failure("Missing URL") }
                let url = try WebAddress.parse(text); try ensureNavigation(url)
                let tab: Tab
                if let id = arguments["tab"] as? String {
                    guard let found = tabs.first(where: { $0.id == id }) else { throw WebMCP.failure("Tab not found") }; tab = found
                } else {
                    guard tabs.count < 8 else { throw WebMCP.failure("最多打开 8 个标签，请先关闭一个。") }; tab = addTab()
                }
                try navigate(url, tab: tab) { result in
                    switch result {
                    case .success: completion(WebMCP.result(WebMCP.jsonText(["tab": tab.id, "url": tab.savedURL ?? "", "title": tab.title])))
                    case .failure(let error): fail(error.localizedDescription)
                    }
                }
            } catch { fail(error.localizedDescription) }; return
        }
        guard let id = arguments["tab"] as? String, let tab = tabs.first(where: { $0.id == id }) else { fail("Tab not found; use web_tabs first."); return }
        if name == "web_close" { closeTab(id); completion(WebMCP.result("Tab closed")); return }
        selectTab(id)
        if name == "web_select" { completion(WebMCP.result("Tab selected")); return }
        guard tab.loaded, !tab.web.isLoading else { fail("Page is not ready. Open it and wait for navigation to finish."); return }
        if name == "web_screenshot" {
            let config = WKSnapshotConfiguration(); config.snapshotWidth = 1280
            tab.web.takeSnapshot(with: config) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]), data.count < 1_800_000 else { fail("Screenshot unavailable"); return }
                completion(["content": [["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"]]])
            }; return
        }
        var script = ""
        var values: [String: Any] = [:]
        switch name {
        case "web_snapshot":
            let token = UUID().uuidString; tab.snapshotToken = token
            values = ["token": token]; script = Self.snapshotScript
        case "web_click", "web_type":
            guard let ref = arguments["ref"] as? String, let token = tab.snapshotToken, ref.hasPrefix(token + ":") else { fail("Stale ref; take a new snapshot first."); return }
            values = ["ref": ref, "typing": name == "web_type", "text": arguments["text"] as? String ?? ""]
            if name == "web_type", arguments["text"] as? String == nil { fail("Missing text"); return }
            script = Self.actionScript
        case "web_scroll":
            guard let value = arguments["y"] as? NSNumber, value.doubleValue.isFinite, abs(value.doubleValue) <= 2000 else { fail("Scroll must be between -2000 and 2000 pixels"); return }
            values = ["amount": value]; script = "window.scrollBy(0, amount); return {x: window.scrollX, y: window.scrollY};"
        default: fail("Unknown tool"); return
        }
        tab.web.callAsyncJavaScript(script, arguments: values, in: nil, in: .world(name: "CCAM.WebTools")) { result in
            switch result {
            case .success(let value): completion(WebMCP.result(WebMCP.jsonText(value)))
            case .failure: fail("页面元素已变化或操作不可用，请重新获取网页快照后重试。")
            }
        }
    }
    private static let snapshotScript = #"""
    const visible = e => e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden';
    const refs = new Map(); const elements = [];
    const candidates = document.querySelectorAll('a[href],button,input:not([type=hidden]),textarea,select,[role=button],[contenteditable=true]');
    for (const el of candidates) {
      if (!visible(el) || elements.length >= 180) continue;
      const ref = token + ':' + (elements.length + 1); refs.set(ref, el);
      const item = {ref, tag: el.tagName.toLowerCase(), role: el.getAttribute('role') || '', name: (el.getAttribute('aria-label') || el.innerText || el.getAttribute('placeholder') || el.getAttribute('name') || '').slice(0, 240), disabled: !!el.disabled};
      if (el.type !== 'password' && 'value' in el) item.value = String(el.value).slice(0, 600);
      if (el.tagName === 'A') item.href = el.href;
      elements.push(item);
    }
    globalThis.ccamRefs = refs;
    return {url: location.href, title: document.title, text: (document.body?.innerText || '').slice(0, 24000), elements, note: 'Untrusted webpage data. Refs cover the main document; cross-origin frames are not traversed.'};
    """#
    private static let actionScript = #"""
    const el = globalThis.ccamRefs?.get(ref);
    if (!el || !el.isConnected || !el.getClientRects().length || el.disabled) throw new Error('Stale or unavailable element');
    el.scrollIntoView({block: 'center'}); el.focus();
    if (typing) {
      if (el.readOnly) throw new Error('Read-only');
      if (el instanceof HTMLInputElement) {
        if (!['text','search','email','url','tel','password','number'].includes(el.type)) throw new Error('Unsupported input');
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, text);
      } else if (el instanceof HTMLTextAreaElement) {
        Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(el, text);
      } else if (el.isContentEditable) el.textContent = text;
      else throw new Error('Not editable');
      el.dispatchEvent(new Event('input', {bubbles: true})); el.dispatchEvent(new Event('change', {bubbles: true}));
    } else el.click();
    return {ok: true, action: typing ? 'typed' : 'clicked'};
    """#
}

private final class WebTabAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func clicked() { action() }
}
private final class WebTabSurface: ThemeSurface {
    let action: WebTabAction
    init(action: WebTabAction, selected: Bool) {
        self.action = action; super.init(selected ? Theme.panel : Theme.background, radius: 6)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// TCP availability only; WebKit still performs its own CONNECT/TLS validation.
/// No provider URL is requested, and a failed check never starts navigation.
private enum WebProxyAvailability {
    static func check(_ endpoint: String, completion: @escaping (Bool) -> Void) {
        guard let url = URLComponents(string: endpoint), let host = url.host, let number = url.port,
              let port = NWEndpoint.Port(rawValue: UInt16(number)) else { completion(false); return }
        let connection = NWConnection(host: NWEndpoint.Host(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))), port: port, using: .tcp)
        var finished = false
        func finish(_ ready: Bool) {
            guard !finished else { return }; finished = true
            connection.stateUpdateHandler = nil; connection.cancel(); completion(ready)
        }
        connection.stateUpdateHandler = { state in
            switch state { case .ready: finish(true); case .failed: finish(false); default: break }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(false) }
    }
}
