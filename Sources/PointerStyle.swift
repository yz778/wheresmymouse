import AppKit

struct PointerColors: Equatable {
    let border: UInt32
    let fill: UInt32

    static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    static func rgb(_ color: NSColor) -> UInt32? {
        guard let color = color.usingColorSpace(.sRGB) else { return nil }
        func channel(_ component: CGFloat) -> UInt32 {
            UInt32((min(max(component, 0), 1) * 255).rounded())
        }
        let red = channel(color.redComponent)
        let green = channel(color.greenComponent)
        let blue = channel(color.blueComponent)
        return (red << 16) | (green << 8) | blue
    }
}

enum PointerStyle: String, CaseIterable {
    case orangeYellow, purpleGreen, redWhite, custom

    static let defaultColors = PointerColors(border: 0xFF8C00, fill: 0xFFFF00)

    var title: String {
        switch self {
        case .orangeYellow: return "Orange border / Yellow fill"
        case .purpleGreen: return "Purple border / Green fill"
        case .redWhite: return "Red border / White fill"
        case .custom: return "Custom"
        }
    }

    var preset: PointerColors? {
        switch self {
        case .orangeYellow: return Self.defaultColors
        case .purpleGreen: return PointerColors(border: 0x800080, fill: 0x32CD32)
        case .redWhite: return PointerColors(border: 0xFF0000, fill: 0xFFFFFF)
        case .custom: return nil
        }
    }
}

struct PointerStyleSettings {
    let defaults: UserDefaults

    var style: PointerStyle {
        get { defaults.string(forKey: "pointerStyle").flatMap(PointerStyle.init(rawValue:)) ?? .orangeYellow }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "pointerStyle") }
    }

    var customColors: PointerColors {
        get {
            let fallback = PointerStyle.defaultColors
            return PointerColors(border: savedColor("pointerBorder") ?? fallback.border,
                                 fill: savedColor("pointerFill") ?? fallback.fill)
        }
        nonmutating set {
            defaults.set(Int(newValue.border), forKey: "pointerBorder")
            defaults.set(Int(newValue.fill), forKey: "pointerFill")
        }
    }

    var colors: PointerColors { style.preset ?? customColors }

    private func savedColor(_ key: String) -> UInt32? {
        guard let value = defaults.object(forKey: key) as? Int, (0...0xFFFFFF).contains(value) else { return nil }
        return UInt32(value)
    }
}
