@testable import Krabzik
import XCTest

/// Resultados y estructuras de prueba para los escenarios de SQL y de la grilla.
///
/// Sin esto cada escenario armaría su propio `SQLResult` a mano y las condiciones de
/// edición —claves únicas, columnas nullable, motor InnoDB— quedarían repetidas en veinte
/// sitios. Acá hay una tabla editable por defecto y variantes para cada motivo de solo
/// lectura del catálogo.
enum QAFixtures {
    static let database = "qa"

    /// `personas(id PK, nombre NULL, estado ENUM NOT NULL DEFAULT, calculado GENERATED)`,
    /// InnoDB: el caso editable del catálogo.
    static func table(name: String = "personas", kind: String = "BASE TABLE",
                      engine: String = "InnoDB", uniqueKeys: [[String]] = [["id"]],
                      metadataComplete: Bool? = true) -> SQLSchemaTable {
        SQLSchemaTable(database: database, name: name, kind: kind, engine: engine,
                       columns: [
                           SQLSchemaColumn(name: "id", type: "int", nullable: false, defaultValue: nil,
                                           extra: "auto_increment"),
                           SQLSchemaColumn(name: "nombre", type: "varchar(80)", nullable: true,
                                           defaultValue: nil, extra: ""),
                           SQLSchemaColumn(name: "estado", type: "enum('nuevo','listo')", nullable: false,
                                           defaultValue: "nuevo", extra: ""),
                           SQLSchemaColumn(name: "obligatoria", type: "int", nullable: false,
                                           defaultValue: nil, extra: ""),
                           SQLSchemaColumn(name: "calculado", type: "int", nullable: true,
                                           defaultValue: nil, extra: "VIRTUAL GENERATED")
                       ],
                       uniqueKeys: uniqueKeys, createSQL: nil, metadataComplete: metadataComplete)
    }

    /// Un `SELECT` directo de `personas` con las columnas que se le pidan.
    static func result(_ connection: DatabaseConnection, columns: [String] = ["id", "nombre", "estado", "calculado"],
                       rows: [[String?]] = [["1", "ana", "nuevo", "10"], ["2", "beto", "listo", "20"]],
                       sql: String? = nil, table: String = "personas",
                       truncated: Bool = false, error: String? = nil) -> SQLResult {
        var result = SQLResult(statement: 1, line: 1)
        result.sql = sql ?? ("SELECT " + columns.joined(separator: ", ") + " FROM " + table)
        result.connection = connection
        result.database = database
        result.columns = columns
        result.origins = columns.map { SQLColumnOrigin(database: database, table: table, column: $0) }
        result.rows = rows
        result.rowCount = rows.count
        result.truncated = truncated
        result.error = error
        return result
    }

    /// Un borrador ya configurado con su estructura: el estado en el que la grilla queda
    /// después de `onAppear`.
    @MainActor
    static func draft(_ connection: DatabaseConnection, result: SQLResult? = nil,
                      table schema: SQLSchemaTable? = nil) -> SQLResultDraft {
        let draft = SQLResultDraft(result: result ?? QAFixtures.result(connection))
        draft.configure(schema ?? table())
        return draft
    }

    /// El perfil que usan los escenarios: loopback, sin TLS, con la política que se pida.
    static func connection(_ name: String = "QA",
                           policy: DatabaseConnection.WritePolicy? = nil) -> DatabaseConnection {
        var connection = DatabaseConnection(name: name)
        connection.tls = .disabled
        connection.database = database
        if let policy { connection.writePolicy = policy.rawValue }
        return connection
    }

    /// El puerto del MySQL desechable, si el desarrollador dejó el marcador. Las pruebas
    /// etiquetadas `needs-mysql` se saltan cuando no está: ver docs/qa-automation.md.
    static func mysqlPort(_ file: StaticString = #filePath) throws -> Int {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.lastPathComponent != "KrabzikTests", directory.path != "/" { directory.deleteLastPathComponent() }
        let marker = directory.deletingLastPathComponent().appendingPathComponent(".build/mysql-test-port")
        guard let text = try? String(contentsOf: marker, encoding: .utf8),
              let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw XCTSkip("necesita el MySQL desechable: creá .build/mysql-test-port (ver docs/qa-automation.md)")
        }
        return port
    }
}
