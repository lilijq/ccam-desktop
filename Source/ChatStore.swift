import Foundation

enum ChatPermissionMode: String, CaseIterable, Codable {
    case `default`, plan, acceptEdits, auto
    var title: String {
        switch self { case .default: return "按需确认"; case .plan: return "计划模式"; case .acceptEdits: return "允许编辑"; case .auto: return "Auto 模式" }
    }
}

struct ChatOptions: Codable, Equatable {
    var model: String? = nil
    var permissionMode: ChatPermissionMode = .default
    var effort: String? = nil
    var translateToEnglish: Bool? = nil
    var autoTranslateReplies: Bool? = nil
}

struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID().uuidString
    var role: String
    var text: String
    var toolName: String? = nil
    var attachments: [ChatAttachment]? = nil
    var originalText: String? = nil
    var translatedText: String? = nil
}

struct ChatConversation: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    let projectID: String
    let directory: String
    var sessionID: String?
    var account: String?
    var messages: [ChatMessage] = []
    var ticket: String?
    var transferredToTerminal = false
    var terminalIdentityUncertain: Bool? = nil
    var continuityUnavailable: Bool? = nil
    var options: ChatOptions? = nil
    var deletedAt: Date? = nil
    var draftAttachments: [ChatAttachment]? = nil
    var updatedAt = Date()
}

/// Each project has its own atomic document, so simultaneous projects never
/// replace each other's conversation metadata. No Claude credentials are copied.
final class ChatStore {
    static let didChange = Notification.Name("CCAMChatStoreDidChange")
    // All runtimes in this app serialize read/merge/atomic-write transactions.
    private static let transactionLock = NSRecursiveLock()
    private struct Document: Codable {
        let version: Int
        let projectID: String
        let directory: String
        let conversations: [ChatConversation]
        let selectedID: String?
    }
    let fileURL: URL
    let project: ProjectRecord
    private(set) var conversations: [ChatConversation] = []
    private(set) var selectedID: String?
    private(set) var rememberedTools: Set<String> = []

    init(project: ProjectRecord, fileURL: URL? = nil) throws {
        self.project = project
        self.fileURL = fileURL ?? ProjectStore.defaultURL.deletingLastPathComponent().appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent(project.id.uuidString + ".json")
        Self.transactionLock.lock(); defer { Self.transactionLock.unlock() }
        loadRememberedTools()
        let document = try readDocument()
        conversations = document.conversations; selectedID = document.selectedID
    }

    private func readDocument() throws -> Document {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            guard conversations.isEmpty else { throw AppError.message("聊天记录暂时不可用，已保留内存中的对话。") }
            return Document(version: 1, projectID: project.id.uuidString, directory: project.path, conversations: [], selectedID: nil)
        }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= 64 * 1024 * 1024 else { throw AppError.message("这个项目的聊天记录过大，无法安全打开。") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(Document.self, from: data)
        guard document.version == 1, document.projectID == project.id.uuidString,
              GlobalPool.sameDirectory(document.directory, project.path),
              Set(document.conversations.map(\.id)).count == document.conversations.count,
              document.conversations.allSatisfy({ $0.projectID == project.id.uuidString && GlobalPool.sameDirectory($0.directory, project.path) && Set($0.messages.map(\.id)).count == $0.messages.count }) else {
            throw AppError.message("聊天记录与当前项目不匹配，未载入其他项目的对话。")
        }
        let active = document.conversations.filter { $0.deletedAt == nil }
        let selection = active.contains { $0.id == document.selectedID } ? document.selectedID : active.first?.id
        return Document(version: 1, projectID: project.id.uuidString, directory: project.path, conversations: document.conversations, selectedID: selection)
    }

    /// Rebase pending stream changes without writing them or adopting another
    /// pane's selection. The baseline remains the freshly read disk snapshot.
    func rebase(_ pending: [ChatConversation]) throws -> [ChatConversation] {
        Self.transactionLock.lock(); defer { Self.transactionLock.unlock() }
        let latest = try readDocument()
        let merged = Self.merge(base: conversations, local: Self.sanitized(pending), remote: latest.conversations)
        conversations = latest.conversations; selectedID = latest.selectedID
        loadRememberedTools()
        return merged
    }

    @discardableResult
    func createConversation() throws -> String {
        var updated = try rebase(conversations)
        let conversation = ChatConversation(id: UUID().uuidString, title: "新对话", projectID: project.id.uuidString, directory: project.path)
        updated.insert(conversation, at: 0)
        try save(updated, selectedID: conversation.id)
        return conversation.id
    }

    func save(_ desired: [ChatConversation], selectedID: String?, preserveSelection: Bool = false) throws {
        Self.transactionLock.lock(); defer { Self.transactionLock.unlock() }
        guard Set(desired.map(\.id)).count == desired.count,
              desired.allSatisfy({ $0.projectID == project.id.uuidString && GlobalPool.sameDirectory($0.directory, project.path) && Set($0.messages.map(\.id)).count == $0.messages.count }) else {
            throw AppError.message("聊天记录与当前项目不匹配，未保存。")
        }
        let latest = try readDocument()
        let safeConversations = Self.merge(base: conversations, local: Self.sanitized(desired), remote: latest.conversations)
        let active = safeConversations.filter { $0.deletedAt == nil }
        let requestedSelection = preserveSelection ? latest.selectedID : selectedID
        let safeSelectedID = active.contains { $0.id == requestedSelection } ? requestedSelection : active.first?.id
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(version: 1, projectID: project.id.uuidString, directory: project.path, conversations: safeConversations, selectedID: safeSelectedID))
        guard data.count <= 64 * 1024 * 1024 else { throw AppError.message("这个项目的聊天记录过大，无法安全保存。") }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        // Callers must accept this merged snapshot before their next save.
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        conversations = try decoder.decode(Document.self, from: data).conversations
        self.selectedID = safeSelectedID
        announceChange()
    }

    private func announceChange() {
        // Delivery after the caller adopts the merge prevents reentrant saves
        // from treating the caller's pre-merge state as a new local edit.
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    /// Reverse only fields introduced by a failed launch. A later edit made
    /// by another pane takes precedence over the inverse operation.
    func rollback(attempted: [ChatConversation], to previous: [ChatConversation], selectedID: String?, preserveSelection: Bool) throws {
        Self.transactionLock.lock(); defer { Self.transactionLock.unlock() }
        let latest = try readDocument()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let baseline = try decoder.decode([ChatConversation].self, from: encoder.encode(Self.sanitized(attempted)))
        let reverted = Self.merge(base: baseline, local: Self.sanitized(previous), remote: latest.conversations, rollback: true)
        try save(reverted, selectedID: selectedID, preserveSelection: preserveSelection)
    }

    private static func sanitized(_ values: [ChatConversation]) -> [ChatConversation] {
        values.map { conversation -> ChatConversation in
            var copy = conversation; copy.title = Self.redacted(copy.title)
            copy.messages = copy.messages.map { message in
                var copy = message; copy.text = Self.redacted(copy.text)
                copy.originalText = copy.originalText.map(Self.redacted)
                copy.translatedText = copy.translatedText.map(Self.redacted)
                return copy
            }
            return copy
        }
    }

    private static func changed<T: Equatable>(_ base: T, _ local: T, _ remote: T) -> T { local == base ? remote : local }

    private static func merge(base: [ChatConversation], local: [ChatConversation], remote: [ChatConversation], rollback: Bool = false) -> [ChatConversation] {
        func pick<T: Equatable>(_ prior: T, _ value: T, _ current: T) -> T { rollback && current != prior ? current : changed(prior, value, current) }
        let baseline = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        let desired = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let latest = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        let ids = local.filter { latest[$0.id] == nil && baseline[$0.id] == nil }.map(\.id) + remote.map(\.id)
        return ids.compactMap { id in
            guard let value = desired[id] else {
                // An explicit rollback may remove only its own unchanged record.
                return baseline[id] != nil && latest[id] == baseline[id] ? nil : latest[id]
            }
            guard let prior = baseline[id], let current = latest[id] else { return latest[id] ?? value }
            var result = current
            result.title = pick(prior.title, value.title, current.title)
            // Session/account/ticket form one identity; never mix two owners.
            if (value.sessionID != prior.sessionID || value.account != prior.account || value.ticket != prior.ticket) && (!rollback || (current.sessionID == prior.sessionID && current.account == prior.account && current.ticket == prior.ticket)) {
                result.sessionID = value.sessionID; result.account = value.account; result.ticket = value.ticket
            }
            result.transferredToTerminal = pick(prior.transferredToTerminal, value.transferredToTerminal, current.transferredToTerminal)
            result.terminalIdentityUncertain = pick(prior.terminalIdentityUncertain, value.terminalIdentityUncertain, current.terminalIdentityUncertain)
            result.continuityUnavailable = pick(prior.continuityUnavailable, value.continuityUnavailable, current.continuityUnavailable)
            result.deletedAt = pick(prior.deletedAt, value.deletedAt, current.deletedAt)
            result.draftAttachments = pick(prior.draftAttachments, value.draftAttachments, current.draftAttachments)
            result.options = mergeOptions(prior.options, value.options, current.options, rollback: rollback)
            result.messages = mergeMessages(prior.messages, value.messages, current.messages, rollback: rollback)
            result.updatedAt = max(value.updatedAt, current.updatedAt)
            return result
        }
    }

    private static func mergeOptions(_ base: ChatOptions?, _ local: ChatOptions?, _ remote: ChatOptions?, rollback: Bool) -> ChatOptions? {
        func pick<T: Equatable>(_ prior: T, _ value: T, _ current: T) -> T { rollback && current != prior ? current : changed(prior, value, current) }
        guard local != base, remote != base, let local, let remote else { return pick(base, local, remote) }
        let base = base ?? ChatOptions()
        return ChatOptions(model: pick(base.model, local.model, remote.model),
                           permissionMode: pick(base.permissionMode, local.permissionMode, remote.permissionMode),
                           effort: pick(base.effort, local.effort, remote.effort),
                           translateToEnglish: pick(base.translateToEnglish, local.translateToEnglish, remote.translateToEnglish),
                           autoTranslateReplies: pick(base.autoTranslateReplies, local.autoTranslateReplies, remote.autoTranslateReplies))
    }

    private static func mergeMessages(_ base: [ChatMessage], _ local: [ChatMessage], _ remote: [ChatMessage], rollback: Bool) -> [ChatMessage] {
        func pick<T: Equatable>(_ prior: T, _ value: T, _ current: T) -> T { rollback && current != prior ? current : changed(prior, value, current) }
        let baseline = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        let desired = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let latest = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        let ids = remote.map(\.id) + local.filter { latest[$0.id] == nil && baseline[$0.id] == nil }.map(\.id)
        return ids.compactMap { id in
            guard let value = desired[id] else { return baseline[id] != nil && latest[id] == baseline[id] ? nil : latest[id] }
            guard let prior = baseline[id], let current = latest[id] else { return latest[id] ?? value }
            var result = current
            result.role = pick(prior.role, value.role, current.role)
            result.text = pick(prior.text, value.text, current.text)
            result.toolName = pick(prior.toolName, value.toolName, current.toolName)
            result.attachments = pick(prior.attachments, value.attachments, current.attachments)
            result.originalText = pick(prior.originalText, value.originalText, current.originalText)
            result.translatedText = pick(prior.translatedText, value.translatedText, current.translatedText)
            let translationSource = value.translatedText != prior.translatedText ? value.text : current.text
            if result.text != translationSource { result.translatedText = nil }
            return result
        }
    }

    private struct Permissions: Codable {
        let projectID: String
        let directory: String
        let tools: Set<String>
    }
    private var permissionsURL: URL { fileURL.deletingPathExtension().appendingPathExtension("permissions.json") }
    private func loadRememberedTools() {
        rememberedTools = []
        guard let data = try? Data(contentsOf: permissionsURL), data.count < 65_536,
              let value = try? JSONDecoder().decode(Permissions.self, from: data),
              value.projectID == project.id.uuidString,
              GlobalPool.sameDirectory(value.directory, project.path) else { return }
        rememberedTools = value.tools
    }
    func remember(tool: String) throws {
        Self.transactionLock.lock(); defer { Self.transactionLock.unlock() }
        loadRememberedTools()
        var values = rememberedTools; values.insert(tool); try saveRememberedTools(values)
    }
    func clearRememberedTools() throws {
        Self.transactionLock.lock(); defer { Self.transactionLock.unlock() }
        try saveRememberedTools([])
    }
    func refreshedRememberedTools() -> Set<String> {
        Self.transactionLock.lock(); defer { Self.transactionLock.unlock() }
        loadRememberedTools(); return rememberedTools
    }
    private func saveRememberedTools(_ tools: Set<String>) throws {
        let data = try JSONEncoder().encode(Permissions(projectID: project.id.uuidString, directory: project.path, tools: tools))
        try FileManager.default.createDirectory(at: permissionsURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: permissionsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: permissionsURL.path)
        rememberedTools = tools
        announceChange()
    }

    /// Redact known credential forms in the app's additional saved copy only.
    /// The user's actual prompt and Claude's own transcript are not rewritten.
    static func redacted(_ text: String) -> String {
        let patterns = [
            #"\bsk-(?:ant-|proj-)[A-Za-z0-9_-]+"#,
            #"(?i)\bBearer\s+[A-Za-z0-9._~+/-]+=*"#,
            #"(?i)\b(?:ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|OPENAI_API_KEY|access_token|refresh_token)[\"']?\s*[:=]\s*[\"']?[^\s\"',;}]+"#
        ]
        return patterns.reduce(text) { result, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
            return regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "［已隐藏凭据］")
        }
    }
}
