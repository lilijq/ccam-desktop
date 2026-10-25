import AppKit

enum PoolActivity: String {
    case starting, checkingQuota, waitingForAccount, switchingAccount, continuingTask, paused, closed, failed
}

extension TerminalWorkspace {
    @discardableResult
    func openPool(plan: PoolLaunch, projectID: String, projectName: String, onStateChanged: ((PoolActivity, String) -> Void)? = nil) -> TerminalSessionView {
        let view = open(executable: plan.environment["CCAM_DESKTOP_CCAM"] ?? CCAMClient.executable,
                        args: plan.args, directory: plan.directory, title: "自动续做",
                        projectID: projectID, projectName: projectName, environmentOverrides: plan.environment,
                        environmentExclusions: GlobalPool.overrideKeys)
        view.showNotice("正在连接可用账号。项目上下文会保留，额度耗尽后自动续做。")
        let controller = PoolCoordinator(plan: plan, view: view, onStateChanged: onStateChanged)
        // The view owns the controller through these callbacks; the controller
        // only keeps a weak view, so closing a tab also releases its event files.
        view.onProcessStarted = { pid in controller.started(pid) }
        view.onProcessExit = { code in controller.exited(code) }
        view.onUserStop = { controller.cancel(user: true) }
        view.onInterrupt = { controller.interrupted() }
        return view
    }
}

/// Runs on the main queue. Account selection happens before ending the old
/// session, and replacement starts only after its PTY has reaped the old child.
final class PoolCoordinator {
    private weak var view: TerminalSessionView?
    private var plan: PoolLaunch
    private var timer: Timer?
    private var rootPID: Int32 = -1
    private var event: PoolLimitEvent?
    private var pending: PoolLaunch?
    private var checking = false
    private var cancelled = false
    private var generation = 0
    private var nextAttempt = Date.distantFuture
    private var waitingSince: Date?
    private var lastNotice = ""
    private var lastInterruptAt: Date?
    private let retryInterval: TimeInterval
    private let onStateChanged: ((PoolActivity, String) -> Void)?

    init(plan: PoolLaunch, view: TerminalSessionView, retryInterval: TimeInterval = GlobalPool.retryInterval,
         onStateChanged: ((PoolActivity, String) -> Void)? = nil) {
        self.plan = plan; self.view = view; self.retryInterval = retryInterval; self.onStateChanged = onStateChanged
    }
    deinit { timer?.invalidate(); GlobalPool.clean(plan); if let pending { GlobalPool.clean(pending) } }

    func started(_ pid: Int32) {
        rootPID = pid
        view?.setWaiting(false)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        if plan.automaticallyContinuesTask {
            notice("正在恢复项目上下文并自动继续未完成任务，无需再次输入。", state: .continuingTask)
        } else {
            onStateChanged?(.starting, "正在从全局账号池启动项目会话。")
        }
    }

    private func notice(_ text: String, state: PoolActivity? = nil) {
        if let state { onStateChanged?(state, text) }
        guard text != lastNotice else { return }; lastNotice = text; view?.showNotice(text)
    }

    private func tick() {
        guard !cancelled, let view else { return }
        if event == nil && view.session.running, let candidate = GlobalPool.readEvent(plan) {
            if let interrupted = lastInterruptAt, interrupted >= (candidate.limitAt ?? candidate.at) {
                try? FileManager.default.removeItem(at: plan.eventURL)
                notice("已取消本次额度中断的自动续做，当前会话保留。", state: .paused)
                return
            }
            // This check binds the hook to this exact child, including a native
            // CCAM relay if one was already configured by the user.
            guard GlobalPool.ownedProcess(event: candidate, rootPID: rootPID) else {
                try? FileManager.default.removeItem(at: plan.eventURL); return
            }
            event = candidate
            waitingSince = Date()
            notice("账号 \(candidate.account) 的额度已用完，正在选择下一个可用账号；随后自动继续当前任务。", state: .checkingQuota)
            nextAttempt = .distantPast
        }
        if let since = waitingSince, Date().timeIntervalSince(since) >= GlobalPool.maximumWait {
            notice("等待可用额度已满 5 小时。会话记录已保留，请稍后从项目继续。", state: .paused)
            cancel(user: false); return
        }
        if waitingSince != nil && !checking && pending == nil && Date() >= nextAttempt { preflight() }
    }

    private func preflight() {
        guard !cancelled, view != nil else { return }
        checking = true; generation += 1
        let checkGeneration = generation
        let ticket = event?.ticket ?? plan.ticket
        let continuation = ticket != nil || plan.args.contains("--continue")
        let base = plan
        let prepared: PoolLaunch
        do {
            prepared = try GlobalPool.prepare(directory: base.directory, continueLast: continuation, ticket: ticket,
                                              automaticallyContinueTask: event != nil || base.automaticallyContinuesTask,
                                              helperExecutable: base.helperExecutable,
                                              ccamExecutable: base.environment["CCAM_DESKTOP_CCAM"] ?? CCAMClient.executable,
                                              baseEnvironment: base.environment)
        } catch {
            checking = false; notice("无法准备自动接续：\(error.localizedDescription)", state: .failed); cancel(user: false); return
        }
        let executable = prepared.environment["CCAM_DESKTOP_CCAM"] ?? CCAMClient.executable
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = GlobalPool.command(executable: executable, args: GlobalPool.preflightArguments(prepared),
                                            directory: prepared.directory, environment: prepared.environment)
            DispatchQueue.main.async {
                guard let self, !self.cancelled, self.generation == checkGeneration, let view = self.view else { GlobalPool.clean(prepared); return }
                self.checking = false
                if result.code == 0 {
                    self.pending = prepared
                    self.notice("已有可用账号。正在切换账号，并从原任务中断处自动续做。", state: .switchingAccount)
                    guard !self.cancelled, self.generation == checkGeneration, self.pending != nil else { return }
                    if view.session.running { view.session.stop() }
                    else { self.replace() }
                } else if result.code == 75 {
                    GlobalPool.clean(prepared)
                    self.nextAttempt = Date().addingTimeInterval(self.retryInterval)
                    view.setWaiting(true)
                    self.notice(self.event == nil ? "全局账号池暂无已登录且额度可用的账号。每 60 秒重试，最长等待 5 小时；Ctrl-C 可取消。" : "全局账号池暂无其他已登录且额度可用的账号。每 60 秒重试，最长等待 5 小时；Ctrl-C 可取消，原会话仍可操作。", state: .waitingForAccount)
                } else {
                    GlobalPool.clean(prepared)
                    self.notice("自动接续未完成。原会话与文件已保留；请检查登录、项目目录或 CCAM 配置。", state: .failed)
                    // Dry-run diagnostics may contain environment values; do not
                    // copy them to the interface or persistent logs.
                    self.cancel(user: false)
                }
            }
        }
    }

    func exited(_ code: Int32) {
        guard !cancelled else { return }
        if pending != nil { replace(); return }
        if code == 75 && event == nil, let ticket = plan.ticket, FileManager.default.fileExists(atPath: ticket) {
            waitingSince = waitingSince ?? Date()
            nextAttempt = Date().addingTimeInterval(retryInterval)
            view?.setWaiting(true)
            notice("全局账号池暂无已登录且额度可用的账号。每 60 秒重试；Ctrl-C 可取消。", state: .waitingForAccount)
            if timer == nil { timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() } }
            return
        }
        if code == 75 && plan.ticket == nil {
            notice("本次未能启动。全局账号池可能没有可用账号；请检查登录和额度后重新开始。", state: .failed)
        } else {
            onStateChanged?(code == 0 ? .closed : .failed, code == 0 ? "会话已结束，项目文件与对话记录已保留。" : "会话已退出（\(code)），项目文件与对话记录已保留。")
        }
        // A normal exit, authentication/network failure, or user /exit is not
        // evidence that an account is exhausted and must never cause a restart.
        cancel(user: false)
    }

    private func replace() {
        guard !cancelled, let replacement = pending, let view, !view.session.running else { return }
        pending = nil
        GlobalPool.clean(plan); plan = replacement
        event = nil; waitingSince = nil; nextAttempt = .distantFuture; lastNotice = ""
        lastInterruptAt = nil
        view.setWaiting(false)
        view.start(executable: replacement.environment["CCAM_DESKTOP_CCAM"] ?? CCAMClient.executable,
                   args: replacement.args, environmentOverrides: replacement.environment)
    }

    func interrupted() {
        // A hook may arrive just after Ctrl-C. Remember the interruption even
        // before the polling timer has observed its event, without disabling
        // automatic recovery for a genuinely later quota failure.
        lastInterruptAt = Date()
        guard waitingSince != nil || pending != nil else { return }
        notice("已取消本次自动接续。可以稍后从项目继续工作。", state: .paused)
        generation += 1; checking = false
        if let pending { GlobalPool.clean(pending); self.pending = nil }
        event = nil; waitingSince = nil; nextAttempt = .distantFuture
        try? FileManager.default.removeItem(at: plan.eventURL)
        view?.setWaiting(false)
        // The current Claude may keep running after Ctrl-C. Its next genuine
        // StopFailure still gets a fresh event and can use the pool again.
        if view?.session.running != true { cancel(user: false) }
    }

    func cancel(user: Bool) {
        if user { onStateChanged?(.paused, "已停止自动续做，项目文件与对话记录已保留。") }
        cancelled = true; generation += 1; checking = false
        timer?.invalidate(); timer = nil; view?.setWaiting(false)
        if let pending { GlobalPool.clean(pending); self.pending = nil }
        GlobalPool.clean(plan)
    }
}
