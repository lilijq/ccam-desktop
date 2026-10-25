import Foundation
import Darwin
#if !PROJECT_GIT_CORE_ONLY
import AppKit
#endif

enum ProjectGitError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
struct ProjectGitFile: Equatable {
    let path: String
    let originalPath: String?
    let index: String
    let working: String
    var untracked: Bool { index == "?" && working == "?" }
    var staged: Bool { index != " " && index != "?" }
    var unstaged: Bool { working != " " }
    var title: String {
        if untracked { return "新文件" }
        if index == "U" || working == "U" || ["AA", "DD"].contains(index + working) { return "有冲突" }
        if staged && unstaged { return "已暂存 / 另有修改" }
        return staged ? "已暂存" : "未暂存"
    }
}
struct ProjectGitState {
    let branch: String
    let hasHead: Bool
    let files: [ProjectGitFile]
}
struct ProjectGitResult { let code: Int32; let text: String; let data: Data }

final class ProjectGitClient {
    let directory: URL
    init(directory: String) throws {
        self.directory = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: self.directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw ProjectGitError.message("项目目录不可访问。") }
    }
    /// No shell, pathspec expansion, external diff, or credential prompts.
    private func run(_ arguments: [String], accepted: Set<Int32> = [0], timeout: TimeInterval = 30) throws -> ProjectGitResult {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "--literal-pathspecs", "-c", "color.ui=false", "-c", "core.quotepath=false", "-c", "core.fsmonitor=false"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        // Match repository discovery: an inherited Git location/config override
        // must not redirect operations away from the repository shown in the UI.
        for key in Array(environment.keys) where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GIT_OPTIONAL_LOCKS"] = "0"; environment["LC_ALL"] = "C"; process.environment = environment
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
        try process.run(); try? pipe.fileHandleForWriting.close()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        defer { try? pipe.fileHandleForReading.close() }
        var output = Data(), truncated = false, buffer = [UInt8](repeating: 0, count: 16_384)
        func drain() {
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count <= 0 { break }
                let remaining = 2 * 1024 * 1024 - output.count
                if remaining > 0 { output.append(contentsOf: buffer.prefix(min(count, remaining))) }
                if count > remaining { truncated = true }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            drain()
            if Date() > deadline {
                timedOut = true; process.terminate()
                let grace = Date().addingTimeInterval(1)
                while process.isRunning && Date() < grace { drain(); usleep(20_000) }
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                break
            }
            usleep(20_000)
        }
        process.waitUntilExit(); drain()
        if timedOut { throw ProjectGitError.message("Git 操作超时。请刷新状态后确认结果。") }
        let text = String(decoding: output, as: UTF8.self) + (truncated ? "\n较长的输出已省略。" : "")
        guard accepted.contains(process.terminationStatus) else { throw ProjectGitError.message(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Git 操作未完成。" : String(text.suffix(3000))) }
        if truncated && arguments.first == "status" { throw ProjectGitError.message("改动列表过大，请使用外部 Git 工具。") }
        return ProjectGitResult(code: process.terminationStatus, text: text, data: output)
    }
    private func safePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("..") else { throw ProjectGitError.message("只能操作当前项目内的文件。") }
    }
    func status() throws -> ProjectGitState {
        let repository = try run(["rev-parse", "--is-inside-work-tree"], accepted: [0, 128])
        guard repository.code == 0, repository.text.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { throw ProjectGitError.message("这个文件夹还不是 Git 仓库。") }
        let prefix = try run(["rev-parse", "--show-prefix"]).text.trimmingCharacters(in: .newlines)
        let raw = try run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."])
        var files: [ProjectGitFile] = [], parts = raw.data.split(separator: 0, omittingEmptySubsequences: true), index = 0
        while index < parts.count {
            let item = parts[index]; index += 1
            guard item.count >= 4, let status = String(data: item.prefix(2), encoding: .utf8), let fullPath = String(data: item.dropFirst(3), encoding: .utf8) else { throw ProjectGitError.message("仓库中包含无法显示的文件名。") }
            let renamed = status.contains("R") || status.contains("C")
            var original: String?
            if renamed {
                guard index < parts.count, let old = String(data: parts[index], encoding: .utf8) else { throw ProjectGitError.message("无法读取文件改名状态。") }
                index += 1
                if old.hasPrefix(prefix) { original = String(old.dropFirst(prefix.count)) }
            }
            guard fullPath.hasPrefix(prefix) else { continue }
            let path = String(fullPath.dropFirst(prefix.count)); try safePath(path)
            files.append(ProjectGitFile(path: path, originalPath: original, index: String(status.prefix(1)), working: String(status.suffix(1))))
        }
        let symbolic = try run(["symbolic-ref", "--quiet", "--short", "HEAD"], accepted: [0, 1])
        let head = try run(["rev-parse", "--verify", "HEAD"], accepted: [0, 128])
        let branch: String
        if symbolic.code == 0 { branch = symbolic.text.trimmingCharacters(in: .newlines) }
        else { branch = "分离状态 " + (head.code == 0 ? String(head.text.prefix(8)) : "") }
        return ProjectGitState(branch: branch, hasHead: head.code == 0, files: files)
    }
    func diff(_ file: ProjectGitFile) throws -> String {
        try safePath(file.path)
        let paths = [file.path] + (file.originalPath.map { [$0] } ?? [])
        for path in paths { try safePath(path) }
        if file.untracked {
            return try run(["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--", "/dev/null", file.path], accepted: [0, 1]).text
        }
        var sections: [String] = []
        if file.staged {
            let staged = try run(["diff", "--cached", "--no-ext-diff", "--no-textconv", "--"] + paths).text
            if !staged.isEmpty { sections.append("已暂存\n" + staged) }
        }
        if file.unstaged {
            let working = try run(["diff", "--no-ext-diff", "--no-textconv", "--"] + paths).text
            if !working.isEmpty { sections.append("工作区\n" + working) }
        }
        return sections.isEmpty ? "没有可显示的文本差异。" : sections.joined(separator: "\n")
    }
    func stage(_ file: ProjectGitFile) throws {
        let paths = [file.path] + (file.originalPath.map { [$0] } ?? [])
        for path in paths { try safePath(path) }
        _ = try run(["add", "--"] + paths)
    }
    func unstage(_ file: ProjectGitFile) throws {
        let paths = [file.path] + (file.originalPath.map { [$0] } ?? [])
        for path in paths { try safePath(path) }
        let head = try run(["rev-parse", "--verify", "HEAD"], accepted: [0, 128])
        if head.code == 0 { _ = try run(["restore", "--staged", "--"] + paths) }
        else { _ = try run(["rm", "--cached", "--force", "--ignore-unmatch", "--"] + paths) }
    }
    func commit(message: String) throws {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !message.contains("\0") else { throw ProjectGitError.message("请填写有效的提交说明。") }
        let prefix = try run(["rev-parse", "--show-prefix"]).text.trimmingCharacters(in: .newlines)
        if !prefix.isEmpty {
            let staged = try run(["diff", "--cached", "--name-only", "-z"]).data.split(separator: 0)
            guard staged.allSatisfy({ String(data: $0, encoding: .utf8)?.hasPrefix(prefix) == true }) else {
                throw ProjectGitError.message("仓库还有当前项目目录之外的暂存改动，请在仓库根目录提交。")
            }
        }
        _ = try run(["commit", "-m", message], timeout: 120)
    }
}

#if !PROJECT_GIT_CORE_ONLY
/// Keep the native menu and keyboard behavior while matching the workspace's
/// quiet controls; the standard pop-up bezel can render opaque white offscreen.
private final class RepositoryPicker: NSPopUpButton {
    private var hovering = false
    private var tracking: NSTrackingArea?
    override init(frame: NSRect, pullsDown: Bool) {
        super.init(frame: frame, pullsDown: pullsDown)
        isBordered = false; focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 280, height: 32) }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 1, dy: 1) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 6, yRadius: 6).fill() }
    override func draw(_ dirtyRect: NSRect) {
        (hovering || isHighlighted ? Theme.button : Theme.panel).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        let color = isEnabled ? Theme.text : Theme.muted
        if let icon = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [Theme.muted])) {
            icon.draw(in: NSRect(x: 9, y: (bounds.height - 13) / 2, width: 15, height: 13))
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingMiddle
        let text = NSAttributedString(string: titleOfSelectedItem ?? "选择仓库", attributes: [.font: font ?? Theme.font(size: 13), .foregroundColor: color, .paragraphStyle: paragraph])
        text.draw(in: NSRect(x: 32, y: (bounds.height - text.size().height) / 2, width: max(0, bounds.width - 56), height: text.size().height))
        let arrow = NSBezierPath(); arrow.lineWidth = 1.2; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
        let d: CGFloat = isFlipped ? 1 : -1
        arrow.move(to: NSPoint(x: bounds.width - 16, y: bounds.midY - d * 1.5)); arrow.line(to: NSPoint(x: bounds.width - 13, y: bounds.midY + d * 1.5)); arrow.line(to: NSPoint(x: bounds.width - 10, y: bounds.midY - d * 1.5))
        Theme.muted.setStroke(); arrow.stroke()
    }
}

private final class ProjectGitSplit: NSStackView {
    private let list: NSView
    private let detail: NSView
    private var narrow = true
    private var paneConstraints: [NSLayoutConstraint] = []
    init(list: NSView, detail: NSView) {
        self.list = list; self.detail = detail
        super.init(frame: .zero)
        spacing = 8; addArrangedSubview(list); addArrangedSubview(detail); arrange(narrow: true)
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
            // A vertically split workspace can be only 242 points high. Give
            // both scrollable surfaces a share instead of fixing a 194pt list.
            paneConstraints = [list.widthAnchor.constraint(equalTo: widthAnchor), detail.widthAnchor.constraint(equalTo: widthAnchor),
                               list.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.3, constant: -4),
                               detail.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.7, constant: -4)]
        } else {
            paneConstraints = [list.widthAnchor.constraint(equalToConstant: 230), detail.widthAnchor.constraint(equalTo: widthAnchor, constant: -238), list.heightAnchor.constraint(equalTo: heightAnchor), detail.heightAnchor.constraint(equalTo: heightAnchor)]
        }
        NSLayoutConstraint.activate(paneConstraints)
    }
}

final class ProjectGitView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private struct RepositoryLoad {
        let scan: GitRepositoryDiscoveryResult
        let selected: GitRepositoryRecord?
        let status: Result<ProjectGitState, Error>?
    }
    private let discovery: Result<GitRepositoryDiscovery, Error>
    private let preferenceKey: String
    private let queue = DispatchQueue(label: "ccam.project.git", qos: .userInitiated)
    private var repositories: [GitRepositoryRecord] = []
    private var selectedRepository: GitRepositoryRecord?
    private var desiredRepositoryPath: String?
    private var repositoryDrafts: [String: String] = [:]
    private var repositorySelections: [String: String] = [:]
    private var scanNote: String?
    private var scanIncomplete = false
    private var state: ProjectGitState?
    private var busy = false
    private var repositoryGeneration = 0
    private var selectionGeneration = 0
    private let repositoryPicker = RepositoryPicker(frame: .zero, pullsDown: false)
    private let table = NSTableView()
    private let branch = label("", size: 12, color: Theme.muted, weight: .medium)
    private let statusLabel = label("", size: 11, color: Theme.muted)
    private let difference = NSTextView()
    private let message = NSTextField()
    private var stageButton: ClosureButton!
    private var unstageButton: ClosureButton!
    private var commitButton: ClosureButton!
    private var refreshButton: ClosureButton!
    private var selectedFile: ProjectGitFile? { guard let files = state?.files, files.indices.contains(table.selectedRow) else { return nil }; return files[table.selectedRow] }
    init(directory: String) {
        discovery = Result { try GitRepositoryDiscovery(directory: directory) }
        let canonical = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        preferenceKey = "git.selectedRepository." + Data(canonical.utf8).base64EncodedString()
        desiredRepositoryPath = UserDefaults.standard.string(forKey: preferenceKey)
        super.init(frame: .zero)
        func icon(_ title: String, symbol: String, action: @escaping () -> Void) -> ClosureButton {
            let button = ClosureButton("", symbol: symbol, action: action)
            button.toolTip = title; button.setAccessibilityLabel(title)
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            return button
        }
        refreshButton = icon("刷新 Git 状态", symbol: "arrow.clockwise") { [weak self] in self?.refresh() }
        stageButton = icon("暂存所选文件", symbol: "plus") { [weak self] in guard let self, let file = self.selectedFile else { return }; self.perform("正在暂存…") { try $0.stage(file) } }
        unstageButton = icon("取消暂存所选文件", symbol: "minus") { [weak self] in guard let self, let file = self.selectedFile else { return }; self.perform("正在取消暂存…") { try $0.unstage(file) } }
        commitButton = ClosureButton("提交", symbol: "checkmark") { [weak self] in self?.commit() }; commitButton.bezelColor = Theme.primary
        repositoryPicker.font = Theme.font(size: 13, weight: .medium)
        repositoryPicker.target = self; repositoryPicker.action = #selector(selectRepository)
        repositoryPicker.setAccessibilityLabel("选择 Git 仓库")
        repositoryPicker.cell?.lineBreakMode = .byTruncatingMiddle
        repositoryPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        repositoryPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        repositoryPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        repositoryPicker.addItem(withTitle: "正在查找仓库…")
        branch.maximumNumberOfLines = 1; branch.lineBreakMode = .byTruncatingMiddle
        branch.setAccessibilityLabel("Git 分支")
        branch.widthAnchor.constraint(lessThanOrEqualToConstant: 130).isActive = true
        branch.widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        branch.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        statusLabel.maximumNumberOfLines = 1; statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityLabel("Git 状态")
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")); nameColumn.title = "改动文件"; table.addTableColumn(nameColumn)
        table.headerView = nil; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.rowHeight = 30; table.dataSource = self; table.delegate = self; table.backgroundColor = Theme.panel
        table.setAccessibilityLabel("当前仓库改动文件")
        let listing = NSScrollView(); listing.documentView = table; listing.hasVerticalScroller = true
        let diffScroll = ThemeScrollView(); diffScroll.documentView = difference; diffScroll.hasVerticalScroller = true; diffScroll.hasHorizontalScroller = true
        diffScroll.drawsBackground = true; diffScroll.backgroundColor = Theme.panel; diffScroll.wantsLayer = true; diffScroll.strokeColor = Theme.border; diffScroll.layer?.borderWidth = 1; diffScroll.layer?.cornerRadius = 8
        difference.isEditable = false; difference.isSelectable = true; difference.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        difference.textColor = Theme.text; difference.backgroundColor = Theme.panel; difference.textContainerInset = NSSize(width: 10, height: 10)
        difference.isVerticallyResizable = true; difference.isHorizontallyResizable = false; difference.autoresizingMask = [.width]; difference.textContainer?.widthTracksTextView = true
        difference.setAccessibilityLabel("文件差异"); diffScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        message.placeholderString = "提交说明"; message.font = Theme.font(size: 13); message.setAccessibilityLabel("提交说明")
        message.delegate = self; message.isContinuous = true
        message.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let body = column([], spacing: 8)
        fillWidth(row([repositoryPicker, branch, spacer(), stageButton, unstageButton, refreshButton], spacing: 4), in: body)
        let files = column([], spacing: 8)
        fillWidth(listing, in: files)
        let detail = column([], spacing: 8)
        fillWidth(diffScroll, in: detail); fillWidth(message, in: detail); fillWidth(row([statusLabel, spacer(), commitButton]), in: detail)
        fillWidth(ProjectGitSplit(list: files, detail: detail), in: body)
        body.translatesAutoresizingMaskIntoConstraints = false; addSubview(body)
        NSLayoutConstraint.activate([body.topAnchor.constraint(equalTo: topAnchor), body.bottomAnchor.constraint(equalTo: bottomAnchor), body.leadingAnchor.constraint(equalTo: leadingAnchor), body.trailingAnchor.constraint(equalTo: trailingAnchor)])
        updateActions(); refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    func focus() { if !isHiddenOrHasHiddenAncestor { window?.makeFirstResponder(table) } }
    private func rememberCurrentRepository() {
        guard let selectedRepository else { return }
        repositoryDrafts[selectedRepository.directory.path] = message.currentEditor()?.string ?? message.stringValue
        if let file = selectedFile { repositorySelections[selectedRepository.directory.path] = file.path }
    }
    func controlTextDidChange(_ notification: Notification) { rememberCurrentRepository() }
    /// Re-discover on an explicit refresh. A missing selected repository leaves
    /// an explicit selection prompt instead of silently targeting another repo.
    func refresh() {
        guard !busy else { return }
        rememberCurrentRepository(); busy = true; repositoryGeneration += 1; selectionGeneration += 1
        let generation = repositoryGeneration, desired = desiredRepositoryPath
        updateActions(); setStatus("正在查找仓库…")
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { () throws -> RepositoryLoad in
                let finder = try self.discovery.get(), scan = try finder.discover()
                let selected: GitRepositoryRecord?
                if let desired { selected = scan.repositories.first { $0.directory.path == desired } }
                else { selected = scan.repositories.first { $0.relativePath == "." } ?? scan.repositories.first }
                let status = selected.map { record in Result { try ProjectGitClient(directory: finder.validate(record).path).status() } }
                return RepositoryLoad(scan: scan, selected: selected, status: status)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.repositoryGeneration == generation else { return }
                switch result {
                case .success(let loaded):
                    self.repositories = loaded.scan.repositories; self.scanNote = loaded.scan.note; self.scanIncomplete = loaded.scan.incomplete
                    self.selectedRepository = loaded.selected
                    if let selected = loaded.selected {
                        self.desiredRepositoryPath = selected.directory.path
                        UserDefaults.standard.set(selected.directory.path, forKey: self.preferenceKey)
                        self.message.stringValue = self.repositoryDrafts[selected.directory.path] ?? ""
                    } else { self.message.stringValue = "" }
                    self.rebuildPicker()
                    if let status = loaded.status { self.apply(status) }
                    else {
                        self.clearState()
                        self.setStatus(self.repositories.isEmpty ? "未找到 Git 仓库。可添加含仓库的文件夹。" : "原仓库已不可用，请选择其他仓库。", error: desired != nil)
                    }
                case .failure(let error):
                    self.repositories = []; self.selectedRepository = nil; self.message.stringValue = ""; self.rebuildPicker(); self.clearState(); self.setStatus(error.localizedDescription, error: true)
                }
                self.busy = false; self.updateActions(); self.loadDiff()
            }
        }
    }
    private func rebuildPicker() {
        repositoryPicker.removeAllItems()
        if selectedRepository == nil {
            repositoryPicker.addItem(withTitle: repositories.isEmpty ? "没有仓库" : "选择仓库…")
            repositoryPicker.lastItem?.isEnabled = false
        }
        for record in repositories {
            repositoryPicker.addItem(withTitle: record.relativePath == "." ? record.displayName : record.relativePath)
            repositoryPicker.lastItem?.representedObject = record.directory.path
            repositoryPicker.lastItem?.toolTip = record.directory.path
        }
        if let selectedRepository, let item = repositoryPicker.itemArray.first(where: { ($0.representedObject as? String) == selectedRepository.directory.path }) { repositoryPicker.select(item) }
        repositoryPicker.toolTip = selectedRepository.map { "仓库：" + $0.directory.path + "\n\(repositories.count) 个仓库" } ?? "选择要查看和提交的仓库"
        if let scanNote { repositoryPicker.toolTip = (repositoryPicker.toolTip ?? "") + "\n" + scanNote }
    }
    @objc private func selectRepository() {
        guard !busy, let path = repositoryPicker.selectedItem?.representedObject as? String,
              let record = repositories.first(where: { $0.directory.path == path }) else { rebuildPicker(); return }
        guard selectedRepository != record else { return }
        rememberCurrentRepository(); selectedRepository = record; desiredRepositoryPath = path
        UserDefaults.standard.set(path, forKey: preferenceKey)
        message.stringValue = repositoryDrafts[path] ?? ""; clearState(); rebuildPicker()
        loadRepository(record)
    }
    private func loadRepository(_ record: GitRepositoryRecord) {
        busy = true; repositoryGeneration += 1; selectionGeneration += 1
        let generation = repositoryGeneration
        updateActions(); setStatus("正在读取…")
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try ProjectGitClient(directory: self.discovery.get().validate(record).path).status() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.repositoryGeneration == generation, self.selectedRepository == record else { return }
                self.apply(result); self.busy = false; self.updateActions(); self.loadDiff()
            }
        }
    }
    private func apply(_ result: Result<ProjectGitState, Error>) {
        switch result {
        case .success(let next):
            state = next; branch.stringValue = next.branch; branch.toolTip = "分支：" + next.branch
            table.deselectAll(nil); table.reloadData()
            if let record = selectedRepository, let selected = repositorySelections[record.directory.path], let index = next.files.firstIndex(where: { $0.path == selected }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
            difference.string = next.files.isEmpty ? "当前仓库没有未提交的改动。" : "选择文件查看差异。"
            setStatus((repositories.count > 1 ? "\(repositories.count) 个仓库 · " : "") + (next.files.isEmpty ? "工作区干净" : "\(next.files.count) 个改动文件"))
        case .failure(let error): clearState(); setStatus(error.localizedDescription, error: true)
        }
    }
    private func clearState() {
        state = nil; selectionGeneration += 1; table.deselectAll(nil); table.reloadData(); branch.stringValue = ""; branch.toolTip = nil; difference.string = ""
    }
    func numberOfRows(in tableView: NSTableView) -> Int { state?.files.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let files = state?.files, files.indices.contains(row) else { return nil }
        let item = files[row]
        let text = label(item.title + "  " + item.path, size: 12); text.maximumNumberOfLines = 1; text.lineBreakMode = .byTruncatingMiddle; text.toolTip = item.path; return text
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if !busy, let record = selectedRepository, let file = selectedFile { repositorySelections[record.directory.path] = file.path }
        updateActions(); loadDiff()
    }
    private func loadDiff() {
        guard !busy, state != nil, let record = selectedRepository, let file = selectedFile else { return }
        selectionGeneration += 1; let generation = selectionGeneration, repoGeneration = repositoryGeneration
        difference.string = "正在读取差异…"
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try ProjectGitClient(directory: self.discovery.get().validate(record).path).diff(file) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionGeneration == generation, self.repositoryGeneration == repoGeneration, self.selectedRepository == record else { return }
                switch result {
                case .success(let text): self.difference.string = text
                case .failure(let error): self.clearState(); self.setStatus(error.localizedDescription, error: true); self.updateActions()
                }
            }
        }
    }
    private func updateActions() {
        repositoryPicker.isEnabled = !busy && !repositories.isEmpty
        refreshButton?.isEnabled = !busy
        stageButton?.isEnabled = !busy && selectedFile?.unstaged == true
        unstageButton?.isEnabled = !busy && selectedFile?.staged == true
        commitButton?.isEnabled = !busy && state?.files.contains(where: { $0.staged }) == true
        message.isEnabled = !busy && selectedRepository != nil && state != nil
    }
    private func perform(_ title: String, action: @escaping (ProjectGitClient) throws -> Void, completed: (() -> Void)? = nil) {
        guard !busy, state != nil, let record = selectedRepository else { return }
        rememberCurrentRepository(); busy = true; repositoryGeneration += 1; selectionGeneration += 1
        let generation = repositoryGeneration
        updateActions(); setStatus(title)
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try action(ProjectGitClient(directory: self.discovery.get().validate(record).path)) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.repositoryGeneration == generation, self.selectedRepository == record else { return }
                self.busy = false
                switch result {
                case .success: completed?(); self.rememberCurrentRepository(); self.loadRepository(record)
                case .failure(let error): self.clearState(); self.setStatus(error.localizedDescription, error: true); self.updateActions()
                }
            }
        }
    }
    private func commit() {
        let text = message.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { setStatus("请填写提交说明。", error: true); return }
        perform("正在提交…", action: { try $0.commit(message: text) }, completed: { [weak self] in
            guard let self else { return }; self.message.stringValue = ""
            if let record = self.selectedRepository { self.repositoryDrafts[record.directory.path] = "" }
        })
    }
    private func setStatus(_ text: String, error: Bool = false) {
        let suffix = scanIncomplete ? " · 可能还有仓库" : ""
        statusLabel.stringValue = text + suffix; statusLabel.toolTip = text + (scanNote.map { "\n" + $0 } ?? "")
        statusLabel.textColor = error ? Theme.warning : Theme.muted
    }
}
#endif
