import AppKit

@main struct ThemeTests {
    static var checks = 0
    static var failures = 0
    static var minimumContrast = Double.infinity

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures += 1; fputs("FAIL: \(message)\n", stderr) }
    }

    struct RGB {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
        var luminance: Double {
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        func matches(_ other: RGB) -> Bool {
            abs(red - other.red) < 0.0001 && abs(green - other.green) < 0.0001 &&
                abs(blue - other.blue) < 0.0001 && abs(alpha - other.alpha) < 0.0001
        }
    }

    static func components(_ color: NSColor) -> RGB {
        guard let srgb = color.usingColorSpace(.sRGB) else {
            fputs("FAIL: theme color cannot be converted to sRGB\n", stderr); exit(1)
        }
        return RGB(red: Double(srgb.redComponent), green: Double(srgb.greenComponent),
                   blue: Double(srgb.blueComponent), alpha: Double(srgb.alphaComponent))
    }

    static func resolve(_ color: NSColor, in appearance: NSAppearance) -> RGB {
        var result: RGB!
        appearance.performAsCurrentDrawingAppearance { result = components(color) }
        return result
    }

    static func layerColor(_ color: CGColor?, _ name: String) -> RGB {
        guard let color, let converted = NSColor(cgColor: color) else {
            fputs("FAIL: \(name) has no resolved layer color\n", stderr); exit(1)
        }
        return components(converted)
    }

    static func contrast(_ foreground: NSColor, on background: NSColor, in appearance: NSAppearance, label: String) {
        let foreground = resolve(foreground, in: appearance)
        let background = resolve(background, in: appearance)
        check(abs(foreground.alpha - 1) < 0.0001 && abs(background.alpha - 1) < 0.0001, "\(label) uses opaque colors")
        let ratio = (max(foreground.luminance, background.luminance) + 0.05) /
                    (min(foreground.luminance, background.luminance) + 0.05)
        minimumContrast = min(minimumContrast, ratio)
        check(ratio >= 4.5, String(format: "%@ contrast %.3f is below 4.5:1", label, ratio))
    }

    static func main() {
        // No window is created, no appearance preference is read or written, and
        // Theme.select is deliberately not called. Views get local appearances.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        check(NSApp.windows.isEmpty, "test begins without windows")

        check(AppearanceMode.allCases == [.system, .light, .dark], "three supported appearance modes")
        for value: String? in [nil, "", "unknown", "LIGHT"] {
            check(AppearanceMode.from(value) == .system, "missing or invalid mode follows the system")
        }
        for mode in AppearanceMode.allCases {
            check(AppearanceMode.from(mode.rawValue) == mode, "valid mode \(mode.rawValue) round trips")
        }
        check(AppearanceMode.system.appearance == nil, "system mode inherits appearance")
        guard let light = AppearanceMode.light.appearance, let dark = AppearanceMode.dark.appearance else {
            fputs("FAIL: explicit appearance unavailable\n", stderr); exit(1)
        }
        check(light.bestMatch(from: [.aqua, .darkAqua]) == .aqua, "light mode requests Aqua")
        check(dark.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua, "dark mode requests Dark Aqua")

        let foregrounds: [(String, NSColor)] = [
            ("text", Theme.text), ("muted", Theme.muted), ("accent", Theme.accent),
            ("success", Theme.success), ("warning", Theme.warning), ("danger", Theme.danger)
        ]
        let surfaces: [(String, NSColor)] = [
            ("background", Theme.background), ("panel", Theme.panel), ("sidebar", Theme.sidebar),
            ("button", Theme.button), ("disabledButton", Theme.disabledButton)
        ]
        for (name, appearance) in [("light", light), ("dark", dark)] {
            for (foregroundName, foreground) in foregrounds {
                for (surfaceName, surface) in surfaces {
                    contrast(foreground, on: surface, in: appearance, label: "\(name) \(foregroundName)/\(surfaceName)")
                }
            }
            contrast(Theme.onPrimary, on: Theme.primary, in: appearance, label: "\(name) primary button")
        }

        let surface = ThemeSurface(Theme.panel, border: Theme.border, radius: 12)
        surface.appearance = light
        let lightFill = layerColor(surface.layer?.backgroundColor, "light surface")
        let lightBorder = layerColor(surface.layer?.borderColor, "light surface border")
        check(lightFill.matches(resolve(Theme.panel, in: light)), "surface resolves light fill")
        check(lightBorder.matches(resolve(Theme.border, in: light)), "surface resolves light border")
        surface.appearance = dark
        let darkFill = layerColor(surface.layer?.backgroundColor, "dark surface")
        let darkBorder = layerColor(surface.layer?.borderColor, "dark surface border")
        check(darkFill.matches(resolve(Theme.panel, in: dark)), "surface resolves dark fill after appearance change")
        check(darkBorder.matches(resolve(Theme.border, in: dark)), "surface border follows dark appearance")
        check(!lightFill.matches(darkFill), "surface CGColor changes between appearances")
        check(!lightBorder.matches(darkBorder), "surface border CGColor changes between appearances")
        surface.appearance = light
        check(layerColor(surface.layer?.backgroundColor, "restored surface").matches(lightFill), "surface fill switches back to light")
        check(layerColor(surface.layer?.borderColor, "restored surface border").matches(lightBorder), "surface border switches back to light")

        let scroll = ThemeScrollView(frame: .zero)
        scroll.wantsLayer = true
        scroll.strokeColor = Theme.border
        scroll.appearance = light
        let lightStroke = layerColor(scroll.layer?.borderColor, "light scroll border")
        check(lightStroke.matches(resolve(Theme.border, in: light)), "scroll view resolves light stroke")
        scroll.appearance = dark
        let darkStroke = layerColor(scroll.layer?.borderColor, "dark scroll border")
        check(darkStroke.matches(resolve(Theme.border, in: dark)), "scroll view stroke follows dark appearance")
        check(!lightStroke.matches(darkStroke), "scroll view stroke CGColor changes")
        scroll.appearance = light
        check(layerColor(scroll.layer?.borderColor, "restored scroll border").matches(lightStroke), "scroll stroke switches back to light")

        check(NSApp.windows.isEmpty, "test ends without creating a window")
        if failures > 0 {
            fputs("Theme: \(failures) of \(checks) checks failed.\n", stderr); exit(1)
        }
        print(String(format: "Theme: %d checks passed; minimum text contrast %.2f:1. No windows or preference changes.", checks, minimumContrast))
    }
}
