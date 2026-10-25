import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

struct ChatAttachment: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case image, file }
    let id: String
    let name: String
    let relativePath: String
    let kind: Kind
    let byteCount: Int
    let mediaType: String?
    let sha256: String
    var isImage: Bool { kind == .image }
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file) }
}

enum ChatAttachmentError: LocalizedError {
    case invalidFile, tooLarge, tooMany, invalidImage, changed, invalidReference
    var errorDescription: String? {
        switch self {
        case .invalidFile: return "请选择可读取的普通文件，不支持文件夹。"
        case .tooLarge: return "图片限 3 MB，文件及一次附件总计限 20 MB。"
        case .tooMany: return "一次最多添加 10 个附件。"
        case .invalidImage: return "无法读取这张图片，请使用 PNG、JPEG、GIF、WebP 或可转换的本机图片。"
        case .changed: return "附件已被修改或丢失，请重新添加。"
        case .invalidReference: return "附件位置无效，请重新添加。"
        }
    }
}

/// User-selected files are copied into a private project-specific directory.
/// Only references and hashes go in chat JSON; image bytes are read at send time.
final class ChatAttachmentStore {
    static let maximumCount = 10
    static let maximumImageBytes = 3 * 1024 * 1024
    static let maximumFileBytes = 20 * 1024 * 1024
    static let maximumTotalBytes = 20 * 1024 * 1024
    let rootURL: URL

    init(project: ProjectRecord, rootURL: URL? = nil) {
        self.rootURL = (rootURL ?? ProjectStore.defaultURL.deletingLastPathComponent()
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(project.id.uuidString, isDirectory: true))
            .standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Returns only the newly imported attachments. A failed batch removes its
    /// own new copies, never existing drafts or message attachments.
    func stageFiles(_ urls: [URL], existing: [ChatAttachment] = []) throws -> [ChatAttachment] {
        guard existing.count + urls.count <= Self.maximumCount else { throw ChatAttachmentError.tooMany }
        try validate(existing)
        var added: [ChatAttachment] = []
        do {
            for source in urls {
                guard source.isFileURL else { throw ChatAttachmentError.invalidFile }
                let data = try readBounded(source.resolvingSymlinksInPath(), limit: Self.maximumFileBytes)
                let attachment = try stage(data: data, name: source.lastPathComponent, requireImage: false,
                                           existing: existing + added)
                added.append(attachment)
            }
            return added
        } catch {
            for attachment in added { try? removeDraftCopy(attachment) }
            throw error
        }
    }

    /// Accepts clipboard PNG/TIFF data; unsupported native image encodings are
    /// normalized to PNG locally. No remote conversion or upload occurs here.
    func stageImage(data: Data, name: String = "Clipboard.png", existing: [ChatAttachment] = []) throws -> ChatAttachment {
        guard data.count <= Self.maximumFileBytes else { throw ChatAttachmentError.tooLarge }
        guard existing.count < Self.maximumCount else { throw ChatAttachmentError.tooMany }
        try validate(existing)
        return try stage(data: data, name: name, requireImage: true, existing: existing)
    }

    func validate(_ attachments: [ChatAttachment]) throws {
        guard attachments.count <= Self.maximumCount else { throw ChatAttachmentError.tooMany }
        guard Set(attachments.map(\.id)).count == attachments.count else { throw ChatAttachmentError.invalidReference }
        var total = 0
        for attachment in attachments {
            guard attachment.byteCount >= 0,
                  attachment.byteCount <= (attachment.isImage ? Self.maximumImageBytes : Self.maximumFileBytes) else { throw ChatAttachmentError.tooLarge }
            total += attachment.byteCount
            guard total <= Self.maximumTotalBytes else { throw ChatAttachmentError.tooLarge }
            _ = try verifiedData(attachment)
        }
    }

    /// Resolve only the exact UUID/name location created by this store. A later
    /// symlink replacement cannot turn a saved reference into another file.
    func url(for attachment: ChatAttachment) throws -> URL {
        guard rootURL.isFileURL, UUID(uuidString: attachment.id) != nil, attachment.name == safeName(attachment.name),
              attachment.relativePath == attachment.id + "/" + attachment.name,
              rootURL.resolvingSymlinksInPath().path == rootURL.path else { throw ChatAttachmentError.invalidReference }
        let directory = rootURL.appendingPathComponent(attachment.id, isDirectory: true)
        let result = directory.appendingPathComponent(attachment.name)
        guard result.standardizedFileURL.path == result.path,
              directory.resolvingSymlinksInPath().path == directory.path,
              result.resolvingSymlinksInPath().path == result.path else { throw ChatAttachmentError.invalidReference }
        return result
    }

    func imageContentBlock(for attachment: ChatAttachment) throws -> [String: Any] {
        guard attachment.isImage, let mediaType = attachment.mediaType else { throw ChatAttachmentError.invalidImage }
        let data = try verifiedData(attachment)
        return ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": data.base64EncodedString()]]
    }

    func fileReference(for attachment: ChatAttachment) throws -> String {
        guard !attachment.isImage else { throw ChatAttachmentError.invalidReference }
        _ = try verifiedData(attachment)
        let path = try url(for: attachment).path
        func quoted(_ value: String) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
        }
        return "附件文件：\(try quoted(attachment.name))\n本机路径：\(try quoted(path))"
    }

    func readableDirectories(for attachments: [ChatAttachment]) throws -> [String] {
        try validate(attachments)
        return try attachments.filter { !$0.isImage }.map { try url(for: $0).deletingLastPathComponent().path }
    }

    /// Call only for a discarded draft copy known not to be referenced by history.
    func removeDraftCopy(_ attachment: ChatAttachment) throws {
        let file = try url(for: attachment)
        _ = try verifiedData(attachment)
        try FileManager.default.removeItem(at: file)
        // rmdir only removes the now-empty UUID directory; never recurse into it.
        _ = file.deletingLastPathComponent().path.withCString { rmdir($0) }
    }

    private func stage(data original: Data, name originalName: String, requireImage: Bool,
                       existing: [ChatAttachment]) throws -> ChatAttachment {
        var data = original, name = safeName(originalName), kind: ChatAttachment.Kind = .file
        var mediaType: String?
        if let source = CGImageSourceCreateWithData(original as CFData, nil), let type = CGImageSourceGetType(source) as String? {
            guard CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                  let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
                  width.doubleValue > 0, height.doubleValue > 0,
                  width.doubleValue <= 8000, height.doubleValue <= 8000,
                  width.doubleValue * height.doubleValue <= 40_000_000 else { throw ChatAttachmentError.invalidImage }
            kind = .image; mediaType = Self.mime(type)
            if mediaType == nil {
                guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ChatAttachmentError.invalidImage }
                let converted = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(converted, UTType.png.identifier as CFString, 1, nil) else { throw ChatAttachmentError.invalidImage }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw ChatAttachmentError.invalidImage }
                data = converted as Data; mediaType = "image/png"
                name = safeName((name as NSString).deletingPathExtension + ".png")
            }
        } else if requireImage || ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "avif"].contains((name as NSString).pathExtension.lowercased()) {
            throw ChatAttachmentError.invalidImage
        }
        let limit = kind == .image ? Self.maximumImageBytes : Self.maximumFileBytes
        guard data.count <= limit, existing.reduce(0, { $0 + $1.byteCount }) + data.count <= Self.maximumTotalBytes else { throw ChatAttachmentError.tooLarge }
        let id = UUID().uuidString
        let attachment = ChatAttachment(id: id, name: name, relativePath: id + "/" + name,
                                        kind: kind, byteCount: data.count, mediaType: mediaType, sha256: Self.digest(data))
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = try url(for: attachment), directory = file.deletingLastPathComponent()
        guard directory.path.withCString({ mkdir($0, 0o700) }) == 0 else { throw ChatAttachmentError.invalidFile }
        do {
            let descriptor = file.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
            guard descriptor >= 0 else { throw ChatAttachmentError.invalidFile }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: data); try handle.close()
            return attachment
        } catch {
            try? FileManager.default.removeItem(at: file)
            _ = directory.path.withCString { rmdir($0) }
            throw error
        }
    }

    private func verifiedData(_ attachment: ChatAttachment) throws -> Data {
        let file = try url(for: attachment)
        let limit = attachment.isImage ? Self.maximumImageBytes : Self.maximumFileBytes
        guard attachment.byteCount >= 0, attachment.byteCount <= limit else { throw ChatAttachmentError.tooLarge }
        let data: Data
        do { data = try readBounded(file, limit: limit) } catch { throw ChatAttachmentError.changed }
        guard data.count == attachment.byteCount, Self.digest(data) == attachment.sha256 else { throw ChatAttachmentError.changed }
        if attachment.isImage {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let type = CGImageSourceGetType(source) as String?,
                  Self.mime(type) == attachment.mediaType else { throw ChatAttachmentError.invalidImage }
        } else if attachment.mediaType != nil { throw ChatAttachmentError.invalidReference }
        return data
    }

    private func readBounded(_ file: URL, limit: Int) throws -> Data {
        let descriptor = file.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard descriptor >= 0 else { throw ChatAttachmentError.invalidFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw ChatAttachmentError.invalidFile }
        guard before.st_size >= 0, before.st_size <= limit else { throw ChatAttachmentError.tooLarge }
        var data = Data()
        while let bytes = try handle.read(upToCount: min(65_536, limit + 1 - data.count)), !bytes.isEmpty {
            data.append(bytes)
            guard data.count <= limit else { throw ChatAttachmentError.tooLarge }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              data.count == before.st_size else { throw ChatAttachmentError.changed }
        return data
    }

    private func safeName(_ input: String) -> String {
        var result = input.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || "/:\\".unicodeScalars.contains(scalar) ? "_" : String(scalar)
        }.joined()
        while result.utf8.count > 180 { result.removeLast() }
        if result.isEmpty || result == "." || result == ".." { result = "attachment" }
        return result
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func mime(_ identifier: String) -> String? {
        switch identifier {
        case UTType.png.identifier: return "image/png"
        case UTType.jpeg.identifier: return "image/jpeg"
        case UTType.gif.identifier: return "image/gif"
        case UTType.webP.identifier: return "image/webp"
        default: return nil
        }
    }
}
