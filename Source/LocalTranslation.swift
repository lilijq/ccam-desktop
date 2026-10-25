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
    case notInstalled, tooLong, cancelled, timedOut, failed
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "本地翻译尚未安装，请先在翻译设置中安装中英模型。"
        case .tooLong: return "这段内容太长，请分段翻译（每次最多 40,000 字符）。"
        case .cancelled: return "已取消翻译，原文已保留。"
        case .timedOut: return "本地翻译超时，原文已保留，请缩短内容后重试。"
        case .failed: return "本地翻译未完成，原文已保留。请检查翻译组件后重试。"
        }
    }
}

/// Inference never contacts a server. Only the separate, explicit setup command
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
    init(home: URL = LocalTranslator.defaultHome, workerURL: URL? = nil, timeout: TimeInterval = 90) {
        self.home = home
        self.workerURL = workerURL ?? Bundle.main.url(forResource: "translate_worker", withExtension: "py", subdirectory: "Translation")
        self.timeout = timeout
    }
    var isReady: Bool {
        let fm = FileManager.default
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
        guard isReady, let workerURL else { gate.finish(.failure(LocalTranslationError.notInstalled)); return request }
        let home = self.home, timeout = self.timeout
        Self.inferenceQueue.async {
            guard !request.isCancelled else { return }
            let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
            process.executableURL = home.appendingPathComponent("venv/bin/python3")
            process.arguments = ["-I", "-B", workerURL.path, "--home", home.path]
            process.currentDirectoryURL = home
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
                                   "OMP_NUM_THREADS": "2", "VECLIB_MAXIMUM_THREADS": "2"]
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            func terminate() {
                guard process.isRunning else { return }; process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
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
                guard process.terminationStatus == 0,
                      let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let translated = response["translation"] as? String,
                      !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalTranslationError.failed }
                gate.finish(.success(translated))
            } catch {
                terminate(); request.clear()
                gate.finish(.failure(request.isCancelled ? LocalTranslationError.cancelled : LocalTranslationError.failed))
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
