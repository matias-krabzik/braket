import AppKit
@testable import Krabzik
import XCTest

@MainActor
final class ThemeTests: XCTestCase {
    func testLegacyPreferencesAndNewInstallation() throws {
        let name = "braket-themes-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppSettings(defaults: defaults).appearanceMode, .system)
        for theme in [AppTheme.graphite, .midnight, .light] {
            defaults.removeObject(forKey: "appearanceMode")
            defaults.set(theme.rawValue, forKey: "appearanceTheme")
            let settings = AppSettings(defaults: defaults)
            XCTAssertEqual(settings.theme, theme.family)
            XCTAssertEqual(settings.resolvedTheme, theme)
        }
        let settings = AppSettings(defaults: defaults)
        settings.theme = .forest
        settings.appearanceMode = .system
        settings.systemIsDark = true
        XCTAssertEqual(settings.resolvedTheme, .forest)
        settings.systemIsDark = false
        XCTAssertEqual(settings.resolvedTheme, .forestLight)
        settings.appearanceMode = .dark
        XCTAssertEqual(settings.resolvedTheme, .forest)
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.theme, .forest)
        XCTAssertEqual(restored.appearanceMode, .dark)
    }

    func testPalettesHaveReadableTextAndSyntaxInBothModes() throws {
        XCTAssertEqual(AppTheme.families.count, 12)
        for family in AppTheme.families {
            for light in [true, false] {
                let theme = family.variant(light: light)
                XCTAssertEqual(theme.family, family)
                XCTAssertEqual(theme.isLight, light)
                let palette = theme.palette
                for ink in [palette.text, palette.muted, palette.keyword, palette.string, palette.number, palette.identifier] {
                    XCTAssertGreaterThanOrEqual(try contrast(ink, palette.background), 4.5, theme.detail)
                }
            }
        }
    }

    private func contrast(_ first: NSColor, _ second: NSColor) throws -> Double {
        func luminance(_ color: NSColor) throws -> Double {
            let rgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
            let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { value in
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
        }
        let values = try [luminance(first), luminance(second)]
        return (max(values[0], values[1]) + 0.05) / (min(values[0], values[1]) + 0.05)
    }
}
