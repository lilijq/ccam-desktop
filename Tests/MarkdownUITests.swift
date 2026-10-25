import AppKit

enum MarkdownUITests {
    static func run() throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ message: String) { checks += 1; if !value { fputs("FAIL: \(message)\n", stderr); exit(1) } }
        let sample = """
        # 项目检查
        已完成 **本地分析**。保留 `user_id`，参阅 [项目文档](https://example.test/docs)。

        ## 下一步
        - 检查配置，不修改现有文件。
          - 保留英文标识符 `getStatus`。
        - [x] 检查输入
        - [ ] 运行测试

        > 翻译后的说明与代码分别显示。

        | 文件 | 状态 | 建议 |
        | :--- | :---: | ---: |
        | `src/main.rs` | 已检查 | 先补充边界测试，再修改实现 |
        | `src/translation_worker.py` | 待检查 | 保留所有原始标识符 |

        ```rust
        fn main() {
            println!("hello");
        }
        ```
        """
        check(ChatMarkdown.cells("| `a|b` | a\\|b |") == ["`a|b`", "a|b"], "table pipes inside code and escaped pipes remain in their cells")
        let blocks = ChatMarkdown.blocks(sample)
        check(blocks.contains { if case .list(_, _, 1) = $0 { return true }; return false }, "nested list depth is retained")
        check(blocks.contains { if case .heading(1, "项目检查") = $0 { return true }; return false }, "heading is a semantic block")
        check(blocks.contains { if case .list("☑", "检查输入", 0) = $0 { return true }; return false }, "task list is rendered")
        check(blocks.contains { if case .table(let rows, let alignment) = $0 { return rows.count == 3 && alignment == [.left, .center, .right] }; return false }, "table preserves cells and alignment")
        check(blocks.contains { if case .code("rust", let source) = $0 { return source == "fn main() {\n    println!(\"hello\");\n}\n" }; return false }, "fenced code preserves source exactly")
        check(ChatMarkdown.blocks("```python\nprint('hello')").contains { if case .code("python", "print('hello')") = $0 { return true }; return false }, "streaming unclosed code fence remains renderable")
        let inline = ChatMarkdown.inline("**Bold** and `user_id` and [docs](https://example.test) and [bad](javascript:alert)")
        check(!inline.string.contains("**") && !inline.string.contains("`"), "inline formatting markers disappear from display")
        let bold = inline.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        check(NSFontManager.shared.traits(of: bold).contains(.boldFontMask), "strong text has an emphasized font")
        let docs = (inline.string as NSString).range(of: "docs"), bad = (inline.string as NSString).range(of: "bad")
        check(inline.attribute(.link, at: docs.location, effectiveRange: nil) != nil && inline.attribute(.link, at: bad.location, effectiveRange: nil) == nil, "only explicit safe link schemes are clickable")
        let html = ChatMarkdownView("<script>alert('x')</script> ![remote](https://example.test/image.png)")
        check(!ChatUITests.all(html).contains { $0 is NSImageView }, "rich text never fetches remote images or executes HTML")
        check(MarkdownTableScrollView.forwardsToConversation(horizontal: 0, vertical: 12, canScrollHorizontally: true), "vertical wheel over a table belongs to the conversation")
        check(!MarkdownTableScrollView.forwardsToConversation(horizontal: 20, vertical: 2, canScrollHorizontally: true), "horizontal trackpad gesture remains in a narrow table")
        check(MarkdownTableScrollView.forwardsToConversation(horizontal: 20, vertical: 2, canScrollHorizontally: false), "wide tables cannot trap mixed wheel movement")
        let oldAppearance = NSApp.appearance
        defer { NSApp.appearance = oldAppearance }
        for (theme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            for width: CGFloat in [900, 360] {
                let markdown = ChatMarkdownView(sample)
                let content = Card(markdown, padding: 24)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 950), styleMask: [], backing: .buffered, defer: false)
                window.contentView = content
                for _ in 0..<4 { content.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
                let fields = ChatUITests.all(markdown).compactMap { $0 as? NSTextField }
                check(fields.allSatisfy { $0.isSelectable }, "rich text stays selectable at \(theme) \(width)")
                check(fields.contains { $0.stringValue.contains("println!") }, "code content survives native layout")
                let outer = fields.first { $0.stringValue == "检查配置，不修改现有文件。" }!
                let nested = fields.first { $0.stringValue.contains("保留英文标识符") }!
                check(nested.convert(nested.bounds, to: markdown).minX >= outer.convert(outer.bounds, to: markdown).minX + 15, "nested list has a visible indent")
                let table = ChatUITests.all(markdown).compactMap { $0 as? ChatMarkdownTable }.first!
                let scroll = ChatUITests.all(table).compactMap { $0 as? NSScrollView }.first!
                check(table.frame.width <= markdown.bounds.width + 1 && table.frame.height > 60, "table has bounded width and measurable rows")
                let passes = table.measurementPasses
                for _ in 0..<200 { _ = table.intrinsicContentSize; table.needsLayout = true; table.layoutSubtreeIfNeeded() }
                check(table.measurementPasses == passes, "scroll/layout passes reuse measured table rows at a fixed width")
                check(scroll.hasHorizontalScroller == (width == 360), "narrow table scrolls horizontally without widening conversation")
                check(ChatUITests.all(markdown).compactMap { $0 as? NSButton }.contains { $0.accessibilityLabel() == "复制代码" }, "code copy action is available")
                try ChatUITests.snapshot(content, name: "markdown-\(theme)-\(Int(width))")
            }
        }
        return checks
    }
}
