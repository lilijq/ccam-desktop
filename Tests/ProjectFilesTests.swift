import Foundation
import Darwin

@main struct ProjectFilesTests {
    static var count = 0
    static func check(_ value: Bool, _ name: String) { count += 1; if !value { fputs("FAIL: \(name)\n", stderr); exit(1) } }
    static func rejects(_ name: String, _ action: () throws -> Void) { do { try action(); check(false, name) } catch { check(true, name) } }
    static func aclText(_ path: String) -> String {
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else { return "" }; defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var size = 0
        guard let text = acl_to_text(acl, &size) else { return "" }; defer { acl_free(text) }
        return String(cString: text)
    }
    static func main() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("ccam-files-\(UUID().uuidString)")
        let project = fixture.appendingPathComponent("project"), outside = fixture.appendingPathComponent("outside")
        try fm.createDirectory(at: project.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let file = project.appendingPathComponent("中文 notes & file.txt")
        try Data("first\n中文\n".utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        let permissions = Process(); permissions.executableURL = URL(fileURLWithPath: "/bin/chmod"); permissions.arguments = ["+a", "everyone allow read", file.path]
        try permissions.run(); permissions.waitUntilExit()
        check(permissions.terminationStatus == 0, "temporary ACL fixture created")
        let originalACL = aclText(file.path)
        try Data("nested".utf8).write(to: project.appendingPathComponent("folder/deep.txt"))
        let store = try ProjectFileStore(directory: project.path)
        let entries = try store.entries()
        check(entries.count == 2 && entries.first?.isDirectory == true, "directory listing is shallow and folders sort first")
        let nested = try store.entries(in: "folder")
        check(nested.count == 1 && nested[0].path == "folder/deep.txt", "directory navigation retains relative paths")
        let original = try store.read(file.lastPathComponent)
        check(original.text == "first\n中文\n", "UTF-8 and special filenames read exactly")
        let saved = try store.save(original, text: "edited\n中文\n")
        check(try String(contentsOf: file, encoding: .utf8) == saved.text, "atomic save writes requested text")
        check((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640, "atomic replacement preserves permissions")
        check(!originalACL.isEmpty && aclText(file.path) == originalACL, "atomic replacement preserves macOS access-control entries")
        let twice = try store.save(saved, text: "saved twice")
        check(twice.text == "saved twice", "returned snapshot can be saved again without a false conflict")
        try Data("external change".utf8).write(to: file)
        rejects("external change blocks overwrite") { _ = try store.save(twice, text: "lost update") }
        check(try String(contentsOf: file, encoding: .utf8) == "external change", "conflict leaves external contents unchanged")
        let current = try store.read(file.lastPathComponent)
        try fm.removeItem(at: file); try Data(current.text.utf8).write(to: file)
        rejects("replacement with equal contents still conflicts") { _ = try store.save(current, text: "wrong identity") }
        let secret = outside.appendingPathComponent("secret.txt"); try Data("OUTSIDE-CONTENT".utf8).write(to: secret)
        try fm.createSymbolicLink(at: project.appendingPathComponent("outside-link"), withDestinationURL: secret)
        try fm.createSymbolicLink(at: project.appendingPathComponent("outside-dir"), withDestinationURL: outside)
        rejects("outside symlink cannot be read") { _ = try store.read("outside-link") }
        rejects("outside symlink directory cannot be navigated") { _ = try store.entries(in: "outside-dir") }
        let blocked = try store.entries().first { $0.name == "outside-link" }
        check(blocked?.blocked == true, "outside links are visibly blocked in the list")
        rejects("parent traversal rejected") { _ = try store.read("../outside/secret.txt") }
        rejects("absolute paths rejected") { _ = try store.read(secret.path) }
        let beforeSwap = try store.read(file.lastPathComponent)
        try fm.removeItem(at: file); try fm.createSymbolicLink(at: file, withDestinationURL: secret)
        rejects("file changed into outside symlink cannot be saved") { _ = try store.save(beforeSwap, text: "overwrite outside") }
        check(try String(contentsOf: secret, encoding: .utf8) == "OUTSIDE-CONTENT", "outside target is untouched")
        try fm.createSymbolicLink(at: project.appendingPathComponent("internal-link"), withDestinationURL: project.appendingPathComponent("folder/deep.txt"))
        let alias = try store.read("internal-link")
        _ = try store.save(alias, text: "through internal link")
        check(try String(contentsOf: project.appendingPathComponent("folder/deep.txt"), encoding: .utf8) == "through internal link", "safe internal symlinks update the in-project target")
        check((try fm.attributesOfItem(atPath: project.appendingPathComponent("internal-link").path)[.type] as? FileAttributeType) == .typeSymbolicLink, "internal symlink itself is preserved")
        try Data([0, 1, 2]).write(to: project.appendingPathComponent("binary"))
        try Data([0xff, 0xfe]).write(to: project.appendingPathComponent("legacy-encoding"))
        rejects("binary text rejected") { _ = try store.read("binary") }
        rejects("invalid UTF-8 rejected") { _ = try store.read("legacy-encoding") }
        let small = try ProjectFileStore(directory: project.path, maximumBytes: 4)
        rejects("oversized file rejected") { _ = try small.read("folder/deep.txt") }
        check(!(try store.entries()).contains { $0.name.hasPrefix(".ccam-edit-") }, "temporary save files are cleaned up")
        print("PASS: \(count) project file checks")
    }
}
