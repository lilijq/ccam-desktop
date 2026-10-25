import Foundation

@main struct CoreTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() throws {
        // The fixture follows CCAM 0.11.0's Report/Limits/Window JSON contract.
        let fixture = #"[{"name":"work","slot":1,"status":"ok","source":"cache","at":"2026-10-24T23:00:00Z","limits":{"five_hour":{"percent":72.5,"known":true,"resets_at":"2026-10-25T01:00:00Z"},"weekly":{"percent":0,"known":false,"resets_at":"0001-01-01T00:00:00Z"},"scoped":[{"name":"Fable","window":{"percent":0,"known":true,"resets_at":"0001-01-01T00:00:00Z"}}]}},{"name":"side","status":"logged_out"},{"name":"api","status":"api"},{"name":"expired","status":"expired","error":"token expired","limits":{"five_hour":{"percent":99,"known":true}}},{"name":"error","status":"error","error":"HTTP 429"}]"#
        let values = try AccountUsage.parse(Data(fixture.utf8))
        let empty = try AccountUsage.parse(Data("null".utf8))
        check(empty.isEmpty, "CCAM empty account set emits null")
        check(values.count == 5, "all accounts survive parsing")
        check(values[0].windows.count == 2, "unknown weekly window is not invented as 0%")
        check(values[0].windows[0].used == 72.5, "percent decodes without unit conversion")
        check(values[0].windows[1].used == 0, "known zero is retained")
        check(values[0].windows[1].reset == nil, "Go zero timestamp is hidden")
        check(values[0].cached, "cached source remains visible")
        check(values[1].needsLogin && values[1].windows.isEmpty, "logged out has no synthetic quota")
        check(values[2].statusText == "API 账号", "API account has no subscription quota")
        check(values[3].needsLogin && values[3].windows.count == 1, "expired login retains cached limits")
        check(values[4].statusText == "读取失败", "server error is explicit")
        do { _ = try AccountUsage.parse(Data("{}".utf8)); check(false, "invalid shape rejected") } catch { check(true, "invalid shape") }
        let accounts = try JSONDecoder().decode([Account].self, from: Data(#"[{"name":"work","default":true,"email":"","groups":[]}]"#.utf8))
        check(accounts[0].isDefault == true, "default account maps correctly")
        let escaped = "space and 'quote' $(touch /tmp/not-run); `whoami`"
        let quoted = Shell.quote(escaped)
        let task = Process(); let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", "printf '%s' " + quoted]; task.standardOutput = pipe
        try task.run(); let result = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        check(String(decoding: result, as: UTF8.self) == escaped, "shell launch quoting preserves literal metacharacters")
        let arguments = try Shell.arguments(#"["mcp","add-json","test","{\"command\":\"npx\"}"]"#)
        check(arguments.last == #"{"command":"npx"}"#, "nested JSON is one argument")
        do { _ = try Shell.arguments("[42]"); check(false, "non-string argv rejected") } catch { check(true, "invalid argv") }
        do { _ = try Catalog.groups[0].arguments([:]); check(false, "required fields rejected") } catch { check(true, "required fields") }
        let group = try Catalog.groups[0].arguments(["group":"team","items":"settings,history","members":"work,side"])
        check(group == ["group","add","team","--items","settings,history","--members","work,side"], "group migration plan command")
        do { _ = try Catalog.mcp[0].arguments(["name":"bad","url":"file:///etc/passwd"]); check(false, "unsupported URL rejected") } catch { check(true, "URL validation") }
        do { _ = try Catalog.mcp[1].arguments(["name":"bad","json":"[]"]); check(false, "MCP array rejected") } catch { check(true, "MCP object validation") }
        let spec = Catalog.positional("test", "", ["folder"], [Catalog.account, Catalog.folder])
        let args = try spec.arguments(["account":"work","folder":"/tmp/project ' with spaces","extra":"[\"--help\"]"])
        check(args == ["folder","work","/tmp/project ' with spaces","--help"], "paths stay a single argument")
        print("PASS: \(count) core checks")
    }
}
