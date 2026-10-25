import Foundation
import Darwin

// UI-free adapters execute the production coordinator against real PTYs and
// installed CCAM. Only Claude is a fixture; no real account or API is contacted.
final class TerminalSessionView {
    let session = PTYSession()
    let directory: String
    var onProcessStarted: ((Int32) -> Void)?
    var onProcessExit: ((Int32) -> Void)?
    var onUserStop: (() -> Void)?
    var onInterrupt: (() -> Void)?
    var notices: [String] = []
    var output = ""
    var isWaiting = false
    var starts = 0
    init(directory: String) {
        self.directory = directory
        session.onData = { [weak self] in self?.output += String(decoding: $0, as: UTF8.self) }
        session.onExit = { [weak self] in self?.onProcessExit?($0) }
    }
    func start(executable: String, args: [String], initialInput: String? = nil, environmentOverrides: [String: String]? = nil) {
        starts += 1
        do {
            try session.start(executable: executable, args: args, directory: directory, environment: environmentOverrides ?? [:], rows: 24, cols: 100)
            onProcessStarted?(session.pid)
        } catch { onProcessExit?(127) }
    }
    func showNotice(_ text: String) { notices.append(text) }
    func setWaiting(_ value: Bool) { isWaiting = value }
}

final class TerminalWorkspace {
    func open(executable: String, args: [String], directory: String, title: String, projectID: String, projectName: String,
              environmentOverrides: [String: String], environmentExclusions: [String] = []) -> TerminalSessionView {
        let view = TerminalSessionView(directory: directory)
        DispatchQueue.main.async { view.start(executable: executable, args: args, environmentOverrides: environmentOverrides) }
        return view
    }
}

@main
enum PoolTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        checks += 1
    }
    static func spin(_ seconds: TimeInterval, until: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !until() { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    final class Fixture {
        let root: URL
        let project: URL
        let ccam = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/ccam").path
        var env: [String: String]
        var views: [TerminalSessionView] = []
        var activities: [PoolActivity] = []
        init(mode: String, secondPercent: Double = 30, useWrapper: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ccam-pool-test-" + UUID().uuidString)
            project = root.appendingPathComponent("project with spaces")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            env = CCAMClient.environment
            env["CCAM_HOME"] = root.path; env["POOL_TEST_MODE"] = mode; env["POOL_TEST_NATIVE"] = ccam
            let fake = root.appendingPathComponent("fakeclaude.py")
            try Self.fake.write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
            var config = "claude_bin = '\(fake.path)'\ndefault = 'second'\n[[profile]]\nname = 'first'\nslot = 1\n[[profile]]\nname = 'second'\nslot = 2\n[[folder]]\npath = '\(project.path)'\naccount = 'second'\n"
            if mode == "consecutive" { config += "[[profile]]\nname = 'third'\nslot = 3\n" }
            try write("config/config.toml", Data(config.utf8))
            for (name, percent) in [("first", 10.0), ("second", secondPercent)] + (mode == "consecutive" ? [("third", 60.0)] : []) {
                try json("data/profiles/\(name)/.credentials.json", ["claudeAiOauth": ["refreshToken": "not-a-real-token-\(name)", "accessToken": "not-a-real-token", "expiresAt": Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)]])
                try json("state/usage/\(name).json", ["at": ISO8601DateFormatter().string(from: Date()), "limits": ["five_hour": ["percent": percent,"known": true,"resets_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))],"weekly": ["percent": 10,"known": true,"resets_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400))]]])
            }
            if useWrapper {
                let wrapper = root.appendingPathComponent("race-ccam.py")
                try Self.wrapper.write(to: wrapper, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
                env["POOL_TEST_WRAPPER"] = wrapper.path
            }
        }
        func write(_ path: String, _ data: Data) throws {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        func json(_ path: String, _ value: Any) throws { try write(path, JSONSerialization.data(withJSONObject: value)) }
        func plan() throws -> PoolLaunch {
            try GlobalPool.prepare(directory: project.path, continueLast: false,
                                   helperExecutable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path,
                                   ccamExecutable: env["POOL_TEST_WRAPPER"] ?? ccam, baseEnvironment: env)
        }
        func start(onState: ((PoolActivity) -> Void)? = nil) throws -> (TerminalSessionView, PoolLaunch) {
            let plan = try plan(), view = TerminalSessionView(directory: project.path)
            let controller = PoolCoordinator(plan: plan, view: view, retryInterval: 0.2) { [weak self] state, _ in self?.activities.append(state); onState?(state) }
            view.onProcessStarted = { controller.started($0) }; view.onProcessExit = { controller.exited($0) }
            view.onInterrupt = { controller.interrupted() }; view.onUserStop = { controller.cancel(user: true) }
            views.append(view)
            view.start(executable: plan.environment["CCAM_DESKTOP_CCAM"]!, args: plan.args, environmentOverrides: plan.environment)
            return (view, plan)
        }
        var runs: [String] { ((try? String(contentsOf: root.appendingPathComponent("runs"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        var workEvents: [[String: Any]] { ((try? String(contentsOf: root.appendingPathComponent("work-events"), encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } }
        func cleanup() {
            for view in views { view.onUserStop?(); view.session.stop(force: true) }
            spin(3) { self.views.allSatisfy { !$0.session.running } }
            try? FileManager.default.removeItem(at: root)
        }
        deinit { cleanup() }

        static let fake = #"""
#!/usr/bin/python3
import json,os,pathlib,subprocess,sys,time,datetime,shlex
root=pathlib.Path(os.environ['CCAM_HOME']); account=os.environ['CCAM_PROFILE']; mode=os.environ['POOL_TEST_MODE']
with (root/'runs').open('a') as f: f.write(account+'\n')
(root/(account+'-args.json')).write_text(json.dumps(sys.argv[1:]))
if mode=='ordinary': print('Network request failed'); sys.exit(7)
if mode=='exit75': print('A program exit code is not a quota event'); sys.exit(75)
if mode=='text-only': print("You've hit your session limit"); sys.exit(0)
continuations=[a for a in sys.argv[1:] if a.startswith('上一个账号的额度已耗尽')]
state_file=pathlib.Path.cwd()/'work-state.json'
if account=='first' and not state_file.exists(): state_file.write_text(json.dumps({'completed':['initial-work']}))
if account!='first' and continuations:
    state=json.loads(state_file.read_text());state['completed'].append('continued-'+account);state_file.write_text(json.dumps(state))
    with (root/'work-events').open('a') as f:f.write(json.dumps({'account':account,'count':len(continuations),'cwd':os.getcwd(),'completed':state['completed']})+'\n')
if account=='third' or account=='second' and mode!='consecutive':
    time.sleep(30); sys.exit(0)
now=datetime.datetime.now(datetime.timezone.utc).isoformat(); sid='11111111-1111-4111-8111-111111111111' if account=='first' else '22222222-2222-4222-8222-222222222222'
conv=root/'data/profiles'/account/'projects/fixture'/f'{sid}.jsonl';conv.parent.mkdir(parents=True,exist_ok=True)
msg="You've hit your session limit · resets 3:30am (Asia/Seoul)"
rows=[{'type':'user','uuid':'u1','timestamp':now,'message':{'role':'user','content':'Keep working'},'sessionId':sid,'permissionMode':'default'},
      {'type':'assistant','uuid':'l1','parentUuid':'u1','timestamp':now,'sessionId':sid,'apiError':'usage_limit_reached','error':'rate_limit','isApiErrorMessage':True,
       'message':{'model':'<synthetic>','role':'assistant','content':[{'type':'text','text':msg}]},
       'apiErrorParams':{'rate_limit_info':{'status':'rejected','rateLimitType':'five_hour','resetsAt':int(time.time()+3600)}},
       'quotaLimits':{'status':'rejected','rateLimitType':'five_hour','resetsAt':int(time.time()+3600)}}]
conv.write_text('\n'.join(json.dumps(x) for x in rows)+'\n')
settings=json.loads(sys.argv[sys.argv.index('--settings')+1]); command=settings['hooks']['StopFailure'][0]['hooks'][0]['command']
env=dict(os.environ,CLAUDE_PID=str(os.getpid()),CLAUDE_PROJECT_DIR=os.getcwd(),CLAUDE_CODE_SESSION_ATTENDED='1',CLAUDE_CODE_ENTRYPOINT='cli')
payload={'error':'rate_limit','last_assistant_message':msg,'session_id':sid,'transcript_path':str(conv),'cwd':os.getcwd()}
r=subprocess.run(shlex.split(command),input=json.dumps(payload),env=env,text=True,capture_output=True)
(root/'hook-result').write_text(str(r.returncode)+'\n'+r.stdout+'\n'+r.stderr)
# A newer, unrelated conversation in the very same project must not be resumed.
other=root/'other.jsonl';other.write_text('{}\n'); note=root/'state/handoff/second/other.json';note.parent.mkdir(parents=True,exist_ok=True)
note.write_text(json.dumps({'account':'second','session_id':'other','transcript_path':str(other),'cwd':os.getcwd(),'at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'reason':'limit'}))
time.sleep(30)
"""#
        static let wrapper = #"""
#!/usr/bin/python3
import os,sys,pathlib
root=pathlib.Path(os.environ['CCAM_HOME']);args=sys.argv[1:]
if '--note' in args:
    with (root/'note-invocations').open('a') as f:f.write(args[args.index('--note')+1]+'\n')
    if '--dry-run' not in args and not (root/'raced').exists():
        (root/'raced').write_text('once');sys.exit(75)
os.execv(os.environ['POOL_TEST_NATIVE'],[os.environ['POOL_TEST_NATIVE']]+args)
"""#
    }

    static func main() throws {
        if let code = GlobalPool.handleHelperInvocation() { exit(code) }
        // Native CCAM account selection and native StopFailure are both exercised.
        do {
            let fixture = try Fixture(mode: "limit"); defer { fixture.cleanup() }
            let (view, plan) = try fixture.start()
            check(plan.args.prefix(3) == ["next", "--auto", "--cross-org"], "global pool launch bypasses project/default binding")
            spin(12) { fixture.runs.count >= 2 }
            check(fixture.runs == ["first", "second"], "real CCAM switches account 1 → 2 after structured quota hook; \(view.output) \(view.notices)")
            let args = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.root.appendingPathComponent("second-args.json"))) as! [String]
            check(args.contains("--resume") && args.contains("--fork-session"), "native exact conversation handoff")
            check(args.contains { $0.hasSuffix("11111111-1111-4111-8111-111111111111.jsonl") } && !args.contains { $0.hasSuffix("other.jsonl") }, "newer unrelated conversation is not resumed")
            check(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("state/usage/first.limit.json").path), "native hook records global exhausted-account limit")
            check(args.filter { $0 == GlobalPool.continuationPrompt }.count == 1, "one quota recovery injects exactly one continuation prompt")
            check(!plan.automaticallyContinuesTask && !plan.args.contains(GlobalPool.continuationPrompt), "new sessions never auto-inject recovery work")
            spin(1) { fixture.workEvents.count == 1 }
            check(fixture.workEvents.count == 1 && fixture.workEvents[0]["count"] as? Int == 1, "resumed Claude automatically starts work without typed input")
            check(fixture.workEvents[0]["completed"] as? [String] == ["initial-work", "continued-second"], "already completed project work is preserved")
            check(GlobalPool.sameDirectory(fixture.workEvents[0]["cwd"] as? String ?? "", fixture.project.path), "continuation works in same exact project directory")
            check(fixture.activities.contains(.checkingQuota) && fixture.activities.contains(.switchingAccount) && fixture.activities.contains(.continuingTask), "UI receives selection/switching/automatic-continuation states")
            spin(1.3)
            check(view.session.running && view.starts == 2, "replacement survives old PTY termination watchdog")
        }
        do {
            let fixture = try Fixture(mode: "limit", secondPercent: 100); defer { fixture.cleanup() }
            let (view, _) = try fixture.start()
            spin(12) { view.isWaiting }
            check(view.isWaiting && view.session.running, "all other accounts exhausted preserves old interactive session and waits")
            spin(1.3)
            check(fixture.runs == ["first"] && view.starts == 1, "no restart loop when pool is empty")
            view.onInterrupt?()
            check(!view.isWaiting && view.session.running, "Ctrl-C cancels pending handoff without killing live session")
            check(fixture.workEvents.isEmpty, "waiting/cancelled quota handoff does not execute a new task")
        }
        for mode in ["ordinary", "text-only", "exit75"] {
            let fixture = try Fixture(mode: mode); defer { fixture.cleanup() }
            let (view, _) = try fixture.start()
            spin(8) { !view.session.running }
            spin(1.2)
            check(fixture.runs == ["first"] && view.starts == 1 && !view.isWaiting, "\(mode) cannot trigger account rotation")
        }
        do {
            let fixture = try Fixture(mode: "limit", useWrapper: true); defer { fixture.cleanup() }
            let (view, _) = try fixture.start()
            spin(15) { fixture.runs.count >= 2 }
            check(fixture.runs == ["first", "second"], "quota race after preflight retries and resumes; \(view.output) \(view.notices)")
            let notes = try String(contentsOf: fixture.root.appendingPathComponent("note-invocations"), encoding: .utf8).split(separator: "\n")
            check(notes.count >= 4 && Set(notes).count == 1, "every preflight/retry preserves exact handoff note")
            spin(1) { fixture.workEvents.count == 1 }
            check(fixture.workEvents.count == 1 && fixture.workEvents[0]["count"] as? Int == 1, "preflight quota race does not duplicate the actual continuation prompt")
        }
        do {
            let fixture = try Fixture(mode: "consecutive"); defer { fixture.cleanup() }
            let (view, _) = try fixture.start()
            spin(18) { fixture.workEvents.count == 2 }
            check(fixture.runs == ["first", "second", "third"], "consecutive quota failures advance to two different available accounts; \(view.output) \(view.notices)")
            check(fixture.workEvents.map { $0["account"] as? String ?? "" } == ["second", "third"], "each replacement automatically continues without manual input")
            check(fixture.workEvents.allSatisfy { $0["count"] as? Int == 1 }, "each quota event gets one initial continuation prompt")
            check(fixture.workEvents.last?["completed"] as? [String] == ["initial-work", "continued-second", "continued-third"], "project work survives two account switches")
            let args = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.root.appendingPathComponent("third-args.json"))) as! [String]
            check(args.contains { $0.hasSuffix("22222222-2222-4222-8222-222222222222.jsonl") }, "second recovery resumes second account's exact newest task session")
        }
        do {
            let fixture = try Fixture(mode: "limit"); defer { fixture.cleanup() }
            var target: TerminalSessionView?
            let (view, _) = try fixture.start { state in if state == .switchingAccount { target?.onInterrupt?() } }
            target = view
            spin(12) { fixture.activities.contains(.paused) }
            spin(1.2)
            check(fixture.activities.contains(.paused) && view.session.running, "cancel at preflight-complete boundary preserves original process")
            check(fixture.runs == ["first"] && fixture.workEvents.isEmpty, "cancelled handoff never launches account or auto task")
        }
        do {
            let fixture = try Fixture(mode: "limit"); defer { fixture.cleanup() }
            let (view, plan) = try fixture.start()
            spin(8) { FileManager.default.fileExists(atPath: plan.eventURL.path) }
            view.onInterrupt?()
            spin(1.5)
            check(fixture.runs == ["first"] && fixture.workEvents.isEmpty && view.session.running, "Ctrl-C before poll observes quota event also cancels its automatic continuation")
        }
        do {
            let fixture = try Fixture(mode: "ordinary"); defer { fixture.cleanup() }
            let plan = try fixture.plan(); defer { GlobalPool.clean(plan) }
            let now = Date(), transcript = fixture.root.appendingPathComponent("unit.jsonl")
            try Data("{}\n".utf8).write(to: transcript)
            var environment = plan.environment
            environment["CCAM_PROFILE"] = "first"; environment["CLAUDE_PID"] = String(getpid()); environment["CLAUDE_PROJECT_DIR"] = fixture.project.path
            let input: [String: Any] = ["error":"rate_limit", "session_id":"unit", "transcript_path":transcript.path, "cwd":fixture.project.path]
            let formatter = ISO8601DateFormatter();formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
            var note: [String: Any] = ["account":"first", "session_id":"unit", "transcript_path":transcript.path, "cwd":fixture.project.path, "reason":"limit", "at":formatter.string(from: now)]
            try fixture.json("state/handoff/first/unit.json", note)
            check(GlobalPool.validatedEvent(input: input, environment: environment, started: now.addingTimeInterval(-1)) != nil, "matching structured native ticket accepted")
            check(GlobalPool.validatedEvent(input: input.merging(["agent_id":"nested"]) { _, n in n }, environment: environment, started: now.addingTimeInterval(-1)) == nil, "subagent hook rejected")
            check(GlobalPool.validatedEvent(input: input.merging(["error":"network"]) { _, n in n }, environment: environment, started: now.addingTimeInterval(-1)) == nil, "non-quota hook rejected")
            check(GlobalPool.validatedEvent(input: input, environment: environment.merging(["CLAUDE_CODE_SESSION_ATTENDED":"0"]) { _, n in n }, started: now.addingTimeInterval(-1)) == nil, "unattended print hook rejected")
            note["at"] = formatter.string(from: now.addingTimeInterval(-30));try fixture.json("state/handoff/first/unit.json", note)
            check(GlobalPool.validatedEvent(input: input, environment: environment, started: now) == nil, "stale native ticket rejected")
            note["at"] = formatter.string(from: now);note["session_id"] = "another";try fixture.json("state/handoff/first/unit.json", note)
            check(GlobalPool.validatedEvent(input: input, environment: environment, started: now.addingTimeInterval(-1)) == nil, "unrelated session ticket rejected")
            let forged = PoolLimitEvent(token: "wrong", account: "first", sessionID: "unit", transcript: transcript.path, directory: fixture.project.path, ticket: "", claudePID: getpid(), relay: "", at: Date())
            try JSONEncoder().encode(forged).write(to: plan.eventURL)
            check(GlobalPool.readEvent(plan) == nil, "wrong launch token rejected")
            check(!GlobalPool.ownedProcess(event: forged, rootPID: getpid()+100), "unowned PID rejected")
            check(GlobalPool.preflightArguments(plan).firstIndex(of:"--dry-run")! < GlobalPool.preflightArguments(plan).firstIndex(of:"--")!, "dry-run belongs to CCAM, not forwarded Claude args")
            var overrides = fixture.env
            for key in GlobalPool.overrideKeys { overrides[key] = "fixture-only-override" }
            overrides["POOL_ORDINARY_VARIABLE"] = "preserved"
            let filtered = try GlobalPool.prepare(directory: fixture.project.path, continueLast: false, baseEnvironment: overrides)
            defer { GlobalPool.clean(filtered) }
            check(GlobalPool.overrideKeys.allSatisfy { filtered.environment[$0] == nil }, "temporary auth and endpoint overrides removed from pool child")
            check(filtered.environment["POOL_ORDINARY_VARIABLE"] == "preserved" && filtered.environment["CCAM_HOME"] == fixture.root.path, "ordinary environment and isolated account store preserved")
            check(GlobalPool.overrideKeys.allSatisfy { overrides[$0] == "fixture-only-override" }, "original environment dictionary untouched")
            let repeated = try GlobalPool.prepare(directory: fixture.project.path, continueLast: true, baseEnvironment: filtered.environment)
            defer { GlobalPool.clean(repeated) }
            check(GlobalPool.overrideKeys.allSatisfy { repeated.environment[$0] == nil } && repeated.environment["CCAM_HOME"] == fixture.root.path, "subsequent handoff retains account store and strips overrides")
            check(!repeated.automaticallyContinuesTask && !repeated.args.contains(GlobalPool.continuationPrompt), "manual continue never auto-submits task instructions")
            let userTask = "- 从上次中断处继续\n检查一个带空格的文件，再完成测试。"
            let initial = try GlobalPool.prepare(directory: fixture.project.path, continueLast: false, initialPrompt: userTask, baseEnvironment: fixture.env)
            defer { GlobalPool.clean(initial) }
            check(initial.args.suffix(2) == ["--", userTask] && initial.args.filter { $0 == userTask }.count == 1, "multiline dash-prefixed initial task is one literal Claude argument")
            let forwarded = GlobalPool.command(executable: fixture.ccam, args: initial.args, directory: fixture.project.path, environment: initial.environment)
            let forwardedArgs = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.root.appendingPathComponent("first-args.json"))) as! [String]
            check(forwarded.code == 7 && forwardedArgs.suffix(2) == ["--", userTask], "real CCAM forwards dash-prefixed multiline initial task without flag injection")
            note["session_id"] = "unit";note["at"] = formatter.string(from: now)
            try fixture.json("state/handoff/first/unit.json", note)
            let permissionRows = [
                #"{"type":"permission-mode","permissionMode":"plan"}"#,
                #"{"type":"assistant","permissionMode":"bypassPermissions"}"#,
                #"{"type":"user","permissionMode":"bypassPermissions","message":{"content":[{"type":"tool_result"}]}}"#]
            try Data(permissionRows.joined(separator: "\n").utf8).write(to: transcript)
            let path = fixture.root.appendingPathComponent("state/handoff/first/unit.json").path
            let recovered = try GlobalPool.prepare(directory: fixture.project.path, continueLast: true, ticket: path, automaticallyContinueTask: true, initialPrompt: userTask, baseEnvironment: fixture.env)
            defer { GlobalPool.clean(recovered) }
            check(recovered.args.contains("plan") && !recovered.args.contains("bypassPermissions"), "recovery preserves plan mode and ignores modes quoted by assistant/tool rows")
            check(recovered.args.filter { $0 == GlobalPool.continuationPrompt }.count == 1, "explicit validated quota recovery has one scoped initial prompt")
            check(!recovered.args.contains(userTask) && recovered.args.suffix(2) == ["--", GlobalPool.continuationPrompt], "quota recovery never replays original task prompt")
            try Data(#"{"type":"permission-mode","permissionMode":"bypassPermissions"}"#.utf8).write(to: transcript)
            let safeArgs = try GlobalPool.recoveryArguments(ticket: path, directory: fixture.project.path, environment: fixture.env)
            check(safeArgs.prefix(2) == ["--permission-mode","default"] && !safeArgs.contains { $0.contains("skip-permissions") }, "automatic recovery never introduces permission bypass")
            var rejected = false
            do { _ = try GlobalPool.prepare(directory: fixture.project.path, continueLast: true, automaticallyContinueTask: true, baseEnvironment: fixture.env) } catch { rejected = true }
            check(rejected, "task autostart requires an actual native quota ticket")
            note["reason"] = "switch";try fixture.json("state/handoff/first/unit.json", note)
            rejected = false
            do { _ = try GlobalPool.recoveryArguments(ticket: path, directory: fixture.project.path, environment: fixture.env) } catch { rejected = true }
            check(rejected, "manual account-switch ticket cannot trigger automatic task prompt")
        }
        print("PASS: \(checks) global-pool checks (real CCAM + isolated simulated Claude quota events, no real tokens/API calls)")
    }
}
