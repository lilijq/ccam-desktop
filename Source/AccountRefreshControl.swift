import AppKit
import QuartzCore

/// Manual clicks read cache; completed chat turns can update through the usage
/// endpoint. The displayed activity distinguishes the two without model probes.
final class AccountRefreshControl: NSStackView {
    let button: ClosureButton
    let feedback: NSTextField
    private let refreshing: Bool

    init(refreshing: Bool, lastRefresh: Date?, failed: Bool, live: Bool = false, action: @escaping () -> Void) {
        self.refreshing = refreshing
        button = ClosureButton(refreshing ? "刷新中…" : "刷新状态", symbol: "waveform.path.ecg") {
            guard !refreshing else { return }
            action()
        }
        let time = lastRefresh.map { date -> String in
            let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
            return formatter.string(from: date)
        }
        let caption: String
        let color: NSColor
        if refreshing { caption = live ? "正在更新额度" : "正在读取本机状态"; color = Theme.muted }
        else if failed { caption = "读取失败" + (time.map { " " + $0 } ?? ""); color = Theme.warning }
        else if let time { caption = "已刷新 " + time; color = Theme.success }
        else { caption = "仅本机缓存"; color = Theme.muted }
        feedback = label(caption, size: 10, color: color)
        super.init(frame: .zero)
        orientation = .vertical; alignment = .trailing; spacing = 5
        button.isEnabled = !refreshing
        button.setAccessibilityLabel(refreshing ? "正在刷新账号状态" : "刷新账号状态")
        button.toolTip = refreshing && live
            ? "问答已结束，正在经代理查询额度接口；不发送模型消息。"
            : "重新读取本机账号状态与额度缓存，不连接 Claude。" + (time.map { "\n上次读取：" + $0 } ?? "")
        feedback.toolTip = "此处时间是刷新完成时间；额度的实际记录时间见账号卡片。"
        button.wantsLayer = true
        addArrangedSubview(button); addArrangedSubview(feedback)
        button.widthAnchor.constraint(equalToConstant: 126).isActive = true
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updatePulse), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); updatePulse()
    }

    @objc private func updatePulse() {
        button.layer?.removeAnimation(forKey: "accountHeartbeat")
        guard refreshing, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [1, 0.55, 1, 0.75, 1]
        pulse.keyTimes = [0, 0.25, 0.45, 0.65, 1]
        pulse.duration = 1.35; pulse.repeatCount = .infinity
        button.layer?.add(pulse, forKey: "accountHeartbeat")
    }
}
