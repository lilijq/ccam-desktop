import Foundation
import Darwin
import CryptoKit
#if !PROJECT_FILES_CORE_ONLY
import AppKit
#endif

enum ProjectFileError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
struct ProjectFileEntry {
    let name: String
    let path: String
    let isDirectory: Bool
    let blocked: Bool
}
struct ProjectFileVersion: Equatable {
    let device: Int32, inode: UInt64, size: Int64
    let modified: Int, modifiedNS: Int, changed: Int, changedNS: Int
    let digest: String
    init(_ value: stat, data: Data) {
        device = value.st_dev; inode = value.st_ino; size = value.st_size
        modified = value.st_mtimespec.tv_sec; modifiedNS = value.st_mtimespec.tv_nsec
        changed = value.st_ctimespec.tv_sec; changedNS = value.st_ctimespec.tv_nsec
        digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
struct ProjectFileSnapshot {
    let path: String
    let resolvedPath: String
    let text: String
    let version: ProjectFileVersion
}
struct ProjectFileInfo {
    let path: String
    let resolvedPath: String
    let byteCount: Int64
}

/// All handles are opened beneath the canonical project root. Symlinks are
/// resolved and checked first; descriptor traversal then refuses replacement links.
final class ProjectFileStore {
    let root: URL
    let maximumBytes: Int
    init(directory: String, maximumBytes: Int = 2 * 1024 * 1024) throws {
        root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        self.maximumBytes = maximumBytes
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw ProjectFileError.message("项目目录不可访问。") }
    }
    private func canonical(_ relative: String) throws -> (URL, String) {
        guard !relative.hasPrefix("/"), !relative.contains("\0"), !relative.split(separator: "/").contains("..") else { throw ProjectFileError.message("只能访问当前项目内的文件。") }
        let url = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path == "/" ? "/" : root.path + "/"
        guard url.path == root.path || url.path.hasPrefix(prefix) else { throw ProjectFileError.message("此链接指向项目外，不能打开或保存。") }
        return (url, url.path == root.path ? "" : String(url.path.dropFirst(prefix.count)))
    }
    private func withDirectory<T>(_ components: [Substring], _ body: (Int32) throws -> T) throws -> T {
        var descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ProjectFileError.message("无法打开项目目录。") }
        defer { Darwin.close(descriptor) }
        for component in components {
            let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ProjectFileError.message("目录已移动、不可访问或链接发生变化。") }
            Darwin.close(descriptor); descriptor = next
        }
        return try body(descriptor)
    }
    private func withParent<T>(_ relative: String, _ body: (Int32, String, String) throws -> T) throws -> T {
        let (_, resolved) = try canonical(relative)
        let parts = resolved.split(separator: "/")
        guard let last = parts.last else { throw ProjectFileError.message("请选择一个文件。") }
        return try withDirectory(Array(parts.dropLast())) { try body($0, String(last), resolved) }
    }
    func entries(in relative: String = "") throws -> [ProjectFileEntry] {
        let (_, resolved) = try canonical(relative)
        return try withDirectory(resolved.split(separator: "/")) { descriptor in
            let copied = dup(descriptor)
            guard copied >= 0, let stream = fdopendir(copied) else { if copied >= 0 { Darwin.close(copied) }; throw ProjectFileError.message("无法读取文件夹。") }
            defer { closedir(stream) }
            var entries: [ProjectFileEntry] = []
            while let item = readdir(stream) {
                let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                let path = relative.isEmpty ? name : relative + "/" + name
                var metadata = stat()
                guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                var isDirectory = (metadata.st_mode & S_IFMT) == S_IFDIR
                var blocked = false
                if (metadata.st_mode & S_IFMT) == S_IFLNK {
                    do {
                        let (target, _) = try canonical(path)
                        var directory: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &directory) else { throw ProjectFileError.message("链接目标不存在。") }
                        isDirectory = directory.boolValue
                    } catch { blocked = true }
                }
                entries.append(ProjectFileEntry(name: name, path: path, isDirectory: isDirectory, blocked: blocked))
            }
            return entries.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
    private func readHandle(_ descriptor: Int32, limit: Int? = nil) throws -> (Data, stat) {
        let maximumBytes = limit ?? self.maximumBytes
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else { throw ProjectFileError.message("只支持普通文本文件。") }
        guard before.st_size <= maximumBytes else { throw ProjectFileError.message("文件超过 \(maximumBytes / 1024 / 1024) MB，请使用外部编辑器。") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw ProjectFileError.message("读取文件失败。") }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw ProjectFileError.message("文件太大，无法在这里编辑。") }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, ProjectFileVersion(before, data: data) == ProjectFileVersion(after, data: data) else { throw ProjectFileError.message("文件正在被其他程序修改，请重新打开。") }
        return (data, after)
    }
    private func readAt(_ parent: Int32, name: String, limit: Int? = nil) throws -> (Data, stat) {
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ProjectFileError.message("文件不可访问，或链接已发生变化。") }
        defer { Darwin.close(descriptor) }
        return try readHandle(descriptor, limit: limit)
    }
    func read(_ relative: String) throws -> ProjectFileSnapshot {
        try withParent(relative) { parent, name, resolved in
            let (data, metadata) = try readAt(parent, name: name)
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw ProjectFileError.message("这是二进制文件或非 UTF-8 文本，不能在这里编辑。") }
            return ProjectFileSnapshot(path: relative, resolvedPath: resolved, text: text, version: ProjectFileVersion(metadata, data: data))
        }
    }
    /// Raster previews share the same rooted, bounded descriptor read as text.
    /// SVG/HTML are intentionally handled as source, never executed in a web view.
    func previewData(_ relative: String, maximumBytes: Int = 32 * 1024 * 1024) throws -> Data {
        try withParent(relative) { parent, name, _ in try readAt(parent, name: name, limit: maximumBytes).0 }
    }
    func previewInfo(_ relative: String) throws -> ProjectFileInfo {
        try withParent(relative) { parent, name, resolved in
            let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw ProjectFileError.message("文件不可访问，或链接已发生变化。") }
            defer { Darwin.close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { throw ProjectFileError.message("只能打开普通文件。") }
            return ProjectFileInfo(path: relative, resolvedPath: resolved, byteCount: metadata.st_size)
        }
    }
    func externalURL(for info: ProjectFileInfo) throws -> URL {
        let current = try previewInfo(info.path)
        guard current.resolvedPath == info.resolvedPath else { throw ProjectFileError.message("文件链接已变化，请重新打开。") }
        return root.appendingPathComponent(current.resolvedPath)
    }
    func save(_ snapshot: ProjectFileSnapshot, text: String) throws -> ProjectFileSnapshot {
        let data = Data(text.utf8)
        guard data.count <= maximumBytes else { throw ProjectFileError.message("内容超过文件大小限制，未保存。") }
        return try withParent(snapshot.path) { parent, name, resolved in
            guard resolved == snapshot.resolvedPath else { throw ProjectFileError.message("文件链接已变化。请重新打开，修改内容仍保留。") }
            let (existing, metadata) = try readAt(parent, name: name)
            guard ProjectFileVersion(metadata, data: existing) == snapshot.version else { throw ProjectFileError.message("文件已被其他程序修改，未覆盖。请复制当前草稿后重新打开。") }
            let temporary = ".ccam-edit-" + UUID().uuidString
            let output = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw ProjectFileError.message("无法创建保存文件，请检查目录权限。") }
            defer { Darwin.close(output); unlinkat(parent, temporary, 0) }
            let permissionsSource = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard permissionsSource >= 0 else { throw ProjectFileError.message("无法读取文件权限，原文件未修改。") }
            defer { Darwin.close(permissionsSource) }
            guard fcopyfile(permissionsSource, output, nil, copyfile_flags_t(COPYFILE_ACL)) == 0 else {
                throw ProjectFileError.message("无法保留文件访问权限，原文件未修改。")
            }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw ProjectFileError.message("写入失败，原文件未修改。") }
                    offset += count
                }
            }
            guard fchmod(output, metadata.st_mode & 0o7777) == 0, fsync(output) == 0 else { throw ProjectFileError.message("无法保留文件权限或完成写入，原文件未修改。") }
            let (latest, latestMetadata) = try readAt(parent, name: name)
            guard ProjectFileVersion(latestMetadata, data: latest) == snapshot.version else { throw ProjectFileError.message("保存期间文件发生变化，未覆盖。") }
            guard renameat(parent, temporary, parent, name) == 0 else { throw ProjectFileError.message("无法替换文件，原文件未修改。") }
            var saved = stat()
            guard fstat(output, &saved) == 0 else { throw ProjectFileError.message("文件已保存，请重新打开确认。") }
            return ProjectFileSnapshot(path: snapshot.path, resolvedPath: resolved, text: text, version: ProjectFileVersion(saved, data: data))
        }
    }
}

#if !PROJECT_FILES_CORE_ONLY
import ImageIO

private final class FileTreeNode: NSObject {
    let entry: ProjectFileEntry
    weak var parent: FileTreeNode?
    var children: [FileTreeNode]?
    var loading = false
    init(_ entry: ProjectFileEntry, parent: FileTreeNode? = nil) { self.entry = entry; self.parent = parent }
}

private final class FileBuffer {
    let path: String
    var snapshot: ProjectFileSnapshot?
    var draft: String
    var image: NSImage?
    var preview: ProjectFilePreviewView?
    var selection = NSRange(location: 0, length: 0)
    var scroll = NSPoint.zero
    let undoManager = UndoManager()
    var dirty: Bool { snapshot.map { draft != $0.text } ?? false }
    init(_ snapshot: ProjectFileSnapshot) { self.path = snapshot.path; self.snapshot = snapshot; self.draft = snapshot.text }
    init(path: String, image: NSImage) { self.path = path; self.image = image; self.draft = "" }
    init(path: String, preview: ProjectFilePreviewView) { self.path = path; self.preview = preview; self.draft = "" }
}

private final class FilesIconButton: NSButton {
    var invoke: (() -> Void)?
    init(symbol: String, title: String, action: @escaping () -> Void) {
        invoke = action
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        imagePosition = .imageOnly; isBordered = false; bezelStyle = .inline
        self.title = ""; toolTip = title; setAccessibilityLabel(title)
        target = self; self.action = #selector(pressed); contentTintColor = Theme.muted
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true; heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func pressed() { invoke?() }
}

private final class FileTreeSplitView: NSSplitView {
    private(set) var isUserResizing = false
    override var dividerColor: NSColor { Theme.border }
    override func mouseDown(with event: NSEvent) {
        isUserResizing = true; defer { isUserResizing = false }
        super.mouseDown(with: event)
    }
}

/// The tree and editor are independently scrollable. Each open file retains its
/// draft and undo stack, while disk writes still use the guarded file store.
final class ProjectFilesView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSplitViewDelegate {
    private let directory: String
    private let queue = DispatchQueue(label: "ccam.project.files", qos: .userInitiated)
    private var store: ProjectFileStore?
    private var roots: [FileTreeNode] = []
    private var expandedPaths = Set<String>()
    private var buffers: [FileBuffer] = []
    private var current: FileBuffer?
    private var pendingOpen: String?
    private var treeGeneration = 0
    private var saving = Set<String>()
    private var reloading = Set<String>()
    private var treeVisible = true
    private var preferredTreeWidth: CGFloat = 190
    private var initialLayout = true
    private var resizing = false
    private var restoringSelection = false
    private let split = FileTreeSplitView()
    private let treePane = ThemeSurface(Theme.adaptive(0xF7F7F7, 0x101010))
    private let treeScroll = ThemeScrollView()
    private let detail = ThemeSurface(Theme.adaptive(0xFFFFFF, 0x131313))
    let outline = NSOutlineView()
    let codeEditor = CodeEditorView()
    private let imageView = NSImageView()
    private let imagePane = ThemeSurface(Theme.adaptive(0xFFFFFF, 0x131313))
    private let empty = label("选择文件", size: 15, color: Theme.muted)
    private let tabScroll = ThemeScrollView()
    private let tabs = NSStackView()
    private let breadcrumb = label("", size: 11, color: Theme.muted)
    private let status = label("", size: 11, color: Theme.muted)
    private var saveButton: FilesIconButton!
    private var treeButton: FilesIconButton!
    private var findButton: FilesIconButton!
    private var fileMenuButton: FilesIconButton!
    var hasUnsavedChanges: Bool { buffers.contains { $0.dirty } }
    var openFilePaths: [String] { buffers.map(\.path) }
    var selectedFilePath: String? { current?.path }
    func focus() {
        if current?.snapshot != nil { window?.makeFirstResponder(codeEditor.textView) }
        else if let document = current?.preview?.documentTextView { window?.makeFirstResponder(document) }
        else if treeVisible { window?.makeFirstResponder(outline) }
        else { window?.makeFirstResponder(nil) }
    }

    init(directory: String) {
        self.directory = directory
        super.init(frame: .zero)
        treeButton = FilesIconButton(symbol: "sidebar.left", title: "显示或隐藏文件树") { [weak self] in self?.toggleTree() }
        saveButton = FilesIconButton(symbol: "square.and.arrow.down", title: "保存文件 ⌘S") { [weak self] in self?.save() }
        saveButton.isEnabled = false
        findButton = FilesIconButton(symbol: "magnifyingglass", title: "查找文件内容 ⌘F") { [weak self] in self?.codeEditor.find() }
        fileMenuButton = FilesIconButton(symbol: "ellipsis", title: "文件操作") { [weak self] in self?.showFileMenu() }
        let refresh = FilesIconButton(symbol: "arrow.clockwise", title: "刷新文件树") { [weak self] in self?.refreshTree() }
        let collapse = FilesIconButton(symbol: "rectangle.compress.vertical", title: "折叠文件树") { [weak self] in self?.outline.collapseItem(nil, collapseChildren: true); self?.expandedPaths.removeAll() }
        let treeTitle = label(URL(fileURLWithPath: directory).lastPathComponent, size: 12, weight: .medium)
        treeTitle.lineBreakMode = .byTruncatingMiddle; treeTitle.maximumNumberOfLines = 1; treeTitle.toolTip = directory
        let treeHeader = row([treeTitle, spacer(), collapse, refresh], spacing: 2)
        outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        outline.outlineTableColumn = outline.tableColumns[0]; outline.headerView = nil
        outline.rowHeight = 27; outline.indentationPerLevel = 14; outline.intercellSpacing = NSSize(width: 2, height: 0)
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; outline.style = .plain
        outline.delegate = self; outline.dataSource = self; outline.allowsEmptySelection = true
        outline.backgroundColor = .clear; outline.setAccessibilityLabel("项目文件树")
        outline.target = self; outline.doubleAction = #selector(doubleClickTree)
        treeScroll.documentView = outline; treeScroll.hasVerticalScroller = true; treeScroll.hasHorizontalScroller = true
        treeScroll.autohidesScrollers = true; treeScroll.drawsBackground = false; treeScroll.borderType = .noBorder
        treeHeader.translatesAutoresizingMaskIntoConstraints = false; treeScroll.translatesAutoresizingMaskIntoConstraints = false
        treePane.addSubview(treeHeader); treePane.addSubview(treeScroll)
        NSLayoutConstraint.activate([
            treeHeader.topAnchor.constraint(equalTo: treePane.topAnchor), treeHeader.leadingAnchor.constraint(equalTo: treePane.leadingAnchor, constant: 10), treeHeader.trailingAnchor.constraint(equalTo: treePane.trailingAnchor, constant: -4), treeHeader.heightAnchor.constraint(equalToConstant: 34),
            treeScroll.topAnchor.constraint(equalTo: treeHeader.bottomAnchor), treeScroll.leadingAnchor.constraint(equalTo: treePane.leadingAnchor), treeScroll.trailingAnchor.constraint(equalTo: treePane.trailingAnchor), treeScroll.bottomAnchor.constraint(equalTo: treePane.bottomAnchor)
        ])
        tabs.orientation = .horizontal; tabs.alignment = .centerY; tabs.spacing = 0
        tabScroll.documentView = tabs; tabScroll.drawsBackground = false; tabScroll.hasHorizontalScroller = true; tabScroll.autohidesScrollers = true
        tabs.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([tabs.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor), tabs.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor), tabs.heightAnchor.constraint(equalToConstant: 32)])
        let header = row([treeButton, tabScroll, findButton, saveButton, fileMenuButton], spacing: 0)
        tabScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        header.heightAnchor.constraint(equalToConstant: 34).isActive = true
        breadcrumb.lineBreakMode = .byTruncatingMiddle; breadcrumb.maximumNumberOfLines = 1
        status.maximumNumberOfLines = 2; status.lineBreakMode = .byTruncatingTail; status.isHidden = true
        empty.alignment = .center
        codeEditor.onChange = { [weak self] in self?.edited() }
        codeEditor.onSave = { [weak self] in self?.save() }
        imageView.imageScaling = .scaleProportionallyUpOrDown; imageView.translatesAutoresizingMaskIntoConstraints = false; imagePane.addSubview(imageView)
        NSLayoutConstraint.activate([imageView.topAnchor.constraint(equalTo: imagePane.topAnchor, constant: 16), imageView.bottomAnchor.constraint(equalTo: imagePane.bottomAnchor, constant: -16), imageView.leadingAnchor.constraint(equalTo: imagePane.leadingAnchor, constant: 16), imageView.trailingAnchor.constraint(equalTo: imagePane.trailingAnchor, constant: -16)])
        for view in [header, breadcrumb, codeEditor, imagePane, empty, status] { view.translatesAutoresizingMaskIntoConstraints = false; detail.addSubview(view) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: detail.leadingAnchor), header.trailingAnchor.constraint(equalTo: detail.trailingAnchor), header.topAnchor.constraint(equalTo: detail.topAnchor),
            breadcrumb.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 12), breadcrumb.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -12), breadcrumb.topAnchor.constraint(equalTo: header.bottomAnchor), breadcrumb.heightAnchor.constraint(equalToConstant: 26),
            codeEditor.topAnchor.constraint(equalTo: breadcrumb.bottomAnchor), codeEditor.leadingAnchor.constraint(equalTo: detail.leadingAnchor), codeEditor.trailingAnchor.constraint(equalTo: detail.trailingAnchor), codeEditor.bottomAnchor.constraint(equalTo: status.topAnchor),
            imagePane.topAnchor.constraint(equalTo: codeEditor.topAnchor), imagePane.leadingAnchor.constraint(equalTo: codeEditor.leadingAnchor), imagePane.trailingAnchor.constraint(equalTo: codeEditor.trailingAnchor), imagePane.bottomAnchor.constraint(equalTo: codeEditor.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: detail.centerXAnchor), empty.centerYAnchor.constraint(equalTo: detail.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 12), status.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -12), status.bottomAnchor.constraint(equalTo: detail.bottomAnchor, constant: -4)
        ])
        split.isVertical = true; split.dividerStyle = .thin; split.delegate = self
        split.addArrangedSubview(treePane); split.addArrangedSubview(detail)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0); split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        split.translatesAutoresizingMaskIntoConstraints = false; addSubview(split)
        NSLayoutConstraint.activate([split.leadingAnchor.constraint(equalTo: leadingAnchor), split.trailingAnchor.constraint(equalTo: trailingAnchor), split.topAnchor.constraint(equalTo: topAnchor), split.bottomAnchor.constraint(equalTo: bottomAnchor)])
        updateDocumentVisibility()
        queue.async { [weak self] in
            let result = Result { try ProjectFileStore(directory: directory) }
            DispatchQueue.main.async { guard let self else { return }; switch result {
                case .success(let store): self.store = store; self.refreshTree(); if let path = self.pendingOpen { self.pendingOpen = nil; self.openFile(path) }
                case .failure(let error): self.setStatus(error.localizedDescription, error: true)
            } }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        guard !resizing, split.bounds.width > 0 else { return }
        resizing = true; defer { resizing = false }
        // The first action in an empty file pane is choosing a file. Keep the
        // tree visible at every width; activate(_:) gives the editor the space
        // only after a file has actually been opened in a narrow pane.
        if initialLayout { initialLayout = false; applyTreeVisibility() }
        else if treeVisible { split.setPosition(min(preferredTreeWidth, max(115, split.bounds.width * 0.4)), ofDividerAt: 0) }
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { treeVisible ? min(115, splitView.bounds.width * 0.35) : 0 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { max(0, splitView.bounds.width - 180) }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        if split.isUserResizing, !resizing, treeVisible, treePane.frame.width > 0 { preferredTreeWidth = treePane.frame.width }
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { subview === treePane }
    private func toggleTree() { treeVisible.toggle(); applyTreeVisibility() }
    private func applyTreeVisibility() {
        treePane.isHidden = !treeVisible
        treeButton.contentTintColor = treeVisible ? Theme.text : Theme.muted
        split.adjustSubviews()
        if treeVisible { split.setPosition(min(preferredTreeWidth, max(115, split.bounds.width * 0.4)), ofDividerAt: 0) }
    }
    private func icon(for path: String, directory: Bool, expanded: Bool = false) -> NSImage? {
        if directory { return NSImage(systemSymbolName: expanded ? "folder.fill" : "folder", accessibilityDescription: "目录") }
        let symbol: String, description: String
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "avif": symbol = "photo"; description = "图片"
        case "pdf", "doc", "docx", "odt", "rtf", "pages": symbol = "doc.richtext"; description = "文档"
        case "xls", "xlsx", "csv", "numbers": symbol = "tablecells"; description = "表格"
        case "ppt", "pptx", "key": symbol = "rectangle.on.rectangle"; description = "演示文稿"
        case "zip", "gz", "tar", "bz2", "xz", "7z", "rar": symbol = "archivebox"; description = "压缩文件"
        case "mp3", "wav", "m4a", "aac", "flac", "ogg", "aiff": symbol = "waveform"; description = "音频"
        case "mp4", "mov", "m4v", "mkv", "webm", "avi": symbol = "film"; description = "视频"
        default: symbol = CodeLanguage.detect(path: path).icon; description = CodeLanguage.detect(path: path).rawValue
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: description)
    }
    private func tint(for path: String, isDirectory: Bool) -> NSColor {
        if isDirectory { return Theme.muted }
        switch CodeLanguage.detect(path: path) {
        case .rust: return Theme.adaptive(0x9B4A2A, 0xD69D85)
        case .swift: return Theme.adaptive(0xB55229, 0xE4A180)
        case .typescript, .json: return Theme.adaptive(0x2469A6, 0x8CB6E2)
        case .javascript, .python: return Theme.adaptive(0x856A1F, 0xD6C38B)
        case .yaml, .toml: return Theme.adaptive(0x7C5589, 0xBB99C6)
        default: return Theme.muted
        }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? FileTreeNode)?.children?.count ?? (item == nil ? roots.count : 0) }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? FileTreeNode)?.children?[index] ?? roots[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { guard let node = item as? FileTreeNode else { return false }; return node.entry.isDirectory && !node.entry.blocked }
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? FileTreeNode else { return false }
        return node.entry.isDirectory && !node.entry.blocked
    }
    // AppKit and accessibility clients may query shouldExpandItem without a
    // user opening the directory. Only the actual expansion notification may
    // load children or remember expansion state.
    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileTreeNode,
              node.entry.isDirectory, !node.entry.blocked else { return }
        expandedPaths.insert(node.entry.path)
        if node.children == nil { loadChildren(node) }
    }
    func outlineViewItemDidCollapse(_ notification: Notification) { if let node = notification.userInfo?["NSObject"] as? FileTreeNode { expandedPaths.remove(node.entry.path) } }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileTreeNode else { return nil }
        let cell = NSTableCellView(), image = NSImageView(), text = label(node.entry.name, size: 12, color: node.entry.blocked ? Theme.muted : Theme.text)
        text.lineBreakMode = .byTruncatingMiddle; text.maximumNumberOfLines = 1
        image.image = icon(for: node.entry.path, directory: node.entry.isDirectory, expanded: outline.isItemExpanded(node))
        image.contentTintColor = tint(for: node.entry.path, isDirectory: node.entry.isDirectory); image.imageScaling = .scaleProportionallyDown
        for view in [image, text] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        cell.imageView = image; cell.textField = text
        NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 1), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 15), image.heightAnchor.constraint(equalToConstant: 15), text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        cell.toolTip = node.entry.blocked ? "链接指向项目外或不可访问：" + node.entry.path : node.entry.path
        cell.setAccessibilityLabel(node.entry.name)
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !restoringSelection, let node = outline.item(atRow: outline.selectedRow) as? FileTreeNode else { return }
        if node.entry.blocked { setStatus("此链接指向项目外或目标不可访问。", error: true); return }
        if !node.entry.isDirectory { openFile(node.entry.path) }
    }
    @objc private func doubleClickTree() {
        guard let node = outline.item(atRow: outline.clickedRow) as? FileTreeNode, node.entry.isDirectory else { return }
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }
    private func refreshTree() {
        guard let store else { return }
        treeGeneration += 1; let generation = treeGeneration
        queue.async { [weak self] in
            let result = Result { try store.entries() }
            DispatchQueue.main.async {
                guard let self, generation == self.treeGeneration else { return }
                switch result {
                case .success(let entries):
                    self.roots = entries.map { FileTreeNode($0) }; self.restoringSelection = true; self.outline.reloadData(); self.restoringSelection = false
                    self.restoreExpanded(self.roots); self.selectCurrentInTree()
                case .failure(let error): self.setStatus(error.localizedDescription, error: true)
                }
            }
        }
    }
    private func restoreExpanded(_ nodes: [FileTreeNode]) { for node in nodes where expandedPaths.contains(node.entry.path) && !node.entry.blocked { outline.expandItem(node) } }
    private func loadChildren(_ node: FileTreeNode) {
        guard let store, !node.loading else { return }
        // A directory symlink back to an ancestor must not create an endless tree.
        let resolved = URL(fileURLWithPath: directory).appendingPathComponent(node.entry.path).resolvingSymlinksInPath().path
        var ancestor = node.parent
        if resolved == store.root.path { setStatus("此目录链接指向项目根目录。", error: true); return }
        while let parent = ancestor {
            if URL(fileURLWithPath: directory).appendingPathComponent(parent.entry.path).resolvingSymlinksInPath().path == resolved { setStatus("此目录链接指向上级目录。", error: true); return }
            ancestor = parent.parent
        }
        node.loading = true; let generation = treeGeneration
        queue.async { [weak self, weak node] in
            guard let node else { return }; let result = Result { try store.entries(in: node.entry.path) }
            DispatchQueue.main.async {
                guard let self, generation == self.treeGeneration else { return }; node.loading = false
                switch result {
                case .success(let entries):
                    node.children = entries.map { FileTreeNode($0, parent: node) }; self.restoringSelection = true; self.outline.reloadItem(node, reloadChildren: true); self.restoringSelection = false
                    if self.expandedPaths.contains(node.entry.path) { self.outline.expandItem(node) }; self.restoreExpanded(node.children ?? []); self.selectCurrentInTree()
                case .failure(let error): self.setStatus(error.localizedDescription, error: true)
                }
            }
        }
    }
    private func rememberCurrent() {
        guard let current, current.snapshot != nil else { return }
        current.draft = codeEditor.text; current.selection = codeEditor.textView.selectedRange(); current.scroll = codeEditor.scroll.contentView.bounds.origin
    }
    private enum OpenedFile { case text(ProjectFileSnapshot), image(CGImage), preview(ProjectFileInfo, Data?, String?) }
    private func readFile(_ path: String, store: ProjectFileStore) throws -> OpenedFile {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ext == "pdf" {
            let info = try store.previewInfo(path)
            return .preview(info, info.byteCount <= 32 * 1024 * 1024 ? try store.previewData(path) : nil, info.byteCount > 32 * 1024 * 1024 ? "PDF 超过 32 MB，可在默认应用中打开。" : nil)
        }
        if ["rtf", "docx", "odt"].contains(ext) {
            let info = try store.previewInfo(path)
            return .preview(info, info.byteCount <= 4 * 1024 * 1024 ? try store.previewData(path, maximumBytes: 4 * 1024 * 1024) : nil, info.byteCount > 4 * 1024 * 1024 ? "文档超过 4 MB，可在默认应用中打开。" : nil)
        }
        guard ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic"].contains(ext) else {
            do { return .text(try store.read(path)) }
            catch { return .preview(try store.previewInfo(path), nil, error.localizedDescription) }
        }
        let info = try store.previewInfo(path)
        guard info.byteCount <= 20 * 1024 * 1024 else { return .preview(info, nil, "图片超过 20 MB，可在默认应用中打开。") }
        let data = try store.previewData(path, maximumBytes: 20 * 1024 * 1024)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0, width.doubleValue * height.doubleValue <= 40_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 3072, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            return .preview(info, nil, "图片格式不可预览，或像素尺寸过大。")
        }
        return .image(image)
    }
    private func makeBuffer(_ opened: OpenedFile, path: String) -> FileBuffer {
        switch opened {
        case .text(let snapshot): return FileBuffer(snapshot)
        case .image(let image): return FileBuffer(path: path, image: NSImage(cgImage: image, size: .zero))
        case .preview(let info, let data, let notice):
            let view = ProjectFilePreviewView(data: data, filename: path, byteCount: info.byteCount, notice: notice) { [weak self] in
                guard let store = self?.store else { throw ProjectFileError.message("项目不可访问。") }
                let url = try store.externalURL(for: info)
                guard NSWorkspace.shared.open(url) else { throw ProjectFileError.message("没有可打开此文件的应用。") }
            }
            return FileBuffer(path: path, preview: view)
        }
    }
    /// Opening a file is also used by project navigation; it never executes code.
    func openFile(_ path: String) {
        if let existing = buffers.first(where: { $0.path == path }) { pendingOpen = nil; activate(existing); return }
        guard let store else { pendingOpen = path; return }
        pendingOpen = path; setStatus("正在打开…")
        queue.async { [weak self] in
            guard let self else { return }; let result = Result { try self.readFile(path, store: store) }
            DispatchQueue.main.async {
                guard self.pendingOpen == path else { return }; self.pendingOpen = nil
                switch result {
                case .success(let opened):
                    let buffer = self.makeBuffer(opened, path: path)
                    self.buffers.append(buffer); self.activate(buffer)
                case .failure(let error): self.setStatus(error.localizedDescription, error: true)
                }
            }
        }
    }
    private func activate(_ buffer: FileBuffer) {
        if current === buffer { return }
        rememberCurrent(); current = buffer
        if buffer.snapshot != nil {
            codeEditor.setDocument(text: buffer.draft, path: buffer.path, selection: buffer.selection, undoManager: buffer.undoManager)
            codeEditor.isEditable = !saving.contains(buffer.path) && !reloading.contains(buffer.path)
            codeEditor.scroll.contentView.scroll(to: buffer.scroll); codeEditor.scroll.reflectScrolledClipView(codeEditor.scroll.contentView)
        }
        imagePane.subviews.filter { $0 !== imageView }.forEach { $0.removeFromSuperview() }
        imageView.image = buffer.image; imageView.isHidden = buffer.image == nil
        if let preview = buffer.preview {
            preview.translatesAutoresizingMaskIntoConstraints = false; imagePane.addSubview(preview)
            NSLayoutConstraint.activate([preview.leadingAnchor.constraint(equalTo: imagePane.leadingAnchor), preview.trailingAnchor.constraint(equalTo: imagePane.trailingAnchor), preview.topAnchor.constraint(equalTo: imagePane.topAnchor), preview.bottomAnchor.constraint(equalTo: imagePane.bottomAnchor)])
        }
        breadcrumb.stringValue = buffer.path.replacingOccurrences(of: "/", with: "  ›  "); breadcrumb.toolTip = buffer.path
        setStatus(""); updateDocumentVisibility(); renderTabs(); selectCurrentInTree()
        if bounds.width < 520 && treeVisible { treeVisible = false; applyTreeVisibility() }
    }
    private func selectCurrentInTree() {
        guard let current else { return }
        for index in 0..<outline.numberOfRows where (outline.item(atRow: index) as? FileTreeNode)?.entry.path == current.path {
            restoringSelection = true; outline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); restoringSelection = false; return
        }
    }
    private func renderTabs() {
        tabs.arrangedSubviews.forEach { tabs.removeArrangedSubview($0); $0.removeFromSuperview() }
        for buffer in buffers {
            let background = ThemeSurface(current === buffer ? Theme.adaptive(0xFFFFFF, 0x252525) : .clear)
            let name = NSButton(title: (buffer.dirty ? "● " : "") + URL(fileURLWithPath: buffer.path).lastPathComponent, target: nil, action: nil)
            name.font = Theme.font(size: 12, weight: current === buffer ? .medium : .regular); name.isBordered = false; name.contentTintColor = current === buffer ? Theme.text : Theme.muted
            name.image = icon(for: buffer.path, directory: false); name.imagePosition = .imageLeft; name.imageScaling = .scaleProportionallyDown
            name.target = self; name.action = #selector(selectTab(_:)); name.identifier = NSUserInterfaceItemIdentifier(buffer.path); name.toolTip = buffer.path; name.setAccessibilityLabel("打开文件：" + buffer.path)
            name.setContentCompressionResistancePriority(.required, for: .horizontal)
            let close = FilesIconButton(symbol: "xmark", title: "关闭文件：" + buffer.path) { [weak self, weak buffer] in if let buffer { self?.close(buffer) } }
            let tabRow = row([name, close], spacing: 0); tabRow.translatesAutoresizingMaskIntoConstraints = false; background.addSubview(tabRow)
            NSLayoutConstraint.activate([tabRow.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6), tabRow.trailingAnchor.constraint(equalTo: background.trailingAnchor), tabRow.centerYAnchor.constraint(equalTo: background.centerYAnchor), background.heightAnchor.constraint(equalToConstant: 32)])
            tabs.addArrangedSubview(background)
        }
        tabs.layoutSubtreeIfNeeded()
        if let index = buffers.firstIndex(where: { $0 === current }), tabs.arrangedSubviews.indices.contains(index) { tabs.arrangedSubviews[index].scrollToVisible(tabs.arrangedSubviews[index].bounds) }
        saveButton.isEnabled = current?.dirty == true && !saving.contains(current?.path ?? "")
    }
    @objc private func selectTab(_ sender: NSButton) { if let buffer = buffers.first(where: { $0.path == sender.identifier?.rawValue }) { pendingOpen = nil; activate(buffer) } }
    private func close(_ buffer: FileBuffer) {
        rememberCurrent()
        let perform = { [weak self, weak buffer] in
            guard let self, let buffer, !self.saving.contains(buffer.path), !self.reloading.contains(buffer.path), let index = self.buffers.firstIndex(where: { $0 === buffer }) else { return }
            self.buffers.remove(at: index)
            if self.current === buffer {
                self.current = nil
                if let next = self.buffers.last { self.activate(next) } else { self.breadcrumb.stringValue = ""; self.codeEditor.setDocument(text: "", path: ""); self.codeEditor.isEditable = false; self.setStatus(""); self.updateDocumentVisibility() }
            }
            self.renderTabs()
        }
        guard buffer.dirty else { perform(); return }
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "保存 \(URL(fileURLWithPath: buffer.path).lastPathComponent) 的修改？"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "不保存")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.save(buffer, completion: { if $0 { perform() } }) }
            else if response == .alertThirdButtonReturn { perform() }
        }
    }
    private func edited() {
        guard let current else { return }; let wasDirty = current.dirty; current.draft = codeEditor.text
        if current.dirty != wasDirty { renderTabs() }
        saveButton.isEnabled = current.dirty && !saving.contains(current.path); setStatus("")
    }
    private func updateDocumentVisibility() {
        if current == nil && !treeVisible { treeVisible = true; applyTreeVisibility() }
        empty.isHidden = current != nil; codeEditor.isHidden = current?.snapshot == nil; imagePane.isHidden = current == nil || current?.snapshot != nil
        findButton.isEnabled = current?.snapshot != nil; fileMenuButton.isEnabled = current != nil
        breadcrumb.isHidden = current == nil
    }
    private func save() { rememberCurrent(); if let current { save(current) } }
    private func save(_ buffer: FileBuffer, completion: ((Bool) -> Void)? = nil) {
        guard !saving.contains(buffer.path), let store, let original = buffer.snapshot else { completion?(false); return }
        let text = buffer.draft; saving.insert(buffer.path)
        if current === buffer { codeEditor.isEditable = false; saveButton.isEnabled = false; setStatus("正在保存…") }
        queue.async { [weak self, weak buffer] in
            let result = Result { try store.save(original, text: text) }
            DispatchQueue.main.async {
                guard let self, let buffer else { return }; self.saving.remove(buffer.path)
                let succeeded: Bool
                switch result {
                case .success(let snapshot): buffer.snapshot = snapshot; succeeded = true; if self.current === buffer { self.setStatus("已保存") }
                case .failure(let error): succeeded = false; self.setStatus(error.localizedDescription, error: true)
                }
                if self.current === buffer { self.codeEditor.isEditable = true }; self.renderTabs(); completion?(succeeded)
            }
        }
    }
    private func showFileMenu() {
        let menu = NSMenu()
        let reload = NSMenuItem(title: "从磁盘重新打开", action: #selector(reloadCurrent), keyEquivalent: ""); reload.target = self; menu.addItem(reload)
        let reveal = NSMenuItem(title: "在 Finder 中显示", action: #selector(revealCurrent), keyEquivalent: ""); reveal.target = self; menu.addItem(reveal)
        if let current, ProjectFilePreviewView.canOpenExternally(filename: current.path) {
            let external = NSMenuItem(title: "在默认应用中打开", action: #selector(openCurrentExternally), keyEquivalent: ""); external.target = self; menu.addItem(external)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: fileMenuButton.bounds.maxY), in: fileMenuButton)
    }
    @objc private func reloadCurrent() {
        guard let current else { return }; rememberCurrent()
        let reload = { [weak self, weak current] in
            guard let self, let current, !self.saving.contains(current.path) else { return }
            guard let store = self.store else { return }
            let path = current.path; self.pendingOpen = path; self.reloading.insert(path); self.codeEditor.isEditable = false; self.setStatus("正在重新打开…")
            self.queue.async { [weak self, weak current] in
                guard let self, let current else { return }; let result = Result { try self.readFile(path, store: store) }
                DispatchQueue.main.async {
                    self.reloading.remove(path)
                    if self.current === current { self.codeEditor.isEditable = current.snapshot != nil }
                    guard self.pendingOpen == path else { return }; self.pendingOpen = nil
                    switch result {
                    case .success(let opened):
                        let replacement = self.makeBuffer(opened, path: path)
                        if let index = self.buffers.firstIndex(where: { $0 === current }) { self.buffers[index] = replacement }
                        // Do not throw away the old buffer until a successful read.
                        if self.current === current { self.activate(replacement) } else { self.renderTabs() }
                    case .failure(let error): self.setStatus(error.localizedDescription, error: true)
                    }
                }
            }
        }
        if !current.dirty { reload(); return }
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "放弃当前文件的未保存修改？"; alert.informativeText = "重新打开会读取磁盘中的版本。"
        alert.addButton(withTitle: "保留草稿"); alert.addButton(withTitle: "重新打开")
        alert.beginSheetModal(for: window) { if $0 == .alertSecondButtonReturn { reload() } }
    }
    @objc private func revealCurrent() { guard let current else { return }; NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory).appendingPathComponent(current.path)]) }
    @objc private func openCurrentExternally() {
        guard let current, let store, ProjectFilePreviewView.canOpenExternally(filename: current.path) else { return }
        do {
            let url = try store.externalURL(for: store.previewInfo(current.path))
            guard NSWorkspace.shared.open(url) else { throw ProjectFileError.message("没有可打开此文件的应用。") }
        } catch { setStatus(error.localizedDescription, error: true) }
    }
    private func setStatus(_ text: String, error: Bool = false) { status.stringValue = text; status.toolTip = text; status.textColor = error ? Theme.warning : Theme.muted; status.isHidden = text.isEmpty }
}
#endif
