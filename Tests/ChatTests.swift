import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers

@main enum ChatTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ text: String) {
        guard condition() else { fputs("FAIL: \(text)\n", stderr); exit(1) }; checks += 1
    }
    static func spin(_ seconds: TimeInterval = 12, until: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !until() { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
    static func imageData() -> Data {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let data = NSMutableData()
        let writer = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(writer, context.makeImage()!, nil); precondition(CGImageDestinationFinalize(writer))
        return data as Data
    }
    final class Fixture {
        let root: URL
        let project: ProjectRecord
        let store: ChatStore
        let runtime: ChatRuntime
        let native = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/ccam").path
        let environment: [String: String]
        var starts: [[String]] = []
        init(_ mode: String = "normal", full: Bool = false, race: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ccam-chat-tests-" + UUID().uuidString)
            let directory = root.appendingPathComponent("project with spaces")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            project = ProjectRecord(id: UUID(), name: "Fixture", path: directory.path, createdAt: Date(), lastOpenedAt: Date(), archived: false)
            var env = CCAMClient.environment; env["CCAM_HOME"] = root.path; env["CHAT_FIXTURE_MODE"] = mode; env["CHAT_NATIVE"] = native
            environment = env
            let fake = root.appendingPathComponent("fakeclaude.py")
            try Self.fake.write(to: fake, atomically: true, encoding: .utf8); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
            let config = "usage_source = 'cache'\nclaude_bin = '\(fake.path)'\ndefault = 'second'\n[[profile]]\nname = 'first'\nslot = 1\n[[profile]]\nname = 'second'\nslot = 2\n[[profile]]\nname = 'third'\nslot = 3\n[[folder]]\npath = '\(directory.path)'\naccount = 'second'\n"
            try Self.write(root, "config/config.toml", Data(config.utf8))
            for (name, usage) in [("first", 10), ("second", full ? 100 : 30), ("third", full ? 100 : 60)] {
                try Self.json(root, "data/profiles/\(name)/.credentials.json", ["claudeAiOauth": ["accessToken": "fixture-only", "refreshToken": "fixture-only-\(name)", "expiresAt": Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)]])
                try Self.json(root, "state/usage/\(name).json", ["at": ISO8601DateFormatter().string(from: Date()), "limits": ["five_hour": ["percent": usage, "known": true, "resets_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))], "weekly": ["percent": 10, "known": true, "resets_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400))]]])
            }
            let wrapper = root.appendingPathComponent("race-ccam.py")
            if race { try Self.wrapper.write(to: wrapper, atomically: true, encoding: .utf8); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path) }
            store = try ChatStore(project: project, fileURL: root.appendingPathComponent("desktop/chat.json"))
            runtime = try ChatRuntime(project: project, store: store, ccamExecutable: race ? wrapper.path : native,
                                      helperExecutable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path,
                                      environment: env, retryInterval: 0.15, maximumWait: 10)
            runtime.beforeStart = { [weak self] args in self?.starts.append(args) }
            runtime.createConversation()
        }
        static func write(_ root: URL, _ path: String, _ data: Data) throws {
            let url = root.appendingPathComponent(path); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try data.write(to: url)
        }
        static func json(_ root: URL, _ path: String, _ value: Any) throws { try write(root, path, JSONSerialization.data(withJSONObject: value)) }
        var runs: [[String: Any]] {
            ((try? String(contentsOf: root.appendingPathComponent("runs"), encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        var work: [String] { ((try? Data(contentsOf: URL(fileURLWithPath: project.path).appendingPathComponent("work-state.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] }) ?? [] }
        func send(_ prompt: String, mode: ChatPermissionMode? = nil) { runtime.send(text: prompt, permissionMode: mode); spin { !self.runtime.hasRunning } }
        func clean() { runtime.stop(); spin(3) { !self.runtime.hasRunning }; try? FileManager.default.removeItem(at: root) }
        deinit { clean() }
        static let wrapper = #"""
#!/usr/bin/python3
import os,sys,pathlib
root=pathlib.Path(os.environ['CCAM_HOME']);args=sys.argv[1:]
if '--note' in args and not (root/'raced').exists():
    (root/'raced').write_text('once');sys.exit(75)
os.execv(os.environ['CHAT_NATIVE'],[os.environ['CHAT_NATIVE']]+args)
"""#
        static let fake = #"""
#!/usr/bin/python3
import os,sys,json,pathlib,uuid,datetime,time,subprocess,shlex
root=pathlib.Path(os.environ['CCAM_HOME']);account=os.environ['CCAM_PROFILE'];mode=os.environ['CHAT_FIXTURE_MODE'];args=sys.argv[1:];raw_input=sys.stdin.read();prompt=raw_input
content=prompt
if '--input-format' in args:
    envelope=json.loads(raw_input);assert envelope['type']=='user' and envelope['message']['role']=='user'
    content=envelope['message']['content'];prompt='\n'.join(b['text'] for b in content if b['type']=='text')
def value(flag):return args[args.index(flag)+1] if flag in args else None
resume=value('--resume');sid=str(uuid.uuid4()) if '--fork-session' in args else resume if resume else value('--session-id')
sid=sid or str(uuid.uuid4());transcript=root/'data/profiles'/account/'projects/fixture'/f'{sid}.jsonl';transcript.parent.mkdir(parents=True,exist_ok=True)
if resume and resume.endswith('.jsonl'):
    assert pathlib.Path(resume).exists(), 'missing exact transcript'
    transcript.write_text(pathlib.Path(resume).read_text())
with (root/'runs').open('a') as f:f.write(json.dumps({'account':account,'sid':sid,'args':args,'prompt':prompt,'raw_input':raw_input,'content':content,'cwd':os.getcwd(),'pid':os.getpid()})+'\n')
if mode=='early-stop':time.sleep(30);sys.exit(0)
settings=json.loads(value('--settings'));env=dict(os.environ,CLAUDE_PID=str(os.getpid()),CLAUDE_PROJECT_DIR=os.getcwd(),CLAUDE_CODE_SESSION_ATTENDED='0',CLAUDE_CODE_ENTRYPOINT='sdk-cli')
def hook(name,extra={}):
    payload={'hook_event_name':name,'session_id':sid,'transcript_path':str(transcript),'cwd':os.getcwd(),**extra}
    command=settings['hooks'][name][0]['hooks'][0]['command']
    result=subprocess.run(shlex.split(command),input=json.dumps(payload),env=env,text=True,capture_output=True)
    assert result.returncode==0,result.stderr
def emit(event):print(json.dumps({'session_id':sid,**event}),flush=True)
if mode!='identityless':hook('SessionStart')
emit({'type':'system','subtype':'init','permissionMode':'default' if mode=='auto-fallback' else value('--permission-mode')})
if mode=='auto-fallback':emit({'type':'system','subtype':'status','permissionMode':'default'})
if mode=='auto-plan':emit({'type':'system','subtype':'status','permissionMode':'plan'})
now=datetime.datetime.now(datetime.timezone.utc).isoformat()
with transcript.open('a') as f:f.write(json.dumps({'type':'user','uuid':str(uuid.uuid4()),'timestamp':now,'sessionId':sid,'permissionMode':'manual','message':{'role':'user','content':content}})+'\n')
work=pathlib.Path.cwd()/'work-state.json';state=json.loads(work.read_text()) if work.exists() else []
state.append('continued-'+account if prompt.startswith('上一个账号的额度已耗尽') else 'user:'+prompt);work.write_text(json.dumps(state))
if mode=='slow':
    emit({'type':'assistant','message':{'id':'slow','content':[{'type':'text','text':'Working'}]}});time.sleep(30);sys.exit(0)
if mode=='ordinary':
    emit({'type':'result','subtype':'error_during_execution','is_error':True,'errors':['network error rate_limit text is not a hook']});sys.exit(7)
limited=mode in ('limit','consecutive') and (account=='first' or mode=='consecutive' and account=='second')
if limited:
    msg="You've hit your session limit · resets 3:30am (Asia/Seoul)"
    row={'type':'assistant','uuid':str(uuid.uuid4()),'timestamp':now,'sessionId':sid,'apiError':'usage_limit_reached','error':'rate_limit','isApiErrorMessage':True,'message':{'model':'<synthetic>','role':'assistant','content':[{'type':'text','text':msg}]},'apiErrorParams':{'rate_limit_info':{'status':'rejected','rateLimitType':'five_hour','resetsAt':int(time.time()+3600)}},'quotaLimits':{'status':'rejected','rateLimitType':'five_hour','resetsAt':int(time.time()+3600)}}
    with transcript.open('a') as f:f.write(json.dumps(row)+'\n')
    hook('StopFailure',{'error':'rate_limit','last_assistant_message':msg})
    unrelated=root/'unrelated.jsonl';unrelated.write_text('{}\n')
    note=root/'state/handoff/third/unrelated.json';note.parent.mkdir(parents=True,exist_ok=True);note.write_text(json.dumps({'account':'third','session_id':'unrelated','transcript_path':str(unrelated),'cwd':os.getcwd(),'reason':'limit','at':datetime.datetime.now(datetime.timezone.utc).isoformat()}))
    emit({'type':'result','subtype':'error_during_execution','is_error':True,'errors':['rate_limit']});sys.exit(1)
emit({'type':'stream_event','event':{'type':'message_start','message':{'id':'msg-'+sid}}})
for index,text in [(0,'第一段完成'),(2,'第二段完成')]:
    emit({'type':'stream_event','event':{'type':'content_block_delta','index':index,'delta':{'type':'text_delta','text':text}}})
    emit({'type':'assistant','message':{'id':'msg-'+sid,'content':[{'type':'text','text':text}]}})
emit({'type':'assistant','message':{'id':'msg-'+sid,'content':[{'type':'tool_use','id':'tool1','name':'Read','input':{'file_path':'a.txt'}}]}})
emit({'type':'user','message':{'content':[{'type':'tool_result','tool_use_id':'tool1','content':'fixture tool result'}]}})
emit({'type':'result','subtype':'success','is_error':False,'result':'第二段完成','permission_denials':[{'tool_name':'Bash','tool_use_id':'denied','tool_input':{}}] if mode=='permission' else []})
"""#
    }

    static func main() throws {
        if let code = GlobalPool.handleHelperInvocation() { exit(code) }
        do {
            var parser = ChatStreamDecoder()
            let source = Data("launcher notice\n{\"type\":\"assistant\",\"text\":\"中文\"}\n{\"type\":\"result\"}".utf8)
            var events: [[String: Any]] = []
            for byte in source { events += parser.append(Data([byte])) }
            events += parser.append(Data(), finish: true)
            check(events.count == 2 && events[0]["text"] as? String == "中文", "NDJSON handles split UTF-8 and final line; ignores launcher notices")
        }
        do {
            let f = try Fixture(); defer { f.clean() }
            let original = f.runtime.activeConversations[0], originalID = original.id
            try f.runtime.renameConversation(id: originalID, title: "模型与模式")
            try f.runtime.updateOptions(model: "opus", permissionMode: .plan, effort: "high")
            let options = ChatOptions(model: "opus", permissionMode: .plan, effort: "high")
            check(f.runtime.currentOptions == options && f.runs.isEmpty, "changing controls persists locally without starting Claude")
            let reopened = try ChatStore(project: f.project, fileURL: f.store.fileURL)
            check(reopened.conversations[0].options == options, "model, permission mode and effort survive restart")
            // A version-1 document from before these features has none of the new fields.
            let legacyEncoder = JSONEncoder(); legacyEncoder.dateEncodingStrategy = .iso8601
            var legacy = try JSONSerialization.jsonObject(with: legacyEncoder.encode(original)) as! [String: Any]
            legacy.removeValue(forKey: "options"); legacy.removeValue(forKey: "deletedAt")
            let legacyDecoder = JSONDecoder(); legacyDecoder.dateDecodingStrategy = .iso8601
            let decoded = try legacyDecoder.decode(ChatConversation.self, from: JSONSerialization.data(withJSONObject: legacy))
            check(decoded.options == nil && decoded.deletedAt == nil && decoded.id == originalID, "older conversation records decode without losing identity")
            do { try f.runtime.updateOptions(model: "--dangerous-option", permissionMode: .default); check(false, "invalid model rejected") } catch { check(f.runtime.currentOptions == options, "invalid model cannot partially change stored controls") }
            do { try f.runtime.updateOptions(model: "sonnet", permissionMode: .default, effort: "unknown"); check(false, "invalid effort rejected") } catch { check(f.runtime.currentOptions == options, "invalid effort cannot partially change controls") }
            f.send("first turn")
            check(f.runtime.currentConversation?.title == "模型与模式", "first send preserves an explicitly renamed title")
            let sid = f.runtime.currentConversation?.sessionID, account = f.runtime.currentConversation?.account
            func value(_ flag: String, in args: [String]) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
            let firstArgs = f.runs[0]["args"] as! [String]
            check(value("--model", in: firstArgs) == "opus" && value("--permission-mode", in: firstArgs) == "plan" && value("--effort", in: firstArgs) == "high", "saved options reach the first real-CCAM / fake-Claude turn")
            try f.runtime.updateOptions(model: "haiku", permissionMode: .acceptEdits, effort: "low")
            f.send("same conversation")
            let nextArgs = f.runs[1]["args"] as! [String]
            check(value("--model", in: nextArgs) == "haiku" && value("--permission-mode", in: nextArgs) == "acceptEdits" && value("--effort", in: nextArgs) == "low", "changed options reach the following turn")
            check(f.runtime.currentConversation?.sessionID == sid && f.runtime.currentConversation?.account == account && f.runs[1]["sid"] as? String == sid, "changing model or mode keeps exact session, account and history")
            try f.runtime.updateOptions(model: nil, permissionMode: .default)
            f.send("restore account default")
            let defaultArgs = f.runs[2]["args"] as! [String]
            check(value("--model", in: defaultArgs) == "default" && !defaultArgs.contains("--effort"), "default model explicitly clears the previous override and default effort is omitted")
            let terminal = try GlobalPool.prepareChatTerminal(target: f.runtime.terminalFallback); defer { GlobalPool.clean(terminal) }
            check(value("--model", in: terminal.args) == "default" && terminal.args.contains(sid!) && value("--permission-mode", in: terminal.args) == "default", "terminal takeover retains exact session and selected model/mode")
            let messages = f.runtime.currentMessages
            f.runtime.createConversation(); let secondID = f.runtime.selectedID!
            try f.runtime.deleteConversation(id: originalID)
            check(f.runtime.activeConversations.map(\.id) == [secondID] && f.runtime.deletedConversations[0].messages == messages, "deletion hides only the record and retains history for recovery")
            f.runtime.select(id: originalID)
            check(f.runtime.selectedID == secondID, "deleted record cannot be selected as a live conversation")
            try f.runtime.restoreConversation(id: originalID)
            check(f.runtime.selectedID == originalID && f.runtime.currentMessages == messages && f.runtime.currentConversation?.sessionID == sid, "restoration retains exact context and selects restored conversation")
            try f.runtime.deleteConversation(id: originalID)
            check(f.runtime.selectedID == secondID, "deleting selected conversation selects another active record")
            try f.runtime.deleteConversation(id: secondID)
            check(f.runtime.selectedID == nil && f.runtime.activeConversations.isEmpty && f.runtime.deletedConversations.count == 2, "deleting last active conversation leaves recoverable records and an empty selection")
            let deletedStore = try ChatStore(project: f.project, fileURL: f.store.fileURL)
            check(deletedStore.selectedID == nil && deletedStore.conversations.allSatisfy { $0.deletedAt != nil }, "deleted state and empty selection survive restart")
            try f.runtime.updateOptions(model: "custom-model[1m]", permissionMode: .plan, effort: "max")
            check(f.runtime.activeConversations.count == 1 && f.runtime.currentOptions.model == "custom-model[1m]" && f.runs.count == 3, "changing controls after deleting all records creates a local blank conversation without requests")
        }
        do {
            let f = try Fixture(); defer { f.clean() }
            let prompt = "- 检查一个带空格的文件\n保留第二行"
            f.send(prompt)
            check(!f.runtime.hasRunning && f.runs.count == 1, "first chat turn completes using real CCAM")
            check(f.runs[0]["account"] as? String == "first", "first launch uses global pool, bypassing folder binding")
            check(f.runs[0]["prompt"] as? String == prompt, "multiline dash-prefixed prompt sent intact through stdin")
            check(f.runtime.currentMessages.filter { $0.role == "assistant" }.map(\.text) == ["第一段完成", "第二段完成"], "partial/final blocks with same message ID do not duplicate or overwrite each other")
            check(f.runtime.currentMessages.filter { $0.role == "tool" }.first?.text == "fixture tool result", "structured tool result updates existing tool row")
            let sid = f.runtime.terminalFallback.sessionID
            check(sid == f.runs[0]["sid"] as? String && f.runtime.terminalFallback.account == "first", "SessionStart verifies persisted account and session")
            f.send("继续检查下一项")
            check(f.runs.count == 2 && f.runs[1]["account"] as? String == "first" && f.runs[1]["sid"] as? String == sid, "second turn resumes same account and exact session")
            let args = f.runs[1]["args"] as! [String]
            check(args.contains("--resume") && args.contains(sid!) && !args.contains("--continue"), "ordinary continuation never chooses latest conversation")
            check(!args.contains("bypassPermissions") && args.contains("manual") && args.contains("none"), "default print turn never bypasses permissions")
            check(f.starts.count == 2, "browser/settings preflight runs on each turn")
            let reopened = try ChatStore(project: f.project, fileURL: f.store.fileURL)
            check(reopened.conversations[0].sessionID == sid && reopened.conversations[0].messages.filter { $0.role == "user" }.count == 2, "persisted conversation survives reopen")
            f.runtime.markTransferredToTerminal(); f.runtime.send(text: "must not start")
            check(f.runtime.currentConversationTransferred && f.runs.count == 2, "terminal transfer prevents concurrent graphical sends")
            let transferred = try ChatStore(project: f.project, fileURL: f.store.fileURL)
            check(transferred.conversations[0].transferredToTerminal, "terminal transfer persists across restart")
        }
        do {
            let f = try Fixture(); defer { f.clean() }
            try f.runtime.updateOptions(model: "sonnet", permissionMode: .auto)
            let reopened = try ChatStore(project: f.project, fileURL: f.store.fileURL)
            check(reopened.conversations[0].options?.permissionMode == .auto && f.runs.isEmpty, "Auto selection persists without a request")
            f.send("Auto task")
            let sid = f.runtime.currentConversation!.sessionID!
            func value(_ flag: String, in args: [String]) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
            let args = f.runs[0]["args"] as! [String]
            check(value("--permission-mode", in: args) == "auto" && value("--permission-prompts", in: args) == "none", "Auto reaches the native headless permission classifier")
            check(!args.contains("bypassPermissions") && !args.contains("dontAsk"), "Auto never substitutes blanket permission bypass")
            let terminal = try GlobalPool.prepareChatTerminal(target: f.runtime.terminalFallback); defer { GlobalPool.clean(terminal) }
            check(value("--permission-mode", in: terminal.args) == "auto" && terminal.args.contains(sid), "terminal takeover preserves Auto and the exact session")
            f.send("Auto follow-up")
            let resumed = f.runs[1]["args"] as! [String]
            check(value("--permission-mode", in: resumed) == "auto" && value("--resume", in: resumed) == sid, "Auto follow-up resumes exact context")
            try f.runtime.updateOptions(model: "sonnet", permissionMode: .plan)
            f.send("Plan the next step")
            let planned = f.runs[2]["args"] as! [String]
            check(value("--permission-mode", in: planned) == "plan" && value("--resume", in: planned) == sid, "switching Auto to Plan preserves context and enforces Plan argument")
        }
        for mode in ["limit", "consecutive"] {
            let f = try Fixture(mode); defer { f.clean() }
            let permission: ChatPermissionMode = mode == "limit" ? .auto : .plan
            try f.runtime.updateOptions(model: "sonnet", permissionMode: permission, effort: "xhigh")
            f.send("Original task must execute once")
            let expected = mode == "limit" ? ["first", "second"] : ["first", "second", "third"]
            check(f.runs.map { $0["account"] as! String } == expected, "\(mode) real native CCAM hook selects subsequent accounts")
            check(f.runs.filter { $0["prompt"] as? String == "Original task must execute once" }.count == 1, "\(mode) never replays original task")
            check(f.runs.dropFirst().allSatisfy { $0["prompt"] as? String == GlobalPool.continuationPrompt }, "\(mode) automatically continues with scoped recovery prompt")
            check(f.work == ["user:Original task must execute once"] + expected.dropFirst().map { "continued-" + $0 }, "\(mode) automatic work continues after interrupted work without replay")
            check(f.runs.dropFirst().allSatisfy { ($0["args"] as? [String])?.contains("--fork-session") == true }, "\(mode) native CCAM forks exact transcript across accounts")
            check(f.runs.allSatisfy { run in let args = run["args"] as! [String]; return args.contains("sonnet") && args.contains(permission.rawValue) && args.contains("xhigh") }, "\(mode) account handoffs preserve selected model, mode and effort")
            check(f.runs.dropFirst().allSatisfy { !($0["args"] as! [String]).contains { $0.hasSuffix("unrelated.jsonl") } }, "newer unrelated handoff cannot replace exact conversation")
            let last = f.runs.last!, sid = last["sid"] as! String, account = last["account"] as! String
            check(f.runtime.terminalFallback.sessionID == sid && f.runtime.terminalFallback.account == account, "latest fork identity retained")
            f.send("Second user turn")
            check(f.runs.last?["sid"] as? String == sid && f.runs.last?["account"] as? String == account, "second turn after quota migration continues new exact fork")
            check(f.starts.count == f.runs.count, "every account switch passes browser guard")
        }
        do {
            let f = try Fixture("limit", race: true); defer { f.clean() }
            f.send("once")
            check(f.runs.count == 2 && f.runs[1]["prompt"] as? String == GlobalPool.continuationPrompt, "75 race retries native note without duplicating actual work")
        }
        do {
            let f = try Fixture("limit", full: true); defer { f.clean() }
            f.runtime.send(text: "wait")
            spin { f.runtime.stateText.contains("等待额度") }
            check(f.runtime.hasRunning && f.runs.count == 1, "all accounts exhausted waits without relaunching old task")
            f.runtime.stop(); spin { !f.runtime.hasRunning }
            let count = f.starts.count; spin(0.5) { false }
            check(!f.runtime.hasRunning && f.starts.count == count && f.runs.count == 1, "cancelled waiting never launches a pending continuation")
        }
        do {
            let f = try Fixture("ordinary"); defer { f.clean() }; f.send("network failure")
            check(f.runs.count == 1 && !f.runtime.hasRunning, "non-quota failure does not rotate despite rate_limit words")
        }
        do {
            let f = try Fixture("permission"); defer { f.clean() }; f.send("needs permission")
            check(f.runtime.needsTerminalInteraction && f.runtime.stateText.contains("权限"), "result permission_denials overrides success label")
        }
        do {
            let f = try Fixture("identityless"); defer { f.clean() }; f.send("first")
            f.runtime.send(text: "must not start")
            check(f.runs.count == 1 && !f.runtime.hasRunning && !f.runtime.terminalFallback.canResume, "missing identity cannot silently create new conversation or terminal fallback")
            let unverified = try ChatStore(project: f.project, fileURL: f.store.fileURL)
            check(unverified.conversations[0].continuityUnavailable == true, "unverified identity state persists")
        }
        do {
            let f = try Fixture("slow"); defer { f.clean() }; f.runtime.send(text: "working")
            let runningID = f.runtime.selectedID!
            do { try f.runtime.deleteConversation(id: runningID); check(false, "running record deletion rejected") } catch { check(f.runtime.activeConversations.contains { $0.id == runningID }, "running conversation remains visible until explicitly stopped") }
            do { try f.runtime.updateOptions(model: "opus", permissionMode: .plan); check(false, "running controls rejected") } catch { check(f.runtime.currentOptions.model == nil, "running controls cannot alter in-flight handoff options") }
            spin { f.runtime.currentMessages.contains { $0.role == "assistant" } }; f.runtime.stop(); f.runtime.stop(); f.runtime.send(text: "cannot race old process")
            spin { !f.runtime.hasRunning }
            check(f.runs.count == 1 && !f.runtime.hasRunning, "repeated stop is idempotent and reaps before allowing another send")
            check(f.runtime.terminalFallback.sessionID == f.runs[0]["sid"] as? String && f.runtime.terminalFallback.canResume, "stopped turn retains exact verified identity")
        }
        do {
            let f = try Fixture("early-stop"); defer { f.clean() }; f.runtime.send(text: "working")
            spin { !f.runs.isEmpty }; f.runtime.stop(); f.runtime.stop(); spin { !f.runtime.hasRunning }
            f.runtime.send(text: "must not silently restart")
            check(!f.runtime.hasRunning && f.runs.count == 1 && !f.runtime.terminalFallback.canResume, "stopping before identity cannot silently create a new session")
        }
        do {
            let first = try Fixture(), second = try Fixture(); defer { first.clean(); second.clean() }
            first.runtime.send(text: "parallel project A"); second.runtime.send(text: "parallel project B")
            spin { !first.runtime.hasRunning && !second.runtime.hasRunning }
            check(first.runs.count == 1 && second.runs.count == 1 && first.runtime.terminalFallback.sessionID != second.runtime.terminalFallback.sessionID, "parallel projects have independent session identities")
            first.send("A follow-up"); second.send("B follow-up")
            check(first.work == ["user:parallel project A", "user:A follow-up"] && second.work == ["user:parallel project B", "user:B follow-up"], "parallel project work and follow-ups stay in their own directory")
            let firstSaved = try ChatStore(project: first.project, fileURL: first.store.fileURL)
            let secondSaved = try ChatStore(project: second.project, fileURL: second.store.fileURL)
            check(firstSaved.conversations[0].sessionID != secondSaved.conversations[0].sessionID && !firstSaved.conversations[0].messages.contains { $0.text.contains("project B") }, "parallel project stores never mix messages or overwrite identities")
        }
        do {
            let f = try Fixture(); defer { f.clean() }
            f.runtime.beforeStart = { _ in throw AppError.message("browser lock rejected") }; f.send("blocked")
            check(f.runs.isEmpty && !f.runtime.hasRunning, "browser guard rejection prevents process launch")
            let secret = "ANTHROPIC_API_KEY=fixture-secret Bearer fixture.bearer sk-ant-fixture-token"
            var conversation = f.runtime.conversations[0]; conversation.messages = [ChatMessage(role: "tool", text: secret)]
            try f.store.save([conversation], selectedID: conversation.id)
            let saved = try String(contentsOf: f.store.fileURL, encoding: .utf8)
            check(!saved.contains("fixture-secret") && !saved.contains("fixture.bearer") && !saved.contains("sk-ant-fixture-token"), "known credentials are redacted in the app's saved copy")
            check(conversation.messages[0].text == secret, "redaction never rewrites original prompt or in-memory tool result")
        }
        do {
            let f = try Fixture("limit"); defer { f.clean(); unsetenv("CCAM_DESKTOP_DATA_DIR") }
            setenv("CCAM_DESKTOP_DATA_DIR", f.root.appendingPathComponent("desktopdata").path, 1)
            let source = f.root.appendingPathComponent("source with spaces.txt")
            try "attachment fixture".write(to: source, atomically: true, encoding: .utf8)
            let files = ChatAttachmentStore(project: f.project)
            let file = try files.stageFiles([source])[0], bytes = imageData()
            let picture = try files.stageImage(data: bytes, existing: [file])
            try f.runtime.setDraftAttachments([file, picture])
            let reopened = try ChatRuntime(project: f.project, store: ChatStore(project: f.project, fileURL: f.store.fileURL))
            check(reopened.currentAttachments.count == 2 && f.runs.isEmpty, "attachment drafts persist without executing Claude")
            try f.runtime.updateOptions(model: "sonnet", permissionMode: .auto)
            f.send("")
            check(f.runs.count == 2, "attachments complete isolated quota handoff")
            let blocks = f.runs[0]["content"] as? [[String: Any]] ?? []
            let imageBlock = blocks.first(where: { $0["type"] as? String == "image" })
            let image = imageBlock?["source"] as? [String: String]
            check(image?["media_type"] == "image/png" && Data(base64Encoded: image?["data"] ?? "") == bytes, "actual stdin carries image bytes rather than a placeholder path")
            let input = f.runs[0]["raw_input"] as? String ?? ""
            check(input.hasSuffix("\n") && (f.runs[0]["args"] as? [String] ?? []).contains("stream-json"), "structured user frame is newline terminated")
            let scope = try files.url(for: file).deletingLastPathComponent().path
            check(f.starts.allSatisfy { $0.contains("--add-dir") && $0.contains(scope) && !$0.contains(source.deletingLastPathComponent().path) }, "file permissions follow the exact private copy across handoff")
            check(f.runs[1]["prompt"] as? String == GlobalPool.continuationPrompt && !(f.runs[1]["args"] as? [String] ?? []).contains("--input-format"), "handoff uses transcript content without resending attachments")
            check(f.runtime.currentAttachments.isEmpty && f.runtime.currentMessages.first?.attachments?.count == 2, "sent attachments move from draft into history")
            let saved = try String(contentsOf: f.store.fileURL, encoding: .utf8)
            check(!saved.contains(bytes.base64EncodedString()), "desktop history persists metadata instead of image blobs")
            f.send("follow up")
            let followup = f.runs.last?["prompt"] as? String
            check(f.starts.last?.contains(scope) == true && followup == "follow up", "later text turns retain file access without changing input format")
            try FileManager.default.removeItem(at: files.url(for: file))
            f.send("continue without the missing attachment")
            check(f.runs.count == 4 && f.starts.last?.contains(scope) == false, "missing historical attachment never blocks later turns or grants its directory")
            check(f.runtime.currentMessages.contains { $0.role == "notice" && $0.text.contains("历史附件") }, "missing historical attachment is explained")
        }
        do {
            let f = try Fixture("auto-fallback"); defer { f.clean() }
            f.send("offline Auto fallback", mode: .auto)
            check(f.runtime.currentMessages.filter { $0.role == "notice" && $0.text.contains("Auto") }.count == 1, "init/status report actual fallback mode once")
        }
        do {
            let f = try Fixture("auto-plan"); defer { f.clean() }
            f.send("offline Auto to Plan transition", mode: .auto)
            check(f.runtime.currentMessages.contains { $0.role == "notice" && $0.text == "当前已切换到计划模式。" }, "normal Auto to Plan transition uses neutral status")
            check(!f.runtime.currentMessages.contains { $0.text.contains("未启用 Auto") }, "normal mode transition is not misreported as unavailable Auto")
        }
        print("PASS: \(checks) chat checks (real CCAM, isolated fake Claude, no real credentials/API requests)")
    }
}
