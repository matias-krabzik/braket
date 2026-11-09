# C6 · Logging real y errores no silenciados

| | |
|---|---|
| **Severidad** | Media |
| **Área** | Observabilidad |
| **Archivos** | nuevo `Krabzik/Services/Log.swift`, `Krabzik/Services/MySQLClient.swift`, `Krabzik/Services/AgentController.swift`, `Krabzik/Services/CodexTransport.swift`, `Krabzik/Services/WorkspaceController.swift` |
| **Depende de** | C1. Encaja con C5 (`ErrorCenter`) |
| **Esfuerzo** | Medio día |

## Problema

**No hay logging de ninguna clase en la app.** `grep -rn "print(\|NSLog\|debugPrint" Krabzik` no devuelve
nada, y no se usa `os.Logger`. Además, varios errores se descartan en silencio:

```swift
// MySQLClient.cancel(_:)
do {
    let control = try await open(value.configuration, password: value.password)
    do { _ = try await control.simpleQuery("KILL CONNECTION \(value.serverID)").get() } catch { }
    try? await control.close().get()
} catch { }
try? await value.connection.close().get()
```

Si el `KILL CONNECTION` falla, **el usuario cree que canceló la consulta y en el servidor sigue corriendo**.
Nadie se entera: ni él ni un log. Otros casos:

- `AgentController.receive(_:)`: `try? transport.reject(id:)` y `try? transport.respond(...)` en cuatro
  ramas. Si el canal de escritura está roto, el turno queda colgado sin explicación.
- `WorkspaceController.saveConnection(...)`: `try? CredentialStore.remove(for: previous)` — una credencial
  huérfana queda en el llavero sin registro.
- `CodexTransport`: el stderr del hijo va a `/dev/null` **a propósito** (el comentario lo justifica: puede
  contener rutas privadas). Correcto como decisión, pero el efecto es que un fallo de arranque de Codex no
  deja ninguna pista.
- `MySQLClient`: `logger.logLevel = .critical` fija el logger de MySQLNIO al nivel más alto, así que los
  avisos del protocolo nunca se ven.

Resultado práctico: diagnosticar un problema en la app **instalada** (que es el flujo que pide `AGENTS.md`)
es imposible. No hay nada que leer.

## Objetivo

Todo error tiene un destino: la interfaz, el log, o los dos. Ninguno se descarta en silencio. Un problema en
la app instalada se puede investigar con `log show` sin recompilar.

## Alcance

**Incluye** el subsistema de logging, el reemplazo de los `catch` vacíos, el nivel configurable del logger
de MySQL, y un anillo en memoria para el stderr de Codex.

**No incluye** telemetría remota de ningún tipo. Todo queda en la máquina del usuario.

## Diseño

### 1. `Log.swift`

```swift
import OSLog

enum Log {
    private static let subsystem = "com.krabzik.ide"
    static let workspace = Logger(subsystem: subsystem, category: "workspace")
    static let documents = Logger(subsystem: subsystem, category: "documents")
    static let process   = Logger(subsystem: subsystem, category: "process")
    static let mysql     = Logger(subsystem: subsystem, category: "mysql")
    static let agent     = Logger(subsystem: subsystem, category: "agent")
    static let security  = Logger(subsystem: subsystem, category: "security")
}
```

**Reglas de privacidad, obligatorias:**

- Rutas de archivo, nombres de host, usuarios de base de datos, prompts y contenido de archivos:
  `\(path, privacy: .private)`.
- Nunca, bajo ninguna interpolación, contraseñas ni el contenido de respuestas marcadas `isSecret` (S5).
- Lo público solo son categorías, códigos de error, duraciones y conteos.

Un comentario al principio del archivo con esta regla, porque es el tipo de cosa que se rompe por
conveniencia seis meses después.

### 2. Reemplazo de los `catch` vacíos

| Sitio | Hoy | Debe hacer |
|---|---|---|
| `MySQLClient.cancel` (apertura de la conexión de control) | `catch { }` | `Log.mysql.error` + marcar el resultado para que la UI avise |
| `MySQLClient.cancel` (`KILL CONNECTION`) | `catch { }` | ídem |
| `AgentController.receive` (`reject`/`respond`) | `try?` | `Log.agent.error` y, si el canal está roto, `finishTurn(error:)` |
| `WorkspaceController.saveConnection` (`remove`) | `try?` | `Log.security.error` con el estado del llavero |
| `FileTree.watch` (si `open` falla) | `return` silencioso | `Log.workspace.notice`: el árbol dejará de actualizarse solo |

El caso de `cancel` necesita además un camino visible. `MySQLClient.cancel(_:)` pasa a devolver un
resultado:

```swift
enum CancelOutcome { case killed, localOnly(reason: String) }
func cancel(_ operation: UUID) async -> CancelOutcome
```

y `DatabaseController.cancel(_:)` lo refleja en `SQLExecution.error`:
«Se cerró la conexión local. La consulta puede seguir ejecutándose en el servidor.» Esa frase es información
que hoy el usuario no tiene y que cambia lo que hará a continuación.

### 3. Nivel del logger de MySQL

`logger.logLevel = .critical` pasa a leerse de `UserDefaults` (clave `mysqlLogLevel`), con default
`.warning`, y a volcarse a `Log.mysql` mediante un `LogHandler` propio de swift-log que reenvíe a
`os.Logger` con las reglas de privacidad del punto 1. Así los avisos del protocolo son accesibles sin
recompilar, y los de un fork parcheado (S7) también.

### 4. stderr de Codex

En lugar de `/dev/null`, redirigir el stderr del hijo a un pipe propio y mantener un anillo en memoria de
**64 KiB**, sin persistirlo nunca a disco. Mostrarlo bajo demanda en el panel del agente («Ver diagnóstico»)
y registrar solo las líneas al nivel `debug` con `privacy: .private`. Conserva la intención original —no
guardar rutas privadas— y deja de perder la única pista de por qué Codex no arranca.

### 5. Chequeo automático

En `scripts/verify.sh` (C3):

```sh
grep -rn 'catch *{ *}' --include='*.swift' Krabzik && exit 1 || true
```

Un `catch` vacío vuelve a entrar solo con una justificación escrita, y entonces el chequeo se ajusta con una
excepción nominal, no borrándolo.

## Criterios de aceptación

1. `grep -rn 'catch *{ *}' --include='*.swift' Krabzik` no devuelve nada.
2. Existe `Krabzik/Services/Log.swift` con las seis categorías y la regla de privacidad documentada.
3. Ninguna interpolación de log en el repositorio incluye una contraseña; verificable por inspección de los
   usos de `Log.` (son pocos y acotados).
4. Cancelar una consulta cuando el servidor no acepta la conexión de control deja un mensaje en la interfaz
   que dice que la consulta puede seguir corriendo.
5. `log show --predicate 'subsystem == "com.krabzik.ide"' --last 5m` muestra entradas después de abrir un
   proyecto, arrancar un proceso y conectar una base.
6. Un fallo de arranque de Codex deja al menos una línea de diagnóstico accesible desde el panel.
7. El nivel del logger de MySQL se puede subir sin recompilar.

## Pruebas

- `KrabzikTests/DatabaseTests.swift`: `testCancelReportsLocalOnlyWhenControlConnectionFails` — con el lector
  de credenciales inyectable que introduce S4, o apuntando la conexión de control a un puerto cerrado.
- `KrabzikTests/AgentTests.swift`: `testBrokenTransportFinishesTurnWithError` — cerrar el canal de escritura
  y comprobar que `receive` de una solicitud que requiere respuesta termina el turno con error en lugar de
  quedar colgado.
- El resto se verifica con el criterio 1 (automatizado en `verify.sh`) y el 5 (manual, una vez).

## Riesgos y compatibilidad

- **Fugas de datos por log.** Es el riesgo real de este spec: un log mal escrito expone rutas o consultas.
  Por eso la regla de privacidad va primero y los usos son pocos y revisables.
- El anillo de stderr de Codex ocupa memoria y puede contener rutas privadas: 64 KiB, nunca a disco, nunca
  en el informe de un error que se comparta.
- Subir el nivel del logger de MySQL puede volverlo ruidoso en consultas grandes; el default `.warning` lo
  evita.
