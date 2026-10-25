import AppKit
import Darwin

enum TranslationSetup {
    private static var controller: TranslationSetupController?
    static func show(from window: NSWindow?) {
        if controller == nil { controller = TranslationSetupController() }
        controller?.present(relativeTo: window)
    }
}

/// Retained independently of the chat view: switching projects cannot launch a
/// second installer, lose progress or redirect installation to another folder.
private final class TranslationSetupController: NSWindowController {
    private let status = label("", size: 13, color: Theme.muted)
    private let install = ClosureButton("下载并安装", symbol: "arrow.down.circle") { }
    private let cancel = ClosureButton("取消", symbol: "xmark") { }
    private let progress = NSProgressIndicator()
    private var process: Process?
    private var output: Pipe?, errors: Pipe?
    private var attempt: UUID?
    private var watchdog: DispatchWorkItem?
    private var interruption: String?
    private var terminationObserver: NSObjectProtocol?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "本机翻译"; window.isReleasedWhenClosed = false
        window.backgroundColor = Theme.background
        super.init(window: window)
        let host = ThemeSurface(Theme.background); window.contentView = host
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        let details = label("中英双向翻译，在本机运行。首次安装经当前代理下载 Argos 模型与运行组件；模型约 145 MB。", size: 12, color: Theme.muted)
        let source = ClosureButton("开源项目", symbol: "arrow.up.right") {
            NSWorkspace.shared.open(URL(string: "https://github.com/argosopentech/argos-translate")!)
        }
        let content = column([label("本机翻译", size: 23, weight: .semibold), details,
                              row([progress, status], spacing: 8), row([source, spacer(), cancel, install], spacing: 8)], spacing: 18)
        content.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 24), content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -24), content.topAnchor.constraint(equalTo: host.topAnchor, constant: 24)])
        for item in content.arrangedSubviews { item.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        install.actionBlock = { [weak self] in self?.start() }
        cancel.actionBlock = { [weak self] in self?.stop(message: "已取消安装，可以重试。") }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop(message: "已取消安装，可以重试。")
        }
        refreshReady()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) } }

    func present(relativeTo parent: NSWindow?) {
        if process == nil { refreshReady() }
        if window?.isVisible != true {
            if let parent, let window { window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2, y: parent.frame.midY - window.frame.height / 2)) }
            else { window?.center() }
        }
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    private func refreshReady() {
        let ready = LocalTranslator.shared.isReady
        status.stringValue = ready ? "已就绪 · 翻译无需联网" : "尚未安装中英翻译组件"
        status.textColor = ready ? Theme.success : Theme.muted
        install.title = ready ? "已就绪" : "下载并安装"; install.isEnabled = !ready
        cancel.isHidden = true; progress.stopAnimation(nil)
    }
    private func start() {
        guard process == nil,
              let script = Bundle.main.url(forResource: "setup_translation", withExtension: "py", subdirectory: "Translation"),
              let worker = Bundle.main.url(forResource: "translate_worker", withExtension: "py", subdirectory: "Translation") else {
            if process == nil { status.stringValue = "安装组件缺失，请更新 CCAM Desktop。"; status.textColor = Theme.warning }
            return
        }
        do {
            let proxy = try ExecutionProxy.resolve(environment: [:])
            let child = Process(), stdout = Pipe(), stderr = Pipe(), id = UUID()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            // A private process group lets cancel/timeout stop pip and its
            // children too. Never interpolate paths into shell commands.
            let supervisor = """
            import os,signal,subprocess,sys,threading
            os.setsid()
            def stop(*unused):
                signal.signal(signal.SIGTERM,signal.SIG_IGN)
                threading.Timer(1,lambda: os.killpg(os.getpgrp(),signal.SIGKILL)).start()
            signal.signal(signal.SIGTERM,stop)
            sys.exit(subprocess.call([sys.executable,'-I','-B']+sys.argv[1:]))
            """
            child.arguments = ["-I", "-c", supervisor, script.path,
                               "--home", LocalTranslator.defaultHome.path, "--worker", worker.path]
            var environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
            for name in ExecutionProxy.proxyKeys + ["NO_PROXY", "no_proxy"] { environment[name] = proxy.environment[name] }
            child.environment = environment
            child.standardInput = FileHandle.nullDevice; child.standardOutput = stdout; child.standardError = stderr
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data.prefix(8192), as: UTF8.self)
                let phase = text.contains("Downloading pinned model") ? "正在下载中英模型…"
                    : text.contains("Validated local inference") ? "正在验证本机翻译…" : nil
                if let phase { DispatchQueue.main.async { [weak self] in
                    guard let self, self.attempt == id, self.interruption == nil else { return }; self.status.stringValue = phase
                } }
            }
            // Installer/package diagnostics can contain URLs; expose only fixed
            // status phrases, never raw output or inherited credential values.
            stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
            child.terminationHandler = { [weak self] child in DispatchQueue.main.async { self?.finish(id: id, code: child.terminationStatus) } }
            process = child; output = stdout; errors = stderr; attempt = id; interruption = nil
            try child.run()
            install.isEnabled = false; cancel.isHidden = false; cancel.isEnabled = true
            progress.startAnimation(nil); status.stringValue = "正在准备翻译组件…"; status.textColor = Theme.muted
            let timeout = DispatchWorkItem { [weak self] in
                guard self?.attempt == id else { return }; self?.stop(message: "安装超时，请检查代理后重试。")
            }
            watchdog = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: timeout)
        } catch {
            process = nil; attempt = nil; cleanupPipes()
            status.stringValue = error is ExecutionProxy.Failure ? error.localizedDescription : "无法启动安装，请确认已安装 Python 3.9 或更新版本。"
            status.textColor = Theme.warning; install.isEnabled = true
        }
    }
    private func stop(message: String) {
        guard let process, process.isRunning else { return }
        interruption = message; cancel.isEnabled = false; status.stringValue = "正在停止安装…"
        let pid = process.processIdentifier
        if getpgid(pid) == pid { kill(-pid, SIGTERM) } else { process.terminate() }
        // The supervisor holds its private group alive and escalates after one
        // second, even if the desktop app is quitting at the same time.
    }
    private func finish(id: UUID, code: Int32) {
        guard attempt == id else { return }
        watchdog?.cancel(); watchdog = nil; attempt = nil; process = nil; cleanupPipes()
        progress.stopAnimation(nil); cancel.isHidden = true
        if interruption == nil && code == 0 && LocalTranslator.shared.isReady { refreshReady() }
        else {
            status.stringValue = interruption ?? "安装未完成，请检查代理和磁盘空间后重试。"
            status.textColor = Theme.warning; install.title = "重新安装"; install.isEnabled = true
        }
    }
    private func cleanupPipes() {
        output?.fileHandleForReading.readabilityHandler = nil; errors?.fileHandleForReading.readabilityHandler = nil
        output = nil; errors = nil
    }
}
