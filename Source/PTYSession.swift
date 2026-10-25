import Foundation
import Darwin

/// Owned PTY, foreground process group, nonblocking input/output, and child reaping.
/// All mutable state and callbacks live on the main queue.
final class PTYSession {
    private(set) var pid: pid_t = -1
    private(set) var master: Int32 = -1
    private(set) var running = false
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var monitor: DispatchSourceProcess?
    private var pending = Data()
    private var generation: UInt64 = 0
    var onData: (([UInt8]) -> Void)?
    var onExit: ((Int32) -> Void)?

    func start(executable: String, args: [String], directory: String, environment: [String: String], rows: Int, cols: Int) throws {
        guard !running else { throw AppError.message("此终端已经启动。") }
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw AppError.message("找不到可执行文件：\(executable)") }
        generation &+= 1
        let launchedGeneration = generation
        pending.removeAll()
        var argv = ([executable] + args).map { strdup($0) }; argv.append(nil)
        var env = environment.map { strdup("\($0.key)=\($0.value)") }; env.append(nil)
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        pid = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in
            ccam_pty_spawn(executable, a.baseAddress, e.baseAddress, directory, Int32(max(2, rows)), Int32(max(10, cols)), &master)
        } }
        guard pid > 0 else { throw AppError.message("无法创建终端：\(String(cString: strerror(errno)))") }
        running = true
        let fd = master
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, self.generation == launchedGeneration else { return }
            self.drain()
        }
        // The read source owns closing the descriptor after all pending events finish.
        source.setCancelHandler { Darwin.close(fd) }
        reader = source; source.resume()
        let processMonitor = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        processMonitor.setEventHandler { [weak self] in
            guard let self, self.generation == launchedGeneration else { return }
            self.finish()
        }
        monitor = processMonitor; processMonitor.resume()
    }
    private func drain() {
        guard master >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 65536)
        for _ in 0..<16 {
            let length = Darwin.read(master, &bytes, bytes.count)
            if length > 0 { onData?(Array(bytes.prefix(length))) }
            else { break }
        }
    }
    func send(_ bytes: [UInt8]) {
        guard running, master >= 0 else { return }
        pending.append(contentsOf: bytes); flush()
    }
    func send(_ text: String) { send(Array(text.utf8)) }
    private func flush() {
        while !pending.isEmpty && master >= 0 {
            let n = pending.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            if n > 0 { pending.removeFirst(n) }
            else if n < 0 && errno == EINTR { continue }
            else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if writer == nil {
                    let writingGeneration = generation
                    let source = DispatchSource.makeWriteSource(fileDescriptor: master, queue: .main)
                    source.setEventHandler { [weak self] in
                        guard let self, self.generation == writingGeneration else { return }
                        self.flush()
                    }; writer = source; source.resume()
                }
                return
            } else { pending.removeAll(); break }
        }
        writer?.cancel(); writer = nil
    }
    func resize(rows: Int, cols: Int) {
        if master >= 0 { _ = ccam_pty_resize(master, Int32(max(2, min(rows, 4096))), Int32(max(10, min(cols, 4096)))) }
    }
    func interrupt() { send([3]) }
    func eof() { send([4]) }
    func stop(force: Bool = false) {
        guard running, pid > 0 else { return }
        let signal = force ? SIGKILL : SIGTERM
        let foreground = master >= 0 ? tcgetpgrp(master) : -1
        if foreground > 0 && foreground != getpgrp() { kill(-foreground, signal) }
        kill(-pid, signal); kill(pid, signal)
        if !force {
            let stoppedGeneration = generation, stoppedPID = pid
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.generation == stoppedGeneration, self.pid == stoppedPID else { return }
                self.stop(force: true)
            }
        }
    }
    private func finish() {
        guard running else { return }
        // Consume trailing output before reporting completion.
        drain()
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
        running = false
        writer?.cancel(); writer = nil
        reader?.cancel(); reader = nil; master = -1
        monitor?.cancel(); monitor = nil; pending.removeAll()
        onExit?(result == pid ? ccam_exit_code(status) : -1)
    }
    deinit {
        if running && pid > 0 { kill(-pid, SIGHUP); kill(pid, SIGHUP) }
        writer?.cancel(); reader?.cancel(); monitor?.cancel()
    }
}
