import AppKit
import SwiftUI

@MainActor enum Theme {
    #if DEBUG
    /// Las preferencias que la interfaz está mirando.
    ///
    /// En Release es siempre `AppSettings.shared`. Un escenario de QA la apunta a su
    /// propia instancia —la del arnés, sobre un dominio de preferencias aislado— para
    /// poder afirmar el tema y el zoom sin tocar las preferencias reales del usuario,
    /// que son las del host de pruebas.
    static var settings: AppSettings = .shared
    #else
    static var settings: AppSettings { .shared }
    #endif

    static func zoom(_ size: CGFloat) -> CGFloat { size * CGFloat(settings.uiScale) }
    // Las APIs del sistema eligen San Francisco y SF Mono sin depender de nombres de fuentes instaladas.
    static func interfaceFont(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: zoom(size), weight: weight, design: .default)
    }

    static func codeFont(_ size: CGFloat = 14) -> Font {
        Font(settings.resultTypography.nativeFont(size: size * CGFloat(settings.resultFontScale)))
    }

    static func nativeCodeFont(scale: Double = 1, weight: NSFont.Weight = .regular) -> NSFont {
        settings.codeTypography.nativeFont(size: 14 * CGFloat(scale), forceBold: weight.rawValue >= NSFont.Weight.semibold.rawValue)
    }
    static func nativeResultFont(scale: Double = 1, weight: NSFont.Weight = .regular) -> NSFont {
        settings.resultTypography.nativeFont(size: 14 * CGFloat(scale), forceBold: weight.rawValue >= NSFont.Weight.semibold.rawValue)
    }

    static var palette: ThemePalette { settings.resolvedTheme.palette }
    static var colorScheme: ColorScheme { settings.resolvedTheme.isLight ? .light : .dark }
    static var surfaceInk: Color { Color(nsColor: palette.text) }
    static var background: Color { Color(nsColor: palette.background) }
    static var sidebar: Color { Color(nsColor: palette.sidebar) }
    static var bar: Color { Color(nsColor: palette.bar) }
    static var border: Color { surfaceInk.opacity(0.10) }
    static var accent: Color { Color(nsColor: palette.accent) }

}

/// Shared timings keep workspace transitions consistent and follow the live system preference.
struct WorkspaceMotion: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: AnyHashable
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 4)
            .task(id: value) {
                visible = false
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: reduceMotion ? 0.08 : 0.15)) { visible = true }
            }
    }
}

extension View {
    func workspaceReveal<Value: Hashable>(_ value: Value) -> some View {
        modifier(WorkspaceMotion(value: AnyHashable(value)))
    }
}

/// Short queries finish before the indicator appears, avoiding a loading flash.
struct WorkspaceProgress: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    var body: some View {
        Group {
            if visible {
                if reduceMotion { Image(systemName: "hourglass").accessibilityLabel("Cargando") }
                else { ProgressView() }
            } else { Color.clear.frame(width: 16, height: 16) }
        }
        .task {
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            visible = true
        }
    }
}

/// The complete label, including its padding and frame, is interactive.
struct FullAreaButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}

extension ButtonStyle where Self == FullAreaButtonStyle {
    static var fullArea: FullAreaButtonStyle { FullAreaButtonStyle() }
}

extension View {
    /// Covers gaps between a tab's primary button and its independent close/pin buttons.
    func tabSelectionBackground(action: @escaping () -> Void) -> some View {
        background {
            Button(action: action) { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.fullArea).focusable(false).accessibilityHidden(true)
        }
    }
}
