import AgentMonitorCore
import AppKit

/// "Event Horizon" palette, type scale and motion (DESIGN §1).
enum Theme {
    static func hex(_ v: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }

    static let crust = hex(0x060A14)
    static let base = hex(0x0A1020)
    static let surface = hex(0x162038)
    static let overlay = hex(0x22304F)
    static let muted = hex(0x56688F)
    static let subtext = hex(0x9DB0D3)
    static let text = hex(0xE1E9F7)
    static let accent = hex(0x2B5CFF)
    static let accentHi = hex(0x7D98FF)
    static let cyan = hex(0x56D4F5)

    static let cardFill = hex(0x17223F, 0.70)
    static let cardBorder = hex(0x7D98FF, 0.16)
    static let hairline = NSColor(white: 1, alpha: 0.07)
    static let subtle = NSColor(white: 1, alpha: 0.045)

    static func state(_ s: SessionState) -> NSColor {
        switch s {
        case .working: return hex(0xF5C97A)
        case .input: return hex(0xEC6A7D)
        case .done: return hex(0x5FE0B8)
        case .ready: return subtext
        }
    }

    static func contextFill(_ level: String) -> NSColor {
        switch level {
        case "hi": return state(.input)
        case "mid": return state(.working)
        default: return accent
        }
    }

    /// cubic-bezier(0.16, 1, 0.3, 1) — the one easing used everywhere.
    static let easing = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
    static let colorDuration = 0.24
    static let appearDuration = 0.2

    static func animate(duration: Double = colorDuration, _ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(easing)
        changes()
        CATransaction.commit()
    }

    static func instantly(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    // MARK: - Type

    private static let interFamily: String? = {
        let families = NSFontManager.shared.availableFontFamilies
        return ["Inter", "Inter Variable"].first(where: families.contains)
    }()

    private static var fontCache: [String: NSFont] = [:]

    /// Inter when installed, otherwise the system font; `tabular` keeps ticking numbers from jittering.
    static func font(_ size: CGFloat, _ weight: NSFont.Weight, tabular: Bool = false) -> NSFont {
        let key = "\(size)-\(weight.rawValue)-\(tabular)"
        if let hit = fontCache[key] { return hit }
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        if let family = interFamily {
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: family,
                .traits: [NSFontDescriptor.TraitKey.weight: weight],
            ])
            if let inter = NSFont(descriptor: descriptor, size: size) { font = inter }
        }
        if tabular {
            let descriptor = font.fontDescriptor.addingAttributes([
                .featureSettings: [[
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
                ]],
            ])
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        fontCache[key] = font
        return font
    }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender)
    }

    static func symbol(_ name: String, color: NSColor, size: CGFloat = 11) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
}
