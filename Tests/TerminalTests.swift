import Foundation
import SwiftTerm
import Darwin

@main struct TerminalTests {
    static var checks = 0
    static func check(_ ok: @autoclosure () -> Bool, _ message: String) {
        checks += 1; if !ok() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func run(_ executable: String, _ args: [String], directory: String = "/tmp", onData: @escaping (PTYSession, String) -> Void = {_,_ in}) throws -> (String, Int32, pid_t) {
        let session = PTYSession(); var output = ""; var finished: Int32?
        session.onData = { bytes in output += String(decoding: bytes, as: UTF8.self); onData(session, output) }
        session.onExit = { finished = $0 }
        try session.start(executable: executable, args: args, directory: directory, environment: CCAMClient.environment, rows: 24, cols: 80)
        let pid = session.pid; let limit = Date().addingTimeInterval(8)
        while finished == nil && Date() < limit { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        if finished == nil { session.stop(force: true); check(false, "PTY child timed out") }
        check(!session.running, "child is marked stopped")
        var status: Int32 = 0
        check(waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD, "child was reaped")
        return (output, finished!, pid)
    }
    static func checkReusedSession() throws {
        let session = PTYSession()
        var phase = 0, exits: [Int32] = [], children: [pid_t] = []
        var output = ["", ""], firstInputSent = false, secondInputSent = false
        let firstScript = """
        import signal, sys, tty
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(21))
        tty.setraw(0)
        print('FIRST_READY', flush=True)
        while True: signal.pause()
        """
        let secondScript = """
        import os, sys, time, tty
        tty.setraw(0)
        print('SECOND_READY', flush=True)
        received = b''
        while not received.endswith(b'\\n'):
            part = os.read(0, 4096)
            if not part: sys.exit(92)
            received += part
        print('RECEIVED=' + repr(received), flush=True)
        print('ENV=' + os.environ['CCAM_PTY_TEST_RUN'], flush=True)
        time.sleep(1.4)
        print('SECOND_SURVIVED', flush=True)
        sys.exit(22)
        """
        session.onData = { bytes in
            output[phase] += String(decoding: bytes, as: UTF8.self)
            if phase == 0 && !firstInputSent && output[0].contains("FIRST_READY") {
                firstInputSent = true
                // The first child never reads: leave pending input and EOF behind under backpressure.
                session.send([UInt8](repeating: 122, count: 1_048_576)); session.eof(); session.stop()
            } else if phase == 1 && !secondInputSent && output[1].contains("SECOND_READY") {
                secondInputSent = true; session.send("fresh\n")
            }
        }
        session.onExit = { code in
            let endedPID = session.pid
            exits.append(code)
            check(!session.running, "reused session is stopped before exit callback")
            var status: Int32 = 0
            check(waitpid(endedPID, &status, WNOHANG) == -1 && errno == ECHILD, "reused session child reaped before continuation")
            if phase == 0 {
                phase = 1
                var environment = CCAMClient.environment; environment["CCAM_PTY_TEST_RUN"] = "second"
                do {
                    // Restart synchronously inside onExit, as automatic account continuation does.
                    try session.start(executable: "/usr/bin/python3", args: ["-c", secondScript], directory: "/tmp", environment: environment, rows: 24, cols: 80)
                    children.append(session.pid)
                } catch { check(false, "reused session could not restart: \(error)") }
            }
        }
        try session.start(executable: "/usr/bin/python3", args: ["-c", firstScript], directory: "/tmp", environment: CCAMClient.environment, rows: 24, cols: 80)
        children.append(session.pid)
        let limit = Date().addingTimeInterval(8)
        while exits.count < 2 && Date() < limit { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        if exits.count < 2 { session.stop(force: true); check(false, "reused PTY session timed out") }
        check(children.count == 2 && children[0] != children[1], "same PTYSession starts two separate processes")
        check(exits == [21, 22], "each process preserves its own exit code")
        check(output[1].contains("RECEIVED=b'fresh\\n'"), "pending input and EOF from old PTY do not reach new child")
        check(output[1].contains("ENV=second"), "new child receives the replacement environment")
        check(output[1].contains("SECOND_SURVIVED"), "old delayed force-stop cannot kill the replacement process")
        check(!session.running && session.master == -1, "reused PTY descriptors finish cleanly")
    }
    static func main() throws {
        let holder = HeadlessTerminal(options: TerminalOptions(cols: 40, rows: 10)) { _ in }
        let terminal = holder.terminal!
        func feed(_ value: String) { terminal.feed(buffer: Array(value.utf8)[...]) }
        func screen() -> String { String(decoding: terminal.getBufferAsData(), as: UTF8.self) }
        feed("NORMAL\r\n\u{1B}[31mRED\u{1B}[0m\r\n123\rXY")
        check(screen().contains("RED") && !screen().contains("[31m"), "ANSI escapes interpreted")
        check(screen().contains("XY3"), "cursor overwrite supported")
        feed("\u{1B}[?1049h\u{1B}[2J\u{1B}[HALTERNATE")
        check(screen().contains("ALTERNATE") && !screen().contains("NORMAL"), "alternate screen isolation")
        feed("\u{1B}[?1049l")
        check(screen().contains("NORMAL") && !screen().contains("ALTERNATE"), "normal screen restoration")
        feed("\r\n")
        for byte in Array("中文输入✓".utf8) { terminal.feed(buffer: [byte][...]) }
        check(screen().replacingOccurrences(of: "\0", with: "").contains("中文输入✓"), "UTF-8 survives split reads; ignore wide-cell placeholders")
        var sent = false
        let result = try run("/bin/sh", ["-c", "test -t 0 && test -t 1 || exit 95; printf 'READY\\n'; read answer; stty size; printf 'answer=%s\\n' \"$answer\"; exit 7"]) { p,text in
            if !sent && text.contains("READY") { sent = true; p.resize(rows: 31, cols: 99); p.send("hello world\n") }
        }
        check(result.0.contains("31 99"), "PTY resize reaches child")
        check(result.0.contains("answer=hello world"), "interactive input reaches child")
        check(result.1 == 7, "nonzero exit status preserved")
        var longSent = false
        let large = try run("/usr/bin/python3", ["-c", "import os,tty; tty.setraw(0); print('READY',flush=True); n=0\nwhile n<131072: n+=len(os.read(0,min(4096,131072-n)))\nprint('COUNT='+str(n),flush=True)"]) { p,text in
            if !longSent && text.contains("READY") { longSent=true; p.send([UInt8](repeating: 97,count: 131072)) }
        }
        check(large.0.contains("COUNT=131072") && large.1 == 0, "backpressure does not drop large pastes")
        var stopped = false
        let cancelled = try run("/bin/sh", ["-c", "trap '' INT TERM; echo READY; while :; do sleep 1; done"]) { p,text in
            if !stopped && text.contains("READY") { stopped=true; p.stop() }
        }
        check(cancelled.1 == 137, "force stop ends an uncooperative process group")
        try checkReusedSession()
        let badDirectory = try run("/bin/sh", ["-c","exit 0"], directory: "/this-ccam-test-directory-does-not-exist")
        check(badDirectory.1 == 126, "invalid cwd fails without silently launching elsewhere")
        let badExec = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a valid executable".utf8).write(to: badExec)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],ofItemAtPath:badExec.path)
        defer { try? FileManager.default.removeItem(at:badExec) }
        let failure = try run(badExec.path, [])
        check(failure.1 == 127, "exec failure exits child instead of returning into app")
        let paths = Set(CommandCatalog.all.map { $0.path.joined(separator: " ") })
        check(CommandCatalog.requiredCommandPaths.isSubset(of: paths), "all original CCAM command paths have buttons")
        let data = try JSONSerialization.data(withJSONObject: CommandCatalog.all.map { $0.path })
        try data.write(to: URL(fileURLWithPath: ".build-cache/command-paths.json"))
        print("PASS: \(checks) terminal, PTY lifecycle, input, resize and command-coverage checks")
    }
}
