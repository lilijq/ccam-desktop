import AppKit
import PDFKit
import CoreText

enum ProjectFilePreviewUITests {
    static func run() throws -> Int {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            count += 1
            if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        var launches = 0
        let storage = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 320, height: 240)
        let context = CGContext(consumer: CGDataConsumer(data: storage)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil); context.setFillColor(NSColor.white.cgColor); context.fill(box)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Offline PDF preview", attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black]))
        context.textPosition = CGPoint(x: 24, y: 120); CTLineDraw(line, context)
        context.endPDFPage(); context.closePDF()
        let pdf = storage as Data
        let preview = ProjectFilePreviewView(data: pdf, filename: "documents/sample.pdf", byteCount: Int64(pdf.count), openExternally: { launches += 1 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 242), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = preview; preview.layoutSubtreeIfNeeded()
        preview.pdfView?.layoutDocumentView()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        check(preview.showsPDF && preview.pdfView?.document?.pageCount == 1, "bounded PDF data renders locally")
        check(launches == 0, "opening a PDF preview does not launch any external application")
        check(preview.pdfView!.bounds.width >= 320 && preview.pdfView!.bounds.height > 100, "PDF preview fits a small pane")
        try ChatUITests.snapshot(preview, name: "pdf-small-pane")
        let badPDF = ProjectFilePreviewView(data: Data("not a pdf".utf8), filename: "bad.pdf", byteCount: 9, openExternally: { launches += 1 })
        check(!badPDF.showsPDF, "invalid PDF data falls back without crashing")
        let large = ProjectFilePreviewView(data: nil, filename: "large.pdf", byteCount: 40 * 1024 * 1024, notice: "文件较大", openExternally: { launches += 1 })
        check(!large.showsPDF && all(large).compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue.contains("文件较大") }), "large PDF uses metadata and the caller's bounded-data notice")
        let archive = ProjectFilePreviewView(data: nil, filename: "backup.zip", byteCount: 1024, openExternally: { launches += 1 })
        let open = all(archive).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "在默认应用中打开文件" }!
        check(!open.isHidden && launches == 0, "binary files offer explicit external opening without executing on selection")
        open.performClick(nil); check(launches == 1, "only the explicit open action invokes the validated external-open closure")
        let script = ProjectFilePreviewView(data: nil, filename: "install.command", byteCount: 80, openExternally: { launches += 1 })
        check(all(script).compactMap({ $0 as? NSButton }).allSatisfy({ $0.isHidden }), "executable formats never expose a default-handler launch action")
        check(!ProjectFilePreviewView.canOpenExternally(filename: "installer.pkg") && !ProjectFilePreviewView.canOpenExternally(filename: "script.py") && ProjectFilePreviewView.canOpenExternally(filename: "document.docx"), "file-menu eligibility matches preview action eligibility")
        let rtf = Data("{\\rtf1\\ansi Local document preview.}".utf8)
        let rich = ProjectFilePreviewView(data: rtf, filename: "document.rtf", byteCount: Int64(rtf.count), openExternally: { launches += 1 })
        let deadline = Date().addingTimeInterval(3)
        while !rich.showsDocument && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        check(rich.showsDocument && rich.documentTextView?.string == "Local document preview.", "RTF is imported as local read-only document text")
        check(rich.documentTextView?.isEditable == false && rich.documentTextView?.isRichText == false, "document preview cannot execute attachments or edit the source")
        for (ext, type) in [("docx", NSAttributedString.DocumentType.officeOpenXML), ("odt", NSAttributedString.DocumentType.openDocument)] {
            let text = NSAttributedString(string: "Local document preview.")
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
            let office = ProjectFilePreviewView(data: data, filename: "sample." + ext, byteCount: Int64(data.count), openExternally: { launches += 1 })
            let deadline = Date().addingTimeInterval(3)
            while !office.showsDocument && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            check(office.showsDocument && office.documentTextView?.string.trimmingCharacters(in: .whitespacesAndNewlines) == "Local document preview.", "\(ext) imports as local read-only text")
        }
        let html = ProjectFilePreviewView(data: Data("<img src='https://example.invalid/asset'>".utf8), filename: "page.html", byteCount: 42, openExternally: { launches += 1 })
        check(html.documentTextView == nil && !html.showsPDF && launches == 1, "HTML is never sent to a rich-text or web renderer")
        let failedOpen = ProjectFilePreviewView(data: nil, filename: "removed.zip", byteCount: 10, openExternally: { throw ProjectFileError.message("文件已变化") })
        all(failedOpen).compactMap { $0 as? NSButton }.first!.performClick(nil)
        check(all(failedOpen).compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue == "文件已变化" }), "external-open revalidation errors remain visible")
        check(!window.isVisible && launches == 1, "file previews remain offline and offscreen")
        return count
    }
}
