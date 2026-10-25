import Foundation

@main struct GitRepositoryDiscoveryTests {
    static var count = 0
    static func check(_ value: Bool, _ message: String) {
        count += 1
        if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); check(false, message) } catch { check(true, message) }
    }
    static func git(_ directory: URL, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-c", "user.name=Offline Fixture", "-c", "user.email=fixture@example.invalid"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        environment["GIT_TERMINAL_PROMPT"] = "0"; process.environment = environment
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitRepositoryDiscoveryError.message("Fixture git failed: \(arguments)") }
    }
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("ccam-discovery-tests-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        func folder(_ relative: String) throws -> URL {
            let url = temporary.appendingPathComponent(relative)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url.resolvingSymlinksInPath().standardizedFileURL
        }
        func repository(_ relative: String) throws -> URL {
            let url = try folder(relative); try git(url, ["init", "-q"]); return url
        }
        let project = try folder("workspace")
        let alpha = try repository("workspace/alpha")
        let beta = try repository("workspace/beta")
        let nested = try repository("workspace/services/api")
        _ = try folder("workspace/not-a-repository")
        _ = try folder("workspace/broken/.git")
        let fakeFile = try folder("workspace/broken-file")
        try "gitdir: /path-that-does-not-exist\n".write(to: fakeFile.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let excluded = try repository("workspace/node_modules/hidden-dependency")
        let outside = try repository("outside")
        try fm.createSymbolicLink(at: project.appendingPathComponent("outside-link"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: project.appendingPathComponent("alpha-alias"), withDestinationURL: alpha)
        let scanner = try GitRepositoryDiscovery(directory: project.path)
        let result = try scanner.discover()
        check(result.repositories.map(\.relativePath) == ["alpha", "beta", "services/api"], "ordinary parent finds and stably sorts independent child repositories")
        check(result.repositories.last?.displayName == "services/api", "nested repository display keeps its parent path")
        check(!result.incomplete && result.note?.contains("依赖") == true, "intentional generated-folder omission is disclosed without a false scan failure")
        check(!result.repositories.contains { $0.directory == excluded || $0.directory == outside }, "dependency and symlink destinations are not searched")
        check(!fm.fileExists(atPath: alpha.appendingPathComponent(".git/index").path), "discovery does not stage files or create an index")
        check(try scanner.validate(result.repositories[0]) == alpha, "selected repository validates to its own working directory")
        let gitKeys = ["GIT_DIR", "GIT_WORK_TREE", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0"]
        let previous = Dictionary(uniqueKeysWithValues: gitKeys.map { ($0, ProcessInfo.processInfo.environment[$0]) })
        setenv("GIT_DIR", outside.appendingPathComponent(".git").path, 1)
        setenv("GIT_WORK_TREE", outside.path, 1)
        setenv("GIT_CONFIG_COUNT", "1", 1); setenv("GIT_CONFIG_KEY_0", "core.worktree", 1); setenv("GIT_CONFIG_VALUE_0", outside.path, 1)
        let isolated = try scanner.discover()
        for key in gitKeys { if let saved = previous[key] ?? nil { setenv(key, saved, 1) } else { unsetenv(key) } }
        check(isolated.repositories.map(\.relativePath) == result.repositories.map(\.relativePath), "inherited Git location and config environment cannot redirect discovery")
        rejects("forged outside selection is rejected") {
            _ = try scanner.validate(GitRepositoryRecord(directory: outside, relativePath: "../outside", displayName: "outside"))
        }
        rejects("mismatched relative identity is rejected") {
            _ = try scanner.validate(GitRepositoryRecord(directory: alpha, relativePath: "beta", displayName: "fake"))
        }

        // A project itself may already be a repository and can contain another
        // independent repository. Do not stop searching at the first .git.
        let rootRepo = try repository("root-repository")
        _ = try repository("root-repository/tools/nested")
        let rootScanner = try GitRepositoryDiscovery(directory: rootRepo.path)
        let roots = try rootScanner.discover()
        check(roots.repositories.map(\.relativePath) == [".", "tools/nested"], "root and nested independent repositories are both available")
        check(roots.repositories[0].directory == rootRepo && roots.repositories[0].displayName == "root-repository", "root display and operation scope stay at the project root")

        // Opening a subdirectory of a repository must not silently widen commit
        // scope to the repository's parent. ProjectGitClient retains this scope.
        let scoped = try folder("root-repository/project-scope")
        _ = try repository("root-repository/project-scope/inner")
        let scopedScanner = try GitRepositoryDiscovery(directory: scoped.path)
        let scopedResult = try scopedScanner.discover()
        check(scopedResult.repositories.map(\.relativePath) == [".", "inner"], "project inside an ancestor repository retains a scoped root plus child repositories")
        check(try scopedScanner.validate(scopedResult.repositories[0]) == scoped && scopedResult.repositories[0].directory != rootRepo, "ancestor repository never replaces current project operation directory")

        // Worktrees and submodules use a .git file whose metadata can be outside
        // the project. Only the working directory must remain inside the root.
        let base = try repository("base")
        try "fixture\n".write(to: base.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(base, ["add", "README.md"]); try git(base, ["commit", "-q", "-m", "Offline fixture"])
        let linked = project.appendingPathComponent("linked-worktree", isDirectory: true)
        try git(base, ["worktree", "add", "--detach", "-q", linked.path, "HEAD"])
        let moduleHost = try repository("module-host")
        try git(moduleHost, ["-c", "protocol.file.allow=always", "submodule", "add", "-q", base.path, "module"])
        let module = moduleHost.appendingPathComponent("module", isDirectory: true)
        var isDirectory: ObjCBool = false
        check(fm.fileExists(atPath: linked.appendingPathComponent(".git").path, isDirectory: &isDirectory) && !isDirectory.boolValue, "linked worktree fixture has a .git file")
        let withWorktree = try scanner.discover()
        check(withWorktree.repositories.contains { $0.directory == linked }, "linked worktree .git file is discovered")
        check(try scanner.validate(withWorktree.repositories.first { $0.directory == linked }!) == linked, "linked worktree validation permits external metadata without external working scope")
        let moduleScanner = try GitRepositoryDiscovery(directory: moduleHost.path)
        let modules = try moduleScanner.discover()
        check(modules.repositories.map(\.relativePath) == [".", "module"], "submodule .git file is discovered independently")
        check(try moduleScanner.validate(modules.repositories[1]) == module, "submodule validation keeps its own directory")

        let shallow = try GitRepositoryDiscovery(directory: project.path, maximumDepth: 1).discover()
        check(shallow.incomplete && !shallow.repositories.contains { $0.directory == nested }, "depth bound returns partial results rather than an apparently complete list")
        check(shallow.repositories.contains { $0.directory == alpha }, "depth bound still includes direct child repositories")
        let limited = try GitRepositoryDiscovery(directory: project.path, maximumDirectories: 2).discover()
        check(limited.incomplete && limited.repositories.count <= 1, "directory-count bound limits traversal")
        let single = try GitRepositoryDiscovery(directory: project.path, maximumRepositories: 1).discover()
        check(single.incomplete && single.repositories.count == 1, "repository-count bound is explicit")
        let expired = try GitRepositoryDiscovery(directory: project.path, maximumDuration: 0).discover()
        check(expired.incomplete && !expired.repositories.contains { $0.directory == nested }, "time bound stops deeper traversal")
        check(expired.repositories.contains { $0.directory == alpha } && expired.repositories.contains { $0.directory == beta }, "cold-root time bound retains a small first-level repository batch")
        let empty = try folder("empty")
        let emptyResult = try GitRepositoryDiscovery(directory: empty.path).discover()
        check(emptyResult.repositories.isEmpty && !emptyResult.incomplete, "empty project has a complete empty result")
        rejects("missing project is rejected") { _ = try GitRepositoryDiscovery(directory: temporary.appendingPathComponent("missing").path) }

        // Reinitializing Git metadata can change the repository without changing
        // the working directory inode. Both child and ancestor-scoped candidates
        // must reject the old UI record until the user explicitly refreshes.
        let identityParent = try folder("metadata-identity")
        let identityRepo = try repository("metadata-identity/repository")
        let identityScope = try folder("metadata-identity/repository/scoped-project")
        let identityScanner = try GitRepositoryDiscovery(directory: identityParent.path)
        let identityRecord = try identityScanner.discover().repositories[0]
        let identityRootScanner = try GitRepositoryDiscovery(directory: identityRepo.path)
        let identityRootRecord = try identityRootScanner.discover().repositories[0]
        let identityScopeScanner = try GitRepositoryDiscovery(directory: identityScope.path)
        let identityScopeRecord = try identityScopeScanner.discover().repositories[0]
        try fm.moveItem(at: identityRepo.appendingPathComponent(".git"), to: temporary.appendingPathComponent("original-git-metadata"))
        try git(identityRepo, ["init", "-q"])
        rejects("child working directory cannot retain an old record after only .git is replaced") { _ = try identityScanner.validate(identityRecord) }
        rejects("root repository checks metadata identity in addition to its working directory") { _ = try identityRootScanner.validate(identityRootRecord) }
        rejects("ancestor-scoped project detects replacement of its parent repository metadata") { _ = try identityScopeScanner.validate(identityScopeRecord) }
        let replacementRecord = try identityScanner.discover().repositories[0]
        check(try identityScanner.validate(replacementRecord) == identityRepo, "explicit rediscovery can accept the replacement repository")
        rejects("record from before rediscovery cannot inherit a replacement repository identity") { _ = try identityScanner.validate(identityRecord) }

        let fileParent = try folder("git-file-identity")
        let fileWorking = try folder("git-file-identity/working")
        let otherWorking = try folder("other-working")
        let metadataOne = temporary.appendingPathComponent("metadata-one"), metadataTwo = temporary.appendingPathComponent("metadata-two")
        try git(fileWorking, ["init", "-q", "--separate-git-dir", metadataOne.path])
        try git(otherWorking, ["init", "-q", "--separate-git-dir", metadataTwo.path])
        let fileScanner = try GitRepositoryDiscovery(directory: fileParent.path)
        let fileRecord = try fileScanner.discover().repositories[0]
        try ("gitdir: " + metadataTwo.path + "\n").write(to: fileWorking.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        rejects("redirected .git file cannot silently switch the selected repository") { _ = try fileScanner.validate(fileRecord) }
        let newFileRecord = try fileScanner.discover().repositories[0]
        check(try fileScanner.validate(newFileRecord) == fileWorking, "explicit rediscovery accepts a valid new .git-file target")

        let newlineRoot = try repository("repository-with\nnewline")
        let newlineScope = try folder("repository-with\nnewline/scoped\nproject")
        let newlineScanner = try GitRepositoryDiscovery(directory: newlineScope.path)
        let newlineRecord = try newlineScanner.discover().repositories[0]
        check(try newlineScanner.validate(newlineRecord) == newlineScope && newlineRecord.directory != newlineRoot, "metadata and parent-scope paths preserve embedded newlines")

        let originalAlpha = withWorktree.repositories.first { $0.directory == alpha }!
        let backupAlpha = project.appendingPathComponent("alpha-backup")
        try fm.moveItem(at: alpha, to: backupAlpha)
        try fm.createSymbolicLink(at: alpha, withDestinationURL: outside)
        rejects("selected repository symlink replacement is rejected") { _ = try scanner.validate(originalAlpha) }
        try fm.removeItem(at: alpha); try fm.moveItem(at: backupAlpha, to: alpha)
        let originalNested = withWorktree.repositories.first { $0.directory == nested }!
        let services = project.appendingPathComponent("services"), servicesBackup = temporary.appendingPathComponent("services-backup")
        try fm.moveItem(at: services, to: servicesBackup)
        try fm.createSymbolicLink(at: services, withDestinationURL: temporary)
        rejects("ancestor path symlink replacement is rejected") { _ = try scanner.validate(originalNested) }
        try fm.removeItem(at: services); try fm.moveItem(at: servicesBackup, to: services)

        let originalBeta = withWorktree.repositories.first { $0.directory == beta }!
        try fm.moveItem(at: beta.appendingPathComponent(".git"), to: beta.appendingPathComponent(".git-removed"))
        rejects("repository marker removal is rejected") { _ = try scanner.validate(originalBeta) }
        try fm.moveItem(at: beta.appendingPathComponent(".git-removed"), to: beta.appendingPathComponent(".git"))
        try fm.moveItem(at: beta, to: project.appendingPathComponent("beta-backup"))
        _ = try repository("workspace/beta")
        rejects("same-path replacement by a different repository is rejected until rediscovery") { _ = try scanner.validate(originalBeta) }

        let rootBackup = temporary.appendingPathComponent("workspace-backup")
        try fm.moveItem(at: project, to: rootBackup)
        try fm.createSymbolicLink(at: project, withDestinationURL: outside)
        rejects("project root retargeting is rejected") { _ = try scanner.validate(originalAlpha) }
        rejects("rescan refuses a replaced project root") { _ = try scanner.discover() }
        print("PASS: \(count) local repository discovery checks; no network or model requests")
    }
}
