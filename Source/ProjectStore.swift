import Foundation
import Darwin

struct ProjectRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let path: String
    let createdAt: Date
    var lastOpenedAt: Date
    var archived: Bool

    var directoryExists: Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}

enum ProjectStoreError: LocalizedError {
    case invalidDirectory, invalidName, missingProject, archivedProject, unsupportedVersion
    var errorDescription: String? {
        switch self {
        case .invalidDirectory: return "项目目录不存在或不是文件夹。"
        case .invalidName: return "请填写项目名称。"
        case .missingProject: return "找不到这个项目，请刷新项目列表。"
        case .archivedProject: return "请先恢复这个已归档的项目。"
        case .unsupportedVersion: return "项目列表来自更新版本，请使用新版应用打开。"
        }
    }
}

/// Local workspace metadata only. Account selection and quota deliberately live elsewhere.
final class ProjectStore {
    private struct Document: Codable {
        var version = 1
        var projects: [ProjectRecord]
        var currentProjectID: UUID?
    }
    static var defaultURL: URL {
        if let directory = ProcessInfo.processInfo.environment["CCAM_DESKTOP_DATA_DIR"], directory.hasPrefix("/") {
            return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("projects.json")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CCAM Desktop", isDirectory: true)
            .appendingPathComponent("projects.json")
    }
    let fileURL: URL
    private(set) var projects: [ProjectRecord] = []
    private(set) var currentProjectID: UUID?
    private let now: () -> Date
    var currentProject: ProjectRecord? { projects.first { $0.id == currentProjectID && !$0.archived } }
    var activeProjects: [ProjectRecord] { sorted(projects.filter { !$0.archived }) }
    var archivedProjects: [ProjectRecord] { sorted(projects.filter { $0.archived }) }

    init(fileURL: URL = ProjectStore.defaultURL, legacyDirectory: String? = nil, now: @escaping () -> Date = Date.init) throws {
        self.fileURL = fileURL
        self.now = now
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let saved = try decoder.decode(Document.self, from: Data(contentsOf: fileURL))
            guard saved.version == 1 else { throw ProjectStoreError.unsupportedVersion }
            projects = saved.projects
            currentProjectID = saved.currentProjectID
            if currentProject == nil { currentProjectID = activeProjects.first?.id }
        } else if let legacyDirectory, let canonical = try? Self.canonicalDirectory(legacyDirectory),
                  canonical != FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL.path {
            _ = try add(directory: canonical)
        }
    }

    @discardableResult
    func add(directory: String, name: String? = nil) throws -> ProjectRecord {
        let path = try Self.canonicalDirectory(directory)
        var next = projects
        let record: ProjectRecord
        if let index = next.firstIndex(where: { $0.path == path }) {
            next[index].archived = false
            next[index].lastOpenedAt = now()
            if let name { next[index].name = try Self.validName(name) }
            record = next[index]
        } else {
            let basename = URL(fileURLWithPath: path).lastPathComponent
            let title = try Self.validName(name ?? (basename.isEmpty ? path : basename))
            let timestamp = now()
            record = ProjectRecord(id: UUID(), name: title, path: path, createdAt: timestamp, lastOpenedAt: timestamp, archived: false)
            next.append(record)
        }
        try commit(projects: next, current: record.id)
        return record
    }

    func select(id: UUID) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw ProjectStoreError.missingProject }
        guard !projects[index].archived else { throw ProjectStoreError.archivedProject }
        guard projects[index].directoryExists else { throw ProjectStoreError.invalidDirectory }
        var next = projects; next[index].lastOpenedAt = now()
        try commit(projects: next, current: id)
    }

    func rename(id: UUID, name: String) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw ProjectStoreError.missingProject }
        let title = try Self.validName(name)
        var next = projects; next[index].name = title
        try commit(projects: next, current: currentProjectID)
    }

    func setArchived(id: UUID, archived: Bool) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw ProjectStoreError.missingProject }
        var next = projects; next[index].archived = archived
        let current = archived && currentProjectID == id
            ? sorted(next.filter { !$0.archived }).first?.id
            : (currentProjectID ?? (archived ? nil : id))
        try commit(projects: next, current: current)
    }

    private func commit(projects next: [ProjectRecord], current: UUID?) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(projects: next, currentProjectID: current))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        projects = next; currentProjectID = current
    }

    private func sorted(_ records: [ProjectRecord]) -> [ProjectRecord] {
        records.sorted {
            if $0.lastOpenedAt != $1.lastOpenedAt { return $0.lastOpenedAt > $1.lastOpenedAt }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private static func canonicalDirectory(_ directory: String) throws -> String {
        guard !directory.isEmpty, !directory.contains("\0") else { throw ProjectStoreError.invalidDirectory }
        let url = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw ProjectStoreError.invalidDirectory }
        return url.path
    }
    private static func validName(_ name: String) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("\0") else { throw ProjectStoreError.invalidName }
        return clean
    }
}

struct GitSummary: Equatable {
    let isRepository: Bool
    let branch: String
    let changedFiles: Int
    let error: String?

    static func read(directory: String, completion: @escaping (GitSummary) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = inspect(directory: directory)
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func inspect(directory: String) -> GitSummary {
        let repository = command(["rev-parse", "--is-inside-work-tree"], directory: directory)
        guard repository.code == 0, String(decoding: repository.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return GitSummary(isRepository: false, branch: "", changedFiles: 0, error: repository.code == -1 ? "无法读取项目目录或 Git 不可用。" : nil)
        }
        let symbolic = command(["symbolic-ref", "--quiet", "--short", "HEAD"], directory: directory)
        let branch: String
        if symbolic.code == 0 {
            branch = String(decoding: symbolic.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let revision = command(["rev-parse", "--short", "HEAD"], directory: directory)
            branch = revision.code == 0 ? "游离 HEAD · " + String(decoding: revision.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : "尚无提交"
        }
        let status = command(["status", "--porcelain=v1", "-z", "--untracked-files=all"], directory: directory)
        guard status.code == 0 else { return GitSummary(isRepository: true, branch: branch, changedFiles: 0, error: "Git 状态读取失败或超时。") }
        return GitSummary(isRepository: true, branch: branch, changedFiles: countStatus(status.data), error: nil)
    }

    // Porcelain -z stores a second path after each rename/copy record.
    static func countStatus(_ data: Data) -> Int {
        let records = data.split(separator: 0)
        var count = 0, index = 0
        while index < records.count {
            let record = records[index]
            if record.count >= 3 {
                count += 1
                if record.prefix(2).contains(82) || record.prefix(2).contains(67) { index += 1 }
            }
            index += 1
        }
        return count
    }

    private static func command(_ arguments: [String], directory: String) -> (code: Int32, data: Data) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-c", "core.fsmonitor=false"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardOutput = pipe
        do {
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: timeout)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); timeout.cancel()
            return (process.terminationStatus, data)
        } catch { return (-1, Data()) }
    }
}
