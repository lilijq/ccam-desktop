import AppKit

enum AppearanceMode: String, CaseIterable {
    case system, light, dark
    static let preferenceKey = "appearanceMode"
    static func from(_ value: String?) -> AppearanceMode { value.flatMap(Self.init(rawValue:)) ?? .system }
    var title: String {
        switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" }
    }
    var appearance: NSAppearance? {
        switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) }
    }
}

enum Theme {
    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            color(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        }
    }
    static let background = adaptive(0xFAFAFA, 0x111111)
    static let panel = adaptive(0xFFFFFF, 0x1C1C1C)
    static let sidebar = adaptive(0xF0F0F0, 0x080808)
    static let accent = adaptive(0x292929, 0xECECEC)
    static let primary = adaptive(0x202020, 0xEAEAEA)
    static let onPrimary = adaptive(0xFFFFFF, 0x141414)
    static let muted = adaptive(0x616161, 0xA3A3A3)
    static let text = adaptive(0x1B1B1B, 0xF5F5F5)
    static let border = adaptive(0xD8D8D8, 0x303030)
    static let success = adaptive(0x287159, 0x82D7B4)
    static let warning = adaptive(0x9A5A08, 0xF0BB71)
    static let button = adaptive(0xEAEAEA, 0x272727)
    static let disabledButton = adaptive(0xEFEFEF, 0x242424)
    static var mode: AppearanceMode { .from(UserDefaults.standard.string(forKey: AppearanceMode.preferenceKey) ?? AppearanceMode.dark.rawValue) }
    static var appearance: NSAppearance? { mode.appearance }
    static func select(_ mode: AppearanceMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: AppearanceMode.preferenceKey)
        NSApp.appearance = mode.appearance
        // Windows and views inherit the application choice; existing input and PTYs stay intact.
        for window in NSApp.windows { window.backgroundColor = background; window.contentView?.needsDisplay = true }
    }
    static func windowWidth(_ preferred: CGFloat) -> CGFloat {
        max(390, min(preferred, NSApp.keyWindow?.contentView?.bounds.width ?? preferred))
    }
    static func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }
}

/// CGColor has no appearance information. Resolve layer colors whenever inheritance changes.
class ThemeSurface: NSView {
    var surfaceColor: NSColor? { didSet { refreshColors() } }
    var strokeColor: NSColor? { didSet { refreshColors() } }
    init(_ color: NSColor? = nil, border: NSColor? = nil, radius: CGFloat = 0) {
        surfaceColor = color; strokeColor = border
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = radius; layer?.borderWidth = border == nil ? 0 : 1
        refreshColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshColors() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshColors() }
    func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = surfaceColor?.cgColor
            layer?.borderColor = strokeColor?.cgColor
        }
        needsDisplay = true
    }
}

final class ThemeScrollView: NSScrollView {
    var strokeColor: NSColor? { didSet { refreshStroke() } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshStroke() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshStroke() }
    private func refreshStroke() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.borderColor = strokeColor?.cgColor }
        needsDisplay = true
    }
}
