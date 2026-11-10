import Foundation
import Observation

enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case graphite
    case midnight

    var id: String { rawValue }
    var title: String { self == .graphite ? "Grafito" : "Azul noche" }
    var detail: String { self == .graphite ? "Inspirado en el icono de Krabzik." : "El tema azul oscuro original." }
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
