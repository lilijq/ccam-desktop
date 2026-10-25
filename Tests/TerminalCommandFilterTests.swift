import Foundation

@main struct TerminalCommandFilterTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func filter(_ text: String, chunks: Int = Int.max, accounts: [String] = []) -> String {
        let filter = TerminalCommandFilter(accountNames: accounts)
        let bytes = Array(text.utf8)
        var output = [UInt8](), offset = 0
        while offset < bytes.count {
            let end = offset + min(chunks, bytes.count - offset)
            output += filter.append(Array(bytes[offset..<end])); offset = end
        }
        output += filter.finish()
        return String(decoding: output, as: UTF8.self)
    }
    static func main() {
        let replacement = TerminalCommandFilter.replacement
        let ordinary = "你好，正在工作…\r\n\u{1b}[32m允许修改文件？\u{1b}[0m [y/n]"
        check(filter(ordinary, chunks: 1) == ordinary, "UTF-8, color and no-newline permission prompt remain byte-for-byte intact")
        check(filter("ccam add work\n下一步", chunks: 1) == replacement + "\n下一步", "command split across chunks suppressed")
        check(filter("请运行 ccam usage --json\r\n完成") == "请运行 " + replacement + "\r\n完成", "embedded command parameters suppressed")
        check(filter("ccam c1111 --continue\n", chunks: 2, accounts: ["c1111"]) == replacement + "\n", "known account invocation hidden")
        check(filter("ccam 12 --resume\n") == replacement + "\n", "numeric account shorthand hidden")
        check(filter("ccam: network error\n") == "ccam: network error\n", "diagnostic prefix is not mistaken for a command")
        check(filter("ccam: token expired; ccam login work\n") == "ccam: token expired; " + replacement + "\n", "command inside diagnostic hidden while reason remains")
        check(filter("CCAM Desktop\nccam improves workflow\nmyccam usage\nabc_ccam login\n") == "CCAM Desktop\nccam improves workflow\nmyccam usage\nabc_ccam login\n", "brand prose and longer identifiers stay intact")
        check(filter("CCAM USAGE --json\n") == replacement + "\n", "known operations matched case-insensitively")
        check(filter("ccam --help\n") == replacement + "\n", "root command option hidden")
        let colored = "\u{1b}[31mcc\u{1b}[1mam lo\u{1b}[0mgin work\u{1b}[0m\n"
        check(filter(colored, chunks: 1) == "\u{1b}[31m\u{1b}[1m\u{1b}[0m" + replacement + "\u{1b}[0m\n", "SGR between command letters preserved including resets")
        let moved = "ccam login work\u{1b}[2;1HDo you trust this folder? [y/n]"
        check(filter(moved, chunks: 1) == replacement + "\u{1b}[2;1HDo you trust this folder? [y/n]", "cursor positioning terminates suppression before trust prompt")
        let erased = "ccam next --auto\u{1b}[2J\u{1b}[H授权请求"
        check(filter(erased, chunks: 3) == replacement + "\u{1b}[2J\u{1b}[H授权请求", "clear and redraw ends suppression without newline")
        check(filter("ccam login\r允许连接服务？") == replacement + "\r允许连接服务？", "carriage return preserves following interactive prompt")
        check(filter("Run ccam login work? [Y/n]: ", chunks: 1) == "Run " + replacement + " [Y/n]: ", "same-line explicit confirmation remains visible")
        check(filter("ccam remove work (yes/no)", chunks: 2) == replacement + " (yes/no)", "long confirmation marker survives chunk splits")
        let osc = "\u{1b}]0;ccam run work\u{7}真实内容"
        check(filter(osc, chunks: 1) == osc, "OSC title payload is opaque and preserved")
        let hyperlink = "\u{1b}]8;;https://example.test/ccam/login\u{1b}\\打开链接\u{1b}]8;;\u{1b}\\"
        check(filter(hyperlink, chunks: 1) == hyperlink, "OSC hyperlink escapes remain intact")
        check(filter("ccam usage") == replacement, "unterminated command flushed as replacement at exit")
        check(filter("ccam") == "ccam" && filter("ccam unknown") == "ccam unknown", "incomplete or unknown words retained at exit")
        check(filter("ccam run --settings {\"hooks\":{\"StopFailure\":[]}}\n允许读取文件？") == replacement + "\n允许读取文件？", "helper settings stay hidden inside recognized command")
        let repeated = "ccam list\nccam login work\n确认？"
        check(filter(repeated, chunks: 2) == replacement + "\n" + replacement + "\n确认？", "successive command lines do not suppress following question")
        let bounded = TerminalCommandFilter(maximumSuppressedBytes: 64)
        let longLine = Array(("ccam run " + String(repeating: "x", count: 100) + "允许？").utf8)
        let result = String(decoding: bounded.append(longLine) + bounded.finish(), as: UTF8.self)
        check(result.hasSuffix("允许？") && result.contains(replacement), "unbounded malformed line cannot suppress interaction forever")
        let unicodeBound = TerminalCommandFilter(maximumSuppressedBytes: 64)
        let unicodeResult = unicodeBound.append(Array(("ccam run " + String(repeating: "好", count: 40) + "确认").utf8)) + unicodeBound.finish()
        check(String(bytes: unicodeResult, encoding: .utf8) != nil, "suppression limit never splits a UTF-8 glyph")
        let resettable = TerminalCommandFilter()
        _ = resettable.append(Array("ccam lo".utf8)); resettable.reset()
        check(String(decoding: resettable.append(Array("正常会话".utf8)) + resettable.finish(), as: UTF8.self) == "正常会话", "reset does not carry old launch prefix into next process")
        let dcs = "\u{1b}P" + String(repeating: "ccam login work", count: 1500) + "\u{1b}\\正常"
        check(filter(dcs, chunks: 7) == dcs, "long DCS control strings stream opaquely without unbounded buffering")
        print("PASS: \(count) terminal command display checks")
    }
}
