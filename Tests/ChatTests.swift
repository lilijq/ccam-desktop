import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers

#if !CHAT_UI_FIXTURES
@main
#endif
enum ChatTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ text: String) {
        guard condition() else { fputs("FAIL: \(text)\n", stderr); exit(1) }; checks += 1
    }
    static func spin(_ seconds: TimeInterval = 12, until: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !until() { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
    static func sameSavedMetadata(_ lhs: [ChatConversation], _ rhs: [ChatConversation]) -> Bool {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
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
            for key in ExecutionProxy.proxyKeys + ["CCAM_DESKTOP_PROXY_SOURCE", "CCAM_DESKTOP_PROXY_ENDPOINT"] { env.removeValue(forKey: key) }
            env["HTTP_PROXY"] = "http://127.0.0.1:1"
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
        var replies: [[String: Any]] {
            ((try? String(contentsOf: root.appendingPathComponent("replies"), encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
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
root=pathlib.Path(os.environ['CCAM_HOME']);account=os.environ['CCAM_PROFILE'];mode=os.environ['CHAT_FIXTURE_MODE'];args=sys.argv[1:]
initialize=json.loads(sys.stdin.readline());assert initialize['type']=='control_request' and initialize['request']['subtype']=='initialize'
print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':initialize['request_id'],'response':{}}}),flush=True)
raw_input=sys.stdin.readline();prompt=raw_input
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
if mode not in ('identityless','approval-identityless'):hook('SessionStart')
emit({'type':'system','subtype':'init','permissionMode':'default' if mode=='auto-fallback' else value('--permission-mode')})
if mode=='auto-fallback':emit({'type':'system','subtype':'status','permissionMode':'default'})
if mode=='auto-plan':emit({'type':'system','subtype':'status','permissionMode':'plan'})
now=datetime.datetime.now(datetime.timezone.utc).isoformat()
with transcript.open('a') as f:f.write(json.dumps({'type':'user','uuid':str(uuid.uuid4()),'timestamp':now,'sessionId':sid,'permissionMode':'manual','message':{'role':'user','content':content}})+'\n')
work=pathlib.Path.cwd()/'work-state.json';state=json.loads(work.read_text()) if work.exists() else []
state.append('continued-'+account if prompt.startswith('上一个账号的额度已耗尽') else 'user:'+prompt);work.write_text(json.dumps(state))
if mode.startswith('approval'):
    tool='AskUserQuestion' if mode=='approval-question' else 'ExitPlanMode' if mode in ('approval-plan','approval-plan-empty') else 'Bash'
    tool_input={'command':'git -C ./repo status --short','description':'查看仓库状态'}
    if tool=='AskUserQuestion':tool_input={'questions':[{'header':'范围','question':'要查看哪个仓库？','options':[{'label':'全部','description':'六个子仓库'},{'label':'当前','description':'当前项目'}],'multiSelect':False},{'header':'检查','question':'检查哪些内容？','options':[{'label':'分支','description':'当前分支'},{'label':'改动','description':'工作区状态'}],'multiSelect':True}]}
    if tool=='ExitPlanMode':tool_input={} if mode=='approval-plan-empty' else {'plan':'先检查六个子仓库状态，再逐个安全拉取。','allowedPrompts':[{'tool':'Bash','prompt':'inspect git status'}]}
    request={'type':'control_request','request_id':'permission-1','request':{'subtype':'can_use_tool','tool_name':tool,'tool_use_id':'use-1','input':tool_input,'decision_reason':'需要你的确认'}}
    if mode=='approval-mismatched':request['session_id']=str(uuid.uuid4())
    if mode=='approval-background':
        emit({'type':'system','subtype':'session_state_changed','state':'running','sdk_host_only':True})
        emit({'type':'result','subtype':'success','is_error':False,'result':'后台任务仍在处理'})
    emit(request)
    if mode=='approval-duplicate':emit(request)
    if mode=='approval-changed':
        emit({**request,'request':{**request['request'],'input':{'command':'different command'}}});time.sleep(30);sys.exit(0)
    if mode=='approval-cancel':
        time.sleep(.15);emit({'type':'control_cancel_request','request_id':'permission-1'})
    else:
        raw=sys.stdin.readline()
        if not raw:sys.exit(0)
        reply=json.loads(raw);assert reply['type']=='control_response';response=reply['response'];assert response['request_id']=='permission-1' and response['subtype']=='success'
        with (root/'replies').open('a') as f:f.write(json.dumps(response)+'\n')
        if response['response']['behavior']=='allow':
            assert 'updatedPermissions' not in response['response']
            (root/'approved').write_text('once')
if mode=='slow':
    emit({'type':'assistant','message':{'id':'slow','content':[{'type':'text','text':'Working'}]}});time.sleep(30);sys.exit(0)
if mode=='ordinary':
    emit({'type':'result','subtype':'error_during_execution','is_error':True,'errors':['network error rate_limit text is not a hook']});sys.exit(7)
limited=mode in ('limit','consecutive','approval-limit') and (account=='first' or mode=='consecutive' and account=='second')
if limited:
    msg="You've hit your session limit · resets 3:30am (Asia/Seoul)"
    row={'type':'assistant','uuid':str(uuid.uuid4()),'timestamp':now,'sessionId':sid,'apiError':'usage_limit_reached','error':'rate_limit','isApiErrorMessage':True,'message':{'model':'<synthetic>','role':'assistant','content':[{'type':'text','text':msg}]},'apiErrorParams':{'rate_limit_info':{'status':'rejected','rateLimitType':'five_hour','resetsAt':int(time.time()+3600)}},'quotaLimits':{'status':'rejected','rateLimitType':'five_hour','resetsAt':int(time.time()+3600)}}
    with transcript.open('a') as f:f.write(json.dumps(row)+'\n')
    hook('StopFailure',{'error':'rate_limit','last_assistant_message':msg})
    unrelated=root/'unrelated.jsonl';unrelated.write_text('{}\n')
    note=root/'state/handoff/third/unrelated.json';note.parent.mkdir(parents=True,exist_ok=True);note.write_text(json.dumps({'account':'third','session_id':'unrelated','transcript_path':str(unrelated),'cwd':os.getcwd(),'reason':'limit','at':datetime.datetime.now(datetime.timezone.utc).isoformat()}))
    emit({'type':'result','subtype':'error_during_execution','is_error':True,'errors':['rate_limit']});sys.exit(1)
if mode=='live-translation':
    chunks=['Inspect `main.rs` before deployment.\n\n','```rust\nfn main()', ' {}\n```\n\n','Keep ～server-name～ unchanged.\n']
    emit({'type':'stream_event','event':{'type':'message_start','message':{'id':'live'}}})
    for chunk in chunks:
        emit({'type':'stream_event','event':{'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':chunk}}})
        time.sleep(.8)
    emit({'type':'assistant','message':{'id':'live','content':[{'type':'text','text':''.join(chunks)}]}})
    emit({'type':'result','subtype':'success','is_error':False});sys.exit(0)
emit({'type':'stream_event','event':{'type':'message_start','message':{'id':'msg-'+sid}}})
for index,text in [(0,'第一段完成'),(2,'第二段完成')]:
    emit({'type':'stream_event','event':{'type':'content_block_delta','index':index,'delta':{'type':'text_delta','text':text}}})
    emit({'type':'assistant','message':{'id':'msg-'+sid,'content':[{'type':'text','text':('更正后的正文' if mode=='corrected-final' and index==0 else text)}]}})
emit({'type':'assistant','message':{'id':'msg-'+sid,'content':[{'type':'tool_use','id':'tool1','name':'Read','input':{'file_path':'a.txt'}}]}})
emit({'type':'user','message':{'content':[{'type':'tool_result','tool_use_id':'tool1','content':'fixture tool result'}]}})
emit({'type':'result','subtype':'success','is_error':False,'result':'第二段完成','permission_denials':[{'tool_name':'Bash','tool_use_id':'denied','tool_input':{}}] if mode=='permission' else []})
if mode=='approval-background':emit({'type':'system','subtype':'session_state_changed','state':'idle','sdk_host_only':True})
if mode in ('approval-background','approval-duplicate'):assert sys.stdin.read()==''
"""#
    }

    static func multiConversationChecks() throws {
        let f = try Fixture("slow"); defer { f.clean() }
        let first = f.runtime.selectedID!, second = UUID().uuidString
        var original = f.runtime.currentConversation!
        let answer = ChatMessage(role: "assistant", text: "Original answer")
        original.messages = [answer]
        let other = ChatConversation(id: second, title: "Second", projectID: f.project.id.uuidString, directory: f.project.path)
        try f.store.save([original, other], selectedID: first)
        func store() throws -> ChatStore { try ChatStore(project: f.project, fileURL: f.store.fileURL) }
        func index(_ values: [ChatConversation], _ id: String) -> Int { values.firstIndex { $0.id == id }! }
        let left = try store(), right = try store()
        var pending = left.conversations
        let stream = ChatMessage(role: "assistant", text: "Pending stream")
        pending[index(pending, first)].messages.append(stream)
        var remote = right.conversations
        remote[index(remote, first)].title = "Renamed elsewhere"
        remote[index(remote, first)].messages[0].translatedText = "原回复译文"
        remote[index(remote, first)].options = ChatOptions(autoTranslateReplies: false)
        let attachment = ChatAttachment(id: "fixture-attachment", name: "fixture.txt", relativePath: "fixture/file", kind: .file, byteCount: 1, mediaType: nil, sha256: "fixture-only")
        remote[index(remote, second)].draftAttachments = [attachment]
        remote[index(remote, second)].messages.append(ChatMessage(role: "user", text: "Other pane"))
        try right.save(remote, selectedID: second)
        try left.save(pending, selectedID: first, preserveSelection: true)
        var saved = try store()
        check(saved.conversations[index(saved.conversations, first)].title == "Renamed elsewhere" && saved.selectedID == second,
              "a stale stream save preserves another pane's rename and global selection")
        check(saved.conversations[index(saved.conversations, first)].messages.map(\.id) == [answer.id, stream.id] && saved.conversations[index(saved.conversations, first)].messages[0].translatedText == "原回复译文",
              "message-ID merging preserves pending output and another pane's translation")
        check(saved.conversations[index(saved.conversations, second)].draftAttachments == [attachment] && saved.conversations[index(saved.conversations, second)].messages.count == 1,
              "a sibling stream cannot overwrite another conversation's draft attachments or message")
        pending = left.conversations
        let pendingIndex = index(pending, first)
        pending[pendingIndex].messages[pending[pendingIndex].messages.count - 1].text += " more"
        try left.save(pending, selectedID: first, preserveSelection: true)
        check(left.conversations[index(left.conversations, first)].title == "Renamed elsewhere", "adopting the merged baseline prevents a later save from reverting a remote rename")

        let dirty = try store(), metadata = try store()
        var dirtyValues = dirty.conversations
        dirtyValues[index(dirtyValues, first)].messages[0].text = "Changed source"
        var metadataValues = metadata.conversations
        metadataValues[index(metadataValues, second)].title = "Fresh second title"
        try metadata.save(metadataValues, selectedID: second)
        dirtyValues = try dirty.rebase(dirtyValues)
        check(dirtyValues[index(dirtyValues, first)].messages[0].text == "Changed source" && dirtyValues[index(dirtyValues, second)].title == "Fresh second title",
              "notification rebasing preserves unsaved local stream text while importing other metadata")
        try dirty.save(dirtyValues, selectedID: first, preserveSelection: true)
        check(dirty.conversations[index(dirty.conversations, first)].messages[0].translatedText == nil,
              "a translation tied to an older source is invalidated when stream text changes")

        let stale = try store(), deleting = try store()
        var staleValues = stale.conversations, deletedValues = deleting.conversations
        deletedValues[index(deletedValues, first)].deletedAt = Date()
        try deleting.save(deletedValues, selectedID: second)
        staleValues[index(staleValues, first)].messages.append(ChatMessage(role: "notice", text: "Late stream flush"))
        try stale.save(staleValues, selectedID: first, preserveSelection: true)
        saved = try store()
        check(saved.conversations[index(saved.conversations, first)].deletedAt != nil, "a stale stream flush cannot resurrect a deleted conversation")
        do { _ = try ChatRuntime(project: f.project, conversationID: first, store: saved, environment: f.environment); check(false, "deleted binding must fail") }
        catch { check(true, "opening a deleted binding never silently selects another conversation") }
        do { _ = try ChatRuntime(project: f.project, conversationID: "missing", store: try store(), environment: f.environment); check(false, "missing binding must fail") }
        catch { check(true, "opening a missing binding fails without creating a new conversation") }

        let boundRight = try ChatRuntime(project: f.project, conversationID: second, store: try store(), environment: f.environment)
        try boundRight.restoreConversation(id: first)
        check(boundRight.selectedID == second && boundRight.currentConversation?.title == "Fresh second title", "restoring another conversation keeps the pane's immutable binding")
        boundRight.select(id: first)
        check(boundRight.selectedID == second && boundRight.createConversation() == nil, "bound runtimes cannot switch identity or create a hidden replacement conversation")

        let permissionA = try store(), permissionB = try store()
        try permissionA.remember(tool: "Bash"); try permissionB.remember(tool: "Read")
        check(permissionA.refreshedRememberedTools() == ["Bash", "Read"], "independent permission stores union explicit remembered choices")
        try permissionA.clearRememberedTools()
        check(boundRight.rememberedTools.isEmpty && permissionB.refreshedRememberedTools().isEmpty, "cleared project permissions take effect in other runtimes before notifications run")
        try permissionB.remember(tool: "Edit")
        check(permissionA.refreshedRememberedTools() == ["Edit"], "a stale permission store cannot restore choices that were explicitly cleared")

        let rollback = try store(), previous = rollback.conversations
        let newID = try rollback.createConversation()
        try rollback.save(previous, selectedID: first)
        check(!rollback.conversations.contains { $0.id == newID }, "record rollback recognizes its unchanged save despite ISO8601 date precision")
        let retainedID = try rollback.createConversation(), external = try store()
        var externalValues = external.conversations
        externalValues[index(externalValues, retainedID)].title = "External edit survives rollback"
        try external.save(externalValues, selectedID: retainedID)
        try rollback.save(previous, selectedID: first)
        check(rollback.conversations.contains { $0.id == retainedID && $0.title == "External edit survives rollback" }, "record rollback cannot remove a conversation changed by another writer")
        var invalid = rollback.conversations
        invalid[index(invalid, first)].messages = [answer, answer]
        do { try rollback.save(invalid, selectedID: first); check(false, "duplicate message IDs rejected") }
        catch { check(true, "duplicate message IDs produce an error instead of a dictionary trap") }

        let blocked = try ChatRuntime(project: f.project, conversationID: first, store: try store(),
                                      ccamExecutable: f.root.appendingPathComponent("missing-launcher").path,
                                      helperExecutable: CommandLine.arguments[0], environment: f.environment)
        let beforeBlockedMessages = blocked.currentMessages
        blocked.beforeStart = { _ in
            let concurrent = try store(); var values = concurrent.conversations
            values[index(values, first)].title = "Rename during failed launch"
            try concurrent.save(values, selectedID: second)
        }
        check(!blocked.send(text: "rejected local turn"), "a missing launcher cannot accept the proposed turn")
        check(blocked.currentConversation?.title == "Rename during failed launch" && blocked.currentMessages == beforeBlockedMessages,
              "failed launch rollback removes only its own prompt and preserves an interleaved external rename")

        // Only the fixture fake executable is reachable; no real Claude request.
        let leftRuntime = try ChatRuntime(project: f.project, conversationID: first, store: try store(), ccamExecutable: f.native,
                                          helperExecutable: CommandLine.arguments[0], environment: f.environment, retryInterval: 0.15, maximumWait: 10)
        let rightRuntime = try ChatRuntime(project: f.project, conversationID: second, store: try store(), ccamExecutable: f.native,
                                           helperExecutable: CommandLine.arguments[0], environment: f.environment, retryInterval: 0.15, maximumWait: 10)
        // Remove a metadata-only attachment fixture before exercising execution.
        try rightRuntime.setDraftAttachments([])
        defer { leftRuntime.stop(); rightRuntime.stop(); spin(5) { !leftRuntime.hasRunning && !rightRuntime.hasRunning } }
        check(leftRuntime.send(text: "parallel left") && rightRuntime.send(text: "parallel right"), "two bound conversations can start independent isolated fake turns")
        spin { leftRuntime.currentMessages.contains { $0.text == "Working" } && rightRuntime.currentMessages.contains { $0.text == "Working" } }
        check(leftRuntime.hasRunning && rightRuntime.hasRunning && leftRuntime.selectedID == first && rightRuntime.selectedID == second,
              "simultaneous streams retain independent runtime state and fixed selections")
        try rightRuntime.renameConversation(id: first, title: "Renamed during streaming")
        try rightRuntime.saveTranslation(messageID: answer.id, sourceText: "Changed source", text: "并发译文")
        leftRuntime.stop(); spin { !leftRuntime.hasRunning }
        check(rightRuntime.hasRunning, "stopping one conversation leaves its sibling process running")
        rightRuntime.stop(); spin { !rightRuntime.hasRunning }
        saved = try store()
        check(saved.conversations[index(saved.conversations, first)].title == "Renamed during streaming" && saved.conversations[index(saved.conversations, first)].messages.first { $0.id == answer.id }?.translatedText == "并发译文",
              "stream completion preserves concurrent title and translation metadata")
        check(saved.conversations[index(saved.conversations, first)].messages.contains { $0.text == "parallel left" } && saved.conversations[index(saved.conversations, second)].messages.contains { $0.text == "parallel right" },
              "both concurrent transcripts survive final persistence")
        try boundRight.deleteConversation(id: first)
        leftRuntime.reloadConversationIndex()
        check(leftRuntime.selectedID == first && leftRuntime.boundConversationUnavailable && !leftRuntime.send(text: "must not start"),
              "deleted bound panes remain unavailable and cannot send into another conversation")
        try boundRight.restoreConversation(id: first)
        leftRuntime.reloadConversationIndex()
        check(leftRuntime.selectedID == first && !leftRuntime.boundConversationUnavailable && leftRuntime.stateText == "继续这段对话",
              "restoring a bound conversation also clears its stale deleted-state label")
    }

    static func main() throws {
        if let code = GlobalPool.handleHelperInvocation() { exit(code) }
        try multiConversationChecks()
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
            f.runtime.webMCPArguments = { ["--mcp-config", "/tmp/offline-project-web.json"] }
            f.send("first turn")
            check(f.runtime.currentConversation?.title == "模型与模式", "first send preserves an explicitly renamed title")
            let sid = f.runtime.currentConversation?.sessionID, account = f.runtime.currentConversation?.account
            func value(_ flag: String, in args: [String]) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
            let firstArgs = f.runs[0]["args"] as! [String]
            check(value("--mcp-config", in: firstArgs) == "/tmp/offline-project-web.json", "project browser MCP reaches the CLI after the CCAM separator")
            check(value("--model", in: firstArgs) == "opus" && value("--permission-mode", in: firstArgs) == "plan" && value("--effort", in: firstArgs) == "high", "saved options reach the first real-CCAM / fake-Claude turn")
            try f.runtime.updateOptions(model: "haiku", permissionMode: .acceptEdits, effort: "low")
            f.send("same conversation")
            let nextArgs = f.runs[1]["args"] as! [String]
            check(value("--mcp-config", in: nextArgs) == "/tmp/offline-project-web.json", "project browser MCP persists across resumed turns")
            check(value("--model", in: nextArgs) == "haiku" && value("--permission-mode", in: nextArgs) == "acceptEdits" && value("--effort", in: nextArgs) == "low", "changed options reach the following turn")
            check(f.runtime.currentConversation?.sessionID == sid && f.runtime.currentConversation?.account == account && f.runs[1]["sid"] as? String == sid, "changing model or mode keeps exact session, account and history")
            try f.runtime.updateOptions(model: nil, permissionMode: .default)
            f.send("restore account default")
            let defaultArgs = f.runs[2]["args"] as! [String]
            check(value("--model", in: defaultArgs) == "default" && !defaultArgs.contains("--effort"), "default model explicitly clears the previous override and default effort is omitted")
            let terminal = try GlobalPool.prepareChatTerminal(target: f.runtime.terminalFallback, baseEnvironment: f.environment); defer { GlobalPool.clean(terminal) }
            check(value("--model", in: terminal.args) == "default" && terminal.args.contains(sid!) && value("--permission-mode", in: terminal.args) == "default", "terminal takeover retains exact session and selected model/mode")
            let terminalSettings = try JSONSerialization.jsonObject(with: Data(value("--settings", in: terminal.args)!.utf8)) as! [String: Any]
            let terminalHooks = terminalSettings["hooks"] as? [String: Any]
            check(terminalHooks?["SessionStart"] != nil && terminal.environment["CCAM_DESKTOP_CHAT"] == "1", "terminal takeover captures its verified return identity")
            let injected = terminalSettings["env"] as? [String: String] ?? [:]
            check(ExecutionProxy.proxyKeys.allSatisfy { injected[$0] == terminal.environment[$0] } && injected["NO_PROXY"] == ExecutionProxy.loopbackBypass, "CLI flag settings pin the same mandatory proxy against project settings overrides")
            let replacement = try GlobalPool.prepare(directory: f.project.path, continueLast: false, baseEnvironment: terminal.environment)
            defer { GlobalPool.clean(replacement) }
            let replacementSettings = try JSONSerialization.jsonObject(with: Data(value("--settings", in: replacement.args)!.utf8)) as! [String: Any]
            check((replacementSettings["hooks"] as? [String: Any])?["SessionStart"] != nil, "later terminal account-pool launches keep SessionStart identity capture")
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
            check(!args.contains("bypassPermissions") && args.contains("manual") && args.contains("host") && args.contains("stdio"), "default print turn routes approval to the native UI without bypass")
            check(f.starts.count == 2, "browser/settings preflight runs on each turn")
            let reopened = try ChatStore(project: f.project, fileURL: f.store.fileURL)
            check(reopened.conversations[0].sessionID == sid && reopened.conversations[0].messages.filter { $0.role == "user" }.count == 2, "persisted conversation survives reopen")
            f.runtime.markTransferredToTerminal(); f.runtime.send(text: "must not start")
            check(f.runtime.currentConversationTransferred && f.runs.count == 2, "terminal transfer prevents concurrent graphical sends")
            let transferred = try ChatStore(project: f.project, fileURL: f.store.fileURL)
            check(transferred.conversations[0].transferredToTerminal, "terminal transfer persists across restart")
            let transferredID = f.runtime.currentConversation!.id
            f.runtime.createConversation()
            try f.runtime.restoreFromTerminal(conversationID: transferredID)
            check(f.runtime.selectedID != transferredID && f.runtime.conversations.first { $0.id == transferredID }?.transferredToTerminal == false, "return restores the captured conversation without changing a newer selection")
            f.runtime.select(id: transferredID); f.send("resume after terminal failed")
            check(f.runs.last?["sid"] as? String == sid && f.runs.last?["account"] as? String == "first", "return resumes the verified original session and account")
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
            check(value("--permission-mode", in: args) == "auto" && value("--permission-prompts", in: args) == "host", "Auto keeps its classifier and exposes any human prompts to the host")
            check(!args.contains("bypassPermissions") && !args.contains("dontAsk"), "Auto never substitutes blanket permission bypass")
            let terminal = try GlobalPool.prepareChatTerminal(target: f.runtime.terminalFallback, baseEnvironment: f.environment); defer { GlobalPool.clean(terminal) }
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
            check(!f.runtime.needsTerminalInteraction && f.runtime.currentMessages.contains { $0.role == "notice" && $0.text.contains("权限规则拒绝") }, "policy denials are explained without forcing terminal takeover")
            check(!f.runtime.stateText.contains("已完成"), "blocked operations are not labeled completed")
        }
        do {
            let f = try Fixture("corrected-final"); defer { f.clean() }
            f.send("verify final correction")
            check(f.runtime.currentMessages.filter { $0.role == "assistant" }.map(\.text) == ["更正后的正文", "第二段完成"], "corrected final text replaces its streamed block without duplicating a message")
        }
        for mode in ["approval", "approval-duplicate", "approval-background"] {
            let f = try Fixture(mode); defer { f.clean() }
            f.runtime.send(text: "check the repository")
            spin { !f.runtime.pendingApprovals.isEmpty }
            check(f.runtime.hasRunning && f.runtime.pendingApprovals.count == 1 && f.replies.isEmpty, "\(mode) waits on writable stdin without auto-allow or terminal transfer")
            let approval = f.runtime.pendingApprovals[0]
            check(approval.kind == .tool && approval.toolName == "Bash" && approval.inputDescription.contains("git -C ./repo status") && approval.canApprove, "\(mode) presents the real tool and arguments")
            try f.runtime.approve(id: approval.id)
            spin { !f.runtime.hasRunning }
            let result = f.replies.first?["response"] as? [String: Any]
            check(f.replies.count == 1 && result?["behavior"] as? String == "allow" && result?["updatedPermissions"] == nil, "\(mode) sends exactly one scoped allow only after user action")
            check((result?["updatedInput"] as? [String: Any])?["command"] as? String == "git -C ./repo status --short", "\(mode) preserves exact approved arguments")
            check(!f.runtime.hasRunning && f.runtime.pendingApprovals.isEmpty && !f.runtime.needsTerminalInteraction, "\(mode) finishes and clears approval state")
            do { try f.runtime.approve(id: approval.id); check(false, "old approval rejected") } catch { check(f.replies.count == 1, "repeated click cannot send a second response") }
        }
        do {
            let f = try Fixture("approval"); defer { f.clean() }
            f.runtime.send(text: "remember this tool"); spin { !f.runtime.pendingApprovals.isEmpty }
            try f.runtime.approve(id: f.runtime.pendingApprovals[0].id, remember: true)
            spin { !f.runtime.hasRunning }
            check(f.runtime.rememberedTools == ["Bash"], "explicit remembered approval saves only the chosen tool")
            let reopened = try ChatStore(project: f.project, fileURL: f.store.fileURL)
            check(reopened.rememberedTools == ["Bash"], "tool choice survives app restart")
            f.send("same project next turn")
            check(!f.runtime.hasRunning && f.runtime.pendingApprovals.isEmpty && f.replies.count == 2, "remembered project tool is automatically approved on a later turn")
            f.runtime.send(text: "plan still requires approval", permissionMode: .plan); spin { !f.runtime.pendingApprovals.isEmpty }
            check(!f.runtime.pendingApprovals.isEmpty, "remembered tool cannot override plan mode")
            try f.runtime.deny(id: f.runtime.pendingApprovals[0].id); spin { !f.runtime.hasRunning }
            try f.runtime.clearRememberedPermissions()
            let cleared = try ChatStore(project: f.project, fileURL: f.store.fileURL)
            check(cleared.rememberedTools.isEmpty, "clearing remembered permissions persists")
            f.runtime.send(text: "ask again", permissionMode: .default); spin { !f.runtime.pendingApprovals.isEmpty }
            check(!f.runtime.pendingApprovals.isEmpty, "cleared permissions ask again")
            try f.runtime.deny(id: f.runtime.pendingApprovals[0].id); spin { !f.runtime.hasRunning }
            let other = try Fixture("approval"); defer { other.clean() }
            check(other.runtime.rememberedTools.isEmpty, "permissions never leak into another project")
        }
        do {
            let f = try Fixture("approval"); defer { f.clean() }
            f.runtime.send(text: "deny this operation"); spin { !f.runtime.pendingApprovals.isEmpty }
            let id = f.runtime.pendingApprovals[0].id
            try f.runtime.deny(id: id, message: "只检查文件，不运行命令。")
            spin { !f.runtime.hasRunning }
            let result = f.replies.first?["response"] as? [String: Any]
            check(result?["behavior"] as? String == "deny" && result?["message"] as? String == "只检查文件，不运行命令。", "denial returns the user's explanation to the same request")
            check(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("approved").path), "denied tool never executes")
        }
        do {
            let f = try Fixture("approval-question"); defer { f.clean() }
            f.runtime.send(text: "ask me"); spin { !f.runtime.pendingApprovals.isEmpty }
            let approval = f.runtime.pendingApprovals[0]
            check(approval.kind == .question && approval.questions.count == 2 && approval.questions[1].multiSelect, "questions retain labels and multi-select semantics")
            do { try f.runtime.approve(id: approval.id); check(false, "question cannot be approved without answers") } catch { check(f.replies.isEmpty, "generic approval cannot answer questions implicitly") }
            do { try f.runtime.answer(id: approval.id, answers: ["要查看哪个仓库？": "全部"]); check(false, "partial answers rejected") } catch { check(f.replies.isEmpty, "partial answer is not sent") }
            let answers = ["要查看哪个仓库？": "全部", "检查哪些内容？": "分支, 改动"]
            try f.runtime.answer(id: approval.id, answers: answers); spin { !f.runtime.hasRunning }
            let updated = (f.replies.first?["response"] as? [String: Any])?["updatedInput"] as? [String: Any]
            check(updated?["answers"] as? [String: String] == answers && (updated?["questions"] as? [Any])?.count == 2, "answers use exact question keys and preserve original questions")
        }
        for mode in ["approval-plan", "approval-plan-empty"] {
            let f = try Fixture(mode); defer { f.clean() }
            f.runtime.send(text: "plan the task", permissionMode: .plan); spin { !f.runtime.pendingApprovals.isEmpty }
            let approval = f.runtime.pendingApprovals[0]
            check(approval.kind == .plan, "ExitPlanMode is shown as explicit plan approval")
            if mode == "approval-plan" {
                check(approval.canApprove && approval.inputDescription.contains("先检查六个子仓库"), "plan body is available for review before approval")
                try f.runtime.approve(id: approval.id)
            } else {
                check(!approval.canApprove, "missing plan cannot be silently approved")
                do { try f.runtime.approve(id: approval.id); check(false, "empty plan rejected") } catch { check(f.replies.isEmpty, "empty plan produces no allow") }
                try f.runtime.deny(id: approval.id)
            }
            spin { !f.runtime.hasRunning }
            check(f.replies.count == 1, "plan receives one explicit decision")
        }
        do {
            let f = try Fixture("approval"); defer { f.clean() }
            f.runtime.send(text: "first request"); spin { !f.runtime.pendingApprovals.isEmpty }
            let oldID = f.runtime.pendingApprovals[0].id
            f.runtime.stop(); spin { !f.runtime.hasRunning }
            check(f.runtime.pendingApprovals.isEmpty && f.replies.isEmpty, "stop invalidates pending approvals without granting anything")
            f.runtime.send(text: "second request"); spin { !f.runtime.pendingApprovals.isEmpty }
            do { try f.runtime.approve(id: oldID); check(false, "previous generation approval rejected") } catch { check(f.replies.isEmpty, "same wire request ID in a new run does not make stale UI clickable") }
            try f.runtime.deny(id: f.runtime.pendingApprovals[0].id); spin { !f.runtime.hasRunning }
        }
        do {
            let f = try Fixture("approval-cancel"); defer { f.clean() }
            f.runtime.send(text: "cancel request"); spin { !f.runtime.pendingApprovals.isEmpty }
            let id = f.runtime.pendingApprovals[0].id; spin { !f.runtime.hasRunning }
            check(f.runtime.pendingApprovals.isEmpty && f.replies.isEmpty, "CLI cancellation removes the request without sending a stale response")
            do { try f.runtime.approve(id: id); check(false, "canceled approval rejected") } catch { check(true, "canceled request cannot be approved") }
        }
        do {
            let f = try Fixture("approval-identityless"); defer { f.clean() }
            f.runtime.send(text: "unverified request"); spin { !f.runtime.pendingApprovals.isEmpty }
            do { try f.runtime.approve(id: f.runtime.pendingApprovals[0].id); check(false, "unverified identity rejected") } catch { check(f.replies.isEmpty, "approval requires verified session identity") }
        }
        do {
            let f = try Fixture("approval-changed"); defer { f.clean() }; f.send("changed request")
            check(!f.runtime.hasRunning && f.replies.isEmpty && f.runtime.pendingApprovals.isEmpty, "a changed payload reusing a request ID fails closed")
        }
        do {
            let f = try Fixture("approval-mismatched"); defer { f.clean() }; f.send("wrong session request")
            check(!f.runtime.hasRunning && f.replies.isEmpty && f.runtime.pendingApprovals.isEmpty && !f.runtime.terminalFallback.canResume, "a request from another session is stopped before showing approval")
        }
        do {
            let f = try Fixture(); defer { f.clean() }
            let id = UUID().uuidString, sid = UUID().uuidString, ticket = f.root.appendingPathComponent("pending-ticket.json").path
            let record = ChatConversation(id: id, title: "Return", projectID: f.project.id.uuidString, directory: f.project.path,
                                          sessionID: sid, account: "first", ticket: ticket, transferredToTerminal: true)
            try f.store.save([record], selectedID: id)
            let runtime = try ChatRuntime(project: f.project, store: f.store, environment: f.environment)
            do { try runtime.restoreFromTerminal(conversationID: id, account: "second"); check(false, "partial return identity rejected") } catch { check(runtime.currentConversationTransferred, "partial identity cannot unlock the conversation") }
            try runtime.restoreFromTerminal(conversationID: id, account: "first", sessionID: sid, ticket: ticket)
            check(runtime.currentConversation?.ticket == ticket, "a terminal startup failure preserves an unconsumed handoff ticket")
            runtime.markTransferredToTerminal()
            let next = UUID().uuidString
            try runtime.recordTerminalState(conversationID: id, account: nil, sessionID: nil, ticket: nil, uncertain: true)
            check(!runtime.terminalFallback.canResume, "pending terminal handoff disables fallback resume")
            let uncertainStore = try ChatStore(project: f.project, fileURL: f.store.fileURL)
            let uncertainRuntime = try ChatRuntime(project: f.project, store: uncertainStore, environment: f.environment)
            check(uncertainRuntime.currentConversation?.terminalIdentityUncertain == true && !uncertainRuntime.terminalFallback.canResume, "terminal uncertainty persists across desktop restart")
            do { try uncertainRuntime.restoreFromTerminal(conversationID: id); check(false, "uncertain identity cannot restore") } catch { check(true, "uncertain terminal cannot guess its old account after restart") }
            do { try runtime.recordTerminalState(conversationID: id, account: "second", sessionID: nil, ticket: nil, uncertain: false); check(false, "partial terminal identity rejected") } catch { check(!runtime.terminalFallback.canResume, "partial verification cannot clear uncertainty") }
            try runtime.recordTerminalState(conversationID: id, account: "second", sessionID: next, ticket: nil, uncertain: false)
            let verifiedStore = try ChatStore(project: f.project, fileURL: f.store.fileURL)
            check(verifiedStore.conversations[0].sessionID == next && verifiedStore.conversations[0].account == "second" && verifiedStore.conversations[0].terminalIdentityUncertain == false, "verified terminal identity is durable before tab close")
            try runtime.restoreFromTerminal(conversationID: id, account: "second", sessionID: next, ticket: nil)
            check(runtime.currentConversation?.account == "second" && runtime.currentConversation?.sessionID == next && runtime.currentConversation?.ticket == nil && runtime.currentConversation?.terminalIdentityUncertain == nil, "verified terminal handoff replaces identity, clears consumed ticket and recovery marker")
        }
        do {
            let f = try Fixture("slow"); defer { f.clean() }
            let id = f.runtime.currentConversation!.id
            f.runtime.markTransferredToTerminal(); f.runtime.createConversation()
            f.runtime.send(text: "separate foreground task")
            spin { f.runtime.currentMessages.contains { $0.role == "assistant" } }
            let selected = f.runtime.selectedID, messages = f.runtime.currentMessages
            let next = UUID().uuidString
            try f.runtime.recordTerminalState(conversationID: id, account: nil, sessionID: nil, ticket: nil, uncertain: true)
            try f.runtime.recordTerminalState(conversationID: id, account: "second", sessionID: next, ticket: nil, uncertain: false)
            check(f.runtime.hasRunning && f.runtime.selectedID == selected && f.runtime.currentMessages == messages, "background terminal identity update preserves another actively streaming conversation")
            check(f.runtime.conversations.first { $0.id == id }?.sessionID == next, "background terminal identity updates while another chat runs")
        }
        do {
            let f = try Fixture("approval-limit"); defer { f.clean() }
            f.runtime.send(text: "approval then quota handoff"); spin { !f.runtime.pendingApprovals.isEmpty }
            let oldID = f.runtime.pendingApprovals[0].id
            try f.runtime.approve(id: oldID)
            spin { f.runtime.pendingApprovals.first.map { $0.id != oldID } == true }
            check(f.runs.count == 2 && f.runtime.pendingApprovals.count == 1, "quota handoff keeps native approval available in the resumed session")
            do { try f.runtime.approve(id: oldID); check(false, "pre-handoff approval rejected") } catch { check(f.replies.count == 1, "old approval cannot authorize the new account's reused wire request ID") }
            try f.runtime.approve(id: f.runtime.pendingApprovals[0].id); spin { !f.runtime.hasRunning }
            check(f.replies.count == 2 && f.runtime.currentConversation?.account == "second", "resumed account receives only its own explicit approval")
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
            let original = f.runtime.conversations
            f.runtime.beforeStart = { _ in throw AppError.message("browser lock rejected") }
            check(!f.runtime.send(text: "blocked"), "a failed preflight returns false so the composer retains its text")
            check(f.runs.isEmpty && !f.runtime.hasRunning, "browser guard rejection prevents process launch")
            check(f.runtime.conversations == original && f.runtime.stateText.contains("browser lock rejected"), "preflight failure restores all conversation metadata and exposes the error")
            let reopened = try ChatStore(project: f.project, fileURL: f.store.fileURL)
            check(sameSavedMetadata(reopened.conversations, original), "failed preflight never leaves a sent user message on disk")
            let secret = "ANTHROPIC_API_KEY=fixture-secret Bearer fixture.bearer sk-ant-fixture-token"
            var conversation = f.runtime.conversations[0]; conversation.messages = [ChatMessage(role: "tool", text: secret)]
            try f.store.save([conversation], selectedID: conversation.id)
            let saved = try String(contentsOf: f.store.fileURL, encoding: .utf8)
            check(!saved.contains("fixture-secret") && !saved.contains("fixture.bearer") && !saved.contains("sk-ant-fixture-token"), "known credentials are redacted in the app's saved copy")
            check(conversation.messages[0].text == secret, "redaction never rewrites original prompt or in-memory tool result")
        }
        do {
            let f = try Fixture(); defer { f.clean(); unsetenv("CCAM_DESKTOP_DATA_DIR") }
            setenv("CCAM_DESKTOP_DATA_DIR", f.root.appendingPathComponent("desktopdata").path, 1)
            let files = ChatAttachmentStore(project: f.project)
            let attachment = try files.stageImage(data: imageData(), existing: [])
            try f.runtime.setDraftAttachments([attachment])
            let original = f.runtime.conversations
            let runtime = try ChatRuntime(project: f.project, store: f.store,
                                          ccamExecutable: f.root.appendingPathComponent("missing-executable").path,
                                          environment: f.environment)
            check(!runtime.send(text: "message with an image"), "Process.run failure reports a rejected send")
            check(!runtime.hasRunning && runtime.conversations == original && runtime.currentAttachments == [attachment], "spawn failure restores the user text record, generated title and draft attachments")
            let reopened = try ChatStore(project: f.project, fileURL: f.store.fileURL)
            check(sameSavedMetadata(reopened.conversations, original) && f.runs.isEmpty, "spawn failure rolls back the pre-spawn metadata commit on disk")
        }
        do {
            let f = try Fixture(); defer { f.clean() }
            let original = f.runtime.conversations
            let folder = f.store.fileURL.deletingLastPathComponent(), backup = f.root.appendingPathComponent("saved-desktop")
            try FileManager.default.moveItem(at: folder, to: backup)
            try Data("blocked metadata directory".utf8).write(to: folder)
            check(!f.runtime.send(text: "must not run when save fails"), "metadata failure prevents accepting the send")
            check(!f.runtime.hasRunning && f.runs.isEmpty && f.runtime.conversations == original && f.runtime.stateText.contains("保存失败"), "metadata failure leaves draft and history intact and never spawns Claude")
            try FileManager.default.removeItem(at: folder); try FileManager.default.moveItem(at: backup, to: folder)
            let reopened = try ChatStore(project: f.project, fileURL: f.store.fileURL)
            check(sameSavedMetadata(reopened.conversations, original), "original metadata survives an unavailable save location")
        }
        do {
            let f = try Fixture(); defer { f.clean() }
            let original = f.runtime.conversations, state = f.runtime.stateText
            var called = false
            do {
                try f.runtime.transferToTerminal { target in
                    called = true
                    let saved = try ChatStore(project: f.project, fileURL: f.store.fileURL)
                    check(f.runtime.currentConversationTransferred && saved.conversations[0].transferredToTerminal && target.conversationID == f.runtime.selectedID,
                          "terminal ownership is durable before the launch callback can create a process")
                    throw AppError.message("terminal preflight rejected")
                }
                check(false, "terminal start failure propagated")
            } catch { check(called && error.localizedDescription == "terminal preflight rejected", "terminal launch failure reaches the caller") }
            check(f.runtime.conversations == original && !f.runtime.currentConversationTransferred && f.runtime.stateText == state,
                  "failed terminal preparation restores the original editable chat state")
            let restored = try ChatStore(project: f.project, fileURL: f.store.fileURL)
            check(sameSavedMetadata(restored.conversations, original), "terminal preparation failure rolls ownership back on disk")
            let folder = f.store.fileURL.deletingLastPathComponent(), backup = f.root.appendingPathComponent("saved-transfer-state")
            try FileManager.default.moveItem(at: folder, to: backup); try Data("blocked".utf8).write(to: folder)
            called = false
            do { try f.runtime.transferToTerminal { _ in called = true }; check(false, "unwritable transfer rejected") }
            catch { check(!called && !f.runtime.currentConversationTransferred && f.runtime.conversations == original,
                          "failed ownership save never invokes terminal start or locks the chat") }
            try FileManager.default.removeItem(at: folder); try FileManager.default.moveItem(at: backup, to: folder)
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
            let resumedBlocks = f.runs[1]["content"] as? [[String: Any]] ?? []
            check(f.runs[1]["prompt"] as? String == GlobalPool.continuationPrompt && resumedBlocks.count == 1 && resumedBlocks[0]["type"] as? String == "text", "handoff keeps interactive stdin while using transcript without resending attachments")
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
        do {
            let f = try Fixture(); defer { f.clean() }
            var completed = 0
            f.runtime.onTurnFinished = { completed += 1 }
            try f.runtime.setTranslationEnabled(false)
            try f.runtime.setAutomaticReplyTranslation(false)
            try f.runtime.updateOptions(model: "haiku", permissionMode: .plan, effort: "low")
            check(f.runtime.currentOptions.translateToEnglish == false && f.runtime.currentOptions.autoTranslateReplies == false,
                  "model changes preserve independent translation preferences")
            let english = "Please check this project."
            let chinese = "请检查这个项目。"
            check(f.runtime.send(text: english, originalText: chinese), "translated input can start a real-CCAM fake-model turn")
            spin { !f.runtime.hasRunning }
            check(f.runs.last?["prompt"] as? String == english && f.runtime.currentMessages.first?.originalText == chinese,
                  "Claude receives English while original Chinese remains separate in local history")
            check(f.runtime.currentConversation?.title == chinese && completed == 1,
                  "conversation keeps Chinese title and emits exactly one completed-turn event")
            let message = f.runtime.currentMessages.first { $0.role == "assistant" }!
            try f.runtime.saveTranslation(messageID: message.id, sourceText: message.text, text: "回复译文")
            let reopened = try ChatStore(project: f.project, fileURL: f.store.fileURL)
            let saved = reopened.conversations.flatMap(\.messages).first { $0.id == message.id }!
            check(saved.text == message.text && saved.translatedText == "回复译文" && completed == 1,
                  "cached reply translation does not change English source or trigger a quota refresh")
            do { try f.runtime.saveTranslation(messageID: message.id, sourceText: "stale source", text: "错误译文"); check(false, "stale source rejected") }
            catch { check(true, "stale translated reply cannot overwrite another source revision") }
            f.send("A second turn in English.")
            check(completed == 2 && f.runtime.currentMessages.first?.originalText == chinese,
                  "each later turn emits one refresh while retaining prior Chinese source")
            f.runtime.beforeStart = { _ in throw AppError.message("fixture preflight failure") }
            check(!f.runtime.send(text: "must not run") && completed == 2,
                  "a preflight failure does not trigger an online quota query")
        }
        do {
            let legacy = try JSONDecoder().decode(ChatOptions.self, from: Data(#"{"model":"sonnet","permissionMode":"plan","effort":"high"}"#.utf8))
            check(legacy.translateToEnglish == nil && legacy.autoTranslateReplies == nil && legacy.model == "sonnet",
                  "pre-translation conversation options remain backward compatible")
            let f = try Fixture(); defer { f.clean() }
            var conversation = f.runtime.currentConversation!
            conversation.messages = [ChatMessage(role: "user", text: "safe English", originalText: "Bearer fixture-original-token"),
                                     ChatMessage(role: "assistant", text: "safe reply", translatedText: "Bearer fixture-translated-token")]
            try f.store.save([conversation], selectedID: conversation.id)
            let saved = try String(contentsOf: f.store.fileURL)
            check(!saved.contains("fixture-original-token") && !saved.contains("fixture-translated-token"),
                  "additional original and translated copies receive the same credential redaction as message text")
        }
        do {
            let f = try Fixture("limit"); defer { f.clean() }
            var completed = 0; f.runtime.onTurnFinished = { completed += 1 }
            f.send("one turn across two accounts")
            check(f.runs.count == 2 && completed == 1, "automatic account failover emits only one final-turn quota refresh")
        }
        print("PASS: \(checks) chat checks (real CCAM, isolated fake Claude, no real credentials/API requests)")
    }
}
