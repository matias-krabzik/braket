import Foundation

/// Qué le hace una sentencia al servidor, para decidir si la guarda de escritura del
/// perfil la deja pasar.
enum SQLStatementEffect: String, Sendable {
    /// Lectura reconocida **con certeza**.
    case read
    /// Escribe, o no se reconoce con certeza: las dos cosas se tratan igual.
    case write
}

/// Clasifica sentencias para la guarda de escritura por perfil
/// (`DatabaseConnection.WritePolicy`). Ver docs/specs/S8-guarda-de-escritura-mysql.md.
///
/// **Falla cerrada.** Solo una lista corta de formas cuenta como lectura: `SELECT` sin
/// bloqueo ni `INTO`, `WITH … SELECT`, `SHOW`, `DESCRIBE`/`DESC`, `EXPLAIN`, `USE`, `SET`
/// de variables de sesión y `START TRANSACTION`/`COMMIT`/`ROLLBACK`. Cualquier otra cosa
/// —DML, DDL, `CALL`, `LOAD`, `GRANT`, `FLUSH`, `KILL`, un comentario ejecutable `/*!`, una
/// palabra que no se reconoce o una sentencia sin palabras— cuenta como escritura.
///
/// No sustituye a los `GRANT` del servidor: es una barrera local contra el clic de más.
enum SQLWriteGuard {
    /// Palabras que, en el nivel externo, convierten una lectura en algo que bloquea filas
    /// o escribe: `FOR UPDATE`, `FOR SHARE`, `LOCK IN SHARE MODE`, `INTO OUTFILE`,
    /// `INTO @variable`, `INTO tabla`.
    private static let locking: Set<String> = ["INTO", "FOR", "LOCK"]

    /// Lo que puede seguir a un `WITH`: MySQL 8 admite CTE delante de `UPDATE` y `DELETE`,
    /// así que un `WITH` no implica lectura.
    private static let dml: Set<String> = ["INSERT", "UPDATE", "DELETE", "REPLACE"]

    /// `EXPLAIN ANALYZE` ejecuta de verdad la consulta, y `EXPLAIN` admite delante de sí
    /// un DML. Cualquiera de estas palabras saca al `EXPLAIN` de las lecturas.
    private static let explained: Set<String> = ["ANALYZE", "CALL", "LOAD", "INSERT", "UPDATE", "DELETE", "REPLACE"]

    /// Un `SET` que toca el servidor y no la sesión. `@@GLOBAL.x` también cae acá: el
    /// recorrido deja `GLOBAL` como palabra suelta.
    private static let serverScope: Set<String> = ["GLOBAL", "PERSIST", "PERSIST_ONLY", "PASSWORD"]

    /// Lo que no es una variable de sesión aunque venga detrás de `SET`.
    private static let privileged: Set<String> = ["DEFAULT", "ROLE", "RESOURCE"]

    /// Clasifica **una** sentencia ya separada por `SQLScript`.
    static func effect(of statement: String, noBackslashEscapes: Bool = false) -> SQLStatementEffect {
        let scan = SQLScript.scan(statement, noBackslashEscapes: noBackslashEscapes)
        guard !scan.hasExecutableComment, let first = scan.words.first else { return .write }
        let outer = scan.outer
        if Array(outer.prefix(2)) == ["SET", "LIST"] {
            guard let list = try? SQLListStatement.parse(statement, noBackslashEscapes: noBackslashEscapes) else { return .write }
            return effect(of: list.query, noBackslashEscapes: noBackslashEscapes)
        }
        switch first.word {
        case "SELECT":
            return select(scan)
        case "WITH":
            // Hace falta un SELECT y ningún DML: `WITH x AS (…) DELETE` es una escritura.
            guard scan.words.contains(where: { $0.word == "SELECT" }),
                  !outer.contains(where: dml.contains) else { return .write }
            return select(scan)
        case "SHOW", "USE":
            return .read
        case "DESCRIBE", "DESC", "EXPLAIN":
            return outer.contains(where: explained.contains) || outer.contains(where: locking.contains) ? .write : .read
        case "SET":
            return set(scan)
        case "START":
            return outer.dropFirst().first == "TRANSACTION" ? .read : .write
        case "COMMIT", "ROLLBACK":
            return .read
        default:
            return .write
        }
    }

    private static func select(_ scan: SQLWordScan) -> SQLStatementEffect {
        scan.words.contains { $0.depth == 0 && locking.contains($0.word) } ? .write : .read
    }

    private static func set(_ scan: SQLWordScan) -> SQLStatementEffect {
        let words = scan.words.map(\.word).dropFirst()
        guard let second = words.first, !privileged.contains(second) else { return .write }
        guard !words.contains(where: serverScope.contains), !words.contains(where: locking.contains) else { return .write }
        return .read
    }

    /// La clasificación de **todo** un script, para poder decidir antes de abrir la conexión.
    struct Audit: Sendable {
        /// Cuántas sentencias tiene el script.
        var total = 0
        /// Las que escriben, en orden, con la línea donde empiezan.
        var writes: [SQLStatement] = []
        var hasWrites: Bool { !writes.isEmpty }

        /// Las primeras sentencias que escriben, recortadas para un diálogo.
        ///
        /// `SQLScript` incluye en el texto de la sentencia los comentarios que la preceden,
        /// porque es lo que el servidor recibe. Para el diálogo se descartan: un comentario
        /// largo delante de un `DELETE` empujaría la sentencia fuera del recorte.
        func preview(limit: Int = 3, characters: Int = 110) -> [String] {
            writes.prefix(limit).map { statement in
                let lines = statement.text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .drop { $0.isEmpty || $0.hasPrefix("--") || $0.hasPrefix("#") }
                let flat = lines.joined(separator: " ")
                let text = flat.count > characters ? flat.prefix(characters) + "…" : flat[...]
                return "Línea \(statement.line): \(text)"
            }
        }
    }

    /// Clasifica el script completo. Lanza si el script no se puede partir —una cadena sin
    /// cerrar, un `DELIMITER` inválido—, porque sin poder leerlo no hay nada que afirmar.
    static func audit(_ script: String, startingLine: Int = 1, noBackslashEscapes: Bool = false) throws -> Audit {
        var cursor = SQLScript(script, startingLine: startingLine)
        var audit = Audit()
        while let statement = try cursor.next(noBackslashEscapes: noBackslashEscapes) {
            audit.total += 1
            guard effect(of: statement.text, noBackslashEscapes: noBackslashEscapes) == .write else { continue }
            audit.writes.append(statement)
        }
        return audit
    }
}
