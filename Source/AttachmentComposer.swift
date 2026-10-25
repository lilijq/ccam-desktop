import AppKit
import ImageIO

enum AttachmentPasteboard {
    enum Content { case files([URL]), image(Data) }
    static func recognizes(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil
    }
    static func read(_ pasteboard: NSPasteboard) -> Content? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { return .files(urls) }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { return .image(data) }
        }
        return nil
    }
}

private final class AttachmentChip: NSView {
    private var hovering = false
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        (hovering ? Theme.border : Theme.button).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()
    }
}

private final class AttachmentPreviewButton: NSButton {
    let attachment: ChatAttachment
    var thumbnail: NSImage?
    var handler: (() -> Void)?
    init(_ attachment: ChatAttachment, url: URL?) {
        self.attachment = attachment
        super.init(frame: .zero)
        title = ""; isBordered = false; focusRingType = .exterior
        target = self; action = #selector(invoke)
        setAccessibilityLabel("预览附件：" + attachment.name); toolTip = attachment.name + " · " + attachment.formattedSize
        if attachment.isImage, let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 160] as CFDictionary) {
            thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 1, dy: 1) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 8, yRadius: 8).fill() }
    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            Theme.border.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        let tile = NSRect(x: 8, y: 8, width: 40, height: 40)
        if let thumbnail {
            // Cover the tile and clip to a small radius; full image remains in preview.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: tile, xRadius: 6, yRadius: 6).addClip()
            let scale = max(tile.width / max(1, thumbnail.size.width), tile.height / max(1, thumbnail.size.height))
            let size = NSSize(width: thumbnail.size.width * scale, height: thumbnail.size.height * scale)
            thumbnail.draw(in: NSRect(x: tile.midX-size.width/2, y: tile.midY-size.height/2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            Theme.panel.setFill(); NSBezierPath(roundedRect: tile, xRadius: 6, yRadius: 6).fill()
            if let icon = NSImage(systemSymbolName: attachment.isImage ? "photo" : "doc.text", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [Theme.muted])) {
                let scale = min(20 / max(1, icon.size.width), 24 / max(1, icon.size.height))
                let size = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
                icon.draw(in: NSRect(x: tile.midX-size.width/2, y: tile.midY-size.height/2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingMiddle
        NSAttributedString(string: attachment.name, attributes: [.font: Theme.font(size: 12, weight: .medium), .foregroundColor: Theme.text, .paragraphStyle: paragraph]).draw(in: NSRect(x: 56, y: 10, width: max(0, bounds.width-64), height: 18))
        NSAttributedString(string: attachment.formattedSize, attributes: [.font: Theme.font(size: 11), .foregroundColor: Theme.muted]).draw(at: NSPoint(x: 56, y: 31))
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    @objc private func invoke() { handler?() }
}

private final class AttachmentRemoveButton: NSButton {
    var handler: (() -> Void)?
    private var hovering = false
    private var tracking: NSTrackingArea?
    init(name: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        title = ""; isBordered = false; focusRingType = .exterior
        target = self; action = #selector(invoke)
        setAccessibilityLabel("移除附件：" + name); toolTip = "移除 " + name
    }
    required init?(coder: NSCoder) { fatalError() }
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
    override func drawFocusRingMask() { NSBezierPath(ovalIn: focusRingMaskBounds).fill() }
    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlighted {
            Theme.panel.setFill(); NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        }
        let line = NSBezierPath(); line.lineWidth = 1.2; line.lineCapStyle = .round
        let x = bounds.midX, y = bounds.midY
        line.move(to: NSPoint(x: x-3, y: y-3)); line.line(to: NSPoint(x: x+3, y: y+3))
        line.move(to: NSPoint(x: x-3, y: y+3)); line.line(to: NSPoint(x: x+3, y: y-3))
        (hovering ? Theme.text : Theme.muted).setStroke(); line.stroke()
    }
    @objc private func invoke() { handler?() }
}

final class AttachmentStrip: NSScrollView {
    static let preferredHeight: CGFloat = 64
    init() {
        super.init(frame: .zero)
        drawsBackground = false; hasHorizontalScroller = true; hasVerticalScroller = false
        autohidesScrollers = true; scrollerStyle = .overlay
        setAccessibilityLabel("待发送附件")
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ attachments: [ChatAttachment], store: ChatAttachmentStore, remove: ((String) -> Void)?, preview: @escaping (ChatAttachment, NSView) -> Void) {
        let width: CGFloat = remove == nil ? 208 : 236
        let bodyWidth = max(1, CGFloat(attachments.count) * (width+8) - 8)
        let body = NSView(frame: NSRect(x: 0, y: 0, width: bodyWidth, height: 56))
        for (index, attachment) in attachments.enumerated() {
            let chip = AttachmentChip(frame: NSRect(x: CGFloat(index)*(width+8), y: 0, width: width, height: 56))
            let button = AttachmentPreviewButton(attachment, url: try? store.url(for: attachment))
            button.frame = NSRect(x: 0, y: 0, width: remove == nil ? width : width-28, height: 56)
            button.handler = { [weak button] in guard let button else { return }; preview(attachment, button) }
            chip.addSubview(button)
            if let remove {
                let close = AttachmentRemoveButton(name: attachment.name) { remove(attachment.id) }
                close.frame = NSRect(x: width-28, y: 16, width: 24, height: 24); chip.addSubview(close)
            }
            body.addSubview(chip)
        }
        documentView = body
    }
}
