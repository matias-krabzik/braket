import OSLog

/// Logging de la app, en `os.Logger`. Todo queda en la máquina del usuario: no hay
/// telemetría de ninguna clase y nada de esto sale por la red.
///
/// **Regla de privacidad, obligatoria.** Es el tipo de cosa que se rompe por conveniencia
/// seis meses después, así que está escrita acá y se revisa en cada uso nuevo:
///
/// - Rutas de archivo, nombres de host, usuarios de base de datos, prompts y contenido de
///   archivos van siempre con `privacy: .private`. También los `localizedDescription`, que
///   suelen traer una ruta adentro.
/// - **Nunca**, bajo ninguna interpolación, contraseñas ni el contenido de respuestas
///   marcadas `isSecret` (ver `AgentRequest`).
/// - Público solo lo que no identifica nada: categorías, métodos del protocolo, códigos de
///   error, duraciones y conteos.
///
/// Para leer lo que dejó la app instalada, sin recompilar:
/// `log show --predicate 'subsystem == "com.krabzik.ide"' --last 5m --info`
enum Log {
    private static let subsystem = "com.krabzik.ide"
    static let workspace = Logger(subsystem: subsystem, category: "workspace")
    static let documents = Logger(subsystem: subsystem, category: "documents")
    static let process = Logger(subsystem: subsystem, category: "process")
    static let mysql = Logger(subsystem: subsystem, category: "mysql")
    static let agent = Logger(subsystem: subsystem, category: "agent")
    static let security = Logger(subsystem: subsystem, category: "security")
}
