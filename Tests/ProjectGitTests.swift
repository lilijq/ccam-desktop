import Foundation

@main struct ProjectGitTests {
    static var count = 0
    static func check(_ value: Bool, _ name: String) { count += 1; if !value { fputs("FAIL: \(name)\n", stderr); exit(1) } }
    static func rejects(_ name: String, _ action: () throws -> Void) { do { try action(); check(false, name) } catch { check(true, name) } }
    static func git(_ root: URL, _ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args; p.currentDirectoryURL = root
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit(); if p.terminationStatus != 0 { throw ProjectGitError.message("fixture git failed: \(args)") }
    }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ccam-git-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try git(root, ["init", "-q"])
        try git(root, ["config", "--local", "user.name", "CCAM Fixture"])
        try git(root, ["config", "--local", "user.email", "fixture@example.invalid"])
        try git(root, ["config", "--local", "commit.gpgsign", "false"])
        try git(root, ["config", "--local", "core.hooksPath", root.appendingPathComponent(".git/empty-hooks").path])
        let client = try ProjectGitClient(directory: root.path)
        let names = ["hello file.txt", "-flag.txt", ":(glob)*.txt", "line\nbreak.txt", "汉字.txt"]
        for name in names { try Data("hello\n".utf8).write(to: root.appendingPathComponent(name)) }
        var state = try client.status()
        check(!state.hasHead && !state.branch.isEmpty, "unborn branch is supported")
        check(Set(state.files.map(\.path)) == Set(names), "spaces, flag-looking names, pathspec syntax, Unicode and newline names parse exactly")
        let magic = state.files.first { $0.path == ":(glob)*.txt" }!
        check(try client.diff(magic).contains("+hello"), "new file diff is available before staging")
        try client.stage(magic); state = try client.status()
        check(state.files.filter(\.staged).map(\.path) == [magic.path], "stage treats Git pathspec syntax literally")
        try Data("edited after staging\n".utf8).write(to: root.appendingPathComponent(magic.path))
        state = try client.status()
        try client.unstage(state.files.first { $0.path == magic.path }!); state = try client.status()
        check(state.files.allSatisfy(\.untracked), "unstaging an unborn branch preserves working files")
        check(try String(contentsOf: root.appendingPathComponent(magic.path), encoding: .utf8) == "edited after staging\n", "unborn unstage preserves edits made after staging")
        for name in ["hello file.txt", "-flag.txt"] { try client.stage(state.files.first { $0.path == name }!) }
        try client.commit(message: "First fixture commit\n\nNo shell interpolation $(touch ignored).")
        state = try client.status()
        check(state.hasHead && state.files.count == 3, "commit records staged files only")
        check(!fm.fileExists(atPath: root.appendingPathComponent("ignored").path), "commit message is passed as one argument")
        let external = fm.temporaryDirectory.appendingPathComponent("ccam-external-\(UUID().uuidString)")
        try Data("EXTERNAL-PRIVATE-CONTENT".utf8).write(to: external)
        defer { try? fm.removeItem(at: external) }
        try fm.createSymbolicLink(at: root.appendingPathComponent("external-link"), withDestinationURL: external)
        let link = try client.status().files.first { $0.path == "external-link" }!
        let linkDiff = try client.diff(link)
        check(linkDiff.contains(external.path) && !linkDiff.contains("EXTERNAL-PRIVATE-CONTENT"), "Git diff shows a symlink itself without reading its external target")
        try Data("hello\nchanged\n".utf8).write(to: root.appendingPathComponent("hello file.txt"))
        state = try client.status(); let modified = state.files.first { $0.path == "hello file.txt" }!
        check(modified.unstaged && !modified.staged, "working changes are distinguished from index changes")
        check(try client.diff(modified).contains("+changed"), "working file diff includes edit")
        try client.stage(modified); state = try client.status()
        let staged = state.files.first { $0.path == modified.path }!
        check(try client.diff(staged).contains("已暂存"), "staged diff has a clear section")
        try client.unstage(staged)
        check(try String(contentsOf: root.appendingPathComponent(modified.path), encoding: .utf8).contains("changed"), "unstage preserves working edits")
        try git(root, ["mv", "--", "-flag.txt", "renamed file.txt"])
        state = try client.status(); let renamed = state.files.first { $0.path == "renamed file.txt" }!
        check(renamed.originalPath == "-flag.txt" && renamed.staged, "NUL-separated rename paths parse in the correct order")
        try client.unstage(renamed)
        check(fm.fileExists(atPath: root.appendingPathComponent("renamed file.txt").path), "unstaging rename does not remove renamed working file")
        rejects("empty commit message rejected") { try client.commit(message: " \n") }
        rejects("outside path rejected") { try client.stage(ProjectGitFile(path: "../outside", originalPath: nil, index: "?", working: "?")) }
        let nested = root.appendingPathComponent("nested"); try fm.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data("nested\n".utf8).write(to: nested.appendingPathComponent("inside.txt"))
        let nestedClient = try ProjectGitClient(directory: nested.path)
        let nestedState = try nestedClient.status()
        check(nestedState.files.map(\.path) == ["inside.txt"], "nested project status is scoped and relative to that project")
        try nestedClient.stage(nestedState.files[0])
        state = try client.status(); try client.stage(state.files.first { $0.path == "hello file.txt" }!)
        rejects("nested project cannot silently commit outside staged files") { try nestedClient.commit(message: "Should not commit outside") }
        let separate = root.appendingPathComponent(".git/nonrepository"); try fm.createDirectory(at: separate, withIntermediateDirectories: false)
        rejects("nonrepository has a clear error") { _ = try ProjectGitClient(directory: separate.path).status() }
        print("PASS: \(count) project Git checks")
    }
}
