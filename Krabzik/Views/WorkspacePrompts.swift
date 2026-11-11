import AppKit
import UniformTypeIdentifiers

/// Lo que el usuario decide cuando se le pregunta por un archivo con cambios sin guardar.
enum SaveDecision: Sendable {
    case save, discard, cancel
}

/// Los diálogos y paneles de la ventana, en la capa de vistas.
///
/// Mismo reparto que `TrustPrompts`: el controlador declara **qué** pregunta y acá está
/// **cómo** se pregunta. Por eso el controlador no importa AppKit para esto y se puede
/// manejar desde una prueba sin que aparezca un modal —que en S1 costó una corrida de
/// 4,3 horas colgada—. Ver docs/specs/C5-dividir-workspacecontroller.md.
@MainActor
enum WorkspacePrompts {
    // MARK: - Paneles

    static func exportMySQLDiagnostics() async throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Braket-MySQL-diagnostico.txt"
        panel.message = "Exportá los últimos intentos de conexión para consultar un error. No incluye contraseñas ni consultas SQL."
        panel.prompt = "Exportar"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try await MySQLDiagnostics.shared.export(to: url)
    }

    static func chooseWorkspace() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.kzkProject, .legacyKrabzikProject, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = ""
        panel.prompt = "Abrir"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func createWorkspace() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.kzkProject]
        panel.nameFieldStringValue = "Mi proyecto." + Workspace.fileExtension
        panel.canCreateDirectories = true
        panel.prompt = "Crear"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFolders() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Agregar"
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseScripts() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.allowsMultipleSelection = true
        panel.prompt = "Abrir"
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// El panel de guardar resuelve él mismo la confirmación de sobrescribir.
    static func createFile(named name: String, in directory: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = directory
        panel.canCreateDirectories = true
        panel.prompt = "Crear"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func saveCopy(named name: String, in directory: URL) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = directory
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Confirmaciones

    static func confirmSave(_ name: String) -> SaveDecision {
        let alert = NSAlert()
        alert.messageText = "¿Guardar \(name)?"
        alert.informativeText = "Hay cambios sin guardar."
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "Cancelar")
        alert.addButton(withTitle: "No guardar")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    static func confirmDiscardChanges(_ name: String) -> Bool {
        confirm(message: "¿Recargar \(name)?",
                detail: "Se descartarán tus cambios sin guardar.",
                accept: "Recargar")
    }

    static func confirmCancelQuery() -> Bool {
        confirm(message: "¿Cancelar la consulta y cerrar el archivo?",
                detail: "",
                accept: "Cancelar consulta",
                dismiss: "Volver")
    }

    static func confirmStopAgent() -> Bool {
        confirm(message: "¿Detener Codex?",
                detail: "Los cambios ya realizados se conservarán.",
                accept: "Detener y continuar")
    }

    static func confirmSaveBeforeSending(_ names: [String]) -> Bool {
        confirm(message: "¿Guardar antes de enviar a Codex?",
                detail: names.joined(separator: ", "),
                accept: "Guardar y enviar")
    }

    static func confirmStopProcesses() -> Bool {
        confirm(message: "¿Detener los procesos?",
                detail: "Los procesos de este proyecto siguen en ejecución.",
                accept: "Detener")
    }

    private static func confirm(message: String, detail: String,
                                accept: String, dismiss: String = "Cancelar") -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: accept)
        alert.addButton(withTitle: dismiss)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Los diálogos que el controlador usa, inyectables.
///
/// Los valores por defecto **no preguntan nada y no aceptan nada**: la interfaz engancha
/// los reales con `WorkspaceController.forApp()`. Así una prueba que se olvide de
/// inyectar falla con una aserción en vez de quedarse esperando un modal, y el default
/// seguro es «no hacer».
@MainActor
struct WorkspaceDialogs {
    var chooseWorkspace: () -> URL? = { nil }
    var createWorkspace: () -> URL? = { nil }
    var chooseFolders: () -> [URL] = { [] }
    var chooseScripts: () -> [URL] = { [] }
    var createFile: (String, URL?) -> URL? = { _, _ in nil }
    var saveCopy: (String, URL) -> URL? = { _, _ in nil }
    var confirmSave: (String) -> SaveDecision = { _ in .cancel }
    var confirmDiscardChanges: (String) -> Bool = { _ in false }
    var confirmCancelQuery: () -> Bool = { false }
    var confirmStopAgent: () -> Bool = { false }
    var confirmStopProcesses: () -> Bool = { false }
    var confirmSaveBeforeSending: ([String]) -> Bool = { _ in false }

    /// Los diálogos de verdad.
    static var real: WorkspaceDialogs {
        WorkspaceDialogs(chooseWorkspace: WorkspacePrompts.chooseWorkspace,
                         createWorkspace: WorkspacePrompts.createWorkspace,
                         chooseFolders: WorkspacePrompts.chooseFolders,
                         chooseScripts: WorkspacePrompts.chooseScripts,
                         createFile: { WorkspacePrompts.createFile(named: $0, in: $1) },
                         saveCopy: { WorkspacePrompts.saveCopy(named: $0, in: $1) },
                         confirmSave: WorkspacePrompts.confirmSave,
                         confirmDiscardChanges: WorkspacePrompts.confirmDiscardChanges,
                         confirmCancelQuery: WorkspacePrompts.confirmCancelQuery,
                         confirmStopAgent: WorkspacePrompts.confirmStopAgent,
                         confirmStopProcesses: WorkspacePrompts.confirmStopProcesses,
                         confirmSaveBeforeSending: WorkspacePrompts.confirmSaveBeforeSending)
    }
}
