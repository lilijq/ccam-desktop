import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

@main struct ChatAttachmentTests {
    static var checks = 0
    static func check(_ result: @autoclosure () throws -> Bool, _ reason: String) {
        checks += 1
        if (try? result()) != true { fputs("FAIL: \(reason)\n", stderr); exit(1) }
    }
    static func rejected(_ reason: String, _ block: () throws -> Void) {
        do { try block(); check(false, reason) } catch { check(true, reason) }
    }
    static func image(_ type: UTType, width: Int = 2, height: Int = 2) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ccam-attachments-" + UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let project = ProjectRecord(id: UUID(), name: "Attachment fixture", path: root.path, createdAt: Date(), lastOpenedAt: Date(), archived: false)
        let store = ChatAttachmentStore(project: project, rootURL: root.appendingPathComponent("copies"))
        func file(_ name: String, _ data: Data = Data("example content".utf8)) throws -> URL {
            let path = root.appendingPathComponent(name); try data.write(to: path); return path
        }
        let original = try file("quote\" with space.txt")
        let copy = try store.stageFiles([original])[0]
        check(copy.kind == .file && copy.byteCount == 15 && copy.mediaType == nil, "plain file metadata")
        let copiedURL = try store.url(for: copy)
        check(copiedURL.path != original.path && copiedURL.path.hasPrefix(store.rootURL.path + "/"), "original becomes a private stable copy")
        try Data("changed original".utf8).write(to: original)
        try store.validate([copy])
        check(try String(contentsOf: copiedURL, encoding: .utf8) == "example content", "later changes to original do not change attachment")
        let reference = try store.fileReference(for: copy)
        check(reference.contains("\\\"") && reference.contains(store.rootURL.path), "file prompt uses an escaped explicit path")
        let dirs = try store.readableDirectories(for: [copy])
        check(dirs == [copiedURL.deletingLastPathComponent().path], "only selected attachment directory is granted")
        let metadata = try JSONEncoder().encode(copy)
        check(!String(decoding: metadata, as: UTF8.self).contains("example content"), "metadata never embeds file bytes")
        check(try JSONDecoder().decode(ChatAttachment.self, from: metadata) == copy, "metadata survives save and reopen")
        let mode = try fm.attributesOfItem(atPath: copiedURL.path)[.posixPermissions] as? NSNumber
        check(mode?.intValue == 0o600, "stored attachment is owner-only")
        let empty = try store.stageFiles([file("empty.txt", Data())])[0]
        check(empty.byteCount == 0, "empty ordinary files are allowed")
        let svg = try store.stageFiles([file("diagram.svg", Data("<svg/>".utf8))])[0]
        check(svg.kind == .file, "vector source is available as a file")

        for (type, expected) in [(UTType.png, "image/png"), (.jpeg, "image/jpeg"), (.gif, "image/gif")] {
            let item = try store.stageImage(data: image(type), name: "fixture." + type.preferredFilenameExtension!)
            let block = try store.imageContentBlock(for: item)
            let source = block["source"] as! [String: String]
            check(item.isImage && item.mediaType == expected, "image type detected from bytes")
            check(block["type"] as? String == "image" && source["type"] == "base64" && source["media_type"] == expected, "structured image block matches CLI protocol")
            check(Data(base64Encoded: source["data"]!) == image(type), "image bytes are preserved for model input")
            check(try store.readableDirectories(for: [item]).isEmpty, "inline images do not broaden file access")
        }
        let tiff = try store.stageImage(data: image(.tiff), name: "Clipboard.tiff")
        check(tiff.mediaType == "image/png" && tiff.name == "Clipboard.png", "clipboard TIFF is normalized locally")
        let renamed = try store.stageImage(data: image(.png), name: "../bad:name\n.png")
        check(!renamed.name.contains("/") && !renamed.name.contains(":") && !renamed.name.contains("\n"), "untrusted display names cannot create a path")
        let long = try store.stageImage(data: image(.png), name: String(repeating: "图", count: 120) + ".png")
        check(long.name.utf8.count <= 180, "filename bounds are byte-aware")
        let disguised = try store.stageFiles([file("not-an-extension.bin", image(.png))])[0]
        check(disguised.isImage, "image classification is not based on extension alone")
        rejected("invalid clipboard data rejected") { _ = try store.stageImage(data: Data("not image".utf8)) }
        rejected("overwide images rejected before pixel decoding") { _ = try store.stageImage(data: image(.png, width: 8001, height: 1)) }
        rejected("overhigh images rejected before pixel decoding") { _ = try store.stageImage(data: image(.png, width: 1, height: 8001)) }
        var overLimitImage = image(.png); overLimitImage.append(Data(repeating: 0, count: ChatAttachmentStore.maximumImageBytes))
        rejected("image byte limit enforced separately from file limit") { _ = try store.stageImage(data: overLimitImage) }
        rejected("broken image file rejected") { _ = try store.stageFiles([file("broken.png", Data("oops".utf8))]) }
        rejected("directory rejected") { _ = try store.stageFiles([root]) }
        rejected("remote URL rejected") { _ = try store.stageFiles([URL(string: "https://example.invalid/image.png")!]) }
        let pipe = root.appendingPathComponent("named-pipe"); precondition(mkfifo(pipe.path, 0o600) == 0)
        rejected("nonregular files reject without blocking") { _ = try store.stageFiles([pipe]) }
        let link = root.appendingPathComponent("selected-link.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: original)
        let linkCopy = try store.stageFiles([link])[0]
        check(try String(contentsOf: store.url(for: linkCopy), encoding: .utf8) == "changed original", "explicitly selected symlink is copied from its resolved regular file")

        func altered(_ item: ChatAttachment, id: String? = nil, path: String? = nil, size: Int? = nil, hash: String? = nil) -> ChatAttachment {
            ChatAttachment(id: id ?? item.id, name: item.name, relativePath: path ?? item.relativePath,
                           kind: item.kind, byteCount: size ?? item.byteCount, mediaType: item.mediaType, sha256: hash ?? item.sha256)
        }
        rejected("traversal reference rejected") { _ = try store.url(for: altered(copy, path: "../quote.txt")) }
        rejected("invalid ID rejected") { _ = try store.url(for: altered(copy, id: "..")) }
        rejected("length mismatch rejected") { try store.validate([altered(copy, size: 5)]) }
        rejected("hash mismatch rejected") { try store.validate([altered(copy, hash: String(repeating: "0", count: 64))]) }
        rejected("duplicate attachment identities rejected") { try store.validate([copy, copy]) }
        let other = ChatAttachmentStore(project: project, rootURL: root.appendingPathComponent("other-project"))
        rejected("project attachments cannot resolve in another store") { try other.validate([copy]) }
        let changed = try store.stageFiles([file("mutable.txt")])[0]
        try Data("tamperedcontent".utf8).write(to: store.url(for: changed))
        rejected("mutation with unchanged length rejected") { try store.validate([changed]) }
        let replaced = try store.stageFiles([file("replaced.txt")])[0], replacedURL = try store.url(for: replaced)
        try fm.removeItem(at: replacedURL); try fm.createSymbolicLink(at: replacedURL, withDestinationURL: original)
        rejected("stored file symlink cannot escape its directory") { try store.validate([replaced]) }

        let big = try file("big.bin", Data(repeating: 1, count: ChatAttachmentStore.maximumFileBytes + 1))
        rejected("oversized files fail before reading the contents") { _ = try store.stageFiles([big]) }
        rejected("oversized clipboard fails before image decoding") { _ = try store.stageImage(data: Data(repeating: 0, count: ChatAttachmentStore.maximumFileBytes + 1)) }
        let maxFile = try store.stageFiles([file("max.bin", Data(repeating: 2, count: ChatAttachmentStore.maximumFileBytes))])[0]
        rejected("total limit includes existing draft attachments") { _ = try store.stageFiles([file("extra.bin", Data(repeating: 3, count: 6 * 1024 * 1024))], existing: [maxFile]) }
        let ten = try store.stageFiles((0..<10).map { try file("small-\($0).txt") })
        rejected("count limit includes existing attachments") { _ = try store.stageImage(data: image(.png), existing: ten) }
        let before = try fm.contentsOfDirectory(atPath: store.rootURL.path)
        rejected("failed batch rolls back only its own new copies") { _ = try store.stageFiles([original, big]) }
        check(try fm.contentsOfDirectory(atPath: store.rootURL.path).sorted() == before.sorted(), "batch failure leaves no partial imports")
        try store.validate([copy])
        let removed = try store.stageFiles([file("discard.txt")])[0], removalURL = try store.url(for: removed)
        try store.removeDraftCopy(removed)
        check(!fm.fileExists(atPath: removalURL.path) && !fm.fileExists(atPath: removalURL.deletingLastPathComponent().path), "explicit draft removal deletes only owned copy")
        check(fm.fileExists(atPath: root.appendingPathComponent("discard.txt").path), "draft removal preserves original")
        check(!fm.fileExists(atPath: copiedURL.deletingLastPathComponent().appendingPathComponent("unrelated").path), "no extra files created")
        print("PASS: \(checks) local attachment checks; no CLI, credentials, or network requests")
    }
}
