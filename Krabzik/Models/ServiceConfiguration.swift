import Foundation

struct ServiceConfiguration: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Servicio"
    var command = ""
    var configuration = RunConfiguration()
    var variables: [TerminalEnvironmentVariable] = []
    var dependencies: [UUID] = []
    var dependencyTimeout = 30
    var waitForPort = true
    var php: PHPServiceConfiguration?
    var node: NodeServiceConfiguration?

    func executionProject(in parent: CodeProject) -> CodeProject {
        var config = configuration
        config.name = name
        if let php {
            config.arguments = []
            config.expectedPort = php.effectivePort
            if let port = php.effectivePort { config.launchURL = "http://localhost:\(port)" }
        }
        if node != nil { config.arguments = [] }
        var project = CodeProject(id: id, name: name, path: parent.path, kind: parent.kind,
                                  command: node?.command ?? php?.command(id: id, environmentKeys: variables.map(\.name)) ?? command,
                                  icon: parent.icon,
                                  runConfiguration: config)
        project.serviceParentID = parent.id
        project.serviceParentName = parent.name
        project.serviceDependencyIDs = dependencies
        project.servicePHP = php
        return project
    }
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200,
              (php != nil || node != nil || !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              command.count <= WorkspaceLimits.commandLength,
              command.isValidProjectText(newlines: true),
              name.isValidProjectText(), (1...300).contains(dependencyTimeout), dependencies.count <= 32,
              Set(dependencies).count == dependencies.count else {
            throw WorkspaceError.invalidText("el servicio o sus dependencias")
        }
        guard php == nil || node == nil else { throw WorkspaceError.invalidText("el tipo de servicio") }
        try node?.validate()
        try php?.validate()
        try configuration.validate()
        try TerminalEnvironment.validate(variables)
    }
}

extension CodeProject {
    /// Legacy commands retain their stable identity and approval when represented as the first service.
    var configuredServices: [ServiceConfiguration] {
        if let services { return services }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var service = ServiceConfiguration(id: id, name: "Principal", command: command,
                                           configuration: runConfiguration ?? RunConfiguration())
        if let label = runConfiguration?.name, !label.isEmpty { service.name = label }
        return [service]
    }
    var executionProjects: [CodeProject] {
        guard services != nil else { return command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [self] }
        return configuredServices.map { $0.executionProject(in: self) }
    }
}

enum ServicePlan {
    static func order(_ services: [ServiceConfiguration], targets: [UUID]) throws -> [ServiceConfiguration] {
        guard services.count <= 32, Set(services.map(\.id)).count == services.count else {
            throw WorkspaceError.invalidText("los identificadores de servicios")
        }
        let byID = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
        var visited: Set<UUID> = []
        var visiting: Set<UUID> = []
        var result: [ServiceConfiguration] = []
        func visit(_ id: UUID) throws {
            if visited.contains(id) { return }
            guard let service = byID[id], visiting.insert(id).inserted else {
                throw WorkspaceError.invalidText("dependencias ausentes o circulares")
            }
            for dependency in service.dependencies { try visit(dependency) }
            visiting.remove(id)
            visited.insert(id)
            result.append(service)
        }
        for id in targets { try visit(id) }
        return result
    }
}
