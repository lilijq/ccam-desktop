import Foundation

@main struct ProjectTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func git(_ arguments: [String], in directory: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments; process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        check(process.terminationStatus == 0, "git fixture \(arguments.first ?? "")")
    }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ccam-project-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("项目 ' $(touch nope)", isDirectory: true)
        let other = root.appendingPathComponent("other", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("state/projects.json")
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try ProjectStore(fileURL: file, now: { clock })
        check(store.projects.isEmpty && store.currentProjectID == nil, "empty store does not invent a project")
        let first = try store.add(directory: folder.path)
        check(first.name == folder.lastPathComponent && first.path == folder.resolvingSymlinksInPath().path, "canonical directory and default title")
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: folder)
        let duplicate = try store.add(directory: alias.path)
        check(duplicate.id == first.id && store.projects.count == 1, "symlink aliases do not duplicate projects")
        clock = clock.addingTimeInterval(10)
        let second = try store.add(directory: other.path, name: " Another ")
        check(store.currentProjectID == second.id && store.activeProjects.first?.id == second.id, "new project selected and sorted by recency")
        try store.rename(id: first.id, name: " Renamed ")
        check(store.projects.first?.name == "Renamed" && fm.fileExists(atPath: folder.path), "rename changes metadata only")
        do { try store.rename(id: first.id, name: "  "); check(false, "blank name rejected") } catch { check(true, "blank name rejected") }
        try store.setArchived(id: second.id, archived: true)
        check(store.currentProjectID == first.id && store.archivedProjects.count == 1, "archiving selected project chooses active project")
        check(fm.fileExists(atPath: other.path), "archive preserves project directory")
        do { try store.select(id: second.id); check(false, "archived project cannot launch") } catch { check(true, "archived project cannot launch") }
        try store.setArchived(id: second.id, archived: false)
        clock = clock.addingTimeInterval(10); try store.select(id: first.id)
        check(store.activeProjects.first?.id == first.id && store.currentProject?.id == first.id, "open updates recency and selection")
        let reopened = try ProjectStore(fileURL: file)
        check(reopened.projects == store.projects && reopened.currentProjectID == first.id, "atomic persistence round trip")
        let saved = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        check(!saved.contains("account") && !saved.contains("quota"), "project metadata has no account or quota")
        do { _ = try store.add(directory: root.appendingPathComponent("missing").path); check(false, "missing directory rejected") } catch { check(true, "missing directory rejected") }
        do { _ = try store.add(directory: file.path); check(false, "file rejected as directory") } catch { check(true, "file rejected as directory") }
        try fm.removeItem(at: other)
        do { try store.select(id: second.id); check(false, "moved directory cannot be selected") } catch { check(true, "moved directory cannot be selected") }
        check(store.projects.count == 2 && store.currentProjectID == first.id, "missing directories remain listed without losing current selection")
        let noHome = try ProjectStore(fileURL: root.appendingPathComponent("home.json"), legacyDirectory: fm.homeDirectoryForCurrentUser.path)
        check(noHome.projects.isEmpty, "home fallback is not migrated as a project")
        let migrated = try ProjectStore(fileURL: root.appendingPathComponent("migration.json"), legacyDirectory: folder.path)
        check(migrated.projects.count == 1, "legacy actual project directory migrated")
        let corrupted = root.appendingPathComponent("corrupt.json")
        try Data("not json".utf8).write(to: corrupted)
        do { _ = try ProjectStore(fileURL: corrupted, legacyDirectory: folder.path); check(false, "corruption surfaced") } catch { check(true, "corruption surfaced") }
        let corruptContents = try String(contentsOf: corrupted, encoding: .utf8)
        check(corruptContents == "not json", "corrupted file is not overwritten")
        let obstructed = root.appendingPathComponent("blocked/state.json")
        let cannotSave = try ProjectStore(fileURL: obstructed)
        try Data("file blocks parent".utf8).write(to: obstructed.deletingLastPathComponent())
        do { _ = try cannotSave.add(directory: folder.path); check(false, "save failure surfaced") } catch { check(true, "save failure surfaced") }
        check(cannotSave.projects.isEmpty && cannotSave.currentProjectID == nil, "failed save does not mutate in-memory state")
        check(!GitSummary.inspect(directory: folder.path).isRepository, "ordinary directory is a valid non-Git project")
        try git(["init", "--initial-branch=main"], in: folder)
        let unborn = GitSummary.inspect(directory: folder.path)
        check(unborn.isRepository && unborn.branch == "main" && unborn.changedFiles == 0, "empty Git repository supported")
        try Data("hello".utf8).write(to: folder.appendingPathComponent("before\nname.txt"))
        try git(["add", "--all"], in: folder)
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "core.hooksPath=/dev/null", "commit", "-m", "fixture"], in: folder)
        try git(["mv", "before\nname.txt", "after\nname.txt"], in: folder)
        try Data("new".utf8).write(to: folder.appendingPathComponent("untracked.txt"))
        let status = GitSummary.inspect(directory: folder.path)
        check(status.changedFiles == 2 && status.error == nil, "rename counted once; newline filenames preserve status parsing")
        try git(["checkout", "--detach"], in: folder)
        check(GitSummary.inspect(directory: folder.path).branch.hasPrefix("游离 HEAD"), "detached HEAD has useful summary")
        check(!fm.fileExists(atPath: root.appendingPathComponent("nope").path), "shell metacharacters in project path are never evaluated")
        print("PASS: \(count) project checks")
    }
}
