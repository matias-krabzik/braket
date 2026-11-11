import AppKit
import SwiftUI

@MainActor enum Theme {
    static var colorScheme: ColorScheme { AppSettings.shared.theme == .light ? .light : .dark }
    static var surfaceInk: Color { AppSettings.shared.theme == .light ? .black : .white }
    static var background: Color { Color(nsColor: EditorPalette.background) }
    static var sidebar: Color {
        if AppSettings.shared.theme == .light { return Color(red: 0.94, green: 0.95, blue: 0.97) }
        return AppSettings.shared.theme == .graphite
            ? Color(red: 0.157, green: 0.161, blue: 0.173)
            : Color(red: 0.135, green: 0.147, blue: 0.169)
    }
    static var bar: Color {
        if AppSettings.shared.theme == .light { return Color(red: 0.97, green: 0.975, blue: 0.985) }
        return AppSettings.shared.theme == .graphite
            ? Color(red: 0.137, green: 0.141, blue: 0.153)
            : Color(red: 0.123, green: 0.135, blue: 0.157)
    }
    static var border: Color { surfaceInk.opacity(0.08) }
    static var accent: Color {
        if AppSettings.shared.theme == .light { return Color(red: 0.16, green: 0.36, blue: 0.69) }
        return AppSettings.shared.theme == .graphite
            ? Color(red: 0.85, green: 0.86, blue: 0.89)
            : Color(red: 0.47, green: 0.67, blue: 0.91)
    }
}
