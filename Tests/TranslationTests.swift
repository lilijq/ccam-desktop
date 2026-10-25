import Foundation

@main struct TranslationTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func wait(_ condition: () -> Bool, timeout: TimeInterval = 4) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(condition(), "translation completes within bounded fixture time")
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccam-translation-test-" + UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let absent = LocalTranslator(home: root)
        check(!absent.isReady, "missing installation is unavailable")
        var missing: Result<String, Error>?
        absent.translate("你好", from: .chinese, to: .english) { missing = $0; check(Thread.isMainThread, "completion runs on main thread") }
        wait { missing != nil }
        if case .failure(let error) = missing { check(error.localizedDescription.contains("尚未安装"), "missing engine gives an actionable local message") }
        else { check(false, "missing engine cannot silently pass original text") }
        var cancelCount = 0
        let cancellable = TranslationRequest { cancelCount += 1 }; cancellable.cancel(); cancellable.cancel()
        check(cancelCount == 1, "mock-friendly cancellation is idempotent")

        let bin = root.appendingPathComponent("venv/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: bin.appendingPathComponent("python3"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/python3"))
        try Data("{\"version\":1}".utf8).write(to: root.appendingPathComponent("installed.json"))
        for pair in ["zh_en", "en_zh"] {
            let model = root.appendingPathComponent("models/" + pair)
            try fm.createDirectory(at: model.appendingPathComponent("model"), withIntermediateDirectories: true)
            for name in ["metadata.json", "sentencepiece.model", "model/model.bin"] { try Data().write(to: model.appendingPathComponent(name)) }
        }
        func worker(_ source: String) throws -> URL {
            let file = root.appendingPathComponent(UUID().uuidString + ".py")
            try source.write(to: file, atomically: true, encoding: .utf8); return file
        }
        let echo = try worker("import sys,json,os\nr=json.load(sys.stdin)\nassert 'CCAM_TRANSLATION_TEST_SECRET' not in os.environ\nassert 'HTTPS_PROXY' not in os.environ\nprint(json.dumps({'translation':r['source']+'-'+r['target']+': '+r['text']}))\n")
        let translator = LocalTranslator(home: root, workerURL: echo, timeout: 2)
        check(translator.isReady, "complete local model installation is recognized")
        setenv("CCAM_TRANSLATION_TEST_SECRET", "fixture-only", 1)
        defer { unsetenv("CCAM_TRANSLATION_TEST_SECRET") }
        var translated: Result<String, Error>?
        translator.translate("你好\n`main.rs`", from: .chinese, to: .english) { translated = $0 }
        wait { translated != nil }
        check((try? translated?.get()) == "zh-en: 你好\n`main.rs`", "JSON transport preserves Unicode and code without inheriting environment")
        var overlong: Result<String, Error>?
        translator.translate(String(repeating: "a", count: 40_001), from: .english, to: .chinese) { overlong = $0 }
        wait { overlong != nil }
        if case .failure(let error) = overlong { check(error.localizedDescription.contains("40,000"), "oversized text is rejected before inference") }
        else { check(false, "oversized input must fail") }
        let sleeper = try worker("import time\ntime.sleep(5)\nprint('{\"translation\":\"late\"}')\n")
        let slow = LocalTranslator(home: root, workerURL: sleeper, timeout: 0.15)
        var timedOut: Result<String, Error>?, timeoutCalls = 0
        slow.translate("hello", from: .english, to: .chinese) { timedOut = $0; timeoutCalls += 1 }
        wait { timedOut != nil }
        if case .failure(let error) = timedOut { check(error.localizedDescription.contains("超时"), "stuck worker reports a timeout") }
        else { check(false, "stuck worker must not succeed") }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        check(timeoutCalls == 1, "timeout and process exit cannot deliver duplicate callbacks")
        var cancelled: Result<String, Error>?, cancelCalls = 0
        let pending = slow.translate("hello", from: .english, to: .chinese) { cancelled = $0; cancelCalls += 1 }
        pending.cancel(); pending.cancel(); wait { cancelled != nil }
        if case .failure(let error) = cancelled { check(error.localizedDescription.contains("取消"), "cancelled request preserves an explicit cancellation outcome") }
        else { check(false, "cancelled request must not succeed") }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        check(cancelCalls == 1, "cancel completes once even before worker launch")
        let malformed = LocalTranslator(home: root, workerURL: try worker("print('invalid')\n"), timeout: 1)
        var failure: Result<String, Error>?
        malformed.translate("hello", from: .english, to: .chinese) { failure = $0 }
        wait { failure != nil }
        if case .failure = failure { check(true, "invalid worker output cannot be sent as a translation") }
        else { check(false, "invalid worker must fail") }
        print("PASS: \(checks) offline translation service checks")
    }
}
