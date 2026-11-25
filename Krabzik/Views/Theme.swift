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

    static var colorScheme: ColorScheme { settings.theme == .light ? .light : .dark }
    static var surfaceInk: Color { settings.theme == .light ? .black : .white }
    static var background: Color { Color(nsColor: EditorPalette.background) }
    static var sidebar: Color {
        if settings.theme == .light { return Color(red: 0.94, green: 0.95, blue: 0.97) }
        return settings.theme == .graphite
            ? Color(red: 0.157, green: 0.161, blue: 0.173)
            : Color(red: 0.135, green: 0.147, blue: 0.169)
    }
    static var bar: Color {
        if settings.theme == .light { return Color(red: 0.97, green: 0.975, blue: 0.985) }
        return settings.theme == .graphite
            ? Color(red: 0.137, green: 0.141, blue: 0.153)
            : Color(red: 0.123, green: 0.135, blue: 0.157)
    }
    static var border: Color { surfaceInk.opacity(0.08) }
    static var accent: Color {
        if settings.theme == .light { return Color(red: 0.16, green: 0.36, blue: 0.69) }
        return settings.theme == .graphite
            ? Color(red: 0.85, green: 0.86, blue: 0.89)
            : Color(red: 0.47, green: 0.67, blue: 0.91)
    }
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
