# C4 · Legibilidad: estilo, nombres y constantes con nombre

| | |
|---|---|
| **Severidad** | Media |
| **Área** | Todo el código |
| **Archivos** | Transversal; foco en `Krabzik/Services/SQLScript.swift`, `Krabzik/Models/AgentModels.swift`, `Krabzik/Services/AgentController.swift`, `Krabzik/Views/DatabaseViews.swift`, `Krabzik/Services/WorkspaceController.swift` |
| **Depende de** | C1 (sin diff, un refactor transversal es imposible de revisar), C3 (el linter fija el límite) |
| **Esfuerzo** | 1–2 días, incremental |

## Problema

Medido sobre el árbol del 2026-11-09 a las 16:35 (3.816 líneas en `Krabzik/`):

| Medida | Valor |
|---|---|
| Líneas de comentario | 34 (0,9 % de 3.816) |
| Tipos con doc comment `///` | 6 de 69 top-level (4 de los 38 de `Models/` + `Services/`) |
| Líneas con varias sentencias separadas por `;` | 120 |
| Líneas de más de 140 columnas | 47 |
| `try!` / force unwrap | 2 (`SyntaxStyler.literals`, `MySQLClient.eventLoop()`) |

Lo que hay está bien escrito, y conviene decirlo antes de pedir cambios: los comentarios explican **por
qué**, no qué («The child starts its own group atomically; stop reaches npm/PHP descendants too», «A missing
or externally modified file must never be silently replaced»), y los seis tipos que llevan `///` declaran
justo lo que importa: `SQLScript` («es un cursor, para poder aplicar `NO_BACKSLASH_ESCAPES` después de cada
sentencia»), `MySQLTextCommand` («sus miembros mutables están confinados al event loop de la conexión»),
`OutputBatch` («sin timer permanente, una actualización de UI cada 80 ms»), `CodexTransport`, `LineIndex` y
`AgentComposer`. Ese es el modelo a seguir: **este spec pide extender esa práctica a los tipos de
`Models/` y `Services/` que no la tienen** (34 de 38), no inventar un estándar nuevo. Las vistas privadas
de SwiftUI no necesitan doc comment y quedan fuera. El problema no es la calidad de lo escrito: es la
densidad del código alrededor y la cantidad de tipos sin documentar.

Casos concretos que cuestan leer:

- **`SQLScript.next(noBackslashEscapes:)`** — el parser más delicado del proyecto, del que depende que no se
  parta una sentencia dentro de una cadena — compara bytes contra literales numéricos crudos: `c == 10`,
  `c == 42 && next == 47`, `c == 92`, `c == 96`, `c == 39`, `c == 34`, `c == 35`, `c == 45`,
  `bytes[position + 2] == 33`, `c > 32`. Hay que traducir mentalmente cada número para seguir la lógica.
- **`JSONValue`** (`AgentModels.swift`) usa `c`, `v`, `o`, `a` para contenedor, valor, objeto y array.
- **`AgentController.receive(_:)`** usa `p` para los parámetros y concentra un `switch` largo con la lógica
  de todo el protocolo; la línea de `turn/completed` encadena tres condicionales ternarios.
- **`DatabaseViews.swift`**, el `.disabled(...)` del botón de ejecutar: una sola expresión con dos
  `controller.database.states[$0.id]` y un `map` anidado.
- **`WorkspaceController.saveConnection(_:password:)`**: la condición que decide si borrar la credencial
  vieja compara cuatro campos en una línea de 190 columnas.

## Objetivo

Un lector que no escribió el código puede seguir cualquier función sin traducir constantes ni desarmar
expresiones encadenadas, y cada tipo declara su responsabilidad y sus invariantes.

## Alcance

**Incluye** reglas escritas, el refactor mecánico de estilo, constantes con nombre en el parser, nombres
completos en los puntos señalados, y doc comments en los tipos de `Models/` y `Services/`.

**No incluye** cambiar comportamiento. Ni uno. Toda la verificación de este spec se apoya en que las 29
pruebas existentes sigan pasando sin modificarse.

## Diseño

### 1. Reglas escritas en `docs/style.md`

- Una sentencia por línea. El `;` como separador no se usa.
- Máximo 140 columnas.
- Nombres completos; una letra solo en el cuerpo de un closure de una línea (`{ $0.id }` está bien).
- Todo tipo de `Models/` y `Services/` lleva `///` con: qué representa, quién lo posee, y sus invariantes
  (en especial el aislamiento: main actor, actor propio, o confinado a un event loop).
- Los comentarios explican el **por qué**. No se agregan comentarios que repitan el código.
- Los números mágicos de protocolos y formatos van en constantes con nombre.

### 2. Constantes con nombre en `SQLScript`

```swift
private enum Byte {
    static let tab: UInt8 = 9, newline: UInt8 = 10, carriageReturn: UInt8 = 13, space: UInt8 = 32
    static let exclamation: UInt8 = 33      // /*! … */ ejecutable
    static let doubleQuote: UInt8 = 34, hash: UInt8 = 35, singleQuote: UInt8 = 39
    static let asterisk: UInt8 = 42, hyphen: UInt8 = 45, slash: UInt8 = 47
    static let backslash: UInt8 = 92, backtick: UInt8 = 96
}
```

y reescribir las comparaciones. El cuerpo del bucle no cambia de forma; solo deja de requerir traducción.
Mismo tratamiento para los bytes del protocolo en `MySQLTextCommand` (`35` para el marcador de SQLSTATE,
`63` para el charset binario, la lista `[249, 250, 251, 252, 253, 254, 255, 16]` de tipos binarios, que
merece un nombre: `binaryFieldTypes`).

### 3. Nombres en `JSONValue` y `AgentController`

`c` → `container`, `v` → `value`, `o` → `object`, `a` → `array`, `p` → `params`. Son renombrados locales,
sin riesgo.

### 4. Desarmar las expresiones señaladas

- `AgentController.receive(_:)`: extraer el manejo de `turn/completed` a
  `private func finishTurn(from turn: JSONValue)`, y el de `item/started`/`item/completed` a
  `private func handleItem(_ item: JSONValue, completed: Bool)`. El `switch` principal queda como índice
  legible del protocolo.
- `DatabaseViews.swift`: propiedad calculada `private var canExecute: Bool` en la vista.
- `WorkspaceController.saveConnection`: extraer
  `private func endpointChanged(from previous: DatabaseConnection, to connection: DatabaseConnection) -> Bool`.
  Ese predicado tiene valor propio: es el que garantiza que la credencial siga ligada al endpoint (ver
  `CredentialStore.query`), así que merece nombre y, de paso, una prueba directa.

### 5. Los dos casos de `try!` / force unwrap

- `SyntaxStyler.literals` usa `try!` mientras las otras expresiones del mismo enum usan `compactMap` con
  `try?`. Unificar: o todas toleran el fallo, o todas fallan temprano. Recomendación: patrones estáticos
  validados en una prueba, y `try!` en todos con un comentario que diga que la prueba los cubre. Un patrón
  literal mal escrito debe romper la compilación de las pruebas, no la app en runtime.
- `MySQLClient.eventLoop()` hace `group!.next()` justo después de asignarlo. Reescribir sin force unwrap:

  ```swift
  private func eventLoop() -> any EventLoop {
      if let group { return group.next() }
      let created = MultiThreadedEventLoopGroup(numberOfThreads: 1)
      group = created
      return created.next()
  }
  ```

### 6. Doc comments

Una pasada por `Models/` y `Services/` agregando `///` a cada tipo. Prioridad por riesgo de malentendido:
`MySQLClient` (actor, sesión por conexión, qué garantiza `busy`), `MySQLTextCommand` (confinamiento al event
loop), `ProcessRunner` y `OutputBatch` (el `NSLock`), `CodexTransport` (un hijo, orden de los mensajes),
`AgentScope` (qué significa «contiene» y por qué resuelve symlinks), `CredentialStore` (por qué la cuenta
incluye host, puerto, usuario y TLS), `SQLScript` (es un cursor, y por qué).

### 7. Orden de ejecución

Para que el diff sea revisable, hacerlo en commits separados y por archivo:
`swiftformat` mecánico → constantes del parser → renombrados → extracción de funciones → doc comments.
Nunca mezclar formato con extracción en el mismo commit.

## Criterios de aceptación

1. `grep -rn '; ' --include='*.swift' Krabzik KrabzikTests | grep -v 'for ' | grep -v '//'` no devuelve
   nada.
2. Ninguna línea de `Krabzik/` o `KrabzikTests/` supera 140 columnas.
3. `SQLScript` y `MySQLTextCommand` no contienen literales numéricos de bytes sin nombre, salvo los índices
   de bucles.
4. Todos los tipos de `Models/` y `Services/` tienen `///`, con el mismo criterio que los seis que ya lo
   tienen: responsabilidad, dueño e invariante de aislamiento.
5. Las 29 pruebas pasan **sin modificar el cuerpo de ninguna**: es la red que garantiza que el refactor no
   cambió comportamiento.
6. `swiftformat --lint .` y `swiftlint --strict` pasan (C3).
7. No queda ningún force unwrap ni `try!` sin un comentario que explique qué lo hace seguro.

## Pruebas

- Nueva en `DatabaseTests`: `testSyntaxStylerPatternsCompile` — construir `SyntaxStyler` y comprobar que los
  patrones estáticos existen (cubre el punto 5 y hace que un patrón roto falle en pruebas).
- Nueva en `CoreTests`: `testEndpointChangeDetection` — tabla de casos para el predicado extraído en el
  punto 4, incluida la insensibilidad a mayúsculas del host, que hoy está implícita en la línea larga.
- El resto es no-regresión con las pruebas existentes.

## Riesgos y compatibilidad

- Un refactor transversal en un proyecto que se está editando en paralelo genera conflictos. Hacerlo por
  archivo, en commits chicos, y preferentemente cuando no haya otro cambio grande en vuelo.
- `swiftformat` puede tocar más de lo que se quiere. Fijar la configuración primero, correrlo sobre un
  archivo, revisar el diff, y solo entonces sobre el resto.
- Agregar doc comments sin entender el invariante es peor que no agregarlos: si algo no se entiende, el
  comentario correcto es una pregunta anotada en el spec, no una descripción inventada.


## Estado: parcial

**2026-11-10**, commits `3910c44` (pasada mecánica) y `2f4439a` (constantes con nombre).

Hecho y verificado:

| Criterio | Estado |
|---|---|
| 1 · ninguna línea con más de una sentencia | hecho. El chequeo pasó a `scripts/check_style.py`, que salta cadenas y comentarios: el `grep '; '` anterior marcaba media docena de pruebas con SQL o Python dentro de un literal, y SQL sin punto y coma no es SQL |
| 2 · ninguna línea de más de 140 columnas | hecho: de 57 a 0 |
| 3 · sin literales de bytes sin nombre en `SQLScript` y `MySQLTextCommand` | hecho: enums `Byte`, `Wire` y `Retained` |
| 5 · las pruebas pasan sin cambiarles el cuerpo | las 97 pasan. Se tocaron tres líneas de pruebas, las de los force unwrap que pide el punto 5 del diseño |
| 6 · `swiftformat --lint` y `swiftlint --strict` | los dos pasan, con cero avisos |
| 7 · ningún force unwrap ni `try!` sin justificación | hecho. `MySQLClient.eventLoop()` ya no fuerza; las pruebas usan `XCTUnwrap`; las expresiones del resaltado se unificaron en `try!` con el comentario y el `swiftlint:disable` que dice qué prueba las cubre |

**Falta**, y queda para una próxima vuelta:

- **Criterio 4**: los `///` en los tipos de `Models/` y `Services/` que todavía no los tienen. Se agregaron
  los de `JSONValue`, `SQLStatement`, `SQLScript`, `Byte`, `Wire`, `Retained` y `MySQLClient.eventLoop`,
  además de los que C6, C7, S1 y S2 fueron dejando. Faltan los del resto.
- **Punto 4 del diseño**: desarmar `AgentController.receive(_:)` en `finishTurn(from:)` y
  `handleItem(_:completed:)`, el `canExecute` de `DatabaseViews` y el `endpointChanged(from:to:)` de
  `WorkspaceController` con su prueba.
- **`docs/style.md`** con las reglas escritas.
- **Bajar los topes de `scripts/verify.sh`** a 0 y cambiar el trinquete de `;` por `check_style.py`. Los
  valores actuales (57, 159, 60) ya están muy por encima de la realidad (0, 0, 0), así que hoy no frenan
  nada: el paso sigue siendo bloqueante pero con margen de sobra.
