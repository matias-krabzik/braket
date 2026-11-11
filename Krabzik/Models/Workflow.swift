import Foundation

enum WorkflowKind: String, Codable, CaseIterable {
    case start, event, schedule, script, decision, end
    var isTrigger: Bool { self == .start || self == .event || self == .schedule }
    var title: String {
        switch self {
        case .start: return "Manual"
        case .event: return "Evento"
        case .schedule: return "Horario"
        case .script: return "Script"
        case .decision: return "Decisión"
        case .end: return "Fin"
        }
    }
}

struct WorkflowEnvironmentVariable: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var value = ""
}

struct WorkflowScriptSettings: Codable, Equatable {
    /// Empty means the root directory of the current project.
    var workingDirectory = ""
    /// Zero disables the time limit.
    var timeoutSeconds = 0
    var environment: [WorkflowEnvironmentVariable] = []
}

struct WorkflowNode: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: WorkflowKind
    var title: String
    var command = ""
    var settings = WorkflowScriptSettings()
    var x: Double
    var y: Double
    var next: UUID?
    var no: UUID?
}

extension WorkflowNode {
    private enum CodingKeys: String, CodingKey {
        case id, kind, title, command, settings, x, y, next, no
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(WorkflowKind.self, forKey: .kind)
        title = try values.decode(String.self, forKey: .title)
        command = try values.decodeIfPresent(String.self, forKey: .command) ?? ""
        settings = try values.decodeIfPresent(WorkflowScriptSettings.self, forKey: .settings) ?? .init()
        x = try values.decode(Double.self, forKey: .x)
        y = try values.decode(Double.self, forKey: .y)
        next = try values.decodeIfPresent(UUID.self, forKey: .next)
        no = try values.decodeIfPresent(UUID.self, forKey: .no)
    }
}

struct Workflow: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var nodes: [WorkflowNode]

    @discardableResult
    mutating func connect(from sourceID: UUID, isNo: Bool, to targetID: UUID) -> Bool {
        guard let sourceIndex = nodes.firstIndex(where: { $0.id == sourceID }),
              let target = nodes.first(where: { $0.id == targetID }),
              sourceID != targetID, nodes[sourceIndex].kind != .end,
              !target.kind.isTrigger, (!isNo || nodes[sourceIndex].kind == .decision) else { return false }
        var pending = [targetID]
        var seen = Set<UUID>()
        while let current = pending.popLast() {
            if current == sourceID { return false }
            guard seen.insert(current).inserted, let node = nodes.first(where: { $0.id == current }) else { continue }
            pending.append(contentsOf: [node.next, node.no].compactMap { $0 })
        }
        if isNo { nodes[sourceIndex].no = targetID }
        else { nodes[sourceIndex].next = targetID }
        return true
    }

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
                  flow.nodes.contains(where: { $0.kind.isTrigger }),
                  WorkflowKind.allCases.filter(\.isTrigger).allSatisfy({ kind in
                      flow.nodes.filter { $0.kind == kind }.count <= 1
                  }),
                  Set(flow.nodes.map(\.id)).count == flow.nodes.count else {
                throw WorkflowError.invalid("El flujo necesita un disparador y nodos únicos.")
            }
            let ids = Set(flow.nodes.map(\.id))
            for node in flow.nodes {
                let variables = node.settings.environment
                let names = variables.map(\.name)
                let validNames = names.allSatisfy { name in
                    guard let first = name.utf8.first,
                          first == 95 || (65...90).contains(first) || (97...122).contains(first) else { return false }
                    return name.utf8.dropFirst().allSatisfy {
                        $0 == 95 || (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    }
                }
                guard !node.title.isEmpty, node.title.count <= 100, node.command.utf8.count <= 8000,
                      node.settings.timeoutSeconds >= 0, node.settings.timeoutSeconds <= 86_400,
                      node.settings.workingDirectory.utf8.count <= 2_048,
                      variables.count <= 50, variables.allSatisfy({ $0.value.utf8.count <= 8_000 }),
                      validNames, Set(names).count == names.count,
                      node.x.isFinite, node.y.isFinite, abs(node.x) < 20_000, abs(node.y) < 20_000,
                      node.next.map(ids.contains) ?? true, node.no.map(ids.contains) ?? true,
                      !flow.nodes.contains(where: { $0.next == node.id || $0.no == node.id }) || !node.kind.isTrigger else {
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
