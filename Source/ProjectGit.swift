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
        process.arguments = ["--no-pager", "--literal-pathspecs", "-c", "color.ui=false", "-c", "core.quotepath=false"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_PREFIX"] { environment.removeValue(forKey: key) }
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["LC_ALL"] = "C"; process.environment = environment
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
private final class ProjectGitSplit: NSStackView {
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

final class ProjectGitView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let directory: String
    private let queue = DispatchQueue(label: "ccam.project.git", qos: .userInitiated)
    private var client: ProjectGitClient?
    private var state: ProjectGitState?
    private var busy = false
    private var selectionGeneration = 0
    private let table = NSTableView()
    private let branch = label("正在读取 Git 状态…", size: 14, weight: .semibold)
    private let statusLabel = label("", size: 12, color: Theme.muted)
    private let difference = NSTextView()
    private let message = NSTextField()
    private var stageButton: ClosureButton!
    private var unstageButton: ClosureButton!
    private var commitButton: ClosureButton!
    private var selectedFile: ProjectGitFile? { guard let files = state?.files, files.indices.contains(table.selectedRow) else { return nil }; return files[table.selectedRow] }
    init(directory: String) {
        self.directory = directory
        super.init(frame: .zero)
        let refreshButton = ClosureButton("刷新", symbol: "arrow.clockwise") { [weak self] in self?.refresh() }
        stageButton = ClosureButton("暂存") { [weak self] in guard let self, let file = self.selectedFile else { return }; self.perform("正在暂存…") { try $0.stage(file) } }
        unstageButton = ClosureButton("取消暂存") { [weak self] in guard let self, let file = self.selectedFile else { return }; self.perform("正在取消暂存…") { try $0.unstage(file) } }
        commitButton = ClosureButton("提交", symbol: "checkmark") { [weak self] in self?.commit() }; commitButton.bezelColor = Theme.primary
        branch.maximumNumberOfLines = 1; branch.lineBreakMode = .byTruncatingMiddle
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")); nameColumn.title = "改动文件"; table.addTableColumn(nameColumn)
        table.headerView = nil; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.rowHeight = 30; table.dataSource = self; table.delegate = self; table.backgroundColor = Theme.panel
        let listing = NSScrollView(); listing.documentView = table; listing.hasVerticalScroller = true
        let diffScroll = ThemeScrollView(); diffScroll.documentView = difference; diffScroll.hasVerticalScroller = true; diffScroll.hasHorizontalScroller = true
        diffScroll.drawsBackground = true; diffScroll.backgroundColor = Theme.panel; diffScroll.wantsLayer = true; diffScroll.strokeColor = Theme.border; diffScroll.layer?.borderWidth = 1; diffScroll.layer?.cornerRadius = 8
        difference.isEditable = false; difference.isSelectable = true; difference.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        difference.textColor = Theme.text; difference.backgroundColor = Theme.panel; difference.textContainerInset = NSSize(width: 10, height: 10)
        difference.isVerticallyResizable = true; difference.isHorizontallyResizable = false; difference.autoresizingMask = [.width]; difference.textContainer?.widthTracksTextView = true
        difference.setAccessibilityLabel("文件差异"); diffScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        message.placeholderString = "提交说明"; message.font = Theme.font(size: 13); message.setAccessibilityLabel("提交说明")
        message.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let body = column([], spacing: 10)
        fillWidth(row([branch, spacer(), refreshButton]), in: body)
        let files = column([], spacing: 10)
        fillWidth(listing, in: files); fillWidth(row([stageButton, unstageButton, spacer()]), in: files)
        let detail = column([], spacing: 10)
        fillWidth(diffScroll, in: detail); fillWidth(message, in: detail); fillWidth(row([statusLabel, spacer(), commitButton]), in: detail)
        fillWidth(ProjectGitSplit(list: files, detail: detail, compactHeight: 194), in: body)
        body.translatesAutoresizingMaskIntoConstraints = false; addSubview(body)
        NSLayoutConstraint.activate([body.topAnchor.constraint(equalTo: topAnchor), body.bottomAnchor.constraint(equalTo: bottomAnchor), body.leadingAnchor.constraint(equalTo: leadingAnchor), body.trailingAnchor.constraint(equalTo: trailingAnchor)])
        updateActions(); refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    func refresh() {
        guard !busy else { return }; busy = true; selectionGeneration += 1; updateActions(); setStatus("正在读取…")
        let selectedPath = selectedFile?.path
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { () throws -> (ProjectGitClient, ProjectGitState) in let client = try self.client ?? ProjectGitClient(directory: self.directory); return (client, try client.status()) }
            DispatchQueue.main.async {
                switch result {
                case .success(let (client, state)):
                    self.client = client; self.state = state; self.branch.stringValue = state.branch; self.table.deselectAll(nil); self.table.reloadData()
                    self.setStatus(state.files.isEmpty ? "工作区干净" : "\(state.files.count) 个改动文件")
                    if let selectedPath, let index = state.files.firstIndex(where: { $0.path == selectedPath }) { self.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
                    else { self.difference.string = "选择文件查看差异。" }
                case .failure(let error): self.state = nil; self.table.deselectAll(nil); self.table.reloadData(); self.branch.stringValue = "Git"; self.difference.string = ""; self.setStatus(error.localizedDescription, error: true)
                }
                self.busy = false; self.updateActions(); self.loadDiff()
            }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { state?.files.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let item = state?.files[row] else { return nil }
        let text = label(item.title + "  " + item.path, size: 12); text.maximumNumberOfLines = 1; text.lineBreakMode = .byTruncatingMiddle; text.toolTip = item.path; return text
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateActions(); loadDiff() }
    private func loadDiff() {
        guard !busy, let client, let file = selectedFile else { return }
        selectionGeneration += 1; let generation = selectionGeneration; difference.string = "正在读取差异…"
        queue.async { [weak self] in
            let result = Result { try client.diff(file) }
            DispatchQueue.main.async { guard let self, self.selectionGeneration == generation else { return }; switch result { case .success(let text): self.difference.string = text; case .failure(let error): self.difference.string = error.localizedDescription } }
        }
    }
    private func updateActions() {
        stageButton?.isEnabled = !busy && selectedFile?.unstaged == true
        unstageButton?.isEnabled = !busy && selectedFile?.staged == true
        commitButton?.isEnabled = !busy && state?.files.contains(where: { $0.staged }) == true
        message.isEnabled = !busy
    }
    private func perform(_ title: String, action: @escaping (ProjectGitClient) throws -> Void, completed: (() -> Void)? = nil) {
        guard !busy, let client else { return }; busy = true; selectionGeneration += 1; updateActions(); setStatus(title)
        queue.async { [weak self] in
            let result = Result { try action(client) }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false
                switch result { case .success: completed?(); self.refresh(); case .failure(let error): self.setStatus(error.localizedDescription, error: true); self.updateActions() }
            }
        }
    }
    private func commit() {
        let text = message.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { setStatus("请填写提交说明。", error: true); return }
        perform("正在提交…", action: { try $0.commit(message: text) }, completed: { [weak self] in self?.message.stringValue = "" })
    }
    private func setStatus(_ text: String, error: Bool = false) { statusLabel.stringValue = text; statusLabel.textColor = error ? Theme.warning : Theme.muted }
}
#endif
