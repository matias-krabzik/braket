import CryptoKit
import Foundation

struct AutomationStore {
    let root: URL
    var configuration: URL { root.appendingPathComponent(".braket/automations.json") }
    var historyDirectory: URL {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Braket/AutomationRuns/\(digest)")
    }

    func load() throws -> AutomationFile {
        guard FileManager.default.fileExists(atPath: configuration.path) else { return AutomationFile() }
        let data = try boundedRead(configuration, limit: 2_000_000)
        let file = try JSONDecoder().decode(AutomationFile.self, from: data)
        try file.validate()
        return file
    }

    func save(_ file: AutomationFile) throws {
        try file.validate()
        try FileManager.default.createDirectory(at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(file).write(to: configuration, options: .atomic)
    }

    func directory(for execution: AutomationExecution) -> URL {
        historyDirectory.appendingPathComponent(execution.id.uuidString)
    }

    func save(_ execution: AutomationExecution) throws {
        let directory = directory(for: execution)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("execution.json")
        try JSONEncoder().encode(execution).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func history() throws -> [AutomationExecution] {
        guard FileManager.default.fileExists(atPath: historyDirectory.path) else { return [] }
        let directories = try FileManager.default.contentsOfDirectory(at: historyDirectory, includingPropertiesForKeys: nil)
        return directories.compactMap { directory in
            guard let data = try? boundedRead(directory.appendingPathComponent("execution.json"), limit: 2_000_000),
                  var execution = try? JSONDecoder().decode(AutomationExecution.self, from: data) else { return nil }
            guard execution.root.standardizedFileURL.path == root.standardizedFileURL.path,
                  execution.states.count == execution.automation.steps.count,
                  (0...execution.states.count).contains(execution.stepIndex),
                  (try? AutomationFile(automations: [execution.automation]).validate()) != nil else { return nil }
            if [.running, .waiting].contains(execution.phase) {
                execution.phase = .interrupted
                if execution.states.indices.contains(execution.stepIndex) { execution.states[execution.stepIndex] = .interrupted }
            }
            return execution
        }.sorted { $0.started > $1.started }.prefix(50).map { $0 }
    }

    func boundedRead(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw AutomationError.invalid("Archivo demasiado grande: \(url.lastPathComponent)") }
        return data
    }
}
