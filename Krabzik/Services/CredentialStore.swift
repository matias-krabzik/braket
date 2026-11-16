import CryptoKit
import Foundation
import Security

/// La contraseña se mueve como `String` porque así la pide el transporte de
/// MySQLNIO. Swift no garantiza el borrado de ese buffer, así que el objetivo acá
/// es acotar su VIDA, no su rastro en memoria: nadie la retiene más allá del
/// handshake. Ver docs/specs/S4-no-retener-password.md.
enum CredentialStore {
    private static let service = "com.krabzik.ide.mysql"

    /// La cuenta del llavero para un perfil.
    ///
    /// No es privada para que la prueba pueda fijar el formato: cambiarlo deja
    /// inaccesibles las contraseñas que ya están guardadas.
    static func account(for connection: DatabaseConnection) -> String {
        // Bind the password to the endpoint as well as its ID. A modified project file
        // must not redirect an existing credential to a different server or user.
        var parts = [
            connection.id.uuidString,
            connection.host.lowercased(),
            String(connection.port),
            connection.username,
            connection.tls.rawValue
        ]
        if let fingerprint = trustFingerprint(connection) { parts.append(fingerprint) }
        return parts.joined(separator: "|")
    }

    /// Huella de los parámetros que deciden **contra qué identidad** se verifica el
    /// servidor. El modo de TLS dice cuánto se exige; estos dicen a quién se le cree:
    /// otra CA u otro `tlsServerName` cambian el extremo en el que se confía sin tocar
    /// host ni puerto. Van en la cuenta para que cambiarlos invalide la credencial igual
    /// que cambiar el host, y no pueda reusarla un `.kzk` ajeno que los traiga.
    ///
    /// `nil` cuando no hay ninguno: así los perfiles que nunca los usaron conservan su
    /// cuenta histórica y no hay que migrar nada. Agregarle el primero a un perfil ya es
    /// un cambio de identidad, y la credencial se vuelve a pedir.
    private static func trustFingerprint(_ connection: DatabaseConnection) -> String? {
        let values = [connection.tlsCAPath, connection.tlsServerName,
                      connection.tlsClientCertificatePath, connection.tlsClientKeyPath]
        guard values.contains(where: { !($0 ?? "").isEmpty }) else { return nil }
        // Separador que no puede aparecer en una ruta ni en un nombre de host, para que
        // dos repartos distintos de los mismos caracteres no den la misma huella.
        let joined = values.map { $0 ?? "" }.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func query(_ connection: DatabaseConnection) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account(for: connection)]
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
        if password.isEmpty {
            try remove(for: connection)
            return
        }
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
