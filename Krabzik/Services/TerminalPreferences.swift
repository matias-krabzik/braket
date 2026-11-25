import Foundation
import Security

/// Metadata is local and scoped to the canonical project path. All environment values use Keychain storage.
@MainActor
final class TerminalPreferences {
    private let defaults: UserDefaults
    private let service: String
    init(defaults: UserDefaults) {
        self.defaults = defaults
        service = (Bundle.main.bundleIdentifier ?? "com.krabzik.ide") + ".terminal-environment"
    }
    private func key(_ url: URL) -> String { "terminal.project." + url.standardizedFileURL.path }
    func load(_ url: URL) throws -> TerminalProjectConfiguration {
        guard let data = defaults.data(forKey: key(url)) else { return TerminalProjectConfiguration() }
        guard data.count <= 2_097_152 else { throw DatabaseFailure("La configuración de terminal es demasiado grande.") }
        var config = try JSONDecoder().decode(TerminalProjectConfiguration.self, from: data)
        config.variables = try readValues(config.variables)
        for index in config.tabs.indices { config.tabs[index].variables = try readValues(config.tabs[index].variables) }
        return config
    }
    func save(_ config: TerminalProjectConfiguration, for url: URL) throws {
        defaults.set(try JSONEncoder().encode(config), forKey: key(url))
    }
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
    private func readValues(_ variables: [TerminalEnvironmentVariable]) throws -> [TerminalEnvironmentVariable] {
        try variables.map { variable in
            var result = variable
            var request = query(variable.id)
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &value)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw DatabaseFailure("No se pudo leer el entorno del Llavero (\(status)).")
            }
            if let data = value as? Data { result.value = String(decoding: data, as: UTF8.self) }
            return result
        }
    }
    func saveValues(_ variables: [TerminalEnvironmentVariable]) throws {
        for variable in variables { try saveValue(variable) }
    }
    private func saveValue(_ variable: TerminalEnvironmentVariable) throws {
        let request = query(variable.id)
        let changes = [kSecValueData as String: Data(variable.value.utf8)]
        var status = SecItemUpdate(request as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = request.merging(changes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DatabaseFailure("No se pudo guardar el entorno en el Llavero (\(status)).") }
    }
    func removeValues(_ variables: [TerminalEnvironmentVariable]) {
        for variable in variables { SecItemDelete(query(variable.id) as CFDictionary) }
    }
}
