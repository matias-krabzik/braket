import Foundation

/// Cómo se enciende el registro de QA cuando la app corre a mano.
///
/// `Braket --qa-log /ruta/sesion.ndjson` escribe una línea por evento; `--qa` lo deja en
/// memoria y lo hace visible en la consola de `log stream`. Sin ninguno de los dos no
/// pasa nada, y en Release no existe: ver `QAProbe`.
enum QADiagnostics {
    static let logFlag = "--qa-log"
    static let enableFlag = "--qa"
    static let echoFlag = "--qa-echo"

    @MainActor
    static func activateIfRequested(arguments: [String]) {
        #if DEBUG
        let echo = arguments.contains(echoFlag)
        if let index = arguments.firstIndex(of: logFlag), arguments.indices.contains(index + 1) {
            QAProbe.activate(writingTo: arguments[index + 1], echo: echo)
            return
        }
        if arguments.contains(enableFlag) { QAProbe.activate(echo: echo) }
        #endif
    }
}
