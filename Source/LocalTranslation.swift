import Foundation
import Darwin

enum TranslationLanguage: String { case chinese = "zh", english = "en" }

protocol ChatTranslating {
    @discardableResult
    func translate(_ text: String, from: TranslationLanguage, to: TranslationLanguage,
                   completion: @escaping (Result<String, Error>) -> Void) -> TranslationRequest
}

/// Cancellation is idempotent and can also be used by deterministic UI fixtures.
final class TranslationRequest {
    private let lock = NSLock()
    private var cancelled = false
    private var cancellation: (() -> Void)?
    init(cancel: @escaping () -> Void = {}) { cancellation = cancel }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() {
        lock.lock(); guard !cancelled else { lock.unlock(); return }
        cancelled = true; let action = cancellation; cancellation = nil; lock.unlock(); action?()
    }
    fileprivate func onCancel(_ action: @escaping () -> Void) {
        lock.lock(); let callNow = cancelled
        if !callNow { cancellation = action }; lock.unlock()
        if callNow { action() }
    }
    fileprivate func clear() { lock.lock(); cancellation = nil; lock.unlock() }
}

enum LocalTranslationError: LocalizedError {
    case notInstalled, tooLong, cancelled, timedOut, failed, protectedText, segmentTooLong, emptyResult, nativeUnavailable, nativeFailed
    var errorDescription: String? {
        switch self {
        case .nativeUnavailable: return "移动盘未连接或原生翻译组件缺失，原文已保留。请连接移动盘后重试。"
        case .nativeFailed: return "原生翻译未完成，原文已保留。请检查移动盘或在翻译设置中重新安装。"
        case .notInstalled: return "本地翻译尚未安装，请先在翻译设置中安装中英模型。"
        case .tooLong: return "这段内容太长，请分段翻译（每次最多 40,000 字符）。"
        case .cancelled: return "已取消翻译，原文已保留。"
        case .timedOut: return "本地翻译超时，原文已保留，请缩短内容后重试。"
        case .failed: return "本地翻译未完成，原文已保留。可重试或查看原文。"
        case .protectedText: return "代码或免译内容校验未通过，原文已保留。请分段重试。"
        case .segmentTooLong: return "单段内容超出翻译模型容量，请分段重试。原文已保留。"
        case .emptyResult: return "翻译结果不完整，原文已保留，请重试。"
        }
    }
}

/// Inference only uses an authenticated loopback server. The explicit setup command
/// downloads dependencies and model packages; no Claude/account environment is inherited.
final class LocalTranslator: ChatTranslating {
    static let shared = LocalTranslator()
    // Models are loaded per request. Serialize globally so a reply containing
    // many text blocks cannot start many heavyweight workers at once.
    private static let inferenceQueue = DispatchQueue(label: "ccam.translation.worker", qos: .userInitiated)
    static var defaultHome: URL {
        if let path = ProcessInfo.processInfo.environment["CCAM_TRANSLATION_HOME"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CCAM Desktop/Translation", isDirectory: true)
    }
    let home: URL
    let workerURL: URL?
    private let timeout: TimeInterval
    init(home: URL = LocalTranslator.defaultHome, workerURL: URL? = nil, timeout: TimeInterval = 300) {
        self.home = home
        self.workerURL = workerURL ?? Bundle.main.url(forResource: "translate_worker", withExtension: "py", subdirectory: "Translation")
        self.timeout = timeout
    }
    var usesNative: Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent("native.json").path) }
    var nativeDataRoot: String? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("native.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              config["engine"] as? String == "Hy-MT2-1.8B-Q8_0",
              let path = config["dataRoot"] as? String, path.hasPrefix("/") else { return nil }
        return path
    }
    var isReady: Bool {
        let fm = FileManager.default
        if usesNative {
            guard let workerURL, fm.isReadableFile(atPath: workerURL.path), let root = nativeDataRoot else { return false }
            return fm.isExecutableFile(atPath: root + "/runtime/llama-b11871/llama-server")
                && fm.isReadableFile(atPath: root + "/models/Hy-MT2-1.8B-Q8_0.gguf")
                && fm.isReadableFile(atPath: workerURL.deletingLastPathComponent().appendingPathComponent("native_translation.py").path)
        }
        guard let workerURL, fm.isReadableFile(atPath: workerURL.path),
              fm.isExecutableFile(atPath: home.appendingPathComponent("venv/bin/python3").path),
              let data = try? Data(contentsOf: home.appendingPathComponent("installed.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["version"] as? Int == 1 else { return false }
        return ["zh_en", "en_zh"].allSatisfy { pair in
            ["model/model.bin", "sentencepiece.model", "metadata.json"].allSatisfy {
                fm.isReadableFile(atPath: home.appendingPathComponent("models/" + pair + "/" + $0).path)
            }
        }
    }

    @discardableResult
    func translate(_ text: String, from: TranslationLanguage, to: TranslationLanguage,
                   completion: @escaping (Result<String, Error>) -> Void) -> TranslationRequest {
        let request = TranslationRequest()
        let gate = TranslationCompletion(completion)
        request.onCancel { gate.finish(.failure(LocalTranslationError.cancelled)) }
        guard text.count <= 40_000, text.utf8.count <= 160_000 else {
            gate.finish(.failure(LocalTranslationError.tooLong)); return request
        }
        guard !text.isEmpty, from != to else { gate.finish(.success(text)); return request }
        guard isReady, let workerURL else { gate.finish(.failure(usesNative ? LocalTranslationError.nativeUnavailable : LocalTranslationError.notInstalled)); return request }
        let home = self.home, timeout = self.timeout, native = self.usesNative
        Self.inferenceQueue.async {
            guard !request.isCancelled else { return }
            let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
            process.executableURL = native ? URL(fileURLWithPath: "/usr/bin/python3") : home.appendingPathComponent("venv/bin/python3")
            process.arguments = ["-I", "-B", workerURL.path, "--home", home.path]
            process.currentDirectoryURL = home
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
                                   "OMP_NUM_THREADS": "2", "VECLIB_MAXIMUM_THREADS": "2"]
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            func terminate() {
                guard process.isRunning else { return }
                let pid = process.processIdentifier
                if native && getpgid(pid) == pid { kill(-pid, SIGTERM) } else { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning {
                        if native && getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
                    }
                }
            }
            request.onCancel { terminate(); gate.finish(.failure(LocalTranslationError.cancelled)) }
            do {
                guard !request.isCancelled else { return }
                try process.run()
                if request.isCancelled { terminate() }
                let watchdog = DispatchWorkItem {
                    if gate.finish(.failure(LocalTranslationError.timedOut)) { terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                let drain = DispatchGroup(); drain.enter()
                DispatchQueue.global(qos: .utility).async {
                    while !errors.fileHandleForReading.availableData.isEmpty { }
                    try? errors.fileHandleForReading.close(); drain.leave()
                }
                let frame: [String: String] = ["text": text, "source": from.rawValue, "target": to.rawValue]
                try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: frame))
                try input.fileHandleForWriting.close()
                var data = Data()
                while true {
                    let bytes = output.fileHandleForReading.availableData
                    if bytes.isEmpty { break }
                    guard data.count + bytes.count <= 640_000 else { terminate(); throw LocalTranslationError.failed }
                    data.append(bytes)
                }
                try? output.fileHandleForReading.close(); process.waitUntilExit(); drain.wait(); watchdog.cancel()
                request.clear()
                guard !request.isCancelled else { return }
                let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                if let code = response?["error"] as? String {
                    switch code {
                    case "preservation_failed": throw LocalTranslationError.protectedText
                    case "segment_too_long": throw LocalTranslationError.segmentTooLong
                    case "empty_result", "incomplete_result": throw LocalTranslationError.emptyResult
                    case "component_unavailable": throw LocalTranslationError.notInstalled
                    case "native_unavailable": throw LocalTranslationError.nativeUnavailable
                    case "native_start_failed", "native_failed": throw LocalTranslationError.nativeFailed
                    default: throw LocalTranslationError.failed
                    }
                }
                guard process.terminationStatus == 0, let response,
                      let translated = response["translation"] as? String,
                      !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalTranslationError.failed }
                gate.finish(.success(translated))
            } catch {
                terminate(); request.clear()
                gate.finish(.failure(request.isCancelled ? LocalTranslationError.cancelled : (error as? LocalTranslationError ?? LocalTranslationError.failed)))
            }
        }
        return request
    }
}

private final class TranslationCompletion {
    private let lock = NSLock()
    private var completed = false
    private let completion: (Result<String, Error>) -> Void
    init(_ completion: @escaping (Result<String, Error>) -> Void) { self.completion = completion }
    @discardableResult func finish(_ result: Result<String, Error>) -> Bool {
        lock.lock(); guard !completed else { lock.unlock(); return false }; completed = true; lock.unlock()
        DispatchQueue.main.async { self.completion(result) }; return true
    }
}

/// Translates stable prose/code units while a reply is still arriving. Partial
/// results stay in memory; only an exact, completed source is persisted by the view.
final class StreamingReplyTranslation {
    private let translator: ChatTranslating
    private var request: TranslationRequest?
    private var scheduled: DispatchWorkItem?
    private var token = UUID()
    private var consumed = ""
    private(set) var source = ""
    private(set) var translated = ""
    private(set) var error: Error?
    private(set) var complete = false
    private(set) var working = false
    var onChange: (() -> Void)?
    var finished: Bool { complete && !working && consumed == source && error == nil }
    var preview: String? {
        guard error == nil else { return nil }
        return translated + (consumed == source ? "" : (translated.isEmpty ? "" : "\n\n") + "正在翻译…")
    }
    init(translator: ChatTranslating) { self.translator = translator }
    deinit { request?.cancel(); scheduled?.cancel() }
    func cancel() {
        token = UUID(); scheduled?.cancel(); scheduled = nil
        let old = request; request = nil; working = false; old?.cancel()
    }
    func update(_ value: String, complete: Bool) {
        let becameComplete = complete && !self.complete
        if !value.hasPrefix(source) {
            cancel(); consumed = ""; translated = ""; error = nil
        }
        source = value; self.complete = complete
        if becameComplete && consumed == source && !working && error == nil { onChange?(); return }
        guard !working, scheduled == nil, error == nil, consumed != source else { return }
        let work = DispatchWorkItem { [weak self] in self?.scheduled = nil; self?.pump() }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (complete ? 0 : 0.35), execute: work)
    }
    private func pump() {
        guard !working, error == nil else { return }
        let remainder = String(source.dropFirst(consumed.count))
        let chunk = complete ? remainder : Self.stablePrefix(remainder)
        guard !chunk.isEmpty else { return }
        if chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            translated += chunk; consumed += chunk; onChange?(); update(source, complete: complete); return
        }
        let expected = consumed + chunk, operation = UUID(); token = operation; working = true
        let next = translator.translate(chunk, from: .english, to: .chinese) { [weak self] result in
            guard let self, self.token == operation, self.source.hasPrefix(expected) else { return }
            self.working = false; self.request = nil
            do {
                let value = try result.get()
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalTranslationError.emptyResult }
                let leading = String(chunk.prefix { $0.isWhitespace })
                let trailing = String(chunk.reversed().prefix { $0.isWhitespace }.reversed())
                self.translated += leading + value.trimmingCharacters(in: .whitespacesAndNewlines) + trailing
                self.consumed = expected
            } catch { self.error = error }
            self.onChange?()
            self.update(self.source, complete: self.complete)
        }
        if working && token == operation { request = next }
    }

    /// Never cut a fenced/inline code span, no-translate wrapper or table in half.
    /// Incomplete markup stays buffered until it closes or the reply ends.
    static func stablePrefix(_ text: String) -> String {
        var fence: Character?, fenceLength = 0, ticks = 0, exempt = 0, table = false
        var offset = text.startIndex, boundary = text.startIndex
        while offset < text.endIndex {
            let end = text[offset...].firstIndex(of: "\n")
            let lineEnd = end ?? text.endIndex
            let after = end.map { text.index(after: $0) } ?? text.endIndex
            let line = String(text[offset..<lineEnd])
            let trim = line.trimmingCharacters(in: .whitespaces)
            let marker = trim.first
            let run = (marker == "`" || marker == "~") ? trim.prefix { $0 == marker }.count : 0
            if let active = fence {
                if marker == active && run >= fenceLength && trim.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                    if end != nil { boundary = after }
                }
                offset = after; continue
            }
            if ticks == 0 && exempt == 0 && run >= 3 {
                fence = marker; fenceLength = run; offset = after; continue
            }
            if ticks == 0 && exempt == 0 && trim.contains("|") { table = true }
            var i = offset
            while i < lineEnd {
                let c = text[i]
                if c == "`" && exempt == 0 {
                    var next = i
                    while next < lineEnd && text[next] == "`" { next = text.index(after: next) }
                    let length = text.distance(from: i, to: next)
                    if ticks == 0 { ticks = length } else if ticks == length { ticks = 0 }
                    i = next; continue
                }
                if c == "～" && ticks == 0 {
                    var next = text.index(after: i)
                    if next < lineEnd && text[next] == "～" { next = text.index(after: next) }
                    let length = text.distance(from: i, to: next)
                    if exempt == 0 { exempt = length } else if exempt == length { exempt = 0 }
                    i = next; continue
                }
                let next = text.index(after: i)
                if ticks == 0 && exempt == 0 && !table && ".!?。！？".contains(c),
                   next < text.endIndex && text[next].isWhitespace,
                   text.distance(from: text.startIndex, to: next) >= 80 {
                    boundary = next
                }
                i = next
            }
            if ticks == 0 && exempt == 0 && end != nil {
                if trim.isEmpty { table = false }
                if !table { boundary = after }
            }
            if text.distance(from: text.startIndex, to: boundary) >= 900 { break }
            offset = after
        }
        return String(text[..<boundary])
    }
}
