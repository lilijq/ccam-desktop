import Foundation

@main struct CodeEditorTests {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        count += 1; if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() {
        for (path, language) in [("src/main.rs", CodeLanguage.rust), ("App.swift", .swift), ("index.tsx", .typescript), ("run.py", .python), ("Cargo.toml", .toml), ("README.md", .markdown), ("src/Main.java", .java), ("Page.vue", .vue), ("component.svelte", .svelte), ("query.sql", .sql), ("Dockerfile", .docker), (".env.local", .ini), ("notes.unknown", .plain)] {
            check(CodeLanguage.detect(path: path) == language, "language detection: \(path)")
        }
        let rust = """
        /* outer /* inner */ still comment */
        pub fn greet<'a>(name: &'a str) -> String {
            let raw = r##"// not comment \" still string"##;
            let icon = '💜';
            println!("hello {}", name);
            String::from(raw)
        }
        """
        let tokens = CodeHighlighter.tokens(rust, language: .rust), source = rust as NSString
        func contains(_ text: String, _ kind: CodeTokenKind) -> Bool { tokens.contains { $0.kind == kind && source.substring(with: $0.range) == text } }
        check(contains("/* outer /* inner */ still comment */", .comment), "nested Rust comment stays one comment")
        check(contains("pub", .keyword) && contains("fn", .keyword), "Rust declarations are keywords")
        check(contains("'a", .type) && contains("'💜'", .string), "lifetimes and surrogate-pair characters are distinct")
        check(contains("r##\"// not comment \" still string\"##", .string), "raw string delimiters preserve embedded quote and comment")
        check(contains("greet", .function) && contains("println", .function), "generic function declarations and macro invocations are recognised")
        check(contains("str", .type) && contains("String", .type), "Rust types are recognised")
        check(zip(tokens, tokens.dropFirst()).allSatisfy { NSMaxRange($0.0.range) <= $0.1.range.location }, "tokens do not overlap")
        check(tokens.allSatisfy { NSMaxRange($0.range) <= source.length }, "Unicode ranges fit UTF-16 storage")
        let json = "{\"key\": \"// string\", \"ok\": true, \"number\": 12.5}"
        let jsonTokens = CodeHighlighter.tokens(json, language: .json), jsonSource = json as NSString
        check(jsonTokens.contains { $0.kind == .property && jsonSource.substring(with: $0.range) == "\"key\"" }, "JSON property and value use different token kinds")
        check(!jsonTokens.contains { $0.kind == .comment }, "comment markers inside quoted strings do not become comments")
        let python = "def greet():\n    text = \"\"\"multiline\n# not comment\"\"\"\n    return text # comment"
        check(CodeHighlighter.tokens(python, language: .python).filter { $0.kind == .comment }.count == 1, "Python multiline strings consume comment-like contents")
        let markdown = "# Title\n```rust\nfn main() {}\n```\n"
        check(CodeHighlighter.tokens(markdown, language: .markdown).map(\.kind) == [.heading, .string], "Markdown headings and fenced code remain structured")
        let sql = "SELECT * FROM users WHERE id = 42 -- comment"
        check(CodeHighlighter.tokens(sql, language: .sql).filter { $0.kind == .keyword }.count == 3, "SQL upper-case keywords are supported")
        check(CodeHighlighter.tokens("fn plain() {}", language: .plain).isEmpty, "unknown text retains plain editable fallback")
        let lines = CodeHighlighter.lineStarts("a\n💜\r\nlast\n")
        check(lines == [0, 2, 6, 11], "line indexing uses correct UTF-16 positions and trailing empty line")
        check(CodeHighlighter.lineIndex(at: 5, starts: lines) == 1 && CodeHighlighter.lineIndex(at: 11, starts: lines) == 3, "caret lookup uses preceding line start")
        let line = "pub fn run() -> i32 { /* note */ let result = 42; result }\n"
        let large = String(repeating: line, count: (2 * 1024 * 1024) / line.utf8.count)
        let started = Date(); let largeTokens = CodeHighlighter.tokens(large, language: .rust); let seconds = Date().timeIntervalSince(started)
        check(!largeTokens.isEmpty && largeTokens.last.map { NSMaxRange($0.range) <= (large as NSString).length } == true, "2 MB input completes with valid ranges")
        print(String(format: "PASS: %d editor checks; 2 MB tokenization %.3f s", count, seconds))
    }
}
