import AppKit
import SwiftUI

@MainActor enum Theme {
    static var background: Color { Color(nsColor: EditorPalette.background) }
    static var sidebar: Color {
        AppSettings.shared.theme == .graphite
            ? Color(red: 0.157, green: 0.161, blue: 0.173)
            : Color(red: 0.135, green: 0.147, blue: 0.169)
    }
    static var bar: Color {
        AppSettings.shared.theme == .graphite
            ? Color(red: 0.137, green: 0.141, blue: 0.153)
            : Color(red: 0.123, green: 0.135, blue: 0.157)
    }
    static let border = Color.white.opacity(0.08)
    static var accent: Color {
        AppSettings.shared.theme == .graphite
            ? Color(red: 0.85, green: 0.86, blue: 0.89)
            : Color(red: 0.47, green: 0.67, blue: 0.91)
    }
}
