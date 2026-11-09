# S4 · No retener la contraseña en memoria durante la sesión

| | |
|---|---|
| **Severidad** | Media-baja |
| **Área** | MySQL, credenciales |
| **Archivos** | `Krabzik/Services/MySQLClient.swift`, `Krabzik/Services/CredentialStore.swift` |
| **Depende de** | — |
| **Esfuerzo** | 2–3 horas |

## Problema

El actor `MySQLClient` guarda la contraseña en claro dentro de cada sesión abierta:

```swift
private struct Session {
    let connection: MySQLConnection
    let configuration: DatabaseConnection
    let password: String          // ← vive mientras viva la sesión
    let serverID: UInt64
    …
}
```

El único consumidor es `cancel(_:)`, que necesita credenciales para abrir una segunda conexión corta y
mandar `KILL CONNECTION <serverID>`:

```swift
let control = try await open(value.configuration, password: value.password)
```

Consecuencia: mientras haya una conexión MySQL abierta —que puede ser toda la jornada— la contraseña está
en el heap del proceso, y aparecería en un volcado de memoria, en un core dump o en el estado guardado por
el sistema si la app se cuelga. El resto del diseño es cuidadoso con esto (nunca va al `.krabzik`, vive en
el llavero, ligada al endpoint), así que esta retención es la pieza que desentona.

## Objetivo

La contraseña se lee del llavero, se usa para el handshake y no queda retenida por la app después. El
camino de cancelación sigue funcionando.

## Alcance

**Incluye** quitar el campo de `Session`, releer del llavero en el camino de cancelación, y acotar la vida
de la copia que `DatabaseController` pasa como parámetro.

**No incluye** garantizar el borrado de la memoria de un `String` de Swift. No se puede hacer de forma
fiable sin reescribir el transporte para que trabaje con buffers propios; queda documentado como
limitación conocida, no como criterio de aceptación.

## Diseño

### 1. `Session` sin contraseña

Quitar el campo. `Session` conserva `configuration` y `serverID`, que es todo lo que hace falta para
identificar qué matar y contra qué servidor reconectar.

### 2. `cancel(_:)` relee del llavero

`CredentialStore` es síncrono y usa la API de Security, que bloquea. Dentro de un actor hay que sacarlo del
hilo del actor:

```swift
let password = try await Task.detached(priority: .userInitiated) {
    try CredentialStore.read(for: value.configuration)
}.value
```

`CredentialStore.read` ya devuelve `""` si no hay ítem, así que el caso «conexión sin contraseña» sigue
funcionando. Si la lectura falla —el usuario denegó el acceso al llavero, por ejemplo— no se puede mandar
el `KILL`: hay que cerrar el socket igual (como ya se hace) y **reportarlo** en lugar de tragarlo, que es
justo el `catch { }` vacío que señala C6:

```swift
catch { Log.mysql.error("no se pudo abrir la conexión de control: \(…)") ; await report(.killFailed) }
```

El estado visible queda: «Se cerró la conexión local. La consulta puede seguir corriendo en el servidor.»
Eso es información que hoy el usuario no tiene y sí necesita.

### 3. Acotar la copia del parámetro

`DatabaseController.connect(_:)` y `execute(_:connection:)` leen del llavero y pasan `password` como
parámetro; eso está bien y se conserva. Lo que hay que evitar es guardar esa copia en el `SQLExecution` o
en el estado observable. Verificar que no ocurra (hoy no ocurre) y dejar un comentario en
`DatabaseController` que lo diga, para que no se agregue después «por comodidad».

### 4. Limitación documentada

Comentario en `CredentialStore`:

```swift
// La contraseña se mueve como String porque el transporte de MySQLNIO la pide así.
// Swift no garantiza el borrado del buffer; el objetivo acá es acotar su VIDA, no su rastro.
```

## Criterios de aceptación

1. `MySQLClient.Session` no tiene ningún campo que guarde la credencial, verificado por compilación y por
   inspección del tipo en una prueba `@testable`.
2. Cancelar una consulta larga sigue cerrando la sesión del servidor: la prueba existente
   `testMySQLCancellationClosesActualServerSession` pasa sin modificar su cuerpo.
3. Si la lectura del llavero falla durante la cancelación, la conexión local se cierra y la UI muestra el
   aviso de que la consulta puede seguir en el servidor; no hay `catch` vacío en ese camino.
4. Conectar a un servidor sin contraseña (`MYSQL_ALLOW_EMPTY_PASSWORD`) sigue funcionando, incluida la
   cancelación.

## Pruebas

En `KrabzikTests/DatabaseTests.swift`:

- Reusar `testMySQLCancellationClosesActualServerSession` como prueba de no regresión (requiere servidor,
  se salta sin `.build/mysql-test-port`).
- `testCancellationReportsWhenKeychainIsUnavailable`: inyectar el lector de credenciales como closure en
  `MySQLClient` para poder simular el fallo sin tocar el llavero real. Esto obliga a un pequeño cambio de
  diseño —el actor recibe `readPassword: @Sendable (DatabaseConnection) throws -> String`— que además
  elimina la dependencia dura con `CredentialStore` y hace el actor probable sin Security.

## Riesgos y compatibilidad

- Releer del llavero en la cancelación añade una llamada a Security en un camino sensible al tiempo. Es una
  lectura de un ítem ya desbloqueado (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), del orden de
  milisegundos, y ocurre una sola vez por cancelación. Aceptable.
- Si el usuario cambia la contraseña en el llavero mientras hay una sesión abierta, el `KILL` fallará con
  error de autenticación. Antes, con la copia en memoria, habría funcionado. Es un caso raro y el mensaje
  nuevo lo explica; no vale la pena conservar la copia por eso.

## Resuelto

**2026-11-09** · commit `909ae2e`.

| # | Criterio | Resultado |
|---|---|---|
| 1 | `Session` sin campo de credencial | ✓ queda `connection`, `configuration`, `serverID`, `database`, `flags` |
| 2 | Cancelar sigue cerrando la sesión del servidor | ✓ `testMySQLCancellationClosesActualServerSession` pasa **sin modificar su cuerpo** |
| 3 | Si falla el llavero, se cierra lo local y la UI avisa; sin `catch` vacío | ✓ `testCancellationReportsWhenCredentialIsUnavailable` |
| 4 | Servidor sin contraseña sigue funcionando, incluida la cancelación | ✓ las 6 pruebas de MySQL real corren contra una instancia con `MYSQL_ALLOW_EMPTY_PASSWORD` |

Suite completa con MySQL real: **44 pruebas, 1 saltada** (la de Codex con suscripción), 0 fallos.

### Decisiones

- **El lector de credenciales es inyectable.** `MySQLClient(readPassword:)` tiene como valor por defecto
  `CredentialStore.read`. Además de permitir la prueba del punto 3 sin tocar el llavero real, saca la
  dependencia dura con Security y deja el actor probable sin él. Fue el cambio de diseño que el spec
  anticipaba, y valió la pena.
- **`CancelOutcome` en vez de `catch {}`.** El spec de S4 pedía reportar; acá se agregó el tipo que
  [C6](C6-logging-y-errores.md) también necesitaba. C6 le suma el logging.
- **El aviso va en `SQLExecution.cancelNote`, no en `.error`.** Si se escribiera en `.error`, el `catch` del
  propio `execute` lo pisaría al terminar con `CancellationError`. Un campo aparte evita depender del orden
  en que se resuelven las dos tareas.
- **`DatabaseController` no guarda la credencial** en estado observable: la lee del llavero y la pasa como
  parámetro. Quedó un comentario que lo dice, para que no se agregue después «por comodidad».

### Limitación que queda, declarada

La contraseña viaja como `String` porque así la pide el transporte de MySQLNIO, y Swift no garantiza el
borrado de ese buffer. Lo que cambió es su **vida**: ya nadie la retiene más allá del handshake. Está
anotado en `CredentialStore`. Cerrar esa limitación requeriría reescribir el transporte con buffers propios
y se dejó explícitamente fuera de alcance.

### Costo aceptado

Cancelar ahora hace una lectura del llavero en un camino sensible al tiempo. Es un ítem ya desbloqueado
(`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), del orden de milisegundos, una vez por cancelación. Y si
el usuario cambió la contraseña en el llavero mientras había una sesión abierta, el `KILL` falla con error
de autenticación donde antes habría funcionado; el mensaje nuevo lo explica.
