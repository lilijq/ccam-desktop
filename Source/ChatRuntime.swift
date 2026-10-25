import Foundation
import Darwin

struct ChatApprovalQuestion {
    struct Option { let label: String; let description: String }
    let question: String
    let header: String
    let options: [Option]
    let multiSelect: Bool
}

/// A request from one running process, never a reusable permission rule.
struct ChatApproval {
    enum Kind { case tool, question, plan }
    let id: String
    let toolName: String
    let inputDescription: String
    let reason: String?
    let kind: Kind
    let questions: [ChatApprovalQuestion]
    let canApprove: Bool
    fileprivate let requestID: String
    fileprivate let generation: Int
    fileprivate let conversationID: String
    fileprivate let input: [String: Any]
}

/// Incremental NDJSON decoding. Non-JSON launcher notices never become model
/// events, permission approvals, or quota signals.
struct ChatStreamDecoder {
    private var buffer = Data()
    mutating func append(_ data: Data, finish: Bool = false) -> [[String: Any]] {
        buffer.append(data)
        var events: [[String: Any]] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            if let value = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { events.append(value) }
            buffer.removeSubrange(...newline)
        }
        if finish && !buffer.isEmpty {
            if let value = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any] { events.append(value) }
            buffer.removeAll()
        }
        // A malformed single line cannot grow memory without bound.
        if buffer.count > 8 * 1024 * 1024 { buffer.removeAll() }
        return events
    }
}

/// Main-thread model; only pipe draining and process waiting run on worker queues.
/// Every send is a separate exact-session print turn, not a replay of history.
final class ChatRuntime {
    let project: ProjectRecord
    private let store: ChatStore
    private let executable: String
    private let helper: String
    private let environment: [String: String]
    private let retryInterval: TimeInterval
    private let maximumWait: TimeInterval
    private(set) var conversations: [ChatConversation]
    private(set) var selectedID: String?
    private(set) var hasRunning = false
    private(set) var stateText = "可以开始新任务"
    private(set) var needsTerminalInteraction = false
    private(set) var pendingApprovals: [ChatApproval] = []
    var beforeStart: (([String]) throws -> Void)?
    var onChange: (() -> Void)?
    var onMessage: ((ChatMessage) -> Void)?
    var onState: ((String) -> Void)?
    private var process: Process?
    private var inputHandle: FileHandle?
    private let inputQueue = DispatchQueue(label: "ccam.chat.stdin")
    private var answeredApprovalIDs = Set<String>()
    private var initializationID: String?
    private var initializationTimer: Timer?
    private var queuedPrompt: Data?
    private var sessionState: String?
    private var activeAgentTasks = Set<String>()
    private var plan: PoolLaunch?
    private var poll: Timer?
    private var retry: Timer?
    private var saveTimer: Timer?
    private var generation = 0
    private var stoppingGeneration: Int?
    private var decoder = ChatStreamDecoder()
    private var streamMessageID: String?
    private var streamTextIndex = 0
    private var streamSessionID: String?
    private var assistantIDs: [String: String] = [:]
    private var finalizedAssistantKeys = Set<String>()
    private var toolIDs: [String: String] = [:]
    private var lastAssistantID: String?
    private var receivedResult = false
    private var resultFailed = false
    private var hadPermissionDenials = false
    private var identityMismatch = false
    private var identity: PoolChatIdentity?
    private var quota: PoolLimitEvent?
    private var runConversationID: String?
    private var runOptions = ChatOptions()
    private var runAttachments: [ChatAttachment] = []
    private var initialInput: Data?
    private var effectivePermissionMode: String?
    private var waitingSince: Date?
    private var attemptedQuotaTickets = Set<String>()
    private var recovery = false

    var currentMessages: [ChatMessage] { currentConversation?.messages ?? [] }
    var currentConversationTransferred: Bool { currentConversation?.transferredToTerminal ?? false }
    var activeConversations: [ChatConversation] { conversations.filter { $0.deletedAt == nil } }
    var deletedConversations: [ChatConversation] { conversations.filter { $0.deletedAt != nil }.sorted { $0.deletedAt! > $1.deletedAt! } }
    var currentConversation: ChatConversation? { activeConversations.first { $0.id == selectedID } }
    var currentOptions: ChatOptions { currentConversation?.options ?? ChatOptions() }
    var currentAttachments: [ChatAttachment] { currentConversation?.draftAttachments ?? [] }
    var terminalFallback: ChatTerminalTarget {
        ChatTerminalTarget(directory: project.path, sessionID: currentConversation?.sessionID,
                           account: currentConversation?.account, ticket: currentConversation?.ticket,
                           canResume: currentConversation?.continuityUnavailable != true && currentConversation?.terminalIdentityUncertain != true,
                           model: currentOptions.model, permissionMode: currentOptions.permissionMode.rawValue, effort: currentOptions.effort,
                           conversationID: currentConversation?.id)
    }

    init(project: ProjectRecord, store: ChatStore? = nil, ccamExecutable: String = CCAMClient.executable,
         helperExecutable: String = CommandLine.arguments[0], environment: [String: String] = CCAMClient.environment,
         retryInterval: TimeInterval = GlobalPool.retryInterval, maximumWait: TimeInterval = GlobalPool.maximumWait) throws {
        self.project = project; self.store = try store ?? ChatStore(project: project)
        self.executable = ccamExecutable; self.helper = helperExecutable; self.environment = environment
        self.retryInterval = retryInterval; self.maximumWait = maximumWait
        conversations = self.store.conversations; selectedID = self.store.selectedID
        if currentConversationTransferred { stateText = "终端中，可先写草稿" }
    }

    deinit {
        poll?.invalidate(); retry?.invalidate(); saveTimer?.invalidate(); initializationTimer?.invalidate()
        try? inputHandle?.close()
        if let process, process.isRunning { process.terminate() }
        if let plan { GlobalPool.clean(plan) }
    }

    func createConversation() {
        guard !hasRunning else { return }
        let conversation = ChatConversation(id: UUID().uuidString, title: "新对话", projectID: project.id.uuidString, directory: project.path)
        conversations.insert(conversation, at: 0); selectedID = conversation.id
        needsTerminalInteraction = false; stateText = "可以开始新任务"
        persist(); changed()
    }

    func select(id: String) {
        guard !hasRunning, activeConversations.contains(where: { $0.id == id }) else { return }
        selectedID = id; needsTerminalInteraction = false
        stateText = currentConversationTransferred ? "终端中，可先写草稿" : "继续这段对话"
        persist(); changed()
    }

    func updateOptions(model: String?, permissionMode: ChatPermissionMode, effort: String? = nil) throws {
        guard !hasRunning else { throw AppError.message("请等待本轮完成或先停止，再修改模型与模式。") }
        let validatedModel = try GlobalPool.validatedChatModel(model)
        let effort = try GlobalPool.validatedChatEffort(effort)
        var updated = conversations
        let id: String
        if let selectedID, let index = updated.firstIndex(where: { $0.id == selectedID && $0.deletedAt == nil }) {
            guard !updated[index].transferredToTerminal else { throw AppError.message("请在终端修改这段对话的设置。") }
            id = selectedID
            updated[index].options = ChatOptions(model: validatedModel, permissionMode: permissionMode, effort: effort)
            updated[index].updatedAt = Date()
        } else {
            let conversation = ChatConversation(id: UUID().uuidString, title: "新对话", projectID: project.id.uuidString, directory: project.path,
                                                options: ChatOptions(model: validatedModel, permissionMode: permissionMode, effort: effort))
            id = conversation.id; updated.insert(conversation, at: 0)
        }
        try saveMetadata(updated, selectedID: id)
    }

    func renameConversation(id: String, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120, !trimmed.contains(where: { $0.isNewline }) else { throw AppError.message("名称需为 1–120 个字符，不能换行。") }
        guard let index = conversations.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { throw AppError.message("这段对话已不存在。") }
        var updated = conversations; updated[index].title = trimmed; updated[index].updatedAt = Date()
        try saveMetadata(updated, selectedID: selectedID)
    }

    func setDraftAttachments(_ attachments: [ChatAttachment]) throws {
        guard !hasRunning, !currentConversationTransferred else { throw AppError.message("请等待本轮完成，再修改附件。") }
        try ChatAttachmentStore(project: project).validate(attachments)
        var updated = conversations
        let id: String
        if let selectedID, let index = updated.firstIndex(where: { $0.id == selectedID && $0.deletedAt == nil }) {
            id = selectedID; updated[index].draftAttachments = attachments
        } else {
            let conversation = ChatConversation(id: UUID().uuidString, title: "新对话", projectID: project.id.uuidString, directory: project.path, draftAttachments: attachments)
            id = conversation.id; updated.insert(conversation, at: 0)
        }
        try saveMetadata(updated, selectedID: id)
    }

    private func attachmentInput(text: String, attachments: [ChatAttachment]) throws -> Data {
        let store = ChatAttachmentStore(project: project)
        try store.validate(attachments)
        var blocks: [[String: Any]] = [["type": "text", "text": text]]
        for attachment in attachments {
            if attachment.isImage { blocks.append(try store.imageContentBlock(for: attachment)) }
            else { blocks.append(["type": "text", "text": try store.fileReference(for: attachment)]) }
        }
        let message: [String: Any] = ["type": "user", "parent_tool_use_id": NSNull(), "message": ["role": "user", "content": blocks]]
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        return data
    }

    /// Deletion only moves the desktop record to its recoverable deleted list.
    /// Native Claude transcripts and project files are never removed.
    func deleteConversation(id: String) throws {
        guard !(hasRunning && runConversationID == id) else { throw AppError.message("请先停止这段对话，再删除。") }
        guard let index = conversations.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { throw AppError.message("这段对话已不存在。") }
        var updated = conversations; updated[index].deletedAt = Date(); updated[index].updatedAt = Date()
        let selection = selectedID == id ? updated.first(where: { $0.deletedAt == nil })?.id : selectedID
        try saveMetadata(updated, selectedID: selection)
    }

    func restoreConversation(id: String) throws {
        guard let index = conversations.firstIndex(where: { $0.id == id && $0.deletedAt != nil }) else { throw AppError.message("未找到这段已删除的对话。") }
        var updated = conversations; updated[index].deletedAt = nil; updated[index].updatedAt = Date()
        try saveMetadata(updated, selectedID: hasRunning ? selectedID : id)
    }

    private func saveMetadata(_ updated: [ChatConversation], selectedID: String?) throws {
        // Commit first: a failed disk write must not hide a conversation in memory.
        try store.save(updated, selectedID: selectedID)
        if self.selectedID != store.selectedID && !hasRunning { needsTerminalInteraction = false }
        conversations = updated; self.selectedID = store.selectedID
        if !hasRunning { stateText = currentConversationTransferred ? "终端中，可先写草稿" : currentConversation == nil ? "可以开始新任务" : "继续这段对话" }
        changed()
    }

    func markTransferredToTerminal() {
        guard !hasRunning, let id = selectedID else { return }
        mutate(id) { $0.transferredToTerminal = true }
        stateText = "终端中，可先写草稿"; persist(); changed()
    }

    /// `start` may throw only before it creates a terminal process. Persisting
    /// ownership first prevents a live terminal and an editable chat from ever
    /// owning the same native session after a failed metadata write.
    func transferToTerminal(start: (ChatTerminalTarget) throws -> Void) throws {
        guard !hasRunning, let conversation = currentConversation, !conversation.transferredToTerminal,
              conversation.continuityUnavailable != true, conversation.terminalIdentityUncertain != true,
              let index = conversations.firstIndex(where: { $0.id == conversation.id }) else {
            throw AppError.message("当前对话不能转到终端，请先结束本轮并确认会话身份。")
        }
        let target = terminalFallback
        let previous = conversations, selection = selectedID, previousState = stateText
        let previousInteraction = needsTerminalInteraction
        var updated = conversations
        updated[index].transferredToTerminal = true; updated[index].updatedAt = Date()
        // No terminal may be created unless this atomic commit succeeds.
        try saveMetadata(updated, selectedID: selection)
        do { try start(target) }
        catch {
            let startError = error
            conversations = previous; selectedID = selection; needsTerminalInteraction = previousInteraction
            do {
                try store.save(previous, selectedID: selection)
                state(previousState)
            } catch {
                state("终端未启动，原聊天已恢复；本地记录恢复失败，请检查保存位置。")
                throw AppError.message(startError.localizedDescription + "；原聊天已恢复，但未能保存恢复记录。")
            }
            throw startError
        }
    }

    /// Called by the terminal coordinator before changing accounts, then again
    /// after its SessionStart hook supplies a verified identity. This survives
    /// closing the terminal tab or restarting the desktop app.
    func recordTerminalState(conversationID: String, account: String?, sessionID: String?, ticket: String?, uncertain: Bool) throws {
        guard !(hasRunning && runConversationID == conversationID),
              let index = conversations.firstIndex(where: { $0.id == conversationID && $0.deletedAt == nil }),
              conversations[index].transferredToTerminal else {
            throw AppError.message("这段对话已不在终端中，不能更新终端会话身份。")
        }
        var updated = conversations
        if !uncertain {
            guard let account, account.range(of: "^[a-z0-9][a-z0-9_-]{0,31}$", options: .regularExpression) != nil,
                  let sessionID, UUID(uuidString: sessionID) != nil else {
                throw AppError.message("终端会话身份不完整，未保存新的账号与会话。")
            }
            updated[index].account = account; updated[index].sessionID = sessionID; updated[index].ticket = ticket
        }
        updated[index].terminalIdentityUncertain = uncertain
        updated[index].updatedAt = Date()
        try saveMetadata(updated, selectedID: selectedID)
    }

    /// The workspace calls this only after the associated terminal has exited.
    /// Supplied identity must come from that terminal's verified SessionStart.
    func restoreFromTerminal(conversationID: String, account: String? = nil, sessionID: String? = nil, ticket: String? = nil) throws {
        guard !hasRunning else { throw AppError.message("请先停止当前聊天，再从终端返回。") }
        guard let index = conversations.firstIndex(where: { $0.id == conversationID && $0.deletedAt == nil }),
              conversations[index].transferredToTerminal, conversations[index].continuityUnavailable != true,
              conversations[index].terminalIdentityUncertain != true else {
            throw AppError.message("这段对话不能安全返回，请检查原会话身份。")
        }
        guard (account == nil) == (sessionID == nil) else { throw AppError.message("终端会话身份不完整。") }
        let restoredAccount = account ?? conversations[index].account
        let restoredSession = sessionID ?? conversations[index].sessionID
        guard let restoredAccount, restoredAccount.range(of: "^[a-z0-9][a-z0-9_-]{0,31}$", options: .regularExpression) != nil,
              let restoredSession, UUID(uuidString: restoredSession) != nil else { throw AppError.message("未能验证终端会话，不能猜测账号或最近对话。") }
        var updated = conversations
        updated[index].account = restoredAccount; updated[index].sessionID = restoredSession
        if account != nil { updated[index].ticket = ticket }
        updated[index].transferredToTerminal = false; updated[index].terminalIdentityUncertain = nil; updated[index].updatedAt = Date()
        try saveMetadata(updated, selectedID: selectedID)
        needsTerminalInteraction = false
        if selectedID == conversationID { state("已返回聊天，可以继续原任务") }
    }

    @discardableResult
    func send(text: String, permissionMode: ChatPermissionMode? = nil) -> Bool {
        let attachments = currentAttachments
        guard !hasRunning, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return false }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "请查看附件。" : text
        let previousConversations = conversations, previousSelection = selectedID
        let conversation = currentConversation ?? ChatConversation(id: UUID().uuidString, title: "新对话", projectID: project.id.uuidString, directory: project.path)
        guard !conversation.transferredToTerminal else { state("请先从终端返回聊天，再继续原任务"); return false }
        guard conversation.continuityUnavailable != true, conversation.terminalIdentityUncertain != true else { state("无法验证原会话身份，请新建对话；不会猜测最近会话"); return false }
        guard project.directoryExists else { state("项目文件夹不存在"); return false }
        guard conversation.sessionID == nil || conversation.account != nil else { state("原会话的账号身份未确认，不能安全继续"); return false }
        var options = currentOptions
        if let permissionMode { options.permissionMode = permissionMode }
        do {
            _ = try ExecutionProxy.resolve(environment: environment)
            options.model = try GlobalPool.validatedChatModel(options.model)
            options.effort = try GlobalPool.validatedChatEffort(options.effort)
            initialInput = try attachmentInput(text: text, attachments: attachments)
        }
        catch { state(error.localizedDescription); return false }
        var updated = conversations
        if !updated.contains(where: { $0.id == conversation.id }) { updated.insert(conversation, at: 0) }
        let index = updated.firstIndex { $0.id == conversation.id }!
        updated[index].options = options
        if updated[index].messages.isEmpty && updated[index].title == "新对话" { updated[index].title = String(text.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(48) ?? "新对话".prefix(48)) }
        updated[index].messages.append(ChatMessage(role: "user", text: text, attachments: attachments.isEmpty ? nil : attachments))
        updated[index].draftAttachments = nil; updated[index].updatedAt = Date()
        conversations = updated; selectedID = conversation.id
        runConversationID = conversation.id; runOptions = options; runAttachments = attachments; needsTerminalInteraction = false
        attemptedQuotaTickets.removeAll(); waitingSince = nil; generation += 1; hasRunning = true
        changed()
        var metadataCommitted = false
        let started = launch(prompt: text, ticket: conversation.ticket, automatic: false, generation: generation) {
            do { try self.store.save(updated, selectedID: conversation.id); metadataCommitted = true }
            catch { throw AppError.message("聊天记录保存失败，任务未启动；输入与附件已保留：" + error.localizedDescription) }
        }
        if started { return true }
        // No child was started: undo the optimistic send, including attachment
        // ownership and generated title. A real started turn is never rolled back.
        let failure = stateText
        conversations = previousConversations; selectedID = previousSelection
        runConversationID = nil; initialInput = nil; runAttachments = []; hasRunning = false
        do {
            if metadataCommitted { try store.save(previousConversations, selectedID: previousSelection) }
            state(failure)
        }
        catch { state(failure + "；草稿记录恢复失败，输入与附件仍保留，请检查保存位置。") }
        changed()
        return false
    }

    func stop() {
        guard hasRunning, stoppingGeneration == nil else { return }
        captureIdentity()
        let previous = generation
        generation += 1; retry?.invalidate(); retry = nil; poll?.invalidate(); poll = nil
        clearControlState()
        waitingSince = nil
        if let process {
            stoppingGeneration = previous
            if process.isRunning { terminate(process) }
            state("正在停止，等待当前进程退出"); persist(); return
        }
        hasRunning = false
        if let plan { GlobalPool.clean(plan); self.plan = nil }
        state("已停止，已保存这段对话"); persist()
    }

    func approve(id: String) throws {
        let approval = try activeApproval(id)
        guard approval.kind != .question else { throw AppError.message("请先回答问题，再继续。") }
        guard approval.canApprove else { throw AppError.message("请求内容不完整，请拒绝并让 Claude 补充后重试。") }
        try respond(to: approval, result: ["behavior": "allow", "updatedInput": approval.input])
    }

    func deny(id: String, message: String = "用户拒绝了此操作。") throws {
        let approval = try activeApproval(id)
        let explanation = message.trimmingCharacters(in: .whitespacesAndNewlines)
        try respond(to: approval, result: ["behavior": "deny", "message": explanation.isEmpty ? "用户拒绝了此操作。" : String(explanation.prefix(4_000))])
    }

    func answer(id: String, answers: [String: String]) throws {
        let approval = try activeApproval(id)
        guard approval.kind == .question, approval.canApprove,
              Set(answers.keys) == Set(approval.questions.map(\.question)),
              answers.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 4_000 }) else {
            throw AppError.message("请回答每个问题后再提交。")
        }
        var updatedInput = approval.input; updatedInput["answers"] = answers
        try respond(to: approval, result: ["behavior": "allow", "updatedInput": updatedInput])
    }

    private func activeApproval(_ id: String) throws -> ChatApproval {
        guard let approval = pendingApprovals.first(where: { $0.id == id }), hasRunning, stoppingGeneration == nil,
              approval.generation == generation, approval.conversationID == runConversationID,
              process?.isRunning == true, inputHandle != nil, !answeredApprovalIDs.contains(approval.requestID) else {
            throw AppError.message("这个确认已失效，请使用当前对话中的请求。")
        }
        captureIdentity()
        guard identity != nil, !identityMismatch else { throw AppError.message("会话身份尚未验证，暂不能发送确认。") }
        return approval
    }

    private func respond(to approval: ChatApproval, result: [String: Any]) throws {
        // No updatedPermissions: a click authorizes only this pending call.
        let frame: [String: Any] = ["type": "control_response", "response": ["subtype": "success", "request_id": approval.requestID, "response": result]]
        try writeFrame(frame, generation: approval.generation)
        answeredApprovalIDs.insert(approval.requestID)
        pendingApprovals.removeAll { $0.id == approval.id }
        state(pendingApprovals.isEmpty ? "正在处理" : "等待你的确认")
    }

    private func receiveApproval(_ event: [String: Any]) {
        guard let requestID = event["request_id"] as? String, !requestID.isEmpty, requestID.count <= 512,
              let request = event["request"] as? [String: Any] else { failControl("收到无法识别的确认请求，已停止本轮。"); return }
        guard !answeredApprovalIDs.contains(requestID) else { return }
        guard request["subtype"] as? String == "can_use_tool", let toolName = request["tool_name"] as? String,
              !toolName.isEmpty, toolName.count <= 256, let input = request["input"] as? [String: Any],
              let conversationID = runConversationID,
              let encoded = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), encoded.count <= 1_048_576 else {
            try? writeFrame(["type": "control_response", "response": ["subtype": "error", "request_id": requestID, "error": "CCAM cannot handle this control request."]], generation: generation)
            answeredApprovalIDs.insert(requestID)
            append(role: "notice", text: "收到不支持的交互请求，已返回失败；没有批准执行。")
            return
        }
        if let existing = pendingApprovals.first(where: { $0.requestID == requestID }) {
            if existing.toolName != toolName || !NSDictionary(dictionary: existing.input).isEqual(to: input) {
                failControl("确认内容发生变化，已停止本轮，请重新发起。")
            }
            return
        }
        let kind: ChatApproval.Kind = toolName == "AskUserQuestion" ? .question : toolName == "ExitPlanMode" ? .plan : .tool
        let rawQuestions = input["questions"] as? [[String: Any]] ?? []
        let questions = rawQuestions.compactMap { row -> ChatApprovalQuestion? in
            guard let text = row["question"] as? String, !text.isEmpty, text.count <= 8_000,
                  let options = row["options"] as? [[String: Any]], options.count <= 8 else { return nil }
            let choices = options.compactMap { option -> ChatApprovalQuestion.Option? in
                guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                return .init(label: label, description: option["description"] as? String ?? "")
            }
            guard choices.count == options.count else { return nil }
            return .init(question: text, header: row["header"] as? String ?? "问题", options: choices, multiSelect: row["multiSelect"] as? Bool == true)
        }
        let planText = (input["plan"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let complete = kind == .question ? !questions.isEmpty && questions.count <= 4 && questions.count == rawQuestions.count && Set(questions.map(\.question)).count == questions.count
            : kind == .plan ? !planText.isEmpty : true
        var reason = request["decision_reason"] as? String
        if let path = request["blocked_path"] as? String, !path.isEmpty { reason = (reason.map { $0 + "\n" } ?? "") + path }
        if !complete { reason = kind == .plan ? "未收到可审阅的计划内容，请拒绝并要求补充计划。" : "问题内容不完整，请拒绝并要求重新提问。" }
        pendingApprovals.append(ChatApproval(id: UUID().uuidString, toolName: toolName,
                                            inputDescription: kind == .plan && complete ? planText : String(decoding: encoded, as: UTF8.self),
                                            reason: reason, kind: kind, questions: questions, canApprove: complete,
                                            requestID: requestID, generation: generation, conversationID: conversationID, input: input))
        state(kind == .question ? "等待你的回答" : "等待你的确认")
    }

    private func writeFrame(_ frame: [String: Any], generation expected: Int) throws {
        var bytes = try JSONSerialization.data(withJSONObject: frame); bytes.append(10)
        try writeInput(bytes, generation: expected)
    }

    private func writeInput(_ data: Data, generation expected: Int) throws {
        guard generation == expected, hasRunning, let handle = inputHandle else { throw AppError.message("对话输入通道已关闭。") }
        inputQueue.async { [weak self] in
            do { try handle.write(contentsOf: data) }
            catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == expected, self.hasRunning else { return }
                    self.failControl("未能把输入送入当前会话，已停止本轮；原对话已保留。")
                }
            }
        }
    }

    private func closeInput() {
        guard let handle = inputHandle else { return }
        inputHandle = nil
        inputQueue.async { try? handle.close() }
    }

    private func clearControlState() {
        initializationTimer?.invalidate(); initializationTimer = nil; initializationID = nil; queuedPrompt = nil
        pendingApprovals.removeAll(); answeredApprovalIDs.removeAll(); activeAgentTasks.removeAll(); sessionState = nil
        closeInput()
    }

    private func failControl(_ message: String) {
        resultFailed = true; append(role: "error", text: message); clearControlState()
        if let process, process.isRunning { terminate(process) }
        state("本轮未完成")
    }

    private func closeInputIfFinished() {
        guard receivedResult, pendingApprovals.isEmpty, activeAgentTasks.isEmpty,
              sessionState == nil || sessionState == "idle" else { return }
        closeInput()
    }

    @discardableResult
    private func launch(prompt: String, ticket: String?, automatic: Bool, generation expected: Int, beforeSpawn: (() throws -> Void)? = nil) -> Bool {
        guard generation == expected, hasRunning, let id = runConversationID, let conversation = conversations.first(where: { $0.id == id }) else { return false }
        do {
            let base = try GlobalPool.prepareChat(directory: project.path, account: conversation.account, sessionID: conversation.sessionID,
                                                       newSessionID: conversation.sessionID == nil ? UUID().uuidString : nil, ticket: ticket,
                                                       permissionMode: runOptions.permissionMode.rawValue, model: runOptions.model, effort: runOptions.effort, helperExecutable: helper, ccamExecutable: executable, baseEnvironment: environment)
            var extra: [String] = []
            let store = ChatAttachmentStore(project: project)
            // File copies remain readable in resumed turns and after account handoff.
            // Each --add-dir scope contains only that one selected attachment.
            var directories = Set<String>()
            var unavailable: [String] = []
            var seen = Set<String>()
            do {
                for attachment in conversation.messages.flatMap({ $0.attachments ?? [] }) where !attachment.isImage {
                    guard seen.insert(attachment.id).inserted else { continue }
                    do {
                        for directory in try store.readableDirectories(for: [attachment]) { directories.insert(directory) }
                    } catch {
                        if !automatic && runAttachments.contains(where: { $0.id == attachment.id }) { throw error }
                        unavailable.append(attachment.name)
                    }
                }
            } catch { GlobalPool.clean(base); throw error }
            if !unavailable.isEmpty {
                append(role: "notice", text: "历史附件已变更或丢失：" + unavailable.prefix(3).joined(separator: "、") + "。重新添加后可继续引用，对话仍可继续。")
            }
            if !directories.isEmpty { extra += ["--add-dir"] + directories.sorted() }
            let prepared = PoolLaunch(args: base.args + extra, environment: base.environment, eventDirectory: base.eventDirectory,
                                      token: base.token, directory: base.directory, createdAt: base.createdAt, ticket: base.ticket,
                                      automaticallyContinuesTask: base.automaticallyContinuesTask, helperExecutable: base.helperExecutable)
            let inputData: Data
            if !automatic, let initialInput { inputData = initialInput }
            else { inputData = try attachmentInput(text: prompt, attachments: []) }
            do { try beforeStart?(prepared.args) } catch { GlobalPool.clean(prepared); throw error }
            guard generation == expected, hasRunning else { GlobalPool.clean(prepared); return false }
            clearControlState()
            plan = prepared; identity = nil; quota = nil; recovery = automatic
            effectivePermissionMode = nil
            decoder = ChatStreamDecoder(); streamMessageID = nil; streamSessionID = nil; streamTextIndex = 0; assistantIDs.removeAll(); finalizedAssistantKeys.removeAll(); toolIDs.removeAll(); lastAssistantID = nil
            receivedResult = false; resultFailed = false; hadPermissionDenials = false; identityMismatch = false
            let child = Process(); child.executableURL = URL(fileURLWithPath: executable); child.arguments = prepared.args
            child.currentDirectoryURL = URL(fileURLWithPath: project.path); child.environment = prepared.environment
            let input = Pipe(), output = Pipe(), errors = Pipe()
            // A CLI rejecting a mode can close stdin before a large image finishes.
            // Treat that as an I/O error instead of terminating the desktop app.
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            child.standardInput = input; child.standardOutput = output; child.standardError = errors
            // Commit only after all preflight work succeeds, but before a real
            // process can act on this prompt. Persistence failure cannot start it.
            try beforeSpawn?()
            try child.run(); process = child; inputHandle = input.fileHandleForWriting
            state(automatic ? "已切换账号，正在接续未完成任务" : "正在连接会话")
            poll = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.readHooks(expected) }
            let initialize = "ccam-init-" + UUID().uuidString
            initializationID = initialize; queuedPrompt = inputData
            initializationTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
                guard let self, self.generation == expected, self.initializationID == initialize else { return }
                self.failControl("会话初始化超时，已停止本轮，请检查代理与 Claude Code 安装。")
            }
            let drained = DispatchGroup(); drained.enter()
            DispatchQueue.global(qos: .utility).async {
                while let bytes = try? errors.fileHandleForReading.read(upToCount: 16_384), !bytes.isEmpty { /* Drain launcher diagnostics; never expose environment values. */ }
                try? errors.fileHandleForReading.close(); drained.leave()
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // read(upToCount:) can wait to fill its buffer on Darwin pipes.
                // availableData returns each available chunk, including a small
                // permission request whose producer is waiting for our answer.
                while true {
                    let bytes = output.fileHandleForReading.availableData
                    if bytes.isEmpty { break }
                    DispatchQueue.main.async { [weak self] in self?.consume(bytes, expected) }
                }
                try? output.fileHandleForReading.close(); child.waitUntilExit(); drained.wait()
                let code = child.terminationStatus
                DispatchQueue.main.async { [weak self] in self?.finished(code, expected) }
            }
            do {
                try writeFrame(["type": "control_request", "request_id": initialize,
                                "request": ["subtype": "initialize", "hooks": NSNull()]], generation: expected)
            } catch { failControl("会话已启动，但输入通道无法初始化；已停止本轮，原消息已保留。") }
            return true
        } catch {
            clearControlState()
            if let plan { GlobalPool.clean(plan); self.plan = nil }
            hasRunning = false; state("未能开始：" + error.localizedDescription)
            if automatic { append(role: "error", text: error.localizedDescription); persist() }
            return false
        }
    }

    private func readHooks(_ expected: Int) {
        guard generation == expected, let plan, let process else { return }
        captureIdentity()
        guard !identityMismatch else { return }
        if let event = GlobalPool.readEvent(plan), event.claudePID == process.processIdentifier,
           identity == nil || (identity?.account == event.account && identity?.sessionID == event.sessionID) {
            quota = event
            if let id = runConversationID { mutate(id) { $0.sessionID = event.sessionID; $0.account = event.account; $0.ticket = event.ticket } }
        }
    }

    /// Also used after cancellation, when stream callbacks no longer belong to
    /// the active generation. Capturing identity never schedules a handoff.
    private func captureIdentity() {
        guard let plan, let process else { return }
        if let captured = GlobalPool.readChatIdentity(plan, rootPID: process.processIdentifier) {
            if let streamSessionID, streamSessionID != captured.sessionID { resultFailed = true; identityMismatch = true; return }
            let firstCapture = identity == nil
            identity = captured
            if let id = runConversationID {
                mutate(id) { $0.sessionID = captured.sessionID; $0.account = captured.account; if firstCapture { $0.ticket = nil } }
            }
        }
    }

    private func consume(_ data: Data, _ expected: Int) {
        guard generation == expected, hasRunning else { return }
        readHooks(expected)
        for event in decoder.append(data) { handle(event) }
        scheduleSave(); changed()
    }

    private func handle(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        if let session = event["session_id"] as? String, let identity, session != identity.sessionID {
            identityMismatch = true
            failControl("会话身份不匹配，已停止本轮；不会把确认发送到其他会话。")
            return // A stream from another session is never joined.
        }
        switch type {
        case "system":
            if event["subtype"] as? String == "session_state_changed" {
                sessionState = event["state"] as? String
                closeInputIfFinished()
            }
            if event["subtype"] as? String == "task_started", let task = event["task_id"] as? String,
               ["local_agent", "local_workflow"].contains(event["task_type"] as? String ?? "") { activeAgentTasks.insert(task) }
            if ["task_notification", "task_updated"].contains(event["subtype"] as? String ?? ""), let task = event["task_id"] as? String {
                let status = event["status"] as? String ?? (event["patch"] as? [String: Any])?["status"] as? String ?? ""
                if event["subtype"] as? String == "task_notification" || ["completed", "failed", "stopped"].contains(status) { activeAgentTasks.remove(task) }
            }
            if event["subtype"] as? String == "init", let sid = event["session_id"] as? String, UUID(uuidString: sid) != nil { streamSessionID = sid }
            if ["init", "status"].contains(event["subtype"] as? String ?? ""),
               let effective = event["permissionMode"] as? String, effective != effectivePermissionMode {
                let previous = effectivePermissionMode
                effectivePermissionMode = effective
                if runOptions.permissionMode == .auto, effective != "auto" {
                    let title = ["default": "默认模式", "manual": "默认模式", "plan": "计划模式", "acceptEdits": "允许编辑"][effective] ?? "其他权限模式"
                    append(role: "notice", text: previous == nil
                           ? "当前模型或服务未启用 Auto，实际使用\(title)。需要确认的操作仍会暂停。"
                           : "当前已切换到\(title)。")
                }
            }
        case "stream_event":
            receivedResult = false
            guard let inner = event["event"] as? [String: Any] else { return }
            let kind = inner["type"] as? String
            if kind == "message_start", let message = inner["message"] as? [String: Any] { streamMessageID = message["id"] as? String }
            if kind == "content_block_delta", let delta = inner["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                streamTextIndex = inner["index"] as? Int ?? streamTextIndex
                assistant(text, key: (streamMessageID ?? "stream") + ":block:\(streamTextIndex)", replace: false)
            }
            if kind == "content_block_start", let block = inner["content_block"] as? [String: Any], block["type"] as? String == "tool_use" { tool(block) }
        case "assistant":
            receivedResult = false
            guard let message = event["message"] as? [String: Any] else { return }
            let content = message["content"] as? [[String: Any]] ?? []
            for text in content.filter({ $0["type"] as? String == "text" }).compactMap({ $0["text"] as? String }) where !text.isEmpty {
                let messageID = message["id"] as? String ?? streamMessageID ?? UUID().uuidString
                let existing = assistantIDs.first { key, id in
                    !finalizedAssistantKeys.contains(key) && key.hasPrefix(messageID + ":") && currentMessages.contains { $0.id == id && !$0.text.isEmpty && text.hasPrefix($0.text) }
                }?.key
                let key = existing ?? messageID + ":final:" + UUID().uuidString
                assistant(text, key: key, replace: true); finalizedAssistantKeys.insert(key)
            }
            for block in content where block["type"] as? String == "tool_use" { tool(block) }
        case "user":
            let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_result" {
                guard let toolKey = block["tool_use_id"] as? String, let messageID = toolIDs[toolKey] else { continue }
                let text = block["content"] as? String ?? (block["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                updateMessage(messageID) { $0.text = String(text.prefix(16_000)) }
            }
        case "result":
            receivedResult = true; resultFailed = resultFailed || event["is_error"] as? Bool == true
            if let denials = event["permission_denials"] as? [Any], !denials.isEmpty {
                hadPermissionDenials = true
                append(role: "notice", text: "部分操作被当前权限规则拒绝，可说明下一步要求后继续；需要确认的请求会在聊天中显示。")
            }
            if lastAssistantID == nil, let text = event["result"] as? String, !text.isEmpty { assistant(text, key: "result", replace: true) }
            closeInputIfFinished()
        case "control_response":
            guard let response = event["response"] as? [String: Any], let initialize = initializationID,
                  response["request_id"] as? String == initialize else { return }
            initializationTimer?.invalidate(); initializationTimer = nil; initializationID = nil
            guard response["subtype"] as? String == "success", let prompt = queuedPrompt else {
                failControl("Claude Code 无法建立交互通道，已停止本轮。"); return
            }
            queuedPrompt = nil
            do { try writeInput(prompt, generation: generation); state("正在处理") }
            catch { failControl("会话输入通道已关闭，已停止本轮。") }
        case "control_request":
            receiveApproval(event)
        case "control_cancel_request":
            if let requestID = event["request_id"] as? String {
                answeredApprovalIDs.insert(requestID)
                pendingApprovals.removeAll { $0.requestID == requestID }
                state(pendingApprovals.isEmpty ? "正在处理" : "等待你的确认")
                closeInputIfFinished()
            }
        default: break
        }
    }

    private func assistant(_ text: String, key: String, replace: Bool) {
        if let id = assistantIDs[key] { updateMessage(id) { $0.text = replace ? text : $0.text + text }; lastAssistantID = id }
        else {
            let message = ChatMessage(role: "assistant", text: text); assistantIDs[key] = message.id; lastAssistantID = message.id
            append(message)
        }
    }
    private func tool(_ block: [String: Any]) {
        guard let key = block["id"] as? String, toolIDs[key] == nil, let name = block["name"] as? String else { return }
        let message = ChatMessage(role: "tool", text: "正在使用 \(name)", toolName: name); toolIDs[key] = message.id; append(message)
    }
    private func finished(_ code: Int32, _ expected: Int) {
        defer { if !hasRunning { initialInput = nil; runAttachments = [] } }
        if stoppingGeneration == expected {
            clearControlState()
            captureIdentity()
            if (identity == nil || identityMismatch), let id = runConversationID {
                mutate(id) { $0.continuityUnavailable = true }
            }
            stoppingGeneration = nil; process = nil; hasRunning = false
            if let plan { GlobalPool.clean(plan); self.plan = nil }
            state(identity == nil || identityMismatch ? "已停止，但未能验证会话身份，请新建对话" : "已停止，已保存这段对话"); persist(); return
        }
        guard generation == expected, hasRunning else { return }
        for event in decoder.append(Data(), finish: true) { handle(event) }
        readHooks(expected); poll?.invalidate(); poll = nil
        clearControlState()
        let oldPlan = plan; plan = nil; process = nil
        if let oldPlan { GlobalPool.clean(oldPlan) }
        if let event = quota, !identityMismatch {
            let signature = event.ticket + ":" + String((event.limitAt ?? event.at).timeIntervalSince1970)
            guard attemptedQuotaTickets.insert(signature).inserted else { hasRunning = false; state("重复的额度事件已停止，请在终端检查"); persist(); return }
            waitingSince = waitingSince ?? Date()
            append(role: "notice", text: "账号 \(event.account) 额度已用完，正在从全局账号池切换并接续任务。")
            persist()
            launch(prompt: GlobalPool.continuationPrompt, ticket: event.ticket, automatic: true, generation: expected)
            return
        }
        if code == 75, let ticket = oldPlan?.ticket, FileManager.default.fileExists(atPath: ticket) {
            waitingSince = waitingSince ?? Date()
            if Date().timeIntervalSince(waitingSince!) < maximumWait {
                state("暂无其他可用账号，等待额度恢复；可以停止")
                retry = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: false) { [weak self] _ in
                    self?.launch(prompt: GlobalPool.continuationPrompt, ticket: ticket, automatic: true, generation: expected)
                }
                persist(); return
            }
            hasRunning = false; state("等待额度已超时，原对话已保存"); persist(); return
        }
        hasRunning = false; waitingSince = nil
        if needsTerminalInteraction { state("需要权限确认，可在终端继续") }
        else if code == 0 && receivedResult && !resultFailed { state(hadPermissionDenials ? "本轮结束，部分操作未获授权" : "已完成，可以继续提问") }
        else {
            append(role: "error", text: code == 75 ? "全局账号池暂无已登录且额度可用的账号。" : "本轮未完成，原对话已保留。网络、登录或其他错误不会自动换号。")
            state("本轮未完成")
        }
        if identityMismatch || (identity == nil && (receivedResult || streamSessionID != nil || lastAssistantID != nil)) {
            if let id = runConversationID, let streamSessionID { mutate(id) { $0.sessionID = streamSessionID } }
            if let id = runConversationID { mutate(id) { $0.continuityUnavailable = true } }
            append(role: "notice", text: "未收到可验证的会话身份记录，下一轮不会猜测账号或最近会话。")
        }
        persist(); changed()
    }

    private func terminate(_ child: Process) {
        let pid = child.processIdentifier
        if getpgid(pid) == pid { kill(-pid, SIGTERM) } else { child.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if child.isRunning { if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) } }
        }
    }
    private func mutate(_ id: String, _ action: (inout ChatConversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        action(&conversations[index]); conversations[index].updatedAt = Date()
    }
    private func append(role: String, text: String) { append(ChatMessage(role: role, text: text)) }
    private func append(_ message: ChatMessage) {
        guard let id = runConversationID ?? selectedID else { return }
        mutate(id) { $0.messages.append(message) }; onMessage?(message)
    }
    private func updateMessage(_ id: String, _ action: (inout ChatMessage) -> Void) {
        guard let conversationID = runConversationID else { return }
        mutate(conversationID) { conversation in
            if let index = conversation.messages.firstIndex(where: { $0.id == id }) { action(&conversation.messages[index]) }
        }
    }
    private func scheduleSave() {
        guard saveTimer == nil else { return }
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in self?.saveTimer = nil; self?.persist() }
    }
    private func persist() {
        do { try store.save(conversations, selectedID: selectedID) }
        catch { stateText = "聊天记录保存失败：" + error.localizedDescription; onState?(stateText) }
    }
    private func state(_ text: String) { stateText = text; onState?(text); changed() }
    private func changed() { onChange?() }
}
