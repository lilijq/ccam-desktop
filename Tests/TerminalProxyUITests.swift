import AppKit

/// Real PTY launches with local fixture programs only. No Claude or network calls.
enum TerminalProxyUITests {
    static func run() throws -> Int {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ description: String) {
            count += 1
            if !value() { fputs("FAIL: \(description)\n", stderr); exit(1) }
        }
        func wait(_ done: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            check(done(), "fixture PTY exits within deadline")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccam-terminal-proxy-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = UserDefaults.standard.object(forKey: ExecutionProxy.defaultsKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: ExecutionProxy.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: ExecutionProxy.defaultsKey) }
            try? FileManager.default.removeItem(at: root)
        }
        let output = root.appendingPathComponent("environment.txt")
        let script = root.appendingPathComponent("fixture.sh")
        try Data("printf '%s\\n' \"$HTTP_PROXY\" \"$http_proxy\" \"$HTTPS_PROXY\" \"$https_proxy\" \"$ALL_PROXY\" \"$all_proxy\" \"$NO_PROXY\" > \"$1\"\n".utf8).write(to: script)
        UserDefaults.standard.set("http://127.0.0.1:1", forKey: ExecutionProxy.defaultsKey)
        let view = TerminalSessionView(title: "Fixture", directory: root.path, projectID: "project")
        view.start(executable: "/bin/sh", args: [script.path, output.path])
        wait { !view.session.running }
        let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map(String.init)
        check(lines.count == 7 && lines.prefix(6).allSatisfy { $0 == "http://127.0.0.1:1" }, "terminal injects all six proxy aliases into actual PTY child")
        check(lines.last == ExecutionProxy.loopbackBypass, "terminal removes external NO_PROXY bypass")

        try FileManager.default.removeItem(at: output)
        UserDefaults.standard.set("invalid-proxy", forKey: ExecutionProxy.defaultsKey)
        let blocked = TerminalSessionView(title: "Blocked", directory: root.path)
        blocked.start(executable: "/bin/sh", args: [script.path, output.path])
        check(!blocked.session.running && !FileManager.default.fileExists(atPath: output.path), "invalid proxy blocks child creation")
        check(blocked.status.stringValue == "启动失败", "proxy block is visible instead of an inert terminal")

        let workspace = TerminalWorkspace(frame: .zero)
        let target = ChatTerminalTarget(directory: root.path, sessionID: UUID().uuidString, account: "fixture", ticket: nil, conversationID: "conversation")
        view.chatConversationID = target.conversationID; view.chatReturnTarget = target
        workspace.sessions.append(view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        var returned: ChatTerminalTarget?
        workspace.returnToChat(projectID: "project", target: target, window: window) { result in returned = try? result.get() }
        check(returned?.sessionID == target.sessionID && returned?.account == target.account, "completed terminal returns its exact session and account")
        var checkpointed = false
        view.onChatReturnStateChanged = { saved, uncertain in checkpointed = uncertain && saved.conversationID == target.conversationID }
        view.markReturnIdentityUncertain(); returned = nil
        check(checkpointed, "terminal account switch checkpoints uncertainty before launching a new account")
        workspace.returnToChat(projectID: "project", target: target, window: window) { result in returned = try? result.get() }
        check(returned == nil, "unverified account handoff cannot resume a guessed session")
        return count
    }
}
