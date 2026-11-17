import Foundation
import OSLog

/// Qué clase de cosa pasó. Es el primer campo de cada línea del registro y lo que las
/// pruebas usan para filtrar: `action` es lo que pidió el usuario, `state` lo que quedó
/// después, y `control` lo que la interfaz está ofreciendo en ese momento.
enum QAKind: String, Sendable, CaseIterable {
    /// Una acción iniciada por el usuario: un botón, un atajo, un menú.
    case action
    /// El estado observable después de una acción. Es lo que se afirma.
    case state
    /// Un control de la interfaz que apareció, cambió de título o de habilitación.
    case control
    /// Un diálogo que la app quiso mostrar, con la respuesta que recibió.
    case dialog
    /// Una etapa de una consulta SQL o de una conexión.
    case sql
    /// Un error que llegó al usuario.
    case error
    /// Una marca que pone la propia prueba para separar sus fases.
    case mark
}

/// Un evento del registro de QA, tal como se escribe en el archivo y como lo leen las
/// pruebas.
struct QAEvent: Sendable, Equatable {
    /// Orden de emisión, desde 1. Las aserciones de secuencia lo usan.
    let seq: Int
    /// Segundos desde que se activó el registro.
    let elapsed: TimeInterval
    let kind: QAKind
    /// Nombre con puntos, de lo general a lo particular: `project.open.ok`.
    let name: String
    /// Datos del evento. Nunca contraseñas; las rutas van abreviadas.
    let fields: [String: String]

    /// `true` si el nombre es exactamente `name` o uno de sus descendientes.
    func matches(_ pattern: String) -> Bool {
        name == pattern || name.hasPrefix(pattern + ".")
    }

    /// Una línea NDJSON con las claves ordenadas, para que dos corridas iguales produzcan
    /// archivos iguales y el diff sirva de algo.
    var ndjson: String {
        let head = "{\"seq\":\(seq),\"t\":\(String(format: "%.3f", elapsed))," +
            "\"kind\":\"\(kind.rawValue)\",\"name\":\(QAEvent.quote(name))"
        let body = fields.keys.sorted().map { key in
            ",\(QAEvent.quote(key)):\(QAEvent.quote(fields[key] ?? ""))"
        }.joined()
        return head + body + "}"
    }

    /// Una línea legible para la terminal.
    var line: String {
        let detail = fields.keys.sorted().map { "\($0)=\(fields[$0] ?? "")" }.joined(separator: " ")
        return String(format: "%7.3f %-7@ %-38@ %@", elapsed, kind.rawValue as NSString,
                      name as NSString, detail as NSString)
    }

    private static func quote(_ value: String) -> String {
        var output = "\""
        for character in value.unicodeScalars {
            switch character {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if character.value < 0x20 { output += String(format: "\\u%04x", character.value) }
                else { output.unicodeScalars.append(character) }
            }
        }
        return output + "\""
    }
}

/// El registro de QA: una línea por cosa que pasa en la interfaz, para poder afirmar
/// **cómo reacciona** la app y no solo que no se cayó.
///
/// **Solo funciona en Debug.** En Release `isActive` es `false` constante y cada método
/// tiene cuerpo vacío: la app que se instala en `/Applications` no abre ningún archivo ni
/// escribe ninguna línea. Quedan las funciones vacías y algún literal, nada que se
/// ejecute. Ver docs/qa-automation.md.
///
/// **Privacidad.** Sigue la regla de `Log`, con una vuelta más: las rutas se abreviaron
/// con `~` antes de llegar acá (`QAField.path`), el SQL se recorta, y las contraseñas no
/// entran por ningún campo. Lo que sí entra —host, puerto, usuario, nombres de tabla— es
/// lo que las aserciones necesitan, y queda en un archivo local que la propia corrida
/// crea y borra.
///
/// Confinado al main actor: todo lo que se instrumenta ya vive ahí, así que no hace falta
/// ningún escape de concurrencia.
@MainActor
enum QAProbe {
    #if DEBUG
    /// `true` cuando alguien activó el registro: la app con `--qa-log`, o una prueba.
    private(set) static var isActive = false
    /// Todo lo emitido desde el último `reset()`. Es lo que leen las aserciones.
    private(set) static var timeline: [QAEvent] = []
    private static var start = Date()
    private static var sequence = 0
    private static var handle: FileHandle?
    private static var echoesToConsole = false
    private static var waiters: [Waiter] = []
    private static let logger = Logger(subsystem: "com.krabzik.ide", category: "qa")

    /// Una espera en curso. Es una clase y no una estructura porque el plazo y la
    /// llegada del evento compiten por reanudar la misma continuación, y solo uno puede
    /// ganar: la bandera tiene que ser compartida.
    private final class Waiter {
        let pattern: String
        let afterSequence: Int
        private var continuation: CheckedContinuation<QAEvent?, Never>?

        init(pattern: String, afterSequence: Int, continuation: CheckedContinuation<QAEvent?, Never>) {
            self.pattern = pattern
            self.afterSequence = afterSequence
            self.continuation = continuation
        }

        func finish(_ event: QAEvent?) {
            guard let pending = continuation else { return }
            continuation = nil
            pending.resume(returning: event)
        }
    }

    /// Enciende el registro. `path` es el archivo NDJSON; `nil` deja todo en memoria.
    static func activate(writingTo path: String? = nil, echo: Bool = false) {
        isActive = true
        echoesToConsole = echo
        reset()
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        emit(.mark, "qa.activated", ["file": QAField.path(url)])
    }

    /// Apaga el registro y cierra el archivo. Las pruebas la llaman en el teardown.
    static func deactivate() {
        try? handle?.close()
        handle = nil
        isActive = false
        waiters.removeAll()
    }

    /// Vacía la línea de tiempo sin apagar el registro: una prueba por escenario.
    static func reset() {
        timeline.removeAll()
        sequence = 0
        start = Date()
        waiters.removeAll()
    }

    static func emit(_ kind: QAKind, _ name: String, _ fields: [String: String] = [:]) {
        guard isActive else { return }
        sequence += 1
        let event = QAEvent(seq: sequence, elapsed: Date().timeIntervalSince(start), kind: kind,
                            name: name, fields: fields)
        timeline.append(event)
        if let handle, let data = (event.ndjson + "\n").data(using: .utf8) { try? handle.write(contentsOf: data) }
        if echoesToConsole { FileHandle.standardError.write(Data((event.line + "\n").utf8)) }
        logger.debug("\(event.name, privacy: .public)")
        let matched = waiters.filter { event.seq > $0.afterSequence && event.matches($0.pattern) }
        waiters.removeAll { candidate in matched.contains { $0 === candidate } }
        for waiter in matched { waiter.finish(event) }
    }

    /// El último evento cuyo nombre coincide con `pattern` (exacto o prefijo con punto).
    static func last(_ pattern: String) -> QAEvent? {
        timeline.last { $0.matches(pattern) }
    }

    /// Todos los eventos que coinciden, en orden.
    static func all(_ pattern: String) -> [QAEvent] {
        timeline.filter { $0.matches(pattern) }
    }

    /// Espera el próximo evento que coincida con `pattern`, o `nil` si se agota el plazo.
    ///
    /// Cuenta solo lo que llegue **después** de la llamada: así una prueba que espera dos
    /// veces el mismo nombre no se queda con el primero las dos veces. Si ya hay uno
    /// pendiente desde antes de la acción, usá `last(_:)`.
    static func next(_ pattern: String, timeout: TimeInterval = 5) async -> QAEvent? {
        guard isActive else { return nil }
        let after = sequence
        return await withCheckedContinuation { continuation in
            let waiter = Waiter(pattern: pattern, afterSequence: after, continuation: continuation)
            waiters.append(waiter)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                waiters.removeAll { $0 === waiter }
                waiter.finish(nil)
            }
        }
    }
    #else
    static var isActive: Bool { false }
    static var timeline: [QAEvent] { [] }
    static func activate(writingTo path: String? = nil, echo: Bool = false) {}
    static func deactivate() {}
    static func reset() {}
    static func emit(_ kind: QAKind, _ name: String, _ fields: [String: String] = [:]) {}
    static func last(_ pattern: String) -> QAEvent? { nil }
    static func all(_ pattern: String) -> [QAEvent] { [] }
    static func next(_ pattern: String, timeout: TimeInterval = 5) async -> QAEvent? { nil }
    #endif

    // MARK: - Atajos con nombre
    // Uno por clase de evento, para que los sitios instrumentados lean como prosa y no
    // haya dos formas de escribir lo mismo.

    static func action(_ name: String, _ fields: [String: String] = [:]) {
        emit(.action, name, fields)
    }

    static func state(_ name: String, _ fields: [String: String]) {
        emit(.state, name, fields)
    }

    static func sql(_ name: String, _ fields: [String: String] = [:]) {
        emit(.sql, name, fields)
    }

    /// Un diálogo que la app quiso mostrar y lo que le contestaron. Queda registrado
    /// incluso cuando la respuesta la dio un guion de prueba: eso es justamente lo que
    /// hay que poder afirmar.
    static func dialog(_ name: String, answer: String, _ fields: [String: String] = [:]) {
        emit(.dialog, name, fields.merging(["answer": answer]) { _, new in new })
    }

    static func failure(_ name: String, _ message: String, _ fields: [String: String] = [:]) {
        emit(.error, name, fields.merging(["message": QAField.text(message)]) { _, new in new })
    }

    static func mark(_ name: String, _ fields: [String: String] = [:]) {
        emit(.mark, name, fields)
    }
}

/// Cómo se escribe cada clase de dato en un campo del registro. Un solo sitio, para que
/// la regla de privacidad se pueda revisar leyendo veinte líneas.
enum QAField {
    /// Una ruta, abreviada con `~` y sin el contenido del archivo.
    static func path(_ url: URL?) -> String {
        guard let url else { return "" }
        return (url.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
    }

    /// Un texto cualquiera, en una línea y recortado: los mensajes largos vuelven
    /// ilegible el registro y no se afirman enteros.
    static func text(_ value: String, limit: Int = 160) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "…"
    }

    /// SQL, normalizado a una línea y recortado. Alcanza para identificar la sentencia
    /// sin volcar un script entero en cada evento.
    static func sql(_ value: String, limit: Int = 200) -> String {
        text(value.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " "), limit: limit)
    }

    static func bool(_ value: Bool) -> String { value ? "true" : "false" }

    static func count(_ value: Int) -> String { String(value) }
}
