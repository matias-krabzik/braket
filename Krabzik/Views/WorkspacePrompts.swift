import AppKit
import UniformTypeIdentifiers

/// Lo que el usuario decide cuando se le pregunta por un archivo con cambios sin guardar.
enum SaveDecision: Sendable {
    case save, discard, cancel
}

enum ExplorerConflictDecision {
    case keepBoth, replace, skip, cancel
}

/// Los diálogos y paneles de la ventana, en la capa de vistas.
///
/// Mismo reparto que `TrustPrompts`: el controlador declara **qué** pregunta y acá está
/// **cómo** se pregunta. Por eso el controlador no importa AppKit para esto y se puede
/// manejar desde una prueba sin que aparezca un modal —que en S1 costó una corrida de
/// 4,3 horas colgada—. Ver docs/specs/C5-dividir-workspacecontroller.md.
@MainActor
enum WorkspacePrompts {
    static func nameForNewItem(_ title: String, suggested: String, action: String = "Crear") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancelar")
        let field = NSTextField(string: suggested)
        field.frame = NSRect(x: 0, y: 0, width: 310, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    static func confirmTrash(_ names: [String], openFiles: Int, running: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = names.count == 1 ? "¿Mover «\(names[0])» a la Papelera?"
            : "¿Mover \(names.count) elementos a la Papelera?"
        var details = ["Podés recuperarlos desde la Papelera."]
        if openFiles > 0 { details.append("Se cerrarán \(openFiles) pestañas abiertas.") }
        if !running.isEmpty { details.append("Se detendrán estos procesos: \(running.joined(separator: ", ")).") }
        alert.informativeText = details.joined(separator: "\n")
        alert.addButton(withTitle: "Mover a la Papelera")
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func confirmStopAffectedProcesses(_ names: [String]) -> Bool {
        confirm(message: "¿Detener procesos antes de mover archivos?",
                detail: names.joined(separator: ", "), accept: "Detener y continuar")
    }

    static func resolveConflict(_ name: String) -> ExplorerConflictDecision {
        let alert = NSAlert()
        alert.messageText = "«\(name)» ya existe"
        alert.informativeText = "Elegí qué hacer con el elemento de la carpeta de destino."
        alert.addButton(withTitle: "Conservar ambos")
        alert.addButton(withTitle: "Reemplazar")
        alert.addButton(withTitle: "Omitir")
        alert.addButton(withTitle: "Cancelar")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .keepBoth
        case .alertSecondButtonReturn: return .replace
        case .alertThirdButtonReturn: return .skip
        default: return .cancel
        }
    }
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

    /// El panel elige la ruta; FileCommands valida el proyecto y nunca sobrescribe.
    static func createFile(named name: String, in directory: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = directory
        panel.canCreateDirectories = true
        panel.prompt = "Crear"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseScriptsDirectory(in directory: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Carpeta de scripts SQL"
        panel.message = "Elegí una carpeta para guardar los scripts de este proyecto. Se recordará para las próximas consultas."
        panel.directoryURL = directory
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Usar carpeta"
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
        confirm(message: "¿Detener las ejecuciones?",
                detail: "Se detendrán las ejecuciones en curso.",
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
    var chooseScriptsDirectory: (URL) -> URL? = { _ in nil }
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
                         chooseScriptsDirectory: { WorkspacePrompts.chooseScriptsDirectory(in: $0) },
                         saveCopy: { WorkspacePrompts.saveCopy(named: $0, in: $1) },
                         confirmSave: WorkspacePrompts.confirmSave,
                         confirmDiscardChanges: WorkspacePrompts.confirmDiscardChanges,
                         confirmCancelQuery: WorkspacePrompts.confirmCancelQuery,
                         confirmStopAgent: WorkspacePrompts.confirmStopAgent,
                         confirmStopProcesses: WorkspacePrompts.confirmStopProcesses,
                         confirmSaveBeforeSending: WorkspacePrompts.confirmSaveBeforeSending)
    }
}
