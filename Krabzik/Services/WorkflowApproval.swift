import Foundation

/// Qué se aprueba cuando el usuario acepta correr un script de una automatización.
///
/// Un flujo es un JSON dentro del proyecto —`.braket/automations/`— y esa carpeta cae
/// dentro de lo que Codex puede escribir. Si bastara con confiar en el proyecto, un flujo
/// que alguien plantó correría con tu usuario y tu entorno sin que nadie lo hubiera leído:
/// es el mismo hueco que S1 cerró para los comandos de subproyecto.
///
/// La aprobación cubre **todo lo que cambia lo que se ejecuta**, no solo el texto del
/// comando: también la carpeta y las variables de entorno. Cambiar cualquiera la revoca.
/// Se guarda en el mismo `TrustStore`, por hash, con el id del bloque como proyecto.
struct WorkflowScriptApproval {
    let node: WorkflowNode
    let directory: URL
    let root: URL

    init(node: WorkflowNode, root: URL) {
        self.node = node
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        directory = node.resolvedDirectory(root: root)
    }

    /// Texto canónico que entra al hash. El prefijo y los separadores evitan que dos
    /// combinaciones distintas de comando, carpeta y entorno den la misma cadena.
    var key: String {
        let variables = node.settings.environment.sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
        return (["braket-workflow-script", node.command, directory.path] + variables).joined(separator: "\u{0}")
    }

    /// La carpeta cae fuera del proyecto: el diálogo lo dice, igual que S1 con las
    /// carpetas externas de un subproyecto.
    var isExternal: Bool {
        directory.path != root.path && !directory.path.hasPrefix(root.path + "/")
    }

    var prompt: CommandPrompt {
        CommandPrompt(project: "Automatización · \(node.title)", command: node.command,
                      directory: directory.path,
                      environment: node.settings.environment.sorted { $0.name < $1.name }
                          .map { "\($0.name)=\($0.value)" },
                      isExternal: isExternal)
    }

    /// `true` si el usuario aprobó correrlo, ahora o de una vez para siempre.
    @MainActor
    func authorize(store: TrustStore, workspaceURL: URL,
                   ask: @MainActor (CommandPrompt) -> CommandDecision) -> Bool {
        if store.isApproved(command: key, project: node.id, workspaceURL: workspaceURL) { return true }
        switch ask(prompt) {
        case .cancel: return false
        case .once: return true
        case .always:
            store.approve(command: key, project: node.id, workspaceURL: workspaceURL)
            return true
        }
    }
}

extension WorkflowNode {
    /// Carpeta de trabajo ya resuelta: vacía es la raíz del proyecto, una ruta relativa
    /// cuelga de ella y una absoluta se respeta. Se resuelven enlaces simbólicos para que
    /// lo que se muestra y se aprueba sea el lugar real donde va a correr.
    func resolvedDirectory(root: URL) -> URL {
        let configured = settings.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = configured.isEmpty ? root
            : (configured.hasPrefix("/") ? URL(fileURLWithPath: configured)
                : root.appendingPathComponent(configured))
        return base.resolvingSymlinksInPath().standardizedFileURL
    }
}

extension Workflow {
    /// Los scripts que corre un disparador, en el orden en que los alcanza, sin repetir.
    /// Se aprueban todos antes de arrancar, así un flujo no queda a medias por un «no».
    func scripts(from trigger: WorkflowKind) -> [WorkflowNode] {
        var result: [WorkflowNode] = []
        var seen = Set<UUID>()
        var pending = nodes.filter { $0.kind == trigger }.map(\.id)
        while let id = pending.first {
            pending.removeFirst()
            guard seen.insert(id).inserted, let node = nodes.first(where: { $0.id == id }) else { continue }
            if node.kind == .script { result.append(node) }
            pending.append(contentsOf: [node.next, node.no].compactMap { $0 })
        }
        return result
    }
}

extension WorkflowEnvironmentVariable {
    /// Variables que cambian cómo se carga un programa o qué lee el shell al arrancar.
    /// No tienen un uso legítimo en un flujo y son la forma de meter código en un comando
    /// que parece inocente. El resto —`PATH`, `NODE_OPTIONS`— sí es de uso común y se
    /// muestra completo en el diálogo de aprobación.
    static func isReserved(_ name: String) -> Bool {
        let upper = name.uppercased()
        return upper.hasPrefix("DYLD_") || upper.hasPrefix("LD_")
            || ["ZDOTDIR", "BASH_ENV", "ENV", "SHELL", "IFS", "PROMPT_COMMAND"].contains(upper)
    }
}

/// Dónde viven los flujos. Un repositorio ajeno puede traer `.braket` o `automations`
/// como enlace simbólico: leer seguiría el enlace y guardar escribiría a donde apunte.
enum WorkflowStorage {
    static func requireRealFiles(_ urls: [URL]) throws {
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                throw WorkflowError.invalid("«\(url.lastPathComponent)» es un enlace simbólico; Braket no lo sigue.")
            }
        }
    }
}
