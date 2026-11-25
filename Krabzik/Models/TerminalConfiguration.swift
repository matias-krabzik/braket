import Foundation

struct TerminalEnvironmentVariable: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var secret = false
    // Values live in the Keychain, never in the project or preference payload.
    var value = ""
    enum CodingKeys: String, CodingKey { case id, name, secret }
}

struct TerminalTabConfiguration: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Terminal"
    var directory: String
    var variables: [TerminalEnvironmentVariable] = []
}

struct TerminalProjectConfiguration: Codable {
    var tabs: [TerminalTabConfiguration] = []
    var selectedID: UUID?
    var variables: [TerminalEnvironmentVariable] = []
    var visible = false
}

enum TerminalEnvironment {
    static func validate(_ variables: [TerminalEnvironmentVariable]) throws {
        guard variables.count <= 128 else { throw DatabaseFailure("Máximo 128 variables por nivel.") }
        var names: Set<String> = []
        for variable in variables {
            guard variable.name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                  names.insert(variable.name).inserted else {
                throw DatabaseFailure("Nombres de variable inválidos o repetidos. Usá letras, números y guion bajo.")
            }
            guard !variable.value.contains("\0"), variable.value.utf8.count <= 65_536 else {
                throw DatabaseFailure("El valor de una variable es inválido o demasiado largo.")
            }
        }
    }
    static func merge(system: [String: String], project: [TerminalEnvironmentVariable],
                      terminal: [TerminalEnvironmentVariable]) -> [String: String] {
        var result = system
        for variable in project + terminal { result[variable.name] = variable.value }
        result["TERM"] = "xterm-256color"
        result["COLORTERM"] = "truecolor"
        result["TERM_PROGRAM"] = "Braket"
        return result
    }
}
