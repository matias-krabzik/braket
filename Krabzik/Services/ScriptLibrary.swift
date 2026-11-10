import Foundation

/// Los scripts SQL que el proyecto recuerda: cómo se resuelve su ruta y cuándo se agrega
/// uno a la lista.
///
/// Son funciones puras sobre el modelo: no tocan el disco, no persisten nada y no saben
/// qué proyecto está abierto. `remembering(_:in:at:)` devuelve el workspace cambiado, o
/// `nil` si no había nada que cambiar, y quien decide si lo guarda es el coordinador.
///
/// Ver docs/specs/C5-dividir-workspacecontroller.md.
enum ScriptLibrary {
    /// Dónde está el script, o `nil` si no se puede abrir.
    ///
    /// Devuelve `nil` cuando el proyecto está en solo lectura y el script vive afuera de
    /// su carpeta: un `.krabzik` que no se confió no puede hacer que el IDE abra archivos
    /// de cualquier parte del disco (S1).
    static func url(for path: String, workspaceURL: URL, trust: TrustStore.Trust) -> URL? {
        let base = workspaceURL.deletingLastPathComponent()
        if trust == .untrusted,
           pathScope(path, relativeTo: base.appendingPathComponent("x")) == .external {
            return nil
        }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return base.appendingPathComponent(path)
    }

    /// Agrega el script a la lista del proyecto, si corresponde.
    ///
    /// No se agrega si no es `.sql`, si ya está, o si vive dentro de un subproyecto: ahí
    /// el explorador ya lo muestra y repetirlo en la lista de scripts sería ruido. La ruta
    /// queda relativa al `.krabzik` cuando está debajo de él, y absoluta si no.
    ///
    /// Devuelve `nil` cuando no hay nada que cambiar.
    static func remembering(_ url: URL, in workspace: Workspace, at workspaceURL: URL) -> Workspace? {
        guard url.pathExtension.lowercased() == "sql" else { return nil }
        let insideProject = workspace.projects.contains {
            url.path.hasPrefix($0.directory(relativeTo: workspaceURL).path + "/")
        }
        guard !insideProject else { return nil }
        let base = workspaceURL.deletingLastPathComponent().path + "/"
        let path = url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.path
        guard !workspace.scripts.contains(path) else { return nil }
        var updated = workspace
        updated.scripts.append(path)
        return updated
    }
}
