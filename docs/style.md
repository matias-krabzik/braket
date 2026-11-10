# Estilo de código

Las reglas que el proyecto acordó en [C4](specs/C4-legibilidad.md). Las que se pueden
comprobar, las comprueba `scripts/verify.sh`; las que no, se revisan al leer un cambio.

## Comprobadas automáticamente

| Regla | Quién la comprueba |
|---|---|
| Una sentencia por línea. El `;` como separador no se usa | `scripts/check_style.py`, que salta cadenas y comentarios: una prueba con SQL o Python dentro de un literal no es una violación |
| Máximo 140 columnas | el trinquete de `scripts/verify.sh` y `line_length` de SwiftLint |
| Ningún `catch {}` en `Krabzik/` | el trinquete de `scripts/verify.sh`. En una prueba, `do { … XCTFail() } catch {}` es la forma de decir «esto tiene que lanzar», y ahí es correcto |
| Formato: imports ordenados, `{}` vacíos, líneas en blanco consecutivas, ancho | `swiftformat --lint`, con la lista de reglas de `.swiftformat` |
| Sin force unwrap ni `try!` sin justificación | `swiftlint --strict` con `force_unwrapping` y `force_try`. Una excepción se escribe con `swiftlint:disable` **y** un comentario que diga qué la hace segura, como el de `SyntaxStyler` |
| Sin `@preconcurrency` ni `nonisolated(unsafe)` | `scripts/verify.sh` |
| Avisos del compilador | son errores (`SWIFT_TREAT_WARNINGS_AS_ERRORS`). La válvula de escape es la invocación, nunca editar el ajuste |

Los trinquetes son topes que **solo pueden bajar**. Si un cambio los sube, se arregla el
código, no el tope: para eso están.

## Revisadas al leer

- **Nombres completos.** Una letra solo en el cuerpo de un closure de una línea
  (`{ $0.id }` está bien). Lo que se repite en el archivo lleva nombre: `byte`, no `c`.
- **Todo tipo de `Models/` y `Services/` lleva `///`** con tres cosas: qué representa,
  quién lo posee, y su invariante de aislamiento —main actor, actor propio, o confinado a
  un hilo o event loop—. Es lo que no se puede deducir leyendo las propiedades.
- **Los comentarios explican el por qué.** Un comentario que repite el código se borra. Si
  dice «no es obvio que», probablemente valga la pena.
- **Los números de protocolos y formatos van en constantes con nombre**, agrupadas en un
  enum con el motivo al lado: `Byte` en `SQLScript`, `Wire` y `Retained` en
  `MySQLTextCommand`, `WorkspaceLimits` en `Workspace`.
- **Los comentarios nuevos van en español.** Quedan en inglés los de los archivos que
  todavía no se tocaron; se traducen cuando se edita el archivo, no en una pasada aparte.

## Estilo compacto: qué se conserva

Un bloque de **una sola sentencia** puede ir en una línea, y es deliberado:

```swift
guard let workspace else { return }
if password.isEmpty { try remove(for: connection); return }   // ← esto no: son dos
```

Por eso `.swiftformat` no incluye `wrapIfStatementBodies` ni `wrapLoopBodies`: expandirían
los 274 bloques de una sentencia que el proyecto quiere compactos. Lo que sí se expande es
el que tenía dos sentencias separadas por `;`.

## Pruebas

- Una prueba dice qué comportamiento fija, no qué función llama. `testUntrustedWorkspaceCannotRunProcesses`
  dice más que `testTrust`.
- Un umbral de tiempo lleva el número medido en un comentario, para que el que lo suba
  sepa contra qué lo compara (ver `testEditorKeystrokeLatencyOnLargeDocument`).
- Las pruebas que necesitan un servidor o una sesión se saltan con `XCTSkip` y un
  marcador en `.build/`; las demás corren siempre y sin red.
