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
}

struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID().uuidString
    var role: String
    var text: String
    var toolName: String? = nil
    var attachments: [ChatAttachment]? = nil
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

    init(project: ProjectRecord, fileURL: URL? = nil) throws {
        self.project = project
        self.fileURL = fileURL ?? ProjectStore.defaultURL.deletingLastPathComponent().appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent(project.id.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
        let data = try Data(contentsOf: self.fileURL)
        guard data.count <= 64 * 1024 * 1024 else { throw AppError.message("这个项目的聊天记录过大，无法安全打开。") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(Document.self, from: data)
        guard document.version == 1, document.projectID == project.id.uuidString,
              GlobalPool.sameDirectory(document.directory, project.path),
              Set(document.conversations.map(\.id)).count == document.conversations.count,
              document.conversations.allSatisfy({ $0.projectID == project.id.uuidString && GlobalPool.sameDirectory($0.directory, project.path) }) else {
            throw AppError.message("聊天记录与当前项目不匹配，未载入其他项目的对话。")
        }
        conversations = document.conversations
        let active = conversations.filter { $0.deletedAt == nil }
        selectedID = active.contains { $0.id == document.selectedID } ? document.selectedID : active.first?.id
    }

    func save(_ conversations: [ChatConversation], selectedID: String?) throws {
        let safeConversations = conversations.map { conversation -> ChatConversation in
            var copy = conversation; copy.title = Self.redacted(copy.title)
            copy.messages = copy.messages.map { message in var copy = message; copy.text = Self.redacted(copy.text); return copy }
            return copy
        }
        let active = safeConversations.filter { $0.deletedAt == nil }
        let safeSelectedID = active.contains { $0.id == selectedID } ? selectedID : active.first?.id
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(version: 1, projectID: project.id.uuidString, directory: project.path, conversations: safeConversations, selectedID: safeSelectedID))
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        self.conversations = safeConversations; self.selectedID = safeSelectedID
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
