import AppKit

/// Native Markdown presentation. Raw HTML stays text; rendering never fetches
/// images, executes scripts, or starts a browser until a user follows a link.
enum ChatMarkdown {
    enum Block {
        case paragraph(String), heading(Int, String), list(String, String, Int)
        case quote(String), code(String, String), table([[String]], [NSTextAlignment]), rule
    }
    static func match(_ expression: String, _ value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: expression),
              let found = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (0..<found.numberOfRanges).map { Range(found.range(at: $0), in: value).map { String(value[$0]) } ?? "" }
    }
    static func cells(_ line: String) -> [String] {
        var result: [String] = [], cell = "", fence = 0, index = line.startIndex
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        while index < line.endIndex {
            let c = line[index]
            if c == "\\" {
                let next = line.index(after: index)
                if next < line.endIndex, line[next] == "|" { cell += "|"; index = line.index(after: next); continue }
            }
            if c == "`" {
                var end = index
                while end < line.endIndex, line[end] == "`" { end = line.index(after: end) }
                let count = line.distance(from: index, to: end)
                if fence == 0 { fence = count } else if fence == count { fence = 0 }
                cell += String(line[index..<end]); index = end; continue
            }
            if c == "|", fence == 0 { result.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(c) }
            index = line.index(after: index)
        }
        result.append(cell.trimmingCharacters(in: .whitespaces))
        if trimmed.hasPrefix("|"), result.first == "" { result.removeFirst() }
        if trimmed.hasSuffix("|"), result.last == "" { result.removeLast() }
        return result
    }
    static func blocks(_ text: String) -> [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [Block] = [], paragraph: [String] = [], i = 0
        func flush() { if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }
        while i < lines.count {
            let line = lines[i], trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); i += 1; continue }
            if let fence = match("^ {0,3}(`{3,}|~{3,})(.*)$", line) {
                flush(); let marker = fence[1]; let language = fence[2].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
                i += 1; var code: [String] = []; var closed = false
                while i < lines.count {
                    let end = lines[i].trimmingCharacters(in: .whitespaces)
                    if end.count >= marker.count, end.allSatisfy({ $0 == marker.first! }) { closed = true; i += 1; break }
                    code.append(lines[i]); i += 1
                }
                result.append(.code(language, code.joined(separator: "\n") + (closed && !code.isEmpty ? "\n" : ""))); continue
            }
            if i + 1 < lines.count, line.contains("|") {
                let header = cells(line), separators = cells(lines[i + 1])
                if header.count > 1, separators.count == header.count,
                   separators.allSatisfy({ match("^:?-{3,}:?$", $0) != nil }) {
                    flush(); var rows = [header]; i += 2
                    while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                        let row = cells(lines[i]); if row.count != header.count { break }; rows.append(row); i += 1
                    }
                    let alignment: [NSTextAlignment] = separators.map { $0.hasPrefix(":") && $0.hasSuffix(":") ? .center : $0.hasSuffix(":") ? .right : .left }
                    result.append(.table(rows, alignment)); continue
                }
            }
            if let heading = match("^ {0,3}(#{1,6})[ \\t]+(.+?)(?:[ \\t]+#+)?$", line) {
                flush(); result.append(.heading(heading[1].count, heading[2])); i += 1; continue
            }
            if i + 1 < lines.count, let underline = match("^ {0,3}(={3,}|-{3,})[ \\t]*$", lines[i + 1]) {
                flush(); result.append(.heading(underline[1].hasPrefix("=") ? 1 : 2, line)); i += 2; continue
            }
            if match("^ {0,3}(?:(?:\\*[ \\t]*){3,}|(?:-[ \\t]*){3,}|(?:_[ \\t]*){3,})$", line) != nil {
                flush(); result.append(.rule); i += 1; continue
            }
            if let quote = match("^ {0,3}>[ \\t]?(.*)$", line) {
                flush(); result.append(.quote(quote[1])); i += 1; continue
            }
            if let item = match("^( *)([-+*]|[0-9]+[.)])[ \\t]+(.*)$", line) {
                flush(); var body = item[3], bullet = item[2].count == 1 ? "•" : item[2]
                if let task = match("^\\[([ xX])\\][ \\t]+(.*)$", body) { bullet = task[1] == " " ? "☐" : "☑"; body = task[2] }
                result.append(.list(bullet, body, min(6, item[1].count / 2))); i += 1; continue
            }
            paragraph.append(line); i += 1
        }
        flush(); return result
    }
    static func inline(_ text: String, size: CGFloat = 15, color: NSColor = Theme.text, weight: NSFont.Weight = .regular) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        let base: [NSAttributedString.Key: Any] = [.font: Theme.font(size: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph]
        guard let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: text, attributes: base)
        }
        let output = NSMutableAttributedString(string: "")
        for run in parsed.runs {
            var attributes = base
            let intent = run.inlinePresentationIntent ?? []
            var font = Theme.font(size: size, weight: intent.contains(.stronglyEmphasized) ? .semibold : weight)
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            if intent.contains(.code) {
                font = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
                attributes[.backgroundColor] = Theme.border.withAlphaComponent(0.55)
            }
            attributes[.font] = font
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link, ["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                attributes[.link] = link; attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return output
    }
    static func field(_ content: NSAttributedString) -> NSTextField {
        let view = label(content.string, size: 15)
        view.isSelectable = true; view.allowsEditingTextAttributes = true
        view.attributedStringValue = content; view.maximumNumberOfLines = 0; view.lineBreakMode = .byWordWrapping
        return view
    }
    static func language(_ name: String) -> CodeLanguage {
        let aliases = ["rust":"rs", "javascript":"js", "typescript":"ts", "python":"py", "bash":"sh", "shell":"sh", "c++":"cpp", "csharp":"cs", "kotlin":"kt", "ruby":"rb", "markdown":"md", "protobuf":"proto"]
        return CodeLanguage.detect(path: name.lowercased() == "dockerfile" ? "Dockerfile" : "code." + (aliases[name.lowercased()] ?? name.lowercased()))
    }
    static func code(_ source: String, language name: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle(); style.lineSpacing = 3
        let text = NSMutableAttributedString(string: source, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: Theme.text, .paragraphStyle: style])
        for token in CodeHighlighter.tokens(source, language: language(name)) {
            let color: NSColor
            switch token.kind {
            case .keyword: color = .systemPurple
            case .string: color = .systemGreen
            case .comment: color = Theme.muted
            case .number: color = .systemOrange
            case .type: color = .systemTeal
            case .function: color = .systemBlue
            default: color = Theme.text
            }
            text.addAttribute(.foregroundColor, value: color, range: token.range)
        }
        return text
    }
}

final class ChatMarkdownView: NSStackView {
    let source: String
    init(_ source: String, color: NSColor = Theme.text) {
        self.source = source
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 12
        for block in ChatMarkdown.blocks(source) {
            let view: NSView
            switch block {
            case .paragraph(let text): view = ChatMarkdown.field(ChatMarkdown.inline(text, color: color))
            case .heading(let level, let text):
                view = ChatMarkdown.field(ChatMarkdown.inline(text, size: level == 1 ? 23 : level == 2 ? 20 : 17, color: color, weight: .semibold))
                view.setAccessibilityLabel("标题 \(level)：" + ChatMarkdown.inline(text).string)
            case .list(let marker, let text, let depth):
                let bullet = label(marker, size: 14, color: Theme.muted)
                bullet.widthAnchor.constraint(equalToConstant: 24).isActive = true
                let body = ChatMarkdown.field(ChatMarkdown.inline(text, color: color))
                let line = row([bullet, body], spacing: 6); line.alignment = .top
                line.distribution = .fill
                line.edgeInsets = NSEdgeInsets(top: 0, left: CGFloat(depth) * 16, bottom: 0, right: 0)
                body.setContentHuggingPriority(.defaultLow, for: .horizontal)
                view = line
            case .quote(let text):
                let rule = ThemeSurface(Theme.border); rule.widthAnchor.constraint(equalToConstant: 3).isActive = true
                let body = ChatMarkdown.field(ChatMarkdown.inline(text, color: Theme.muted))
                let line = row([rule, body], spacing: 12); line.alignment = .top
                rule.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true; view = line
            case .code(let language, let code):
                let copy = ClosureButton("", symbol: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) }
                copy.isBordered = false; copy.setAccessibilityLabel("复制代码"); copy.toolTip = "复制代码"
                let text = ChatMarkdown.field(ChatMarkdown.code(code, language: language)); text.setAccessibilityLabel("代码块")
                let content = column([], spacing: 8)
                fillWidth(row([label(language.isEmpty ? "代码" : language, size: 11, color: Theme.muted), spacer(), copy]), in: content)
                fillWidth(text, in: content); view = Card(content, padding: 12)
            case .table(let rows, let alignment): view = ChatMarkdownTable(rows: rows, alignment: alignment)
            case .rule: view = divider()
            }
            fillWidth(view, in: self)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Table cells wrap independently. Narrow panes scroll horizontally, keeping
/// long code identifiers readable without stretching the whole conversation.
final class ChatMarkdownTable: NSView {
    private let scroll = MarkdownTableScrollView()
    private let canvas: MarkdownTableCanvas
    private var lastWidth: CGFloat = -1
    var measurementPasses: Int { canvas.measurementPasses }
    init(rows: [[String]], alignment: [NSTextAlignment]) {
        canvas = MarkdownTableCanvas(rows: rows, alignment: alignment)
        super.init(frame: .zero)
        scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.scrollerStyle = .legacy
        scroll.documentView = canvas; scroll.wantsLayer = true; addSubview(scroll)
        setAccessibilityLabel("表格，\(rows.count - 1) 行，\(alignment.count) 列")
    }
    required init?(coder: NSCoder) { fatalError() }
    private var contentWidth: CGFloat { ceil(max(bounds.width, CGFloat(canvas.columns) * 150)) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: canvas.prepare(width: contentWidth) + (contentWidth > bounds.width + 1 ? 16 : 0)) }
    override func layout() {
        super.layout()
        let needsHorizontal = contentWidth > bounds.width + 1
        if scroll.hasHorizontalScroller != needsHorizontal { scroll.hasHorizontalScroller = needsHorizontal }
        if scroll.frame != bounds { scroll.frame = bounds }
        let frame = NSRect(x: 0, y: 0, width: contentWidth, height: canvas.prepare(width: contentWidth))
        if canvas.frame != frame { canvas.frame = frame }
        if lastWidth != bounds.width { lastWidth = bounds.width; invalidateIntrinsicContentSize() }
    }
}

/// A table owns horizontal movement only. Vertical trackpad/wheel gestures
/// belong to the outer conversation, including when the pointer is over a cell.
final class MarkdownTableScrollView: NSScrollView {
    static func forwardsToConversation(horizontal: CGFloat, vertical: CGFloat, canScrollHorizontally: Bool) -> Bool {
        vertical != 0 && (abs(vertical) >= abs(horizontal) || !canScrollHorizontally)
    }
    override func scrollWheel(with event: NSEvent) {
        if Self.forwardsToConversation(horizontal: event.scrollingDeltaX, vertical: event.scrollingDeltaY, canScrollHorizontally: hasHorizontalScroller),
           let conversation = superview?.enclosingScrollView {
            conversation.scrollWheel(with: event)
        } else { super.scrollWheel(with: event) }
    }
}

private final class MarkdownTableCanvas: NSView {
    let columns: Int
    private var fields: [[NSTextField]] = []
    private var weights: [CGFloat] = []
    private var rowFrames: [NSRect] = []
    private var preparedWidth: CGFloat = -1
    private var preparedHeight: CGFloat = 0
    private(set) var measurementPasses = 0
    override var isFlipped: Bool { true }
    init(rows: [[String]], alignment: [NSTextAlignment]) {
        columns = alignment.count
        super.init(frame: .zero)
        weights = (0..<columns).map { column in min(45, max(12, CGFloat(rows.map { $0[column].count }.max() ?? 12).squareRoot() * 4)) }
        for (index, row) in rows.enumerated() {
            fields.append(row.enumerated().map { column, text in
                let field = ChatMarkdown.field(ChatMarkdown.inline(text, size: 13, weight: index == 0 ? .semibold : .regular))
                let aligned = NSMutableAttributedString(attributedString: field.attributedStringValue)
                aligned.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: aligned.length)) { value, range, _ in
                    let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                    style.alignment = alignment[column]; aligned.addAttribute(.paragraphStyle, value: style, range: range)
                }
                field.attributedStringValue = aligned; addSubview(field); return field
            })
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    @discardableResult func prepare(width: CGFloat) -> CGFloat {
        guard preparedWidth != width else { return preparedHeight }
        preparedWidth = width; measurementPasses += 1
        let total = weights.reduce(0, +), widths = weights.map { width * $0 / max(1, total) }
        var y: CGFloat = 0, frames: [NSRect] = []
        for row in fields {
            let heights = row.enumerated().map { index, field in
                ceil(field.attributedStringValue.boundingRect(with: NSSize(width: max(20, widths[index] - 22), height: 1_000_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 4
            }
            let height = max(22, heights.max() ?? 22) + 20; var x: CGFloat = 0
            for (index, field) in row.enumerated() {
                field.frame = NSRect(x: x + 10, y: y + 10, width: widths[index] - 20, height: height - 20)
                x += widths[index]
            }
            frames.append(NSRect(x: 0, y: y, width: width, height: height)); y += height
        }
        rowFrames = frames; preparedHeight = y; needsDisplay = true
        return y
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for (index, frame) in rowFrames.enumerated() where frame.intersects(dirtyRect) {
            (index == 0 ? Theme.border.withAlphaComponent(0.5) : Theme.panel.withAlphaComponent(0.5)).setFill(); frame.fill()
            Theme.border.setFill(); NSRect(x: frame.minX, y: frame.maxY - 1, width: frame.width, height: 1).fill()
        }
    }
}
