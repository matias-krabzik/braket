import Foundation

enum WorkflowKind: String, Codable, CaseIterable {
    case start, script, decision, end
    var title: String {
        switch self {
        case .start: return "Inicio"
        case .script: return "Script"
        case .decision: return "Decisión"
        case .end: return "Fin"
        }
    }
}

struct WorkflowNode: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: WorkflowKind
    var title: String
    var command = ""
    var x: Double
    var y: Double
    var next: UUID?
    var no: UUID?
}

struct Workflow: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var nodes: [WorkflowNode]

    static func first() -> Workflow {
        let start = UUID(), script = UUID(), decision = UUID(), yes = UUID(), no = UUID()
        return Workflow(name: "Verificar proyecto", nodes: [
            WorkflowNode(id: start, kind: .start, title: "Inicio", x: 70, y: 220, next: script),
            WorkflowNode(id: script, kind: .script, title: "Comprobar cambios",
                         command: "test -z \"$(git status --porcelain)\"", x: 290, y: 220, next: decision),
            WorkflowNode(id: decision, kind: .decision, title: "¿Listo para continuar?", x: 510, y: 220,
                         next: yes, no: no),
            WorkflowNode(id: yes, kind: .end, title: "Proyecto listo", x: 760, y: 120),
            WorkflowNode(id: no, kind: .end, title: "Revisar cambios", x: 760, y: 330)
        ])
    }
}

struct WorkflowFile: Codable {
    var version = 1
    var workflows: [Workflow] = []

    func validate() throws {
        guard version == 1, workflows.count <= 24 else { throw WorkflowError.invalid("Demasiados flujos.") }
        for flow in workflows {
            guard !flow.name.isEmpty, flow.name.count <= 100, flow.nodes.count <= 48,
                  flow.nodes.filter({ $0.kind == .start }).count == 1,
                  Set(flow.nodes.map(\.id)).count == flow.nodes.count else {
                throw WorkflowError.invalid("El flujo necesita un inicio y nodos únicos.")
            }
            let ids = Set(flow.nodes.map(\.id))
            for node in flow.nodes {
                guard !node.title.isEmpty, node.title.count <= 100, node.command.utf8.count <= 8000,
                      node.x.isFinite, node.y.isFinite, abs(node.x) < 20_000, abs(node.y) < 20_000,
                      node.next.map(ids.contains) ?? true, node.no.map(ids.contains) ?? true else {
                    throw WorkflowError.invalid("Nodo inválido: \(node.title).")
                }
            }
        }
    }
}

enum WorkflowError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }
    return nil }
}
