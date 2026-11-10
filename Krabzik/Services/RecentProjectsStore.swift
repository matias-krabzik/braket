import Foundation
import Observation

/// El historial de proyectos abiertos: los últimos diez, sin repetidos y ordenados por
/// apertura.
///
/// Las rutas se guardan normalizadas (`standardizedFileURL`), así que `./proyecto` y
/// `proyecto` son la misma entrada. Quitar uno del historial **no borra nada del disco**:
/// es solo el historial. Persiste en `UserDefaults` en cada cambio, para que cerrar la app
/// de cualquier forma no lo pierda.
///
/// Confinado al main actor. Ver docs/specs/C5-dividir-workspacecontroller.md.
@MainActor @Observable
final class RecentProjectsStore {
    /// Cuántos se recuerdan. Es lo que entra en la pantalla de inicio sin scroll.
    static let limit = 10

    private(set) var urls: [URL] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "recentProjects"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var seen: Set<URL> = []
        urls = Array((defaults.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { seen.insert($0).inserted }
            .prefix(Self.limit))
    }

    /// Lo pone primero. Si ya estaba, lo mueve: el orden es por última apertura.
    func remember(_ url: URL) {
        let normalized = url.standardizedFileURL
        urls.removeAll { $0 == normalized }
        urls.insert(normalized, at: 0)
        urls = Array(urls.prefix(Self.limit))
        persist()
    }

    /// Lo saca del historial. El archivo del proyecto queda donde está.
    func forget(_ url: URL) {
        urls.removeAll { $0 == url.standardizedFileURL }
        persist()
    }

    private func persist() {
        defaults.set(urls.map(\.path), forKey: key)
    }
}
