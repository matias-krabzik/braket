import Foundation
import Logging

/// Puente de swift-log —lo que usa MySQLNIO— a `os.Logger`. Sin esto los avisos del
/// protocolo no van a ninguna parte: antes el nivel estaba fijo en `.critical`, que en la
/// práctica los silenciaba todos.
///
/// Todo el texto va con `privacy: .private`: un mensaje del protocolo puede traer el
/// usuario, el nombre de la base o un fragmento de la consulta. Ver la regla en `Log`.
struct MySQLLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level

    init(logLevel: Logger.Level) { self.logLevel = logLevel }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    /// swift-log pide `log(event:)`; la variante vieja quedó deprecada y con warnings
    /// como errores no compila.
    func log(event: LogEvent) {
        let text = "\(event.message)"
        switch event.level {
        case .critical, .error:
            Log.mysql.error("\(text, privacy: .private)")
        case .warning, .notice:
            Log.mysql.notice("\(text, privacy: .private)")
        default:
            Log.mysql.debug("\(text, privacy: .private)")
        }
    }
}

extension MySQLLogHandler {
    /// Nivel del logger de MySQL, leído de `UserDefaults` para poder subirlo en la app
    /// instalada sin recompilar:
    /// `defaults write com.krabzik.ide mysqlLogLevel debug`
    /// El default es `.warning`: `.debug` es ruidoso en consultas grandes.
    static func configuredLevel(_ defaults: UserDefaults = .standard) -> Logger.Level {
        guard let raw = defaults.string(forKey: "mysqlLogLevel"),
              let level = Logger.Level(rawValue: raw) else { return .warning }
        return level
    }
}
