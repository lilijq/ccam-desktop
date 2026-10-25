import Foundation
#if !CODE_EDITOR_CORE_ONLY
import AppKit
#endif

enum CodeLanguage: String, CaseIterable {
    case rust = "Rust", swift = "Swift", javascript = "JavaScript", typescript = "TypeScript"
    case python = "Python", json = "JSON", yaml = "YAML", toml = "TOML", markdown = "Markdown"
    case shell = "Shell", c = "C / C++", go = "Go", css = "CSS", html = "HTML"
    case java = "Java", kotlin = "Kotlin", csharp = "C#", ruby = "Ruby", php = "PHP"
    case vue = "Vue", svelte = "Svelte", sql = "SQL", docker = "Dockerfile", ini = "配置文件"
    case dart = "Dart", lua = "Lua", r = "R", perl = "Perl", graphql = "GraphQL", protobuf = "Protocol Buffers"
    case plain = "纯文本"
    static func detect(path: String) -> CodeLanguage {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if name == "dockerfile" || name.hasPrefix("dockerfile.") || name == "containerfile" { return .docker }
        if name == "makefile" || name == "justfile" { return .shell }
        if name == ".env" || name.hasPrefix(".env.") || name == ".gitignore" || name == ".editorconfig" { return .ini }
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "rs": return .rust
        case "swift": return .swift
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "py", "pyi": return .python
        case "json", "jsonc": return .json
        case "yml", "yaml": return .yaml
        case "toml": return .toml
        case "md", "markdown", "mdx": return .markdown
        case "sh", "bash", "zsh", "fish": return .shell
        case "c", "h", "cc", "cpp", "hpp", "hxx": return .c
        case "go": return .go
        case "css", "scss", "sass", "less": return .css
        case "html", "htm", "xml", "svg": return .html
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "cs", "csx": return .csharp
        case "rb", "rake", "gemspec": return .ruby
        case "php", "phtml": return .php
        case "vue": return .vue
        case "svelte": return .svelte
        case "sql": return .sql
        case "ini", "conf", "cfg", "properties", "env": return .ini
        case "dart": return .dart
        case "lua": return .lua
        case "r", "rmd": return .r
        case "pl", "pm": return .perl
        case "graphql", "gql": return .graphql
        case "proto": return .protobuf
        default: return [".zshrc", ".bashrc", ".profile", ".zshenv"].contains(name) ? .shell : .plain
        }
    }
    var icon: String {
        switch self {
        case .rust, .c: return "curlybraces"
        case .swift: return "swift"
        case .json, .yaml, .toml, .ini: return "slider.horizontal.3"
        case .markdown: return "doc.richtext"
        case .shell, .docker: return "terminal"
        case .plain: return "doc"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

enum CodeTokenKind: Equatable { case keyword, type, string, comment, number, function, property, heading }
struct CodeToken: Equatable {
    let range: NSRange
    let kind: CodeTokenKind
}

/// UTF-16 offsets match NSTextStorage directly. A single forward scan keeps
/// large source files linear, including nested Rust comments and raw strings.
enum CodeHighlighter {
    private static let commonKeywords = Set("as async await break case catch class const continue default defer do else enum export extends false finally for from func function if impl import in interface let match module mut namespace new nil null package private protected pub public raise ref return self Self static struct super switch throw throws trait true try type typedef typeof unsafe use var virtual void where while yield".split(separator: " ").map(String.init))
    private static let rustKeywords = Set("abstract become box crate dyn extern final fn loop macro move override priv sized union unsized async await mod macro_rules type const in for while match if let else self Self super where as use return break continue unsafe impl trait struct enum pub mut ref static extern dyn".split(separator: " ").map(String.init))
    private static let pythonKeywords = Set("and assert async await class def del elif except False finally global is lambda None nonlocal not or pass True with yield print".split(separator: " ").map(String.init))
    private static let types = Set("str String bool char i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 Int UInt Float Double Bool Character Array Dictionary Set Option Result Vec Box Rc Arc Some None Ok Err String Number Boolean Object Promise Any AnyObject Error List int float double long short size_t string boolean number never unknown any tuple list dict set bytes".split(separator: " ").map(String.init))
    private static let extraKeywords = Set("def end unless until begin rescue ensure require include module attr_reader attr_accessor puts lambda val fun when object sealed data open override companion lateinit suspend synchronized volatile transient native instanceof implements extends abstract this null get set using internal readonly record event delegate operator lock checked unchecked out params foreach cast echo function namespace implements extends isset empty fn local then elseif repeat in pairs ipairs select create table insert into values update delete from where join left right inner outer on group by order having limit offset union all distinct alter drop index primary key references constraint default not null select from where and or asc desc add run cmd entrypoint copy workdir env arg expose volume user label healthcheck stopsignal syntax package message service rpc returns repeated optional reserved oneof enum query mutation subscription fragment true false".split(separator: " ").map(String.init))
    static func tokens(_ text: String, language: CodeLanguage) -> [CodeToken] {
        guard language != .plain else { return [] }
        let chars = Array(text.utf16), count = chars.count
        var result: [CodeToken] = [], i = 0, expectsFunctionName = false
        result.reserveCapacity(min(count / 6, 50_000))
        func has(_ value: [UInt16], at index: Int) -> Bool {
            index >= 0 && index + value.count <= count && chars[index..<(index + value.count)].elementsEqual(value)
        }
        func add(_ start: Int, _ end: Int, _ kind: CodeTokenKind) { if end > start { result.append(CodeToken(range: NSRange(location: start, length: end - start), kind: kind)) } }
        func word(_ c: UInt16) -> Bool { c == 95 || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c >= 128 }
        func digit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        let hashComments: Set<CodeLanguage> = [.python, .shell, .yaml, .toml, .ruby, .php, .ini, .docker, .r, .perl, .graphql]
        let cComments: Set<CodeLanguage> = [.rust, .swift, .javascript, .typescript, .json, .c, .go, .css, .java, .kotlin, .csharp, .php, .vue, .svelte, .dart, .protobuf, .sql]
        while i < count {
            let start = i, c = chars[i]
            if ((language == .sql || language == .lua) && has([45, 45], at: i)) || (language == .ini && c == 59) {
                while i < count && chars[i] != 10 && chars[i] != 13 { i += 1 }; add(start, i, .comment); continue
            }
            if (hashComments.contains(language) && c == 35) || (cComments.contains(language) && has([47, 47], at: i)) {
                while i < count && chars[i] != 10 && chars[i] != 13 { i += 1 }; add(start, i, .comment); continue
            }
            if cComments.contains(language) && has([47, 42], at: i) {
                i += 2; var depth = 1
                while i < count && depth > 0 {
                    if (language == .rust || language == .swift) && has([47, 42], at: i) { depth += 1; i += 2 }
                    else if has([42, 47], at: i) { depth -= 1; i += 2 }
                    else { i += 1 }
                }; add(start, i, .comment); continue
            }
            if ([CodeLanguage.html, .markdown, .vue, .svelte].contains(language)) && has([60, 33, 45, 45], at: i) {
                i += 4; while i < count && !has([45, 45, 62], at: i) { i += 1 }; i = min(count, i + 3); add(start, i, .comment); continue
            }
            if language == .markdown {
                if c == 35 && (i == 0 || chars[i - 1] == 10) {
                    while i < count && chars[i] != 10 { i += 1 }; add(start, i, .heading); continue
                }
                if c == 96 {
                    var delimiterCount = 1; while i + delimiterCount < count && chars[i + delimiterCount] == 96 { delimiterCount += 1 }
                    let delimiter = Array(repeating: UInt16(96), count: delimiterCount); i += delimiterCount
                    while i < count && !has(delimiter, at: i) { i += 1 }; i = min(count, i + delimiterCount); add(start, i, .string); continue
                }
                i += 1; continue
            }
            if language == .rust && (c == 114 || (c == 98 && has([98, 114], at: i))) {
                var cursor = i + (c == 98 ? 2 : 1), hashes = 0
                while cursor < count && chars[cursor] == 35 { hashes += 1; cursor += 1 }
                if cursor < count && chars[cursor] == 34 {
                    let end = [UInt16(34)] + Array(repeating: UInt16(35), count: hashes)
                    i = cursor + 1; while i < count && !has(end, at: i) { i += 1 }; i = min(count, i + end.count); add(start, i, .string); continue
                }
            }
            if c == 34 || c == 39 || ((language == .javascript || language == .typescript || language == .go || language == .shell) && c == 96) {
                // Rust lifetimes are identifiers, not the beginning of a string.
                let characterEnd = i + ((i + 1 < count && (0xD800...0xDBFF).contains(chars[i + 1])) ? 3 : 2)
                if language == .rust && c == 39 && i + 1 < count && word(chars[i + 1]) && !(characterEnd < count && chars[characterEnd] == 39) {
                    i += 2; while i < count && (word(chars[i]) || digit(chars[i])) { i += 1 }; add(start, i, .type); continue
                }
                let triple = (language == .python || language == .swift || language == .toml) && has([c, c, c], at: i)
                let delimiter = Array(repeating: c, count: triple ? 3 : 1); i += delimiter.count
                while i < count {
                    if chars[i] == 92 { i = min(count, i + 2) }
                    else if has(delimiter, at: i) { i += delimiter.count; break }
                    else if !triple && c != 96 && (chars[i] == 10 || chars[i] == 13) { break }
                    else { i += 1 }
                }
                var after = i; while after < count && (chars[after] == 32 || chars[after] == 9) { after += 1 }
                add(start, i, language == .json && after < count && chars[after] == 58 ? .property : .string); continue
            }
            if digit(c) && (i == 0 || !word(chars[i - 1])) {
                i += 1
                while i < count && (digit(chars[i]) || chars[i] == 95 || chars[i] == 46 || (chars[i] >= 65 && chars[i] <= 70) || (chars[i] >= 97 && chars[i] <= 102) || chars[i] == 120 || chars[i] == 111 || chars[i] == 98) { i += 1 }
                add(start, i, .number); continue
            }
            if word(c) {
                i += 1; while i < count && (word(chars[i]) || digit(chars[i])) { i += 1 }
                let value = String(decoding: chars[start..<i], as: UTF16.self)
                var next = i; while next < count && (chars[next] == 32 || chars[next] == 9) { next += 1 }
                let memberCall = start > 0 && (chars[start - 1] == 46 || chars[start - 1] == 58) && next < count && chars[next] == 40
                if expectsFunctionName || memberCall { add(start, i, .function) }
                else if commonKeywords.contains(value) || (language == .rust && rustKeywords.contains(value)) || (language == .python && pythonKeywords.contains(value)) || extraKeywords.contains((language == .sql || language == .docker) ? value.lowercased() : value) { add(start, i, .keyword) }
                else if types.contains(value) || (c >= 65 && c <= 90) { add(start, i, .type) }
                else if next < count && (chars[next] == 40 || (language == .rust && chars[next] == 33)) { add(start, i, .function) }
                else if (language == .yaml || language == .toml || language == .css || language == .ini) && next < count && (chars[next] == 58 || chars[next] == 61) { add(start, i, .property) }
                expectsFunctionName = ["fn", "func", "function", "def", "fun"].contains(value)
                continue
            }
            i += 1
        }
        return result
    }
    static func lineStarts(_ text: String) -> [Int] {
        var starts = [0], offset = 0
        for character in text.utf16 { offset += 1; if character == 10 { starts.append(offset) } }
        return starts
    }
    static func lineIndex(at offset: Int, starts: [Int]) -> Int {
        var low = 0, high = starts.count
        while low < high { let middle = (low + high) / 2; if starts[middle] <= offset { low = middle + 1 } else { high = middle } }
        return max(0, low - 1)
    }
}

#if !CODE_EDITOR_CORE_ONLY
private enum CodePalette {
    static let background = Theme.adaptive(0xFFFFFF, 0x131313)
    static let gutter = Theme.adaptive(0xF7F7F7, 0x131313)
    static let foreground = Theme.adaptive(0x242424, 0xD4D4D4)
    static func color(_ kind: CodeTokenKind) -> NSColor {
        switch kind {
        case .keyword: return Theme.adaptive(0x8A3DA0, 0xC586C0)
        case .type: return Theme.adaptive(0x267F99, 0x4EC9B0)
        case .string: return Theme.adaptive(0xA31515, 0xCE9178)
        case .comment: return Theme.adaptive(0x527D35, 0x7E9D6B)
        case .number: return Theme.adaptive(0x0B7F67, 0xB5CEA8)
        case .function: return Theme.adaptive(0x795E26, 0xDCDCAA)
        case .property: return Theme.adaptive(0x0451A5, 0x9CDCFE)
        case .heading: return Theme.adaptive(0x0451A5, 0x569CD6)
        }
    }
}

final class CodeTextView: NSTextView {
    var onSave: (() -> Void)?
    var documentUndoManager = UndoManager()
    override var undoManager: UndoManager? { documentUndoManager }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == .command {
            if event.charactersIgnoringModifiers?.lowercased() == "s" { onSave?(); return true }
            if event.charactersIgnoringModifiers?.lowercased() == "f" {
                let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
                performFindPanelAction(item); return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
    override func insertTab(_ sender: Any?) { insertText("    ", replacementRange: selectedRange()) }
    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertNewline(sender); return }
        let source = string as NSString, range = selectedRange()
        let line = source.lineRange(for: NSRange(location: min(range.location, source.length), length: 0))
        let prefix = source.substring(with: NSRange(location: line.location, length: max(0, range.location - line.location)))
        let indentation = String(prefix.prefix { $0 == " " || $0 == "\t" })
        insertText("\n" + indentation, replacementRange: range)
    }
}

private final class CodeLineRuler: NSRulerView {
    weak var editor: CodeEditorView?
    override var isFlipped: Bool { true }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        CodePalette.gutter.setFill(); bounds.fill()
        guard let editor, let layout = editor.textView.layoutManager, let container = editor.textView.textContainer else { return }
        let textView = editor.textView, visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y), in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = CodeHighlighter.lineIndex(at: chars.location, starts: editor.lineStarts)
        let last = min(editor.lineStarts.count - 1, CodeHighlighter.lineIndex(at: NSMaxRange(chars), starts: editor.lineStarts) + 1)
        guard first <= last else { return }
        let selectedLine = CodeHighlighter.lineIndex(at: textView.selectedRange().location, starts: editor.lineStarts)
        for index in first...last {
            let offset = editor.lineStarts[index], fragment: NSRect
            if offset < (textView.string as NSString).length {
                fragment = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: offset), effectiveRange: nil)
            } else { fragment = layout.extraLineFragmentRect }
            let point = convert(NSPoint(x: 0, y: fragment.minY + textView.textContainerOrigin.y), from: textView)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: index == selectedLine ? Theme.text : Theme.muted.withAlphaComponent(0.65)]
            let number = NSAttributedString(string: String(index + 1), attributes: attributes)
            number.draw(at: NSPoint(x: ruleThickness - number.size().width - 10, y: point.y + 1))
        }
    }
}

/// Native editable source view. Syntax lives in NSLayoutManager's temporary
/// attributes so highlighting never changes undo history or document contents.
final class CodeEditorView: NSView, NSTextViewDelegate {
    let textView = CodeTextView(frame: .zero)
    let scroll = ThemeScrollView()
    private var ruler: CodeLineRuler!
    private let position = label("行 1，列 1", size: 11, color: Theme.muted)
    private let languageLabel = label("纯文本", size: 11, color: Theme.muted)
    private let footer = ThemeSurface(Theme.background)
    private let syntaxQueue = DispatchQueue(label: "ccam.editor.syntax", qos: .userInitiated)
    private var highlightWork: DispatchWorkItem?
    private var revision = 0
    private(set) var lineStarts = [0]
    private(set) var language = CodeLanguage.plain
    private(set) var syntaxTokens: [CodeToken] = []
    var onChange: (() -> Void)?
    var onSave: (() -> Void)? { didSet { textView.onSave = onSave } }
    var text: String { textView.string }
    var isEditable: Bool { get { textView.isEditable } set { textView.isEditable = newValue } }
    init() {
        super.init(frame: .zero)
        textView.isRichText = false; textView.allowsUndo = true; textView.isEditable = false
        textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false; textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false; textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false; textView.isAutomaticDataDetectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = CodePalette.foreground; textView.backgroundColor = CodePalette.background; textView.insertionPointColor = Theme.text
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.minSize = .zero; textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.usesFindBar = true; textView.isIncrementalSearchingEnabled = true; textView.delegate = self
        textView.setAccessibilityLabel("代码编辑器")
        scroll.documentView = textView; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.backgroundColor = CodePalette.background; scroll.drawsBackground = true; scroll.borderType = .noBorder
        ruler = CodeLineRuler(scrollView: scroll, orientation: .verticalRuler); ruler.editor = self; ruler.clientView = textView; ruler.ruleThickness = 44
        scroll.verticalRulerView = ruler; scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        let footerRow = row([position, spacer(), languageLabel, label("UTF-8", size: 11, color: Theme.muted)], spacing: 12)
        footerRow.translatesAutoresizingMaskIntoConstraints = false; footer.addSubview(footerRow)
        for view in [scroll, footer] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor), footer.trailingAnchor.constraint(equalTo: trailingAnchor), footer.bottomAnchor.constraint(equalTo: bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 26),
            footerRow.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 10), footerRow.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -10), footerRow.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { highlightWork?.cancel(); NotificationCenter.default.removeObserver(self) }
    override func layout() {
        super.layout()
        textView.minSize = NSSize(width: max(0, scroll.contentSize.width), height: max(0, scroll.contentSize.height))
        if textView.frame.width < scroll.contentSize.width { textView.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(textView.frame.height, scroll.contentSize.height))) }
        ruler.needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyTokens(); ruler?.needsDisplay = true }
    func setDocument(text: String, path: String, selection: NSRange = NSRange(location: 0, length: 0), undoManager: UndoManager? = nil) {
        revision += 1; highlightWork?.cancel(); syntaxTokens = []
        textView.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: (textView.string as NSString).length))
        textView.documentUndoManager = undoManager ?? UndoManager()
        textView.string = text
        language = CodeLanguage.detect(path: path); languageLabel.stringValue = language.rawValue
        let length = (text as NSString).length, location = min(selection.location == NSNotFound ? 0 : selection.location, (text as NSString).length)
        textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        textView.scrollToBeginningOfDocument(nil); textView.isEditable = true
        updateLines(); scheduleHighlight(delay: 0)
    }
    func find() { let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue; window?.makeFirstResponder(textView); textView.performFindPanelAction(item) }
    func textDidChange(_ notification: Notification) { updateLines(); scheduleHighlight(delay: 0.12); onChange?() }
    func textViewDidChangeSelection(_ notification: Notification) { updatePosition(); ruler.needsDisplay = true }
    @objc private func scrolled() { ruler.needsDisplay = true; applyTokens() }
    private func updateLines() {
        lineStarts = CodeHighlighter.lineStarts(textView.string)
        ruler.ruleThickness = max(44, CGFloat(String(lineStarts.count).count) * 7 + 20)
        updatePosition(); ruler.needsDisplay = true
    }
    private func updatePosition() {
        let offset = textView.selectedRange().location, line = CodeHighlighter.lineIndex(at: offset, starts: lineStarts)
        position.stringValue = "行 \(line + 1)，列 \(max(1, offset - lineStarts[line] + 1))"
    }
    private func scheduleHighlight(delay: TimeInterval) {
        revision += 1; let version = revision, source = textView.string, language = language
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            let tokens = CodeHighlighter.tokens(source, language: language)
            DispatchQueue.main.async {
                guard let self, self.revision == version else { return }
                if self.textView.hasMarkedText() { self.scheduleHighlight(delay: 0.2); return }
                self.syntaxTokens = tokens; self.applyTokens()
            }
        }
        highlightWork = work; syntaxQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func applyTokens() {
        guard let manager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
        // Colour only the visible portion plus a generous buffer. The full token
        // list is computed off-main; scrolling does not add hundreds of thousands
        // of attributes to a large file on the UI thread.
        var visible = NSRange(location: 0, length: min(length, 5_000))
        if let container = textView.textContainer, textView.visibleRect.height > 0 {
            let glyphs = manager.glyphRange(forBoundingRect: textView.visibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y), in: container)
            let chars = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let start = max(0, chars.location - 2_000), end = min(length, NSMaxRange(chars) + 5_000)
            visible = NSRange(location: start, length: max(0, end - start))
        }
        var low = 0, high = syntaxTokens.count
        while low < high { let middle = (low + high) / 2; if NSMaxRange(syntaxTokens[middle].range) < visible.location { low = middle + 1 } else { high = middle } }
        for token in syntaxTokens.dropFirst(low) {
            if token.range.location > NSMaxRange(visible) { break }
            if NSMaxRange(token.range) <= length { manager.addTemporaryAttribute(.foregroundColor, value: CodePalette.color(token.kind), forCharacterRange: token.range) }
        }
        textView.needsDisplay = true
    }
}
#endif
