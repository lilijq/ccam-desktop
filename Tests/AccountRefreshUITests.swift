import AppKit

private final class AccountRefreshFixtureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Verifies the manual refresh affordance without constructing AppDelegate or starting CCAM.
enum AccountRefreshUITests {
    static func run() throws -> Int {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            count += 1
            if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        func settle(_ view: NSView) {
            for _ in 0..<4 {
                view.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
        }
        func inside(_ view: NSView, _ parent: NSView) -> Bool {
            let rect = view.convert(view.bounds, to: parent)
            return rect.minX >= -0.5 && rect.minY >= -0.5 && rect.maxX <= parent.bounds.width + 0.5 && rect.maxY <= parent.bounds.height + 0.5
        }

        var requests = 0
        let idle = AccountRefreshControl(refreshing: false, lastRefresh: nil, failed: false) { requests += 1 }
        check(idle.button.isEnabled && idle.button.image != nil, "account refresh starts as an enabled visible action")
        check(idle.feedback.stringValue == "仅本机缓存", "initial refresh state does not imply a successful live check")
        check(idle.button.toolTip?.contains("不连接 Claude") == true, "refresh explains its local-only scope")
        idle.button.performClick(nil)
        check(requests == 1, "manual refresh invokes exactly one callback")

        let date = Date(timeIntervalSince1970: 1_798_143_496)
        let loading = AccountRefreshControl(refreshing: true, lastRefresh: date, failed: true) { requests += 1 }
        loading.button.performClick(nil)
        loading.button.invoke()
        check(!loading.button.isEnabled && requests == 1, "pending refresh suppresses duplicate actions, including direct action dispatch")
        check(loading.feedback.stringValue.contains("正在读取") && !loading.feedback.stringValue.contains("已刷新"), "pending feedback does not report stale success")
        check(loading.button.accessibilityLabel()?.contains("正在刷新") == true, "pending state is available to accessibility")

        let success = AccountRefreshControl(refreshing: false, lastRefresh: date, failed: false) { requests += 1 }
        check(success.feedback.stringValue.hasPrefix("已刷新 ") && success.feedback.stringValue.filter { $0 == ":" }.count == 2,
              "successful local read exposes a completion time")
        check(success.feedback.toolTip?.contains("额度的实际记录时间") == true, "read completion time is distinguished from quota measurement time")
        let failed = AccountRefreshControl(refreshing: false, lastRefresh: date, failed: true) { requests += 1 }
        check(failed.button.isEnabled && failed.feedback.stringValue.hasPrefix("读取失败 ") && !failed.feedback.stringValue.contains("已刷新"),
              "failed read stays retryable and never claims success")
        failed.button.performClick(nil)
        check(requests == 2, "failed refresh can be retried")
        let untimedFailure = AccountRefreshControl(refreshing: false, lastRefresh: nil, failed: true) { }
        check(untimedFailure.feedback.stringValue == "读取失败", "failure without an attempt date does not invent a timestamp")

        let title = label("账号与额度", size: 28, weight: .semibold)
        let add = ClosureButton("添加账号", symbol: "plus") { }
        let actions = row([success, add]); actions.alignment = .top
        let header = adaptiveRow([title, spacer(), actions], spacing: 12, breakpoint: 560)
        let host = ThemeSurface(Theme.background)
        host.appearance = NSAppearance(named: .darkAqua)
        header.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: host.topAnchor, constant: 18)
        ])
        let window = AccountRefreshFixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 160), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        for width in [CGFloat(960), CGFloat(390)] {
            window.setContentSize(NSSize(width: width, height: 180)); settle(host)
            check(ChatUITests.all(host).filter { $0 is NSButton }.count == 2, "account header keeps both refresh and add actions at width \(width)")
            check(inside(success.button, host) && inside(success.feedback, host) && inside(add, host) && inside(title, host),
                  "account refresh header fits width \(width) without clipped controls")
            check(success.button.bounds.width >= 120 && success.button.bounds.height >= 32, "refresh remains an ample click target at width \(width)")
            let refreshRect = success.button.convert(success.button.bounds, to: host)
            let addRect = add.convert(add.bounds, to: host)
            check(!refreshRect.intersects(addRect), "refresh and add controls do not overlap at width \(width)")
            check(window.makeFirstResponder(success.button) && window.firstResponder === success.button, "refresh accepts keyboard focus at width \(width)")
            check(header.orientation == (width < 560 ? .vertical : .horizontal), "header reflows rather than compressing action labels at width \(width)")
            try ChatUITests.snapshot(host, name: width < 560 ? "account-refresh-compact" : "account-refresh-desktop")
        }
        check(!window.isVisible, "account refresh validation remains offscreen")
        return count
    }
}
