import AppKit
import WebKit

@main struct WebBrowserTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1; print("CHECK: " + message); if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func pump(_ predicate: () -> Bool, seconds: Double = 10) {
        let end = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
    static func tool(_ view: ProjectWebView, _ name: String, _ arguments: [String: Any] = [:]) -> [String: Any] {
        var output: [String: Any]?
        view.performTool(name, arguments: arguments) { output = $0 }
        pump({ output != nil }, seconds: 35)
        check(output != nil, "\(name) completes")
        return output ?? [:]
    }
    static func text(_ result: [String: Any]) -> String { (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "" }
    static func payload(_ result: [String: Any]) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(text(result).utf8))) as? [String: Any] ?? [:] }
    static func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
    static func snapshot(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["CCAM_UI_SNAPSHOT_DIR"] else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")) }
    }
    static func main() throws {
        if let status = WebMCP.handleHelperInvocation() { exit(status) }
        if let repository = Bundle.main.object(forInfoDictionaryKey: "CCAMTestRepository") as? String {
            FileManager.default.changeCurrentDirectoryPath(repository)
            let output = (Bundle.main.object(forInfoDictionaryKey: "CCAMTestOutput") as? String).map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: repository).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("work/web-integration")
            freopen(output.appendingPathComponent("web-qa.log").path, "w", stdout)
            freopen(output.appendingPathComponent("web-qa.log").path, "a", stderr)
            setbuf(stdout, nil)
            setenv("CCAM_UI_SNAPSHOT_DIR", output.appendingPathComponent("screenshots").path, 1)
        }
        print("Starting browser QA")
        let app = NSApplication.shared; app.setActivationPolicy(.regular); app.appearance = NSAppearance(named: .darkAqua)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccam-web-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("CCAM_DESKTOP_DATA_DIR", root.path, 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Process(); fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = ["-B", "Tests/web_fixture.py", root.path]
        let input = Pipe(); fixture.standardInput = input; fixture.standardOutput = FileHandle.nullDevice
        fixture.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var launched = false; var launchError: Error?
        DispatchQueue.global().async {
            do { try fixture.run(); DispatchQueue.main.async { launched = true } }
            catch { DispatchQueue.main.async { launchError = error } }
        }
        pump({ launched || launchError != nil }, seconds: 8)
        guard launched else { throw launchError ?? WebMCP.failure("Local fixture process startup timed out") }
        defer { try? input.fileHandleForWriting.close(); if fixture.isRunning { fixture.terminate() } }
        pump({ FileManager.default.fileExists(atPath: root.appendingPathComponent("ports.json").path) }, seconds: 5)
        let ports = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("ports.json"))) as! [String: Any]
        func counts() -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("counts.json")))) as? [String: Any] ?? [:] }
        check(WebAddress.isLocal(URL(string: "http://localhost:3000")!), "bare localhost accepted")
        check((try? WebAddress.parse("example.com").absoluteString) == "https://example.com", "bare domain defaults to HTTPS")
        for bad in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,test", "https://u:secret@example.com", "https://x:99999", ""] {
            check((try? WebAddress.parse(bad)) == nil, "reject unsafe address \(bad)")
        }
        check(!WebAddress.isLocal(URL(string: "http://localhost.evil.test")!), "loopback bypass has no suffix matching")
        let project = ProjectRecord(id: UUID(), name: "Browser fixture", path: root.path, createdAt: Date(), lastOpenedAt: Date(), archived: false)
        var proxy = "http://127.0.0.1:\(ports["proxy"] as! Int)"
        let view = ProjectWebView(project: project, sessionURL: root.appendingPathComponent("web.json"), persistent: false) {
            try ExecutionProxy.resolve(environment: [:], manualURL: proxy, systemSettings: [:])
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 780), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "CCAM Web Offline QA"; window.contentView = view
        window.makeKeyAndOrderFront(nil); view.layoutSubtreeIfNeeded()
        check(view.currentWebView?.url == nil, "opening browser does not load any page")
        check(view.configuredProxy == proxy, "browser uses shared proxy resolver")
        let tab = view.selectedTabID
        let loaded = tool(view, "web_open", ["tab": tab, "url": "http://127.0.0.1:\(ports["page"] as! Int)/"])
        print("Navigation result: " + WebMCP.jsonText(loaded))
        check(loaded["isError"] as? Bool != true, "local navigation succeeds")
        check(counts()["proxy"] as? Int == 0, "localhost bypasses proxy")
        var snap = payload(tool(view, "web_snapshot", ["tab": tab]))
        check((snap["text"] as? String)?.contains("Project preview") == true, "MCP reads actual WKWebView page")
        check(!WebMCP.jsonText(snap).contains("NEVER_EXPOSE_PASSWORD"), "snapshot omits password input values")
        var elements = snap["elements"] as? [[String: Any]] ?? []
        let nameRef = elements.first { $0["name"] as? String == "Project name" }?["ref"] as? String ?? ""
        let saveRef = elements.first { $0["name"] as? String == "Save" }?["ref"] as? String ?? ""
        check(!nameRef.isEmpty && !saveRef.isEmpty, "snapshot contains actionable element refs")
        check(tool(view, "web_type", ["tab": tab, "ref": nameRef, "text": "CCAM shared browser"])["isError"] as? Bool != true, "MCP types into actual page")
        check(tool(view, "web_click", ["tab": tab, "ref": saveRef])["isError"] as? Bool != true, "MCP clicks actual page")
        snap = payload(tool(view, "web_snapshot", ["tab": tab]))
        check((snap["text"] as? String)?.contains("Saved: CCAM shared browser") == true, "typing and clicking update same DOM")
        check(tool(view, "web_click", ["tab": tab, "ref": saveRef])["isError"] as? Bool == true, "refs from superseded snapshots are rejected")
        check(tool(view, "web_scroll", ["tab": tab, "y": 350])["isError"] as? Bool != true, "MCP scroll works")
        check(tool(view, "web_scroll", ["tab": tab, "y": 50000])["isError"] as? Bool == true, "oversized scroll is rejected")
        _ = tool(view, "web_scroll", ["tab": tab, "y": -2000])
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let screenshot = tool(view, "web_screenshot", ["tab": tab])
        check((screenshot["content"] as? [[String: Any]])?.first?["mimeType"] as? String == "image/jpeg", "MCP produces a viewport screenshot")
        try snapshot(view, name: "web-desktop")
        // This fake hostname is served entirely by the local proxy; no external requests.
        let proxyLoad = tool(view, "web_open", ["tab": tab, "url": "http://ccam-fixture.invalid/"])
        print("Proxy navigation: " + WebMCP.jsonText(proxyLoad))
        check(proxyLoad["isError"] as? Bool != true, "external URL loads through explicit proxy")
        check((counts()["proxy"] as? Int ?? 0) > 0, "proxy receives the browser connection")
        check((counts()["hosts"] as? [String] ?? []).contains { $0.contains("ccam-fixture.invalid") }, "proxy observes requested target hostname")
        elements = payload(tool(view, "web_snapshot", ["tab": tab]))["elements"] as? [[String: Any]] ?? []
        let oldRef = elements.first?["ref"] as? String ?? ""
        _ = tool(view, "web_open", ["tab": tab, "url": "http://ccam-fixture.invalid/second"])
        check(tool(view, "web_click", ["tab": tab, "ref": oldRef])["isError"] as? Bool == true, "navigation invalidates stale refs")
        _ = tool(view, "web_open", ["url": "http://ccam-fixture.invalid/"])
        check(view.tabCount == 2, "new MCP navigation creates a visible tab")
        check(tool(view, "web_select", ["tab": tab])["isError"] as? Bool != true && view.selectedTabID == tab, "MCP tab selection matches visible page")
        check(tool(view, "web_snapshot", ["tab": UUID().uuidString])["isError"] as? Bool == true, "cannot operate on another project's tab")
        let config = try view.mcpArguments()
        let configData = try Data(contentsOf: URL(fileURLWithPath: config[1]))
        let configObject = try JSONSerialization.jsonObject(with: configData) as! [String: Any]
        let server = (configObject["mcpServers"] as! [String: [String: Any]])["ccam-web"]!
        let descriptor = URL(fileURLWithPath: (server["args"] as! [String])[1])
        var bridgeResult: [String: Any]?
        DispatchQueue.global().async {
            let result: [String: Any]
            do { result = try WebMCP.request(descriptor: descriptor, name: "web_tabs", arguments: [:]) }
            catch { result = WebMCP.result(error.localizedDescription, error: true) }
            DispatchQueue.main.async { bridgeResult = result }
        }
        pump({ bridgeResult != nil })
        print("Bridge result: " + WebMCP.jsonText(bridgeResult ?? [:]))
        check(bridgeResult?["isError"] as? Bool == false && text(bridgeResult!).contains(tab), "authenticated socket bridge reaches same project tabs")
        let wrongDescriptor = root.appendingPathComponent("wrong.json")
        var wrong = try JSONSerialization.jsonObject(with: Data(contentsOf: descriptor)) as! [String: String]; wrong["token"] = "wrong"
        try JSONSerialization.data(withJSONObject: wrong).write(to: wrongDescriptor)
        bridgeResult = nil
        DispatchQueue.global().async {
            let result = (try? WebMCP.request(descriptor: wrongDescriptor, name: "web_tabs", arguments: [:])) ?? [:]
            DispatchQueue.main.async { bridgeResult = result }
        }
        pump({ bridgeResult != nil })
        check(bridgeResult?["isError"] as? Bool == true, "bridge rejects incorrect authentication")
        // Real helper subprocess, MCP handshake and tools/call over stdio.
        let helper = Process(); helper.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); helper.arguments = ["--web-mcp", descriptor.path]
        let helperIn = Pipe(), helperOut = Pipe(); helper.standardInput = helperIn; helper.standardOutput = helperOut; helper.standardError = FileHandle.nullDevice
        try helper.run()
        for frame: [String: Any] in [["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]], ["jsonrpc": "2.0", "id": 2, "method": "tools/list"], ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "web_tabs", "arguments": [:]]]] {
            try helperIn.fileHandleForWriting.write(contentsOf: Data((WebMCP.jsonText(frame) + "\n").utf8))
        }
        try helperIn.fileHandleForWriting.close()
        var helperData: Data?
        DispatchQueue.global().async { let output = helperOut.fileHandleForReading.readDataToEndOfFile(); DispatchQueue.main.async { helperData = output } }
        pump({ helperData != nil })
        check(helperData != nil, "stdio helper exits on EOF")
        let frames = String(data: helperData ?? Data(), encoding: .utf8)!.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        check(frames.count == 3 && ((frames[0]["result"] as? [String: Any])?["protocolVersion"] as? String) == "2025-03-26", "MCP handshake returns supported protocol")
        check(((frames[1]["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.count == 9, "MCP publishes nine bounded browser tools")
        check(WebMCP.jsonText(frames.last ?? [:]).contains(tab), "stdio tool call traverses socket and reads actual project")
        let control = all(view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "停用 Claude 网页操作" }!
        control.performClick(nil)
        check(tool(view, "web_snapshot", ["tab": tab])["isError"] as? Bool == true, "user can disable browser tools immediately")
        control.performClick(nil)
        for width in [1000.0, 480.0, 340.0] {
            window.setContentSize(NSSize(width: width, height: 740)); view.layoutSubtreeIfNeeded()
            let field = all(view).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "网页地址" }!
            check(field.bounds.width >= 140, "address remains editable at width \(width)")
            for button in all(view).compactMap({ $0 as? NSButton }).filter({ ["网页更多操作", "网页共享代理设置", "停用 Claude 网页操作"].contains($0.accessibilityLabel() ?? "") }) {
                let rect = button.convert(button.bounds, to: view)
                check(rect.minX >= 0 && rect.maxX <= view.bounds.width + 1, "browser controls fit width \(width)")
            }
        }
        try snapshot(view, name: "web-compact")
        // Desktop split uses the production workspace and this very same browser.
        window.setContentSize(NSSize(width: 1380, height: 860))
        let conversation = ChatConversation(id: UUID().uuidString, title: "检查本地页面", projectID: project.id.uuidString, directory: project.path,
            messages: [ChatMessage(role: "user", text: "打开本地页面，检查表单。"), ChatMessage(role: "assistant", text: "页面与对话并排显示。\n\n这是离线验收示例，未发送 Claude 请求。")], options: ChatOptions())
        try ChatStore(project: project).save([conversation], selectedID: conversation.id)
        let workspace = ProjectWorkspace(terminal: TerminalWorkspace(frame: .zero), webViewFactory: { _ in view })
        workspace.beforeChatStart = { _, _ in throw WebMCP.failure("No Claude requests in browser QA") }
        let host = ThemeSurface(Theme.background)
        let header = workspace.sectionControl; header.translatesAutoresizingMaskIntoConstraints = false
        workspace.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(header); host.addSubview(workspace)
        NSLayoutConstraint.activate([header.topAnchor.constraint(equalTo: host.topAnchor, constant: 8), header.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12), header.heightAnchor.constraint(equalToConstant: 36), workspace.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8), workspace.leadingAnchor.constraint(equalTo: host.leadingAnchor), workspace.trailingAnchor.constraint(equalTo: host.trailingAnchor), workspace.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
        window.contentView = host; workspace.select(project: project)
        check(workspace.splitActive(adding: .web, axis: .right), "web pane supports native right split")
        host.layoutSubtreeIfNeeded()
        check(workspace.displayedSections == [.chat, .web] && view.window === window, "chat and same live browser coexist")
        _ = tool(view, "web_open", ["tab": view.selectedTabID, "url": "http://ccam-fixture.invalid/"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.3)); try snapshot(host, name: "web-chat-split-desktop")
        workspace.closePane(.web); workspace.showSection(.chat)
        check(workspace.splitActive(adding: .web, axis: .down), "web pane supports native lower split")
        host.layoutSubtreeIfNeeded()
        check(workspace.displayedSections == [.chat, .web] && view.tabCount == 2, "rearranging browser preserves tabs")
        try snapshot(host, name: "web-chat-split-vertical")
        workspace.closePane(.chat); host.layoutSubtreeIfNeeded()
        UserDefaults.standard.removeObject(forKey: WorkspacePaneLayout.key(project.id))
        // The navigation gate must also block a reachable local NIC address
        // outside the explicit loopback bypass when the proxy is unavailable.
        let before = counts()["pages"] as? Int ?? 0
        proxy = "http://127.0.0.1:1"; view.updateProxy()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        if #available(macOS 14.0, *) { print("Applied proxy: " + String(describing: view.currentWebView?.configuration.websiteDataStore.proxyConfigurations)) }
        let blockedDomain = tool(view, "web_open", ["tab": tab, "url": "http://ccam-fixture.invalid/offline-check"])
        check(blockedDomain["isError"] as? Bool == true, "dead proxy blocks external-domain navigation")
        let failed = tool(view, "web_open", ["tab": tab, "url": "http://\(ports["canaryHost"] as! String):\(ports["canary"] as! Int)/"])
        print("Canary result: " + WebMCP.jsonText(failed))
        print("Counters: " + WebMCP.jsonText(counts()))
        check(failed["isError"] as? Bool == true, "unavailable proxy fails navigation")
        check(counts()["pages"] as? Int == before, "unavailable proxy gate blocks direct access to the reachable local canary")
        proxy = ""; view.updateProxy()
        check(tool(view, "web_open", ["tab": tab, "url": "https://example.invalid/"])["isError"] as? Bool == true, "missing proxy blocks external navigation")
        check(tool(view, "web_open", ["tab": tab, "url": "http://127.0.0.1:\(ports["page"] as! Int)/"])["isError"] as? Bool != true, "local development remains available without remote proxy")
        let restored = ProjectWebView(project: project, sessionURL: root.appendingPathComponent("web.json"), persistent: false) { throw ExecutionProxy.Failure.missing }
        check(restored.tabCount == 2 && restored.currentWebView?.url == nil, "saved tabs restore without network traffic")
        window.orderOut(nil)
        print("PASS: \(checks) browser checks; real WebKit, local proxy, stdio MCP; no Claude requests")
    }
}
