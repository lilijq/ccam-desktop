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
        for (code, hint) in [("preservation_failed", "免译"), ("segment_too_long", "单段"), ("incomplete_result", "不完整"), ("unknown_private_error", "可重试")] {
            let fixture = try worker("import sys,json\nprint(json.dumps({'error':'" + code + "'}))\nsys.exit(1)\n")
            let service = LocalTranslator(home: root, workerURL: fixture, timeout: 2)
            var result: Result<String, Error>?
            service.translate("hello", from: .english, to: .chinese) { result = $0 }
            wait { result != nil }
            if case .failure(let error) = result { check(error.localizedDescription.contains(hint) && !error.localizedDescription.contains(code), "typed worker errors are actionable without leaking internal content") }
            else { check(false, "error response cannot succeed") }
        }
        let nativeRoot = root.appendingPathComponent("external")
        try fm.createDirectory(at: nativeRoot.appendingPathComponent("runtime/llama-b11871"), withIntermediateDirectories: true)
        try fm.createDirectory(at: nativeRoot.appendingPathComponent("models"), withIntermediateDirectories: true)
        let server = nativeRoot.appendingPathComponent("runtime/llama-b11871/llama-server")
        try Data("fixture".utf8).write(to: server); try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        try Data().write(to: nativeRoot.appendingPathComponent("models/Hy-MT2-1.8B-Q8_0.gguf"))
        try Data().write(to: root.appendingPathComponent("native_translation.py"))
        try JSONSerialization.data(withJSONObject: ["engine": "Hy-MT2-1.8B-Q8_0", "dataRoot": nativeRoot.path]).write(to: root.appendingPathComponent("native.json"))
        check(translator.usesNative && translator.isReady, "native pointer enables external model without deleting legacy runtime")
        try fm.removeItem(at: nativeRoot)
        check(!translator.isReady, "missing external model does not fall back to legacy engine")
        var unavailable: Result<String, Error>?
        translator.translate("hello", from: .english, to: .chinese) { unavailable = $0 }
        wait { unavailable != nil }
        if case .failure(let error) = unavailable { check(error.localizedDescription.contains("移动盘"), "missing disk has an actionable error") }
        else { check(false, "missing disk must preserve original through failure") }
        let fake = StreamingFixtureTranslator()
        let streaming = StreamingReplyTranslation(translator: fake)
        let intro = "Inspect the repository before deployment.\n\n"
        let openCode = "```rust\nfn main() { println!(\"hello\"); }\n"
        streaming.update(intro + openCode, complete: false)
        wait { fake.jobs.count == 1 }
        check(fake.jobs[0].text == intro, "live prose translates before the turn completes; open code stays buffered")
        fake.jobs[0].finish(.success("部署前检查仓库。"))
        check(streaming.preview!.contains("部署前检查仓库。") && streaming.preview!.contains("正在翻译"), "Chinese prefix appears while trailing content is still streaming")
        let source = intro + openCode + "```\n\nKeep ～server-name～ unchanged."
        streaming.update(source, complete: true)
        wait { fake.jobs.count == 2 }
        check(fake.jobs[1].text == String(source.dropFirst(intro.count)), "only the untranslated suffix is submitted, with complete code and exemption spans")
        fake.jobs[1].finish(.success(openCode + "```\n\n保持 server-name 不变。"))
        check(streaming.finished && streaming.source == source && streaming.translated.contains(openCode), "completed stream retains exact original and preserved code")
        check(!streaming.translated.contains("正在翻译"), "transient progress never becomes the persisted translation")
        check(StreamingReplyTranslation.stablePrefix("Keep ～name\nmore") == "", "open no-translate region is buffered across lines")
        check(StreamingReplyTranslation.stablePrefix("Keep `some\ncode") == "", "open inline code stays buffered")
        check(StreamingReplyTranslation.stablePrefix("| Name | Value |\n| --- | --- |\n| A | B |\n") == "", "streamed tables stay together until their boundary")
        check(StreamingReplyTranslation.stablePrefix("| A | B |\n\nNext") == "| A | B |\n\n", "completed table is released as one unit")
        check(StreamingReplyTranslation.stablePrefix("~~~rust\nlet x = 1;\n~~~\nTail") == "~~~rust\nlet x = 1;\n~~~\n", "tilde code fences are preserved while streaming")
        let rewrite = StreamingReplyTranslation(translator: fake)
        rewrite.update("Original reply.\n", complete: false); wait { fake.jobs.count == 3 }
        rewrite.update("Corrected reply.\n", complete: true)
        check(fake.jobs[2].cancelled, "a final source correction cancels stale inference")
        fake.jobs[2].finish(.success("过期内容")); wait { fake.jobs.count == 4 }
        check(!rewrite.translated.contains("过期"), "late result from replaced source cannot overwrite the corrected reply")
        fake.jobs[3].finish(.failure(LocalTranslationError.failed))
        check(rewrite.error != nil && rewrite.preview == nil, "failed live translation restores the original instead of hiding the reply")
        let jobCount = fake.jobs.count
        rewrite.update("Corrected reply.\n", complete: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        check(fake.jobs.count == jobCount, "translation failure does not create an automatic retry loop")
        let cancelledStream = StreamingReplyTranslation(translator: fake)
        cancelledStream.update("Cancelled text.\n", complete: false); wait { fake.jobs.count == jobCount + 1 }
        cancelledStream.cancel(); fake.jobs.last!.finish(.success("不应出现"))
        check(cancelledStream.translated.isEmpty && fake.jobs.last!.cancelled, "switching away cancels a live translation and rejects its callback")
        let early = StreamingReplyTranslation(translator: fake)
        var completedSignals = 0
        early.onChange = { if early.finished { completedSignals += 1 } }
        let priorCount = fake.jobs.count
        early.update("A complete paragraph.\n", complete: false)
        wait { fake.jobs.count == priorCount + 1 }
        fake.jobs.last!.finish(.success("完整段落。"))
        check(!early.finished, "translated chunks alone do not finalize a running source")
        early.update("A complete paragraph.\n", complete: true)
        check(early.finished && completedSignals == 1, "the final completion signal commits translation even when no untranslated tail remains")
        print("PASS: \(checks) offline translation service checks")
    }
}

private final class StreamingFixtureTranslator: ChatTranslating {
    final class Job {
        let text: String
        let finish: (Result<String, Error>) -> Void
        var cancelled = false
        init(text: String, finish: @escaping (Result<String, Error>) -> Void) { self.text = text; self.finish = finish }
    }
    var jobs: [Job] = []
    func translate(_ text: String, from: TranslationLanguage, to: TranslationLanguage, completion: @escaping (Result<String, Error>) -> Void) -> TranslationRequest {
        let job = Job(text: text, finish: completion); jobs.append(job)
        return TranslationRequest { job.cancelled = true }
    }
}
