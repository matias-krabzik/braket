import Foundation
import JavaScriptCore

/// Motor local, versionado y aislado del hilo de interfaz. Nunca envía ni ejecuta SQL.
actor SQLFormatterEngine {
    static let shared = SQLFormatterEngine()
    private var context: JSContext?

    func format(_ sql: String, options: EditorOptions) throws -> String {
        guard sql.utf16.count <= 250_000 else {
            throw DatabaseFailure("Seleccioná un fragmento de hasta 250.000 caracteres para formatear.")
        }
        var parser = SQLScript(sql)
        while let statement = try parser.next() {
            guard statement.delimiter == ";" else {
                throw DatabaseFailure("El formato de scripts con DELIMITER personalizado todavía no está disponible.")
            }
        }
        guard EditorStructure(sql, sql: true).unmatched.isEmpty else {
            throw DatabaseFailure("Hay paréntesis o delimitadores sin pareja. Corregilos antes de formatear.")
        }
        let context = try engine()
        context.exception = nil
        let function = context.objectForKeyedSubscript("sqlFormatter")?.objectForKeyedSubscript("format")
        let config: [String: Any] = ["language": "mysql", "tabWidth": options.indentWidth,
                                     "keywordCase": options.keywordCase, "linesBetweenQueries": 1]
        let value = function?.call(withArguments: [sql, config])
        if let exception = context.exception {
            let reason = exception.toString()?.components(separatedBy: "\n").first ?? "SQL no reconocido."
            context.exception = nil
            throw DatabaseFailure("No se pudo interpretar el SQL: " + String(reason.prefix(240)))
        }
        guard let result = value?.toString(), value?.isUndefined == false else {
            throw DatabaseFailure("El formateador SQL no devolvió un resultado válido.")
        }
        // Defensa adicional: conservar los tokens, los literales y los comentarios.
        guard fingerprint(sql) == fingerprint(result), comments(sql) == comments(result) else {
            throw DatabaseFailure("El formato modificaría tokens o comentarios. Se conservó el código original.")
        }
        return result + (sql.hasSuffix("\n") ? "\n" : "")
    }

    private func engine() throws -> JSContext {
        if let context { return context }
        guard let url = Bundle.main.url(forResource: "sql-formatter.min", withExtension: "js", subdirectory: "SQLFormatter"),
              let context = JSContext() else { throw DatabaseFailure("No se encontró el motor de formato SQL.") }
        let script = try String(contentsOf: url, encoding: .utf8)
        context.evaluateScript(script)
        guard context.exception == nil else { throw DatabaseFailure("No se pudo iniciar el motor de formato SQL.") }
        self.context = context
        return context
    }

    private func fingerprint(_ sql: String) -> [String] {
        SQLScript.scan(sql, collectLexemes: true).lexemes.map { $0.quoted ? $0.text : $0.text.uppercased() }
    }

    private func comments(_ sql: String) -> [String] {
        SQLScript.scan(sql, collectSyntax: true).syntax.filter { $0.token == "comment" }
            .map { (sql as NSString).substring(with: $0.range) }
    }
}
