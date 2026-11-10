import Foundation
import Observation

/// El proyecto abierto en la ventana: qué es, dónde está, si es confiable, y el único
/// camino para guardarlo.
///
/// Es el contexto que comparten los colaboradores de `WorkspaceController`
/// —`ProjectLibrary`, `ConnectionStore`, `FileCommands`, `AgentBridge`—. Cada uno recibe
/// esta sesión y el servicio que le toca, nada más: así se los puede ejercitar en una
/// prueba armando una sesión a mano, sin controlador y sin ventana.
///
/// Acá viven también el `ErrorCenter` y los diálogos. Los diálogos porque los comparten
/// cuatro colaboradores y tiene que haber **un solo** sitio donde se enganchan los reales
/// (`WorkspaceController.forApp()`): si cada uno tuviera su copia, olvidarse de inyectar
/// en uno lo dejaría con los valores por defecto —que niegan todo— y repetir la inyección
/// arriesgaría que una prueba vuelva a quedarse esperando un modal, que en S1 costó una
/// corrida de 4,3 horas colgada. Los dos prompts que tienen un único usuario no están acá:
/// `confirmTrust` vive en el controlador y `confirmCommand` en `ProjectLibrary`.
///
/// Lo que no se puede perder al partir el controlador: **abrir un proyecto no ejecuta
/// nada**. Un `.krabzik` que no se abrió antes entra en `.untrusted`, y de ahí dependen
/// `runnableProjects`, `mountedProjects` y los gates de scripts, comandos y agente (S1).
///
/// Confinado al main actor. Ver docs/specs/C5-dividir-workspacecontroller.md.
@MainActor @Observable
final class WorkspaceSession {
    private(set) var workspace: Workspace?
    private(set) var url: URL?
    private(set) var trust: TrustStore.Trust = .trusted
    /// Sube cada vez que el árbol de archivos pudo haber quedado viejo. El explorador lo
    /// observa para releer el disco.
    private(set) var revision = 0
    @ObservationIgnored let trustStore: TrustStore
    @ObservationIgnored let errors: ErrorCenter
    /// Por defecto no preguntan ni aceptan nada. Ver el comentario de arriba.
    @ObservationIgnored var dialogs = WorkspaceDialogs()

    init(trustStore: TrustStore, errors: ErrorCenter) {
        self.trustStore = trustStore
        self.errors = errors
    }

    /// `true` mientras se cambia de proyecto. Una transición a la vez, y en el medio no se
    /// envía nada a Codex: el scope que se armó puede ser de otro proyecto.
    private(set) var isSwitching = false

    /// `true` solo con un proyecto abierto en solo lectura: sin proyecto no hay nada que
    /// deshabilitar, y la interfaz no tiene que distinguir los dos casos.
    var isReadOnly: Bool { workspace != nil && trust == .untrusted }

    /// Vacío en solo lectura: así los botones ▶ y el menú Proyecto quedan deshabilitados
    /// sin tener que repetir la condición en cada vista.
    var runnableProjects: [CodeProject] {
        guard trust == .trusted else { return [] }
        return workspace?.projects.filter { !$0.command.isEmpty } ?? []
    }

    /// Subproyectos que el explorador monta. En solo lectura se omiten los externos.
    var mountedProjects: [CodeProject] {
        guard let workspace, let url else { return [] }
        guard trust == .untrusted else { return workspace.projects }
        return workspace.projects.filter { $0.scope(relativeTo: url) == .internalToProject }
    }

    /// Toma la puerta de la transición, o devuelve `false` si ya está tomada. El llamador
    /// la suelta con `endSwitch()`, normalmente en un `defer`.
    func beginSwitch() -> Bool {
        guard !isSwitching else { return false }
        isSwitching = true
        return true
    }

    func endSwitch() { isSwitching = false }

    /// Con qué confianza se abre este proyecto, preguntando solo si hace falta.
    ///
    /// Un proyecto ya conocido no vuelve a preguntar. Uno nuevo se decide con `ask` —la
    /// interfaz pone el diálogo— y, si el usuario confía, queda registrado acá mismo: la
    /// decisión y su registro no pueden separarse, o la próxima apertura volvería a
    /// preguntar. `nil` significa que canceló y no hay que abrir nada.
    func decideTrust(for project: Workspace, at url: URL,
                     ask: @MainActor (TrustPrompt) -> TrustDecision) -> TrustStore.Trust? {
        let known = trustStore.trust(for: url)
        guard known == .untrusted else { return known }
        switch ask(TrustPrompt(for: project, at: url)) {
        case .cancel: return nil
        case .readOnly: return .untrusted
        case .trust:
            trustStore.markTrusted(url)
            return .trusted
        }
    }

    /// Crea el `.krabzik` vacío y lo deja confiable: un proyecto que el usuario acaba de
    /// crear lo escribió él, no vino de afuera.
    func create(named name: String, at url: URL) throws -> Workspace {
        let project = Workspace(name: name)
        try project.write(to: url)
        trustStore.markTrusted(url)
        return project
    }

    /// Adopta el proyecto leído. No avisa a nadie: quien vuelve a cablear los servicios es
    /// el controlador, en `install(_:at:trust:)`.
    func open(_ project: Workspace, at url: URL, trust decided: TrustStore.Trust) {
        workspace = project
        self.url = url.standardizedFileURL
        trust = decided
        revision += 1
    }

    func close() {
        workspace = nil
        url = nil
        trust = .trusted
        revision += 1
    }

    /// Confiar en el proyecto abierto, desde la barra de solo lectura.
    func trustCurrent() {
        guard let url, trust == .untrusted else { return }
        trustStore.markTrusted(url)
        trust = .trusted
        revision += 1
    }

    /// El único camino de escritura. Guarda en disco y recién entonces adopta el cambio:
    /// si falla, el proyecto en memoria queda como estaba, así la interfaz nunca muestra
    /// una lista de subproyectos que el `.krabzik` no tiene.
    ///
    /// Toda escritura sube la revisión. Es una regla más simple que llevar la cuenta de
    /// cuáles cambian el árbol y cuáles no, y el costo de una relectura de más es nada.
    func save(_ updated: Workspace) throws {
        guard let url else { return }
        try updated.write(to: url)
        workspace = updated
        revision += 1
    }

    /// `save(_:)` para quien no tiene nada que revertir: reporta el error y dice si salió.
    /// Lo contrario —dejar pasar el error— lo necesita `ConnectionStore.save`, que tiene
    /// que restaurar la contraseña del llavero cuando el archivo no se pudo escribir.
    @discardableResult
    func write(_ updated: Workspace) -> Bool {
        do {
            try save(updated)
            return true
        } catch {
            errors.report(error)
            return false
        }
    }

    /// El disco cambió sin que cambiara el `.krabzik`: un archivo nuevo, una carpeta que
    /// el agente tocó.
    func touch() { revision += 1 }
}
