import AppKit
import PDFKit
import UniformTypeIdentifiers

/// The caller supplies data already bounded and checked by ProjectFileStore.
/// No remote resource or executable is loaded to produce a file preview.
final class ProjectFilePreviewView: NSView {
    private let filename: String
    private let byteCount: Int64
    private let openExternally: () throws -> Void
    private let message = label("", size: 12, color: Theme.muted)
    private(set) var pdfView: PDFView?
    private(set) var showsPDF = false
    private(set) var documentTextView: NSTextView?
    private(set) var showsDocument = false
    private static let documentQueue = DispatchQueue(label: "ccam.file.document-preview", qos: .userInitiated)

    init(data: Data?, filename: String, byteCount: Int64, notice: String? = nil, openExternally: @escaping () throws -> Void) {
        self.filename = filename; self.byteCount = byteCount; self.openExternally = openExternally
        super.init(frame: .zero)
        let ext = (filename as NSString).pathExtension.lowercased()
        let contentType = UTType(filenameExtension: ext)
        let description = contentType?.localizedDescription ?? (ext.isEmpty ? "文件" : ext.uppercased() + " 文件")
        let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        let title = label((filename as NSString).lastPathComponent, size: 14, weight: .medium)
        title.maximumNumberOfLines = 1; title.lineBreakMode = .byTruncatingMiddle; title.toolTip = filename
        let metadata = label(description + " · " + size, size: 12, color: Theme.muted)
        metadata.maximumNumberOfLines = 1; metadata.lineBreakMode = .byTruncatingMiddle
        let open = ClosureButton("在默认应用中打开", symbol: "arrow.up.forward.square") { [weak self] in
            guard let self else { return }
            do { try self.openExternally() }
            catch { self.message.stringValue = error.localizedDescription; self.message.textColor = Theme.warning }
        }
        open.setAccessibilityLabel("在默认应用中打开文件")
        // Opening scripts or executables in their default handler can run them.
        // Those formats remain inspectable here without presenting a launch action.
        open.isHidden = !Self.canOpenExternally(filename: filename)
        message.maximumNumberOfLines = 2; message.lineBreakMode = .byTruncatingTail
        let heading = column([], spacing: 6)
        fillWidth(title, in: heading); fillWidth(metadata, in: heading)
        heading.translatesAutoresizingMaskIntoConstraints = false; addSubview(heading)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 10), heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            heading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        ])
        let footer = row([message, spacer(), open], spacing: 8)
        footer.translatesAutoresizingMaskIntoConstraints = false; addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        if ext == "pdf", let data, data.count <= 32 * 1024 * 1024, let document = PDFDocument(data: data), document.pageCount > 0 {
            let viewer = PDFView()
            viewer.document = document; viewer.autoScales = true; viewer.displayMode = .singlePageContinuous
            viewer.displayDirection = .vertical; viewer.displaysPageBreaks = true; viewer.backgroundColor = Theme.panel
            viewer.setAccessibilityLabel("PDF 文件预览")
            viewer.translatesAutoresizingMaskIntoConstraints = false; addSubview(viewer)
            NSLayoutConstraint.activate([
                viewer.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8), viewer.leadingAnchor.constraint(equalTo: leadingAnchor),
                viewer.trailingAnchor.constraint(equalTo: trailingAnchor), viewer.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6)
            ])
            pdfView = viewer; showsPDF = true
            message.stringValue = "\(document.pageCount) 页"
        } else if let documentType = Self.documentType(extension: ext), let data, data.count <= 4 * 1024 * 1024 {
            let text = NSTextView()
            text.isEditable = false; text.isSelectable = true; text.isRichText = false
            text.font = Theme.font(size: 14); text.textColor = Theme.text; text.backgroundColor = Theme.panel
            text.textContainerInset = NSSize(width: 14, height: 12)
            text.isVerticallyResizable = true; text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
            text.setAccessibilityLabel("文档只读预览")
            let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.drawsBackground = true; scroll.backgroundColor = Theme.panel
            scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6)
            ])
            documentTextView = text; message.stringValue = "正在读取文档…"
            Self.documentQueue.async { [weak self] in
                let result = Result { () throws -> String in
                    // Only explicit local document importers are allowed; never
                    // use HTML autodetection, WebKit, embedded objects or macros.
                    let attributed = try NSAttributedString(data: data, options: [.documentType: documentType], documentAttributes: nil)
                    let plain = attributed.string
                    guard plain.utf16.count <= 2 * 1024 * 1024 else { throw ProjectFileError.message("文档内容较大，请在外部查看") }
                    return plain
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let plain): self.documentTextView?.string = plain; self.showsDocument = true; self.message.stringValue = "只读文档"
                    case .failure: self.message.stringValue = "无法预览，请在默认应用中打开"
                    }
                    self.message.toolTip = self.message.stringValue
                }
            }
        } else {
            let symbol = NSImageView(image: NSImage(systemSymbolName: "doc", accessibilityDescription: description) ?? NSImage())
            symbol.contentTintColor = Theme.muted; symbol.imageScaling = .scaleProportionallyUpOrDown
            symbol.translatesAutoresizingMaskIntoConstraints = false; addSubview(symbol)
            NSLayoutConstraint.activate([
                symbol.widthAnchor.constraint(equalToConstant: 36), symbol.heightAnchor.constraint(equalToConstant: 44),
                symbol.centerXAnchor.constraint(equalTo: centerXAnchor), symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
                symbol.topAnchor.constraint(greaterThanOrEqualTo: heading.bottomAnchor, constant: 8),
                symbol.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -8)
            ])
            if ext == "pdf" { message.stringValue = data == nil ? "文件较大，请在外部查看" : "无法显示此 PDF" }
            else if open.isHidden { message.stringValue = "可执行文件，仅显示文件信息" }
            else { message.stringValue = "此格式使用默认应用查看" }
            if let notice, !notice.isEmpty { message.stringValue = notice }
        }
        message.toolTip = message.stringValue
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func documentType(extension ext: String) -> NSAttributedString.DocumentType? {
        switch ext {
        case "rtf": return .rtf
        case "docx": return .officeOpenXML
        case "odt": return .openDocument
        default: return nil
        }
    }

    static func canOpenExternally(filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        return !(["app", "command", "sh", "bash", "zsh", "fish", "py", "pyw", "js", "mjs", "cjs", "ts", "rb", "pl", "php", "lua", "scpt", "applescript", "workflow", "jar", "exe", "com", "bat", "cmd", "ps1", "msi", "pkg"].contains(ext)
            || type?.conforms(to: .executable) == true || type?.conforms(to: .application) == true)
    }
}
