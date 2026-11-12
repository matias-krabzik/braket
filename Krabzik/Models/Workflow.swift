import Foundation

enum WorkflowKind: String, Codable, CaseIterable {
    case start, event, schedule, script, ai, decision, end
    var isTrigger: Bool { self == .start || self == .event || self == .schedule }
    var title: String {
        switch self {
        case .start: return "Manual"
        case .event: return "Evento"
        case .schedule: return "Horario"
        case .script: return "Script"
        case .ai: return "Codex"
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

enum WorkflowAIOutputMode: String, Codable, CaseIterable {
    case output, file, filePath
    var title: String {
        switch self {
        case .output: "Dar texto como salida"
        case .file: "Guardar en archivo"
        case .filePath: "Guardar y dar ubicación"
        }
    }
}

struct WorkflowAISettings: Codable, Equatable {
    var prompt = ""
    /// Empty selects the account's default model; Luna is the low-cost starting point.
    var model = "gpt-6-luna"
    var outputMode: WorkflowAIOutputMode = .output
    var outputPath = "docs/releases/notes.md"
}

enum WorkflowConditionMode: String, Codable {
    case previousSuccess, compare
}

enum WorkflowValueType: String, Codable, CaseIterable {
    case text, number
    var title: String { self == .text ? "Texto" : "Número" }
}

enum WorkflowComparisonOperator: String, Codable, CaseIterable {
    case equal, notEqual, less, lessOrEqual, greater, greaterOrEqual
    var title: String {
        switch self {
        case .equal: "Igual (=)"
        case .notEqual: "Distinto (≠)"
        case .less: "Menor (<)"
        case .lessOrEqual: "Menor o igual (≤)"
        case .greater: "Mayor (>)"
        case .greaterOrEqual: "Mayor o igual (≥)"
        }
    }

    func matches(_ order: ComparisonResult) -> Bool {
        switch self {
        case .equal: order == .orderedSame
        case .notEqual: order != .orderedSame
        case .less: order == .orderedAscending
        case .lessOrEqual: order != .orderedDescending
        case .greater: order == .orderedDescending
        case .greaterOrEqual: order != .orderedAscending
        }
    }
}

enum WorkflowValueSource: String, Codable, CaseIterable {
    case literal, previousOutput, previousExitCode, environment, jsonField
    var title: String {
        switch self {
        case .literal: "Valor fijo"
        case .previousOutput: "Salida del último script"
        case .previousExitCode: "Código de salida"
        case .environment: "Variable de entorno"
        case .jsonField: "Campo del JSON"
        }
    }
}

struct WorkflowOperand: Codable, Equatable {
    var source: WorkflowValueSource = .literal
    var value = ""

    func resolve(output: String, exitCode: Int32?, environment: [String: String], json: String = "{}") throws -> String {
        switch source {
        case .literal: return value
        case .previousOutput: return output
        case .previousExitCode:
            guard let exitCode else { throw WorkflowError.invalid("No hay un código de salida previo para comparar.") }
            return String(exitCode)
        case .environment:
            guard let result = environment[value] else {
                throw WorkflowError.invalid("No existe la variable de entorno \(value).")
            }
            return result
        case .jsonField:
            let path = value.split(separator: ".").map(String.init)
            guard !path.isEmpty else { throw WorkflowError.invalid("Elegí un campo del JSON.") }
            var current: Any = WorkflowJSON.decode(json)
            for key in path {
                guard let object = current as? [String: Any], let next = object[key] else {
                    throw WorkflowError.invalid("El campo «\(value)» no existe en la entrada JSON.")
                }
                current = next
            }
            if let string = current as? String { return string }
            if let number = current as? NSNumber { return number.stringValue }
            throw WorkflowError.invalid("El campo «\(value)» debe contener texto o un número.")
        }
    }
}

struct WorkflowCondition: Codable, Equatable {
    var mode: WorkflowConditionMode = .compare
    var valueType: WorkflowValueType = .text
    var operation: WorkflowComparisonOperator = .equal
    var left = WorkflowOperand(source: .previousOutput)
    var right = WorkflowOperand(value: "ok")

    static var exitCodeIsZero: WorkflowCondition {
        WorkflowCondition(mode: .compare, valueType: .number, operation: .equal,
                          left: WorkflowOperand(source: .previousExitCode),
                          right: WorkflowOperand(value: "0"))
    }

    func evaluate(previousSucceeded: Bool, output: String, exitCode: Int32?, json: String = "{}",
                  environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Bool {
        if mode == .previousSuccess { return previousSucceeded }
        let lhs = try left.resolve(output: output, exitCode: exitCode, environment: environment, json: json)
        let rhs = try right.resolve(output: output, exitCode: exitCode, environment: environment, json: json)
        switch valueType {
        case .text:
            return operation.matches(lhs.compare(rhs, options: .literal))
        case .number:
            let locale = Locale(identifier: "en_US_POSIX")
            guard let first = Decimal(string: lhs.replacingOccurrences(of: ",", with: "."), locale: locale),
                  let second = Decimal(string: rhs.replacingOccurrences(of: ",", with: "."), locale: locale) else {
                throw WorkflowError.invalid("La comparación necesita dos números válidos.")
            }
            return operation.matches(NSDecimalNumber(decimal: first).compare(NSDecimalNumber(decimal: second)))
        }
    }
}

struct WorkflowNode: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: WorkflowKind
    var title: String
    var command = ""
    var settings = WorkflowScriptSettings()
    var ai = WorkflowAISettings()
    var condition = WorkflowCondition()
    var x: Double
    var y: Double
    var next: UUID?
    var no: UUID?
}

extension WorkflowNode {
    private enum CodingKeys: String, CodingKey {
        case id, kind, title, command, settings, ai, condition, x, y, next, no
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(WorkflowKind.self, forKey: .kind)
        title = try values.decode(String.self, forKey: .title)
        command = try values.decodeIfPresent(String.self, forKey: .command) ?? ""
        settings = try values.decodeIfPresent(WorkflowScriptSettings.self, forKey: .settings) ?? .init()
        ai = try values.decodeIfPresent(WorkflowAISettings.self, forKey: .ai) ?? .init()
        let savedCondition = try values.decodeIfPresent(WorkflowCondition.self, forKey: .condition)
        if kind == .decision, savedCondition == nil || savedCondition?.mode == .previousSuccess {
            condition = .exitCodeIsZero
        } else {
            condition = savedCondition ?? .init()
            if kind == .decision {
                if condition.left.source != .previousOutput && condition.left.source != .previousExitCode && condition.left.source != .jsonField {
                    condition.left = WorkflowOperand(source: .previousOutput)
                }
                if condition.right.source != .literal && condition.right.source != .environment {
                    condition.right.source = .literal
                }
                if condition.left.source == .previousExitCode { condition.valueType = .number }
            }
        }
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
            WorkflowNode(id: script, kind: .script, title: "Commits sin publicar",
                         command: "git log --format='%h %s' '@{upstream}..HEAD'", x: 290, y: 220, next: decision),
            WorkflowNode(id: decision, kind: .decision, title: "¿Hay commits nuevos?",
                         condition: WorkflowCondition(mode: .compare, valueType: .text,
                                                      operation: .notEqual,
                                                      left: WorkflowOperand(source: .previousOutput),
                                                      right: WorkflowOperand(value: "")), x: 510, y: 220,
                         next: yes, no: no),
            WorkflowNode(id: yes, kind: .end, title: "Commits pendientes", x: 760, y: 120),
            WorkflowNode(id: no, kind: .end, title: "Sin commits nuevos", x: 760, y: 330)
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
                      node.ai.prompt.utf8.count <= 16_000, node.ai.model.utf8.count <= 100,
                      node.ai.outputPath.utf8.count <= 2_048,
                      node.kind != .decision || (node.condition.mode == .compare &&
                          (node.condition.left.source == .previousOutput || node.condition.left.source == .previousExitCode || node.condition.left.source == .jsonField) &&
                          (node.condition.right.source == .literal || node.condition.right.source == .environment) &&
                          (node.condition.left.source != .previousExitCode || node.condition.valueType == .number)),
                      node.condition.left.value.utf8.count <= 2_048,
                      node.condition.right.value.utf8.count <= 2_048,
                      node.settings.timeoutSeconds >= 0, node.settings.timeoutSeconds <= 86_400,
                      node.settings.workingDirectory.utf8.count <= 2_048,
                      variables.count <= 50, variables.allSatisfy({ $0.value.utf8.count <= 8_000 }),
                      validNames, Set(names).count == names.count,
                      !names.contains(where: WorkflowEnvironmentVariable.isReserved),
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
