import Foundation
import Observation

enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case graphite
    case midnight
    case light

    var id: String { rawValue }
    var title: String {
        switch self {
        case .graphite: "Grafito"
        case .midnight: "Azul noche"
        case .light: "Claro"
        }
    }
    var detail: String {
        switch self {
        case .graphite: "Inspirado en el icono de Krabzik."
        case .midnight: "El tema azul oscuro original."
        case .light: "Fondos claros y colores de sintaxis con contraste para trabajar de día."
        }
    }
}

@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: "appearanceTheme") }
    }
    var restoreLastState: Bool {
        didSet {
            defaults.set(restoreLastState, forKey: "restoreLastState")
            if !restoreLastState { defaults.removeObject(forKey: SessionRestoration.key) }
        }
    }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = AppTheme(rawValue: defaults.string(forKey: "appearanceTheme") ?? "") ?? .graphite
        restoreLastState = defaults.bool(forKey: "restoreLastState")
    }
}
