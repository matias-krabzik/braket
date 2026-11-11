import Foundation

struct AutomationVariable: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var value = ""
}

struct AutomationStep: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "Nuevo paso"
    var command = ""
    var directory = "."
    var environment: [AutomationVariable] = []
    var nodeVersion = ""
    var enabled = true
    var retryable = false
    var requiresConfirmation = false
    var timeoutSeconds = 1800
}

struct Automation: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "Nueva automatización"
    var parameters: [AutomationVariable] = []
    var steps: [AutomationStep] = []
}

struct AutomationFile: Codable, Equatable {
    var version = 1
    var automations: [Automation] = []

    func validate() throws {
        guard version == 1, automations.count <= 64, try JSONEncoder().encode(self).count <= 1_000_000,
              Set(automations.map(\.id)).count == automations.count else { throw AutomationError.invalid("Catálogo inválido.") }
        for automation in automations {
            guard !automation.name.isEmpty, automation.name.count <= 200, automation.name.isValidProjectText(),
                  automation.steps.count <= 64, Set(automation.steps.map(\.id)).count == automation.steps.count else {
                throw AutomationError.invalid("Nombre o pasos inválidos.")
            }
            try Self.validateVariables(automation.parameters)
            for step in automation.steps {
                guard !step.name.isEmpty, step.name.count <= 200, step.name.isValidProjectText(), step.command.utf8.count <= 32_000,
                      step.command.isValidProjectText(newlines: true), step.directory.isValidProjectText(),
                      step.directory.count <= 4096, !step.directory.isEmpty,
                      step.nodeVersion.count <= 100, step.nodeVersion.isValidProjectText(),
                      (1...86_400).contains(step.timeoutSeconds) else { throw AutomationError.invalid("Paso inválido: \(step.name)") }
                try Self.validateVariables(step.environment)
            }
        }
    }

    static func validKey(_ key: String) -> Bool {
        key.range(of: "^[A-Z][A-Z0-9_]{0,63}$", options: .regularExpression) != nil
    }

    static func validateVariables(_ variables: [AutomationVariable]) throws {
        guard variables.count <= 64, Set(variables.map(\.name)).count == variables.count else {
            throw AutomationError.invalid("Hay variables repetidas o demasiadas variables.")
        }
        for variable in variables {
            guard validKey(variable.name), !variable.name.hasPrefix("BRAKET_"),
                  variable.value.utf8.count <= 8192, !variable.value.contains("\0") else {
                throw AutomationError.invalid("Variable inválida: \(variable.name). Usá MAYUSCULAS_Y_GUIONES_BAJOS.")
            }
        }
    }
}

enum AutomationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

enum AutomationPhase: String, Codable {
    case pending, running, waiting, succeeded, failed, cancelled, interrupted, skipped
    var label: String {
        switch self {
        case .pending: return "Pendiente"
        case .running: return "En ejecución"
        case .waiting: return "Esperando confirmación"
        case .succeeded: return "Finalizado"
        case .failed: return "Error"
        case .cancelled: return "Cancelado"
        case .interrupted: return "Interrumpido"
        case .skipped: return "Omitido"
        }
    }
}

struct AutomationExecution: Codable, Identifiable {
    var id = UUID()
    var automation: Automation
    var parameters: [AutomationVariable]
    var workspaceURL: URL
    var root: URL
    var started = Date()
    var finished: Date?
    var phase = AutomationPhase.pending
    var stepIndex = 0
    var states: [AutomationPhase]
    var outputs: [String: String] = [:]
    var message = ""
}
