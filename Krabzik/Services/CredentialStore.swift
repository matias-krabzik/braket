import Foundation
import Security

/// La contraseña se mueve como `String` porque así la pide el transporte de
/// MySQLNIO. Swift no garantiza el borrado de ese buffer, así que el objetivo acá
/// es acotar su VIDA, no su rastro en memoria: nadie la retiene más allá del
/// handshake. Ver docs/specs/S4-no-retener-password.md.
enum CredentialStore {
    private static let service = "com.krabzik.ide.mysql"

    private static func query(_ connection: DatabaseConnection) -> [String: Any] {
        // Bind the password to the endpoint as well as its ID. A modified project file
        // must not redirect an existing credential to a different server or user.
        let account = "\(connection.id.uuidString)|\(connection.host.lowercased())|\(connection.port)|\(connection.username)|\(connection.tls.rawValue)"
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read(for connection: DatabaseConnection) throws -> String {
        var request = query(connection)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw DatabaseFailure("No se pudo leer la contraseña del llavero (\(status)).")
        }
        return value
    }

    static func save(_ password: String, for connection: DatabaseConnection) throws {
        if password.isEmpty { try remove(for: connection); return }
        let request = query(connection)
        let changes = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(request as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = request.merging(changes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecAttrLabel as String] = "Krabzik · \(connection.name)"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DatabaseFailure("No se pudo guardar la contraseña en el llavero (\(status)).") }
    }

    static func remove(for connection: DatabaseConnection) throws {
        let status = SecItemDelete(query(connection) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DatabaseFailure("No se pudo quitar la contraseña del llavero (\(status)).")
        }
    }
}
