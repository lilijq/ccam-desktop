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
    private func readHandle(_ descriptor: Int32) throws -> (Data, stat) {
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
    private func readAt(_ parent: Int32, name: String) throws -> (Data, stat) {
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ProjectFileError.message("文件不可访问，或链接已发生变化。") }
        defer { Darwin.close(descriptor) }
        return try readHandle(descriptor)
    }
    func read(_ relative: String) throws -> ProjectFileSnapshot {
        try withParent(relative) { parent, name, resolved in
            let (data, metadata) = try readAt(parent, name: name)
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw ProjectFileError.message("这是二进制文件或非 UTF-8 文本，不能在这里编辑。") }
            return ProjectFileSnapshot(path: relative, resolvedPath: resolved, text: text, version: ProjectFileVersion(metadata, data: data))
        }
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
private final class ProjectFilesSplit: NSStackView {
    private let list: NSView
    private let detail: NSView
    private let compactHeight: CGFloat
    private var narrow = true
    private var paneConstraints: [NSLayoutConstraint] = []
    init(list: NSView, detail: NSView, compactHeight: CGFloat) {
        self.list = list; self.detail = detail; self.compactHeight = compactHeight
        super.init(frame: .zero)
        spacing = 12; addArrangedSubview(list); addArrangedSubview(detail); arrange(narrow: true)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        if bounds.width > 0, (bounds.width < 700) != narrow { arrange(narrow: bounds.width < 700) }
        super.layout()
    }
    private func arrange(narrow: Bool) {
        self.narrow = narrow
        NSLayoutConstraint.deactivate(paneConstraints)
        orientation = narrow ? .vertical : .horizontal; alignment = narrow ? .leading : .top
        if narrow {
            paneConstraints = [list.widthAnchor.constraint(equalTo: widthAnchor), detail.widthAnchor.constraint(equalTo: widthAnchor), list.heightAnchor.constraint(equalToConstant: compactHeight)]
        } else {
            paneConstraints = [list.widthAnchor.constraint(equalToConstant: 230), detail.widthAnchor.constraint(equalTo: widthAnchor, constant: -242), list.heightAnchor.constraint(equalTo: heightAnchor), detail.heightAnchor.constraint(equalTo: heightAnchor)]
        }
        NSLayoutConstraint.activate(paneConstraints)
    }
}

final class ProjectFilesView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    private let directory: String
    private let queue = DispatchQueue(label: "ccam.project.files", qos: .userInitiated)
    private var store: ProjectFileStore?
    private var entries: [ProjectFileEntry] = []
    private var folder = ""
    private var snapshot: ProjectFileSnapshot?
    private var loading = false
    private let table = NSTableView()
    private let editor = NSTextView()
    private let location = label("项目文件", size: 12, color: Theme.muted)
    private let filename = label("选择一个文本文件", size: 14, weight: .semibold)
    private let status = label("正在读取…", size: 12, color: Theme.muted)
    private var saveButton: ClosureButton!
    private var backButton: ClosureButton!
    var hasUnsavedChanges: Bool { snapshot.map { editor.string != $0.text } ?? false }
    init(directory: String) {
        self.directory = directory
        super.init(frame: .zero)
        backButton = ClosureButton("上一级", symbol: "chevron.up") { [weak self] in self?.goUp() }
        let refresh = ClosureButton("刷新", symbol: "arrow.clockwise") { [weak self] in self?.loadFolder(self?.folder ?? "") }
        saveButton = ClosureButton("保存", symbol: "square.and.arrow.down") { [weak self] in self?.save() }
        saveButton.bezelColor = Theme.primary; saveButton.isEnabled = false
        location.maximumNumberOfLines = 1; location.lineBreakMode = .byTruncatingMiddle
        filename.maximumNumberOfLines = 1; filename.lineBreakMode = .byTruncatingMiddle
        let fileColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); fileColumn.title = "文件与文件夹"; table.addTableColumn(fileColumn)
        table.headerView = nil; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.rowHeight = 28; table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(openSelected)
        table.backgroundColor = Theme.panel
        let listing = NSScrollView(); listing.documentView = table; listing.hasVerticalScroller = true; listing.borderType = .noBorder
        let textScroll = ThemeScrollView(); textScroll.documentView = editor; textScroll.hasVerticalScroller = true; textScroll.hasHorizontalScroller = false
        textScroll.drawsBackground = true; textScroll.backgroundColor = Theme.panel
        textScroll.wantsLayer = true; textScroll.strokeColor = Theme.border; textScroll.layer?.borderWidth = 1; textScroll.layer?.cornerRadius = 8
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular); editor.textColor = Theme.text; editor.backgroundColor = Theme.panel; editor.insertionPointColor = Theme.accent
        editor.textContainerInset = NSSize(width: 12, height: 12); editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true; editor.delegate = self; editor.isEditable = false
        editor.setAccessibilityLabel("文件内容")
        textScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        let body = column([], spacing: 10)
        fillWidth(row([backButton, location, spacer(), refresh]), in: body)
        let detail = column([], spacing: 10)
        fillWidth(row([filename, spacer(), saveButton]), in: detail)
        fillWidth(textScroll, in: detail); fillWidth(status, in: detail)
        fillWidth(ProjectFilesSplit(list: listing, detail: detail, compactHeight: 150), in: body)
        body.translatesAutoresizingMaskIntoConstraints = false; addSubview(body)
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: leadingAnchor), body.trailingAnchor.constraint(equalTo: trailingAnchor), body.topAnchor.constraint(equalTo: topAnchor), body.bottomAnchor.constraint(equalTo: bottomAnchor)])
        queue.async { [weak self] in
            do { let store = try ProjectFileStore(directory: directory); DispatchQueue.main.async { self?.store = store; self?.loadFolder("") } }
            catch { DispatchQueue.main.async { self?.setStatus(error.localizedDescription, error: true) } }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = entries[row]
        return label((item.blocked ? "不可访问  " : item.isDirectory ? "文件夹  " : "") + item.name, size: 12, color: item.blocked ? Theme.muted : Theme.text)
    }
    @objc private func openSelected() {
        guard !loading, entries.indices.contains(table.selectedRow) else { return }
        let entry = entries[table.selectedRow]
        guard !entry.blocked else { setStatus("此链接指向项目外或目标不可访问。", error: true); return }
        confirmDiscard { [weak self] proceed in guard let self, proceed else { return }; if entry.isDirectory { self.loadFolder(entry.path, discard: true) } else { self.loadFile(entry.path) } }
    }
    private func goUp() {
        guard !folder.isEmpty, !loading else { return }
        let parent = folder.split(separator: "/").dropLast().joined(separator: "/")
        confirmDiscard { [weak self] proceed in if proceed { self?.loadFolder(parent, discard: true) } }
    }
    private func confirmDiscard(_ completion: @escaping (Bool) -> Void) {
        guard hasUnsavedChanges else { completion(true); return }
        guard let window else { completion(false); return }
        let alert = NSAlert(); alert.messageText = "放弃未保存的修改？"; alert.informativeText = "当前文件的草稿尚未保存。"
        alert.addButton(withTitle: "保留草稿"); alert.addButton(withTitle: "放弃修改")
        alert.beginSheetModal(for: window) { completion($0 == .alertSecondButtonReturn) }
    }
    private func loadFolder(_ path: String, discard: Bool = false) {
        guard !loading, let store else { return }
        loading = true; if discard { editor.isEditable = false }; saveButton.isEnabled = false; setStatus("正在读取文件夹…")
        queue.async { [weak self] in
            let result = Result { try store.entries(in: path) }
            DispatchQueue.main.async {
                guard let self else { return }; self.loading = false
                switch result {
                case .success(let entries):
                    self.entries = entries; self.folder = path; self.location.stringValue = path.isEmpty ? "项目根目录" : path; self.location.toolTip = self.directory + "/" + path
                    self.table.reloadData(); self.backButton.isEnabled = !path.isEmpty
                    if discard { self.snapshot = nil; self.editor.string = ""; self.editor.isEditable = false; self.filename.stringValue = "选择一个文本文件"; self.saveButton.isEnabled = false }
                    self.setStatus(entries.isEmpty ? "文件夹为空。" : "双击文件或文件夹打开。")
                case .failure(let error): self.setStatus(error.localizedDescription, error: true)
                }
                self.editor.isEditable = self.snapshot != nil; self.saveButton.isEnabled = self.hasUnsavedChanges
            }
        }
    }
    private func loadFile(_ path: String) {
        guard !loading, let store else { return }; loading = true; editor.isEditable = false; saveButton.isEnabled = false; setStatus("正在打开文件…")
        queue.async { [weak self] in
            let result = Result { try store.read(path) }
            DispatchQueue.main.async {
                guard let self else { return }; self.loading = false
                switch result {
                case .success(let file): self.snapshot = file; self.editor.string = file.text; self.editor.isEditable = true; self.filename.stringValue = URL(fileURLWithPath: path).lastPathComponent; self.filename.toolTip = path; self.saveButton.isEnabled = false; self.setStatus("UTF-8 文本")
                case .failure(let error): self.setStatus(error.localizedDescription, error: true)
                }
                self.editor.isEditable = self.snapshot != nil; self.saveButton.isEnabled = self.hasUnsavedChanges
            }
        }
    }
    func textDidChange(_ notification: Notification) { saveButton.isEnabled = !loading && hasUnsavedChanges; if hasUnsavedChanges { setStatus("有未保存的修改") } }
    private func save() {
        guard !loading, let store, let original = snapshot else { return }
        let text = editor.string; loading = true; editor.isEditable = false; saveButton.isEnabled = false; setStatus("正在保存…")
        queue.async { [weak self] in
            let result = Result { try store.save(original, text: text) }
            DispatchQueue.main.async {
                guard let self else { return }; self.loading = false; self.editor.isEditable = true
                switch result { case .success(let file): self.snapshot = file; self.setStatus("已保存"); case .failure(let error): self.setStatus(error.localizedDescription, error: true) }
                self.saveButton.isEnabled = self.hasUnsavedChanges
            }
        }
    }
    private func setStatus(_ text: String, error: Bool = false) { status.stringValue = text; status.textColor = error ? Theme.warning : Theme.muted }
}
#endif
