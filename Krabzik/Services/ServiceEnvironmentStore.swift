import Foundation
import Security

/// Service files contain variable names and IDs, while values are bound to the local workspace in Keychain.
struct ServiceEnvironmentStore {
    private let service = (Bundle.main.bundleIdentifier ?? "com.krabzik.ide") + ".service-environment"
    private func query(_ variable: UUID, serviceID: UUID, workspace: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: workspace.standardizedFileURL.path + "|" + serviceID.uuidString + "|" + variable.uuidString]
    }
    func hydrate(_ variables: [TerminalEnvironmentVariable], serviceID: UUID, workspace: URL) throws
        -> [TerminalEnvironmentVariable] {
        try variables.map { variable in
            var request = query(variable.id, serviceID: serviceID, workspace: workspace)
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw DatabaseFailure("No se pudo leer el entorno del servicio (\(status)).")
            }
            var hydrated = variable
            hydrated.value = ""
            if let data = result as? Data { hydrated.value = String(decoding: data, as: UTF8.self) }
            return hydrated
        }
    }
    func save(_ variables: [TerminalEnvironmentVariable], serviceID: UUID, workspace: URL) throws {
        try TerminalEnvironment.validate(variables)
        for variable in variables {
            let request = query(variable.id, serviceID: serviceID, workspace: workspace)
            let changes = [kSecValueData as String: Data(variable.value.utf8)]
            var status = SecItemUpdate(request as CFDictionary, changes as CFDictionary)
            if status == errSecItemNotFound {
                var item = request.merging(changes) { _, new in new }
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw DatabaseFailure("No se pudo guardar el entorno del servicio (\(status)).") }
        }
    }
    func remove(_ variables: [TerminalEnvironmentVariable], serviceID: UUID, workspace: URL) {
        for variable in variables { SecItemDelete(query(variable.id, serviceID: serviceID, workspace: workspace) as CFDictionary) }
    }
}
