import Foundation

@main struct OperationPresentationTests {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        count += 1
        if !value() { fputs("FAIL: \(name)\n", stderr); exit(1) }
    }
    static func main() {
        let stream = OperationPresentation()
        for byte in Array("\u{1B}[32m中文结果\u{1B}[0m\r\n确认移除？ [y/N] ".utf8) { stream.append([byte]) }
        var snapshot = stream.snapshot()
        check(snapshot.text.contains("中文结果"), "split UTF-8 is reassembled")
        check(!snapshot.text.contains("[32m") && !snapshot.text.contains("\u{1B}"), "split ANSI is removed")
        check(snapshot.affirmative == "y" && snapshot.question?.contains("确认移除") == true, "explicit native yes/no prompt recognized")
        stream.hideSubmittedInput("y"); stream.append(Array("y\r\nDone\r\n".utf8))
        check(stream.snapshot().affirmative == nil, "answered confirmation is not reused")
        let typed = OperationPresentation(); typed.append(Array("Type DELETE to permanently remove:".utf8))
        check(typed.snapshot().affirmative == nil, "typed destructive confirmation never becomes automatic yes")
        let fullYes = OperationPresentation(); fullYes.append(Array("Proceed? (yes/no): ".utf8))
        check(fullYes.snapshot().affirmative == "yes", "full-word confirmation uses the requested answer")
        let partial = OperationPresentation(); partial.append(Array("Ready\u{1B}[".utf8))
        check(partial.snapshot().text == "Ready", "incomplete control sequence stays hidden")
        partial.append(Array("31mError\u{1B}[0m".utf8))
        check(partial.snapshot().text == "ReadyError", "split control sequence resumes correctly")
        check(OperationPresentation.clean("\u{1B}]0;window title\u{7}OK") == "OK", "OSC title is removed")
        check(OperationPresentation.clean("badX\u{8} good") == "bad good", "backspace control is applied")
        let commands = OperationPresentation.clean("ccam group remove --force\nError: account missing. Run `ccam login work`.\nretry with --no-cache\nccam v0.11.0")
        check(!commands.lowercased().contains("ccam") && !commands.contains("--"), "command lines and flags never render")
        check(commands.contains("account missing") && commands.contains("v0.11.0"), "diagnostics and version remain readable")
        let secret = OperationPresentation.clean("access_token: abcsecret\nAuthorization: Bearer sometoken\napi_key=sk-ant-long-secret\npassword=hiddenpass\nrefresh_token: \"partialsecret")
        check(!secret.contains("abcsecret") && !secret.contains("sometoken") && !secret.contains("long-secret") && !secret.contains("hiddenpass") && !secret.contains("partialsecret"), "common secrets including partial quoted tokens are masked")
        let links = OperationPresentation()
        links.append(Array("Visit https://example.com/oauth/authorize?state=abc\nCallback https://localhost/callback?code=secretauth\nBad https://user:pass@example.com/\n".utf8))
        snapshot = links.snapshot()
        check(snapshot.links.count == 1 && snapshot.links[0].url.host == "example.com", "only noncredential authorization links are offered")
        check(!snapshot.text.contains("https://") && !snapshot.text.contains("secretauth") && !snapshot.text.contains("state=abc"), "raw URLs and query values are hidden in results")
        let json = OperationPresentation()
        json.append(Array("[{\"name\":\"work\",\"default\":true,\"status\":\"expired\",\"api_key\":\"secretvalue\",\"command\":\"ccam\",\"args\":[\"--json\"],\"limits\":{\"percent\":0}}]".utf8))
        snapshot = json.snapshot()
        check(snapshot.text.contains("名称：work") && snapshot.text.contains("默认：是") && snapshot.text.contains("登录已过期"), "JSON becomes readable labeled fields")
        check(snapshot.text.contains("已使用（%）：0"), "zero values preserved")
        check(!snapshot.text.contains("secretvalue") && !snapshot.text.contains("--json") && !snapshot.text.contains("ccam"), "JSON credentials and command configuration are hidden")
        check(!snapshot.hasIssues && snapshot.text.contains("记录 1") && !snapshot.text.contains("项目 1"), "account records are not projects or partial failures")
        let errors = OperationPresentation()
        errors.append(Array("[{\"status\":\"ok\"},{\"status\":\"error\",\"error\":\"quota service unavailable\"}]".utf8))
        check(errors.snapshot().hasIssues && errors.snapshot().text.contains("读取异常"), "mixed JSON results report issues even when the process exits successfully")
        let echo = OperationPresentation()
        echo.hideSubmittedInput("https://localhost/callback?code=private-code")
        echo.append(Array("https://localhost/callback?code=private-code\nAccepted".utf8))
        check(!echo.snapshot().text.contains("private-code") && echo.snapshot().links.isEmpty, "submitted callback never reappears or becomes a link")
        echo.hideSubmittedInput("mypassword")
        echo.append(Array("mypassword\n".utf8))
        check(!echo.snapshot().text.contains("mypassword"), "submitted text is hidden if a child echoes it")
        let empty = OperationPresentation(); empty.append(Array("[]".utf8))
        check(empty.snapshot().text == "无记录", "empty JSON gets readable empty state")
        let unknown = OperationPresentation(); unknown.append(Array("Choose a custom name:".utf8))
        check(unknown.snapshot().text == "Choose a custom name:" && unknown.snapshot().affirmative == nil, "unknown prompts remain readable without inferred answers")
        print("PASS: \(count) native operation presentation checks")
    }
}
