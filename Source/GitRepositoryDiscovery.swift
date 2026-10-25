import Foundation
import Darwin

struct GitRepositoryRecord: Equatable {
    let directory: URL
    let relativePath: String
    let displayName: String
    // Retained by value copies, renewed by discovery. A stale UI record must
    // not become valid merely because a later refresh accepted a new repository.
    fileprivate let validationID = UUID()
}

struct GitRepositoryDiscoveryResult {
    let repositories: [GitRepositoryRecord]
    let incomplete: Bool
    let note: String?
}

enum GitRepositoryDiscoveryError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

/// Local, bounded repository discovery. Repository metadata can live outside the
/// project for linked worktrees, but every operation directory stays inside it.
/// No remote, credential helper, status, hook or fetch operation is performed.
final class GitRepositoryDiscovery {
    let directory: URL
    private let maximumDepth: Int
    private let maximumDirectories: Int
    private let maximumRepositories: Int
    private let maximumDuration: TimeInterval
    private let rootIdentity: Identity
    private var discoveredIdentities: [UUID: RepositoryIdentity] = [:]
    private let identityLock = NSLock()
    private static let excluded = Set([".git", "node_modules", ".pnpm-store", ".yarn", ".build", "target", "vendor", "Pods", "Carthage", "DerivedData", ".venv", "venv", "__pycache__", ".next", ".nuxt", "dist", "build", ".Trash", ".cache"])

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
    }
    private struct MetadataIdentity: Equatable {
        let directory: URL
        let identity: Identity
    }
    private struct RepositoryIdentity {
        let working: Identity
        let metadata: MetadataIdentity
    }

    init(directory: String, maximumDepth: Int = 6, maximumDirectories: Int = 4000,
         maximumRepositories: Int = 128, maximumDuration: TimeInterval = 5) throws {
        let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard let info = Self.info(root), Self.isDirectory(info) else { throw GitRepositoryDiscoveryError.message("项目目录不可访问。") }
        self.directory = root; rootIdentity = Identity(info)
        self.maximumDepth = max(0, min(32, maximumDepth))
        self.maximumDirectories = max(1, min(100_000, maximumDirectories))
        self.maximumRepositories = max(1, min(1024, maximumRepositories))
        self.maximumDuration = maximumDuration.isFinite ? max(0, maximumDuration) : 5
    }

    func discover() throws -> GitRepositoryDiscoveryResult {
        try checkDirectory(directory)
        let deadline = Date().addingTimeInterval(maximumDuration)
        var repositories: [GitRepositoryRecord] = []
        var identities: [UUID: RepositoryIdentity] = [:]
        var queue: [(URL, Int)] = [(directory, 0)], cursor = 0, visited = 0, entries = 0
        var incomplete = false, skippedGenerated = false
        let maximumEntries = max(256, maximumDirectories * 16)
        let firstLevelAllowance = min(32, maximumDirectories)
        var firstLevelProbes = 0

        while cursor < queue.count {
            let (folder, depth) = queue[cursor]; cursor += 1
            let expired = Date() >= deadline
            // A cold mounted root can consume the time budget in one filesystem
            // call. Still inspect a small first-level candidate batch, without
            // recursively walking those folders after the deadline.
            if expired && depth > 0 && (depth != 1 || firstLevelProbes >= firstLevelAllowance) { incomplete = true; break }
            guard visited < maximumDirectories else { incomplete = true; break }
            visited += 1
            if depth == 1 { firstLevelProbes += 1 }
            do { try checkDirectory(folder) } catch { incomplete = true; continue }
            let marker = markerExists(folder)
            if depth == 0 || marker {
                do {
                    if let metadata = try workTreeIdentity(folder, allowPrefix: depth == 0, timeout: expired ? 0.75 : min(2, max(0.25, deadline.timeIntervalSinceNow))),
                       let info = Self.info(folder), Self.isDirectory(info) {
                        let relative = relativePath(folder)
                        let record = GitRepositoryRecord(directory: folder, relativePath: relative,
                                                         displayName: relative == "." ? folder.lastPathComponent : relative)
                        repositories.append(record)
                        identities[record.validationID] = RepositoryIdentity(working: Identity(info), metadata: metadata)
                        if repositories.count >= maximumRepositories {
                            // There may be more repositories even when the current
                            // result count exactly reaches the configured bound.
                            incomplete = true; break
                        }
                    }
                } catch { incomplete = true }
            }
            if depth > 0 && Date() >= deadline { incomplete = true; continue }
            guard let stream = opendir(folder.path) else { incomplete = true; continue }
            var children: [URL] = []
            while let entry = readdir(stream) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                entries += 1
                if entries > maximumEntries || (Date() >= deadline && (depth > 0 || entries >= 256)) { incomplete = true; break }
                let child = folder.appendingPathComponent(name, isDirectory: true)
                guard let info = Self.info(child), Self.isDirectory(info) else { continue }
                if Self.excluded.contains(name) { if name != ".git" { skippedGenerated = true }; continue }
                if depth >= maximumDepth { incomplete = true; continue }
                children.append(child)
                if queue.count + children.count >= maximumDirectories { incomplete = true; break }
            }
            closedir(stream)
            children.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            queue += children.map { ($0, depth + 1) }
            if entries > maximumEntries { break }
        }
        try checkDirectory(directory)
        repositories.sort {
            if $0.relativePath == "." { return $1.relativePath != "." }
            if $1.relativePath == "." { return false }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        identityLock.lock(); discoveredIdentities = identities; identityLock.unlock()
        var notes: [String] = []
        if incomplete { notes.append("仅显示已发现的仓库；扫描达到范围或时间限制，或部分目录不可读取。可把更深的仓库单独添加为项目。") }
        if skippedGenerated { notes.append("已跳过依赖、构建和缓存目录。") }
        return GitRepositoryDiscoveryResult(repositories: repositories, incomplete: incomplete,
                                            note: notes.isEmpty ? nil : notes.joined(separator: "\n"))
    }

    /// Recheck immediately before selecting or operating on a repository. This
    /// detects deletion/replacement and directory symlink retargeting; the caller
    /// must still keep each asynchronous operation bound to this returned path.
    /// Filesystem paths are not a sandbox against concurrent hostile renames.
    func validate(_ record: GitRepositoryRecord) throws -> URL {
        try checkDirectory(record.directory)
        guard relativePath(record.directory) == record.relativePath else { throw GitRepositoryDiscoveryError.message("仓库路径已改变，请刷新仓库列表。") }
        identityLock.lock(); let expected = discoveredIdentities[record.validationID]; identityLock.unlock()
        guard let expected, let actual = Self.info(record.directory), expected.working == Identity(actual) else {
            throw GitRepositoryDiscoveryError.message("仓库已移动或替换，请刷新仓库列表。")
        }
        if record.relativePath != ".", !markerExists(record.directory) { throw GitRepositoryDiscoveryError.message("这个子目录已不再是独立仓库，请刷新仓库列表。") }
        guard let metadata = try workTreeIdentity(record.directory, allowPrefix: record.relativePath == ".", timeout: 2) else {
            throw GitRepositoryDiscoveryError.message("仓库不可读取，请刷新仓库列表。")
        }
        guard expected.metadata == metadata else { throw GitRepositoryDiscoveryError.message("Git 仓库已替换或重定向，请刷新仓库列表。") }
        try checkDirectory(record.directory)
        return record.directory
    }

    private static func info(_ url: URL) -> stat? {
        var value = stat()
        return lstat(url.path, &value) == 0 ? value : nil
    }
    private static func isDirectory(_ value: stat) -> Bool { (value.st_mode & S_IFMT) == S_IFDIR }
    private func markerExists(_ folder: URL) -> Bool {
        guard let marker = Self.info(folder.appendingPathComponent(".git")) else { return false }
        return [S_IFDIR, S_IFREG].contains(marker.st_mode & S_IFMT)
    }
    private func relativePath(_ folder: URL) -> String {
        folder.path == directory.path ? "." : String(folder.path.dropFirst(directory.path.count + (directory.path == "/" ? 0 : 1)))
    }
    private func checkDirectory(_ folder: URL) throws {
        let path = folder.standardizedFileURL.path
        let rootPath = directory.path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path == folder.path, path == rootPath || path.hasPrefix(prefix),
              let root = Self.info(directory), Self.isDirectory(root), Identity(root) == rootIdentity else {
            throw GitRepositoryDiscoveryError.message("项目或仓库目录已改变，请重新打开项目。")
        }
        var current = directory
        if path != rootPath {
            for component in path.dropFirst(prefix.count).split(separator: "/") {
                current.appendPathComponent(String(component), isDirectory: true)
                guard let info = Self.info(current), Self.isDirectory(info) else {
                    throw GitRepositoryDiscoveryError.message("仓库路径不可访问或包含目录链接，请刷新仓库列表。")
                }
            }
        }
        guard folder.resolvingSymlinksInPath().standardizedFileURL.path == path else {
            throw GitRepositoryDiscoveryError.message("仓库路径已转向其他目录，请刷新仓库列表。")
        }
    }

    private func workTreeIdentity(_ folder: URL, allowPrefix: Bool, timeout: TimeInterval) throws -> MetadataIdentity? {
        let deadline = Date().addingTimeInterval(timeout)
        guard let scope = try gitOutput(["rev-parse", "--is-inside-work-tree", "--show-prefix"], directory: folder, timeout: timeout),
              scope.starts(with: Data("true\n".utf8)), allowPrefix || scope == Data("true\n\n".utf8) else { return nil }
        guard deadline.timeIntervalSinceNow > 0 else { throw GitRepositoryDiscoveryError.message("仓库检查超时，请刷新后重试。") }
        guard let data = try gitOutput(["rev-parse", "--absolute-git-dir"], directory: folder, timeout: deadline.timeIntervalSinceNow),
              var path = String(data: data, encoding: .utf8), path.hasPrefix("/"), path.hasSuffix("\n") else { return nil }
        // Remove Git's one record terminator, not newlines belonging to a path.
        path.removeLast()
        let metadata = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard let info = Self.info(metadata), Self.isDirectory(info) else { return nil }
        return MetadataIdentity(directory: metadata, identity: Identity(info))
    }

    private func gitOutput(_ arguments: [String], directory folder: URL, timeout: TimeInterval) throws -> Data? {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "-c", "core.fsmonitor=false"] + arguments
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GIT_OPTIONAL_LOCKS"] = "0"; environment["LC_ALL"] = "C"
        process.environment = environment
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run(); try? pipe.fileHandleForWriting.close()
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        defer { try? pipe.fileHandleForReading.close() }
        var output = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        func drain() {
            while true {
                let read = Darwin.read(fd, &buffer, buffer.count)
                if read <= 0 { return }
                if output.count < 8192 { output.append(contentsOf: buffer.prefix(min(read, 8192 - output.count))) }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            drain()
            if Date() >= deadline { timedOut = true; process.terminate(); break }
            usleep(5_000)
        }
        if timedOut {
            let grace = Date().addingTimeInterval(0.25)
            while process.isRunning && Date() < grace { drain(); usleep(5_000) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit(); drain()
        if timedOut { throw GitRepositoryDiscoveryError.message("仓库检查超时，请刷新后重试。") }
        return process.terminationStatus == 0 ? output : nil
    }
}
