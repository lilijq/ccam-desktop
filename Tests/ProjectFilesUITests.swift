import AppKit

enum ProjectFilesUITests {
    static var count = 0
    static func check(_ value: Bool, _ message: String) {
        count += 1; if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
    static func wait(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(4)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    static func run(root: URL) throws -> Int {
        let project = root.appendingPathComponent("editor-fixture")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        let rust = """
        use std::collections::HashMap;

        /// Keep every project in its own workspace.
        #[derive(Debug, Clone)]
        pub struct Workspace {
            pub name: String,
            files: HashMap<String, String>,
        }

        impl Workspace {
            pub fn new(name: &str) -> Self {
                Self { name: name.into(), files: HashMap::new() }
            }

            pub fn open(&self, path: &str) -> Option<&String> {
                self.files.get(path)
            }
        }

        fn main() {
            let workspace = Workspace::new("ccam-desktop");
            println!("Ready: {}", workspace.name);
        }

        """
        let sourceFile = project.appendingPathComponent("src/main.rs")
        try rust.write(to: sourceFile, atomically: true, encoding: .utf8)
        try "[package]\nname = \"workspace\"\nversion = \"0.1.0\"\n".write(to: project.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)
        try "# Offline workspace\n\nA local source editor fixture.\n".write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try Data([0, 1, 2]).write(to: project.appendingPathComponent("archive.bin"))
        for width in [340.0, 480.0] {
            let narrow = ProjectFilesView(directory: project.path)
            let narrowWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 440), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            narrowWindow.contentView = narrow; narrow.layoutSubtreeIfNeeded()
            wait { narrow.outline.numberOfRows == 4 }
            narrow.layoutSubtreeIfNeeded()
            check(narrow.selectedFilePath == nil && !narrow.outline.isHiddenOrHasHiddenAncestor && narrow.outline.visibleRect.width > 0,
                  "a new \(width) px file pane shows the file tree before any document is open")
            let fileRow = (0..<narrow.outline.numberOfRows).first { index in
                (narrow.outline.view(atColumn: 0, row: index, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue == "Cargo.toml"
            }
            check(fileRow != nil, "the initial narrow tree contains a selectable file row")
            try ChatUITests.snapshot(narrow, name: "files-first-open-\(Int(width))")
            if let fileRow { narrow.outline.selectRowIndexes(IndexSet(integer: fileRow), byExtendingSelection: false) }
            wait { narrow.selectedFilePath == "Cargo.toml" }
            check(narrow.selectedFilePath == "Cargo.toml" && narrow.codeEditor.text.contains("[package]"),
                  "selecting a tree row opens its file at \(width) px without programmatic openFile")
            check(narrow.outline.isHiddenOrHasHiddenAncestor && !narrow.codeEditor.isHiddenOrHasHiddenAncestor,
                  "the narrow file tree collapses only after the document opens")
            let close = all(narrow).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "关闭文件：Cargo.toml" }!
            close.performClick(nil)
            check(narrow.selectedFilePath == nil && !narrow.outline.isHiddenOrHasHiddenAncestor,
                  "closing the last tab restores the file tree at \(width) px")
            check(!narrowWindow.isVisible, "first-open fixtures remain offscreen")
        }
        let view = ProjectFilesView(directory: project.path)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 640), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view; view.layoutSubtreeIfNeeded()
        wait { view.outline.numberOfRows == 4 }
        check(view.outline.numberOfRows == 4, "tree initially loads only project root entries")
        if let folder = view.outline.item(atRow: 0) {
            for _ in 0..<12 { _ = view.outlineView(view.outline, shouldExpandItem: folder) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            check(view.outline.numberOfRows == 4 && !view.outline.isItemExpanded(folder),
                  "accessibility-style expansion eligibility queries never load or expand a directory")
            view.outline.expandItem(folder)
        }
        wait { view.outline.numberOfRows == 5 }
        check(view.outline.numberOfRows == 5, "directory expansion loads its children in place")
        check(all(view).compactMap { $0 as? NSTextField }.allSatisfy { !$0.stringValue.hasPrefix("文件夹  ") }, "folders use images rather than a text prefix")
        view.openFile("src/main.rs"); wait { view.selectedFilePath == "src/main.rs" && !view.codeEditor.syntaxTokens.isEmpty }
        check(view.codeEditor.language == .rust && view.codeEditor.text == rust, "Rust opens with language detection and exact source")
        check(view.codeEditor.lineStarts.count == rust.filter { $0 == "\n" }.count + 1, "editor exposes every line including the trailing line")
        check(!view.hasUnsavedChanges && !view.codeEditor.textView.undoManager!.canUndo, "syntax highlighting does not dirty the document or undo stack")
        let text = view.codeEditor.textView
        window.makeFirstResponder(text)
        let findEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
        check(text.performKeyEquivalent(with: findEvent) && view.codeEditor.scroll.isFindBarVisible, "Command-F opens the editor find bar without requiring a global app menu")
        let hideFind = NSMenuItem(); hideFind.tag = NSTextFinder.Action.hideFindInterface.rawValue; text.performFindPanelAction(hideFind)
        let end = (rust as NSString).length
        text.setSelectedRange(NSRange(location: end, length: 0)); text.insertText("// draft", replacementRange: text.selectedRange())
        text.breakUndoCoalescing()
        check(view.hasUnsavedChanges && view.codeEditor.text.hasSuffix("// draft"), "typing changes the current file draft")
        view.openFile("Cargo.toml"); wait { view.selectedFilePath == "Cargo.toml" }
        check(view.hasUnsavedChanges && view.openFilePaths.count == 2 && view.codeEditor.language == .toml, "switching files preserves the other file draft")
        view.openFile("src/main.rs")
        check(view.codeEditor.text.hasSuffix("// draft") && text.selectedRange().location == end + 8, "returning to a tab restores its draft and caret")
        text.undoManager?.undo()
        check(view.codeEditor.text == rust && !view.hasUnsavedChanges, "undo history remains attached to the same file across tab switches")
        text.setSelectedRange(NSRange(location: end, length: 0)); text.insertText("// saved\n", replacementRange: text.selectedRange())
        view.codeEditor.onSave?(); wait { !view.hasUnsavedChanges }
        check(try String(contentsOf: sourceFile, encoding: .utf8) == rust + "// saved\n", "save writes the selected file draft through the guarded store")
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0)); text.insertText("// local\n", replacementRange: text.selectedRange())
        try "// external update\n".write(to: sourceFile, atomically: true, encoding: .utf8)
        view.codeEditor.onSave?(); wait { view.codeEditor.isEditable }
        check(try String(contentsOf: sourceFile, encoding: .utf8) == "// external update\n" && view.hasUnsavedChanges, "external changes are not overwritten and local edits remain")
        check(all(view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("文件已被其他程序修改") }, "a save conflict is visible beside the retained draft")
        view.openFile("README.md"); wait { view.selectedFilePath == "README.md" }
        view.openFile("src/main.rs"); wait { !view.codeEditor.syntaxTokens.isEmpty }
        for width in [940.0, 480.0, 320.0] {
            window.setContentSize(NSSize(width: width, height: 640)); view.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.04)); view.layoutSubtreeIfNeeded()
            for title in ["显示或隐藏文件树", "保存文件 ⌘S", "查找文件内容 ⌘F"] {
                let control = all(view).first { $0.accessibilityLabel() == title }!
                let rect = control.convert(control.bounds, to: view)
                check(rect.minX >= -0.5 && rect.maxX <= width + 0.5, "file control \(title) fits \(width) px")
            }
            if width == 320 { let toggle = all(view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "显示或隐藏文件树" }!; toggle.performClick(nil); view.layoutSubtreeIfNeeded(); toggle.performClick(nil) }
            check(!window.isVisible, "file layout checks do not open a user window")
        }
        window.setContentSize(NSSize(width: 940, height: 640)); view.layoutSubtreeIfNeeded()
        try ChatUITests.snapshot(view, name: "files-rust-dark")
        window.appearance = NSAppearance(named: .aqua); view.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        try ChatUITests.snapshot(view, name: "files-rust-light")
        window.appearance = NSAppearance(named: .darkAqua)
        view.openFile("archive.bin"); wait { view.selectedFilePath == "archive.bin" }
        check(view.selectedFilePath == "archive.bin" && !view.openFilePaths.isEmpty, "binary files open an information view instead of blocking the file tree")
        check(all(view).contains { $0 is ProjectFilePreviewView }, "unsupported files use the local preview fallback")
        check(view.hasUnsavedChanges, "opening binary previews preserves unsaved source drafts")
        return count
    }
}
