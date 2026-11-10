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

## Resuelto

**2026-11-10**, commit `b252444`.

| Criterio | Cómo se verificó |
|---|---|
| 1 · ningún `catch { }` en `Krabzik/` | el trinquete de `scripts/verify.sh` bajó a 0 y ahora cuenta solo el código de producción. En una prueba, `do { … XCTFail() } catch {}` es la forma idiomática de decir «esto tiene que lanzar»; ahí el catch vacío es correcto y queda fuera de la cuenta |
| 2 · `Log.swift` con las seis categorías y la regla de privacidad | hecho, con la regla escrita arriba del archivo y el comando de `log show` para leer la app instalada |
| 3 · ninguna interpolación incluye una contraseña | revisado uso por uso: son quince, y los únicos datos que viajan sin `.private` son métodos del protocolo, el pid, el modo de TLS, conteos y `errno` |
| 4 · cancelar sin conexión de control avisa en la interfaz | ya lo resolvió S4 con `CancelOutcome` y `SQLExecution.cancelNote`; acá se le sumó el registro. Lo cubre `testCancellationReportsWhenCredentialIsUnavailable` |
| 5 · `log show` muestra entradas al abrir un proyecto, arrancar un proceso y conectar una base | hay una línea en cada uno de los tres caminos felices (`Log.workspace.info` en `install`, `Log.process.info` tras el `posix_spawn`, `Log.mysql.info` tras conectar). Sobre la Release instalada el 2026-11-10 se comprobó que el subsistema y las categorías están en el binario; **las entradas no se verificaron** porque la app recién arrancada se queda en la pantalla de inicio y abrir un proyecto en la app del usuario cambiaría su historial y podría dejarle un diálogo de confianza abierto. Se comprueba la próxima vez que se abra un proyecto, con `log show --predicate 'subsystem == "com.krabzik.ide"' --last 5m --info` |
| 6 · un fallo de arranque de Codex deja diagnóstico accesible | el stderr del hijo va a un anillo de 64 KiB en memoria y el panel ofrece «Ver diagnóstico» cuando hay algo |
| 7 · el nivel del logger de MySQL se sube sin recompilar | `defaults write com.krabzik.ide mysqlLogLevel debug`, leído por `MySQLLogHandler.configuredLevel` |

### Decisiones

- **`isSecret` pasó al modelo.** Estaba como propiedad privada de la vista. El controlador necesita saberlo
  para registrar que llegó una pregunta marcada como secreta —el evento, nunca el contenido—, y el dato es
  del `AgentRequest`, no de la vista.
- **Responder y rechazar comparten el tratamiento del error.** Los dos terminan el turno con un mensaje
  visible: si el canal de escritura está roto, seguir esperando una respuesta es lo único que no puede
  pasar.
- **Dos líneas nuevas en seguridad**, que el spec no pedía: confiar en un proyecto y aprobar un comando.
  Son las dos decisiones de S1 que amplían lo que la app puede hacer, y tener cuándo se tomaron es
  justamente lo que sirve si algo sale mal.
- **El trinquete de catch vacíos cuenta solo `Krabzik/`.** Antes contaba también las pruebas, donde el
  patrón es correcto. Bajarlo a 0 sin esa distinción habría forzado a escribir peor las pruebas.

### Errores cometidos

- `MySQLLogHandler` implementaba la firma vieja de `LogHandler`; swift-log la dejó deprecada y, con
  warnings como errores, no compila. Va con `log(event:)`.
- La primera versión de la línea de log de la conexión partía una interpolación en dos líneas con `\` dentro
  de una cadena multilínea. No compila: la interpolación tiene que quedar entera en su línea.
