import AppKit
import Foundation

/// Visual theme. The Windows version loads every colour from an XML theme
/// file; on macOS we derive a small palette from three built-in themes
/// (system / light / dark) plus a configurable accent colour, which covers
/// the same surface area without shipping XML files.
struct DittoTheme: Equatable {
    enum Mode: String, CaseIterable {
        case system, light, dark

        var title: String {
            switch self {
            case .system: return LocalizationManager.shared.text("theme_system")
            case .light: return LocalizationManager.shared.text("theme_light")
            case .dark: return LocalizationManager.shared.text("theme_dark")
            }
        }

        var appearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }

        var isDark: Bool {
            switch self {
            case .dark: return true
            case .light: return false
            case .system:
                return NSAppearance.current.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            }
        }
    }

    var mode: Mode
    var accent: NSColor

    static var current: DittoTheme {
        let mode = Mode(rawValue: DittoSettings.themeName) ?? .system
        let accent = DittoTheme.storedAccent()
        return DittoTheme(mode: mode, accent: accent)
    }

    var effectiveAppearance: NSAppearance? { mode.appearance }

    var mainWindowBackground: NSColor {
        mode.isDark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.97, alpha: 1)
    }

    var listBoxOddRowBackground: NSColor {
        mode.isDark ? NSColor(white: 0.16, alpha: 1) : NSColor.white
    }

    var listBoxEvenRowBackground: NSColor {
        mode.isDark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.96, alpha: 1)
    }

    var listBoxText: NSColor {
        mode.isDark ? NSColor(white: 0.92, alpha: 1) : NSColor.black
    }

    var listBoxSelectedBackground: NSColor {
        accent.withAlphaComponent(mode.isDark ? 0.32 : 0.22)
    }

    var listBoxSelectedText: NSColor {
        mode.isDark ? NSColor.white : NSColor.black
    }

    var captionText: NSColor {
        mode.isDark ? NSColor(white: 0.7, alpha: 1) : NSColor(white: 0.3, alpha: 1)
    }

    var border: NSColor {
        mode.isDark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.82, alpha: 1)
    }

    var pastedIndicator: NSColor {
        NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
    }

    var favoriteIndicator: NSColor {
        NSColor(calibratedRed: 0.99, green: 0.73, blue: 0.18, alpha: 1)
    }

    var searchHighlight: NSColor {
        NSColor(calibratedRed: 1.0, green: 0.23, blue: 0.19, alpha: 1)
    }

    // MARK: - Accent persistence

    private static let accentKey = "Ditto.AccentColor"

    static let accentPresets: [NSColor] = [
        NSColor.systemBlue,
        NSColor.systemPurple,
        NSColor.systemPink,
        NSColor.systemRed,
        NSColor.systemOrange,
        NSColor.systemYellow,
        NSColor.systemGreen,
        NSColor.systemTeal,
        NSColor.systemIndigo
    ]

    static func storedAccent() -> NSColor {
        if let data = UserDefaults.standard.data(forKey: accentKey),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        // Fall back to the system control-accent colour, matching the Windows
        // "load accent from OS" behaviour.
        return NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor.systemBlue
    }

    static func setAccent(_ color: NSColor) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: accentKey)
        }
        NotificationCenter.default.post(name: .dittoThemeChanged, object: nil)
    }

    static func setMode(_ mode: Mode) {
        DittoSettings.themeName = mode.rawValue
        NotificationCenter.default.post(name: .dittoThemeChanged, object: nil)
    }
}
