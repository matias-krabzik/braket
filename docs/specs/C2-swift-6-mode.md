# C2 · Migrar a Swift 6 language mode

| | |
|---|---|
| **Severidad** | Alta |
| **Área** | Configuración del compilador, concurrencia |
| **Archivos** | `scripts/generate_project.py`, `Krabzik/Editor/CodeEditor.swift`, `Krabzik/Services/ProcessRunner.swift`, `Krabzik/Services/CodexTransport.swift` |
| **Depende de** | C1 |
| **Esfuerzo** | 2–4 horas |

## Problema

Todas las configuraciones se generan con `'SWIFT_VERSION': '5.0'`
(`scripts/generate_project.py`, diccionario `settings`). El código, en cambio, está escrito con el modelo
de concurrencia moderno: `@MainActor @Observable` en los controladores, un `actor MySQLClient`,
`@unchecked Sendable` explícito en `OutputBatch` y `MySQLTextCommand`, `nonisolated` donde hace falta,
`MainActor.assumeIsolated` en un callback de `NotificationCenter`, y trabajo real en colas de fondo
(`DispatchQueue.global`) que entregan al main actor.

Es decir: **el diseño asume las reglas de Swift 6 pero el compilador no las comprueba**. Toda esa intención
está sin verificar, y las anotaciones `@unchecked Sendable` son promesas que nadie audita.

Que esto importa no es teórico: los logs de compilación del 2026-11-09 a las 08:27 muestran tres avisos de
concurrencia reales en `FileTree.swift` (`capture of 'node' with non-Sendable type 'FileNode?' in a
'@Sendable' closure`, `main actor-isolated static property 'excluded' can not be referenced from a
nonisolated context`), que se corrigieron más tarde ese mismo día. Sin modo estricto ni CI, nada evita que
vuelvan.

## Objetivo

El proyecto compila y pasa las pruebas en Swift 6 language mode, sin errores ni avisos propios.

## Alcance

**Incluye** los cambios medidos necesarios para que `SWIFT_VERSION = 6.0` compile limpio, y el cambio del
ajuste.

**No incluye** rediseñar la concurrencia de nada que ya compile. No se persigue elegancia: se persigue que
las reglas se verifiquen.

## Diagnóstico medido

Compilación de prueba del 2026-11-09 con `xcodebuild … SWIFT_VERSION=6.0 build` sobre el árbol de las
16:30. Resultado: **2 errores y 2 avisos propios**, todos localizados.

```
CodeEditor.swift:139  error: cannot access property 'scrollObserver' with a non-Sendable type
                             '(any NSObjectProtocol)?' from nonisolated deinit
CodeEditor.swift:140  error: cannot access property 'highlighter' with a non-Sendable type
                             'DispatchWorkItem?' from nonisolated deinit
ProcessRunner.swift:170   warning: reference to captured var 'pid' in concurrently-executing code
CodexTransport.swift:89   warning: reference to captured var 'pid' in concurrently-executing code
CodeEditor.swift:1        warning: add '@preconcurrency' to treat 'Sendable'-related errors from
                                   module 'ObjectiveC' as warnings
```

La migración es pequeña y acotada a tres archivos. No hay nada estructural que impida el cambio.

## Diseño

### 1. `EditorSurface.deinit` (los dos errores)

```swift
deinit {
    if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    highlighter?.cancel()
}
```

`EditorSurface` es `@MainActor`, pero `deinit` es `nonisolated` y no puede tocar propiedades de tipos no
`Sendable`. Solución preferida: **limpieza explícita y determinista**, que además es mejor diseño que
depender del `deinit` de una vista.

- Agregar `@MainActor func teardown()` con el cuerpo actual del `deinit`, idempotente.
- Llamarla desde donde se destruye el documento: `WorkspaceController.closeDocument(_:)` y
  `closeWorkspace()` ya recorren `documents`; antes de quitarlos,
  `(document.editorStorage as? EditorSurface)?.teardown()`. `EditorDocument.editorStorage` es
  precisamente el dueño de la surface, así que el punto existe.
- Dejar el `deinit` vacío (o eliminarlo). Si se quiere una red de seguridad, usar un token observador
  envuelto en una clase `final class ObserverToken: Sendable` que haga el `removeObserver` en su propio
  `deinit`; es la variante que no necesita main actor.

Alternativa aceptable si el punto de llamada resulta incómodo: marcar las dos propiedades como
`nonisolated(unsafe)` con un comentario que explique que solo se tocan desde el main actor. Es más barato y
menos correcto; preferir `teardown()`.

### 2. `pid` capturado (los dos avisos)

En `ProcessRunner.start(_:workspaceURL:)` y `CodexTransport.start(executable:…)`, `pid` es `var` porque
`posix_spawn` lo escribe por puntero. Después se usa dentro de un closure que corre en otra cola:

```swift
var pid: pid_t = 0
let result = posix_spawn(&pid, …)
…
DispatchQueue.global(qos: .utility).async { … waitpid(pid, &status, 0) … }
```

Arreglo trivial: copiar a una constante después del `posix_spawn` y usar esa en los closures.

```swift
let spawnedPID = pid
```

En `ProcessRunner` hay además la captura en el cierre del lector y en el bloque de `waitpid`: usar
`spawnedPID` en los dos.

### 3. El aviso de `ObjectiveC`

Es consecuencia del error 1; debería desaparecer al arreglarlo. Si persiste, `@preconcurrency import` **no**
es la solución: indica que queda un uso real sin resolver. Investigar antes de silenciar.

### 4. Cambiar el ajuste

En `generate_project.py`: `'SWIFT_VERSION': '6.0'`. Regenerar con `python3 scripts/generate_project.py` y
commitear el `.pbxproj` resultante junto al cambio (C8).

### 5. Revisar las promesas `@unchecked Sendable`

Con el modo estricto activo, repasar los dos usos existentes y dejar un comentario que explique **por qué**
son seguros, ya que el compilador deja de opinar:

- `OutputBatch` (`ProcessRunner.swift`): todo el estado mutable está bajo un `NSLock`.
- `MySQLTextCommand` (`MySQLTextCommand.swift`): el comentario ya dice que sus miembros mutables están
  confinados al event loop de la conexión. Conservarlo y verificar que siga siendo cierto.

## Criterios de aceptación

1. `xcodebuild -project Krabzik.xcodeproj -scheme Krabzik -destination 'platform=macOS' build` con
   `SWIFT_VERSION = 6.0` en el proyecto termina en `BUILD SUCCEEDED`.
2. Cero errores y cero avisos cuyo archivo esté bajo `Krabzik/` o `KrabzikTests/`.
3. Las 29 pruebas siguen pasando (23 sin servidor MySQL, 29 con `.build/mysql-test-port`).
4. `grep -rn "SWIFT_VERSION" scripts/generate_project.py` devuelve `6.0`, y el `.pbxproj` versionado
   coincide con lo que genera el script.
5. No se agregó ningún `@preconcurrency import` ni `nonisolated(unsafe)` sin un comentario que justifique
   por qué es seguro.
6. El editor sigue funcionando: abrir un archivo, editar, guardar, cerrar la pestaña y cerrar el proyecto no
   deja observadores de `NotificationCenter` colgados (comprobable con la prueba del punto siguiente).

## Pruebas

En `KrabzikTests/CoreTests.swift`, junto a `testEditorHasVisibleTextGeometry`:

- `testEditorSurfaceTeardownIsIdempotentAndRemovesObserver`: crear la surface, llamar `teardown()` dos
  veces, comprobar que no hay crash y que una notificación de bounds posterior no dispara el resaltado
  (por ejemplo, exponiendo un contador interno de resaltados en modo test).

El resto de la verificación es la propia compilación en modo 6, que es exactamente lo que C3 debe dejar
corriendo en CI para que no se pierda.

## Riesgos y compatibilidad

- El cambio de `deinit` a `teardown()` explícito puede dejar una fuga si aparece un camino nuevo que
  destruya documentos sin pasar por `closeDocument`/`closeWorkspace`. Mitigación: el `ObserverToken` del
  punto 1 como red de seguridad, o una prueba que recorra los caminos de cierre.
- Swift 6 puede volverse más estricto en versiones futuras del compilador y aparecer avisos nuevos. Con C3
  activo eso se detecta en CI, que es el objetivo.

## Resuelto

**2026-11-09** · commit `1c648ab`.

`SWIFT_VERSION` pasó de `5.0` a `6.0` en las seis configuraciones de
`scripts/generate_project.py`, y el `.pbxproj` se regeneró.

### Lo que hizo falta

Exactamente lo que el diagnóstico medido anticipaba: 85 líneas agregadas y 12 quitadas en 8 archivos.

- **Los dos errores de `EditorSurface.deinit`.** Se tomó la opción de `teardown()` explícito, no
  `nonisolated(unsafe)`, y se le sumó la red de seguridad: el observador de scroll se guarda en
  `ObserverToken`, una clase que lo quita en su propio `deinit`. El resultado es **mejor que el código
  original**, porque antes la limpieza dependía de que el `deinit` de la vista corriera y ahora la garantiza
  ARC. `EditorSurface` ya no tiene `deinit`.
- **`EditorDocument.releaseEditor()`** llama `teardown()` y suelta `editorStorage`. Lo invocan los tres
  sitios donde se descartan documentos: `closeDocument`, `closeWorkspace` e `install`, los dos últimos a
  través del helper `releaseEditors()`.
- **Los dos avisos de `pid`**: copiado a `spawnedPID` después de `posix_spawn`, en `ProcessRunner` y en
  `CodexTransport`.
- **Las tres promesas `@unchecked Sendable`** (`ObserverToken`, `OutputBatch`, `MySQLTextCommand`) quedaron
  justificadas por escrito, que es el mínimo ahora que el compilador no opina sobre ellas.

### Criterios verificados

| # | Criterio | Resultado |
|---|---|---|
| 1 | Compila en Swift 6 | `TEST SUCCEEDED` |
| 2 | Cero errores y avisos propios | 0 bajo `Krabzik/` y `KrabzikTests/` |
| 3 | Las pruebas pasan | **38 ejecutadas, 0 fallos.** Sin servidor: 7 saltadas. Con instancia MySQL desechable en el puerto 23307: **1 saltada** (solo la de Codex con suscripción), con las 6 de MySQL real en verde |
| 4 | `generate_project.py` dice `6.0` y el `.pbxproj` coincide | sí; regenerar no produce diferencias |
| 5 | Sin `@preconcurrency` ni `nonisolated(unsafe)` sin justificar | ninguno de los dos aparece en el repositorio |
| 6 | El editor no deja observadores colgados | cubierto por las dos pruebas nuevas |

Las 6 pruebas de MySQL real se corrieron a propósito: son las que ejercitan el actor `MySQLClient` y el
`@unchecked Sendable` de `MySQLTextCommand`, que es la parte del código con más riesgo bajo las reglas
nuevas. El contenedor desechable y el marcador `.build/mysql-test-port` se limpiaron después.

### Pruebas nuevas

- `testEditorSurfaceTeardownIsIdempotentAndStopsObserving`
- `testClosingDocumentReleasesItsEditorSurface`

Ambas se apoyan en un accesor interno nuevo, `EditorSurface.isObservingScroll`, para que la verificación sea
determinista en vez de depender del momento en que ARC libera la vista.

### Nota para C3

El aviso de `@preconcurrency import` del módulo `ObjectiveC` que aparecía en el diagnóstico desapareció al
arreglar el error 1, tal como decía el punto 3 del diseño. No hizo falta silenciar nada.

Con Swift 6 activo, **ya se puede activar `SWIFT_TREAT_WARNINGS_AS_ERRORS`** sin mezclar dos problemas:
es el punto 1 de [C3](C3-ci-lint-warnings.md).
