# S2 · Verificar el ejecutable de Codex antes de lanzarlo

| | |
|---|---|
| **Severidad** | Media |
| **Área** | Agente, ejecución de binarios externos |
| **Archivos** | `Krabzik/Services/CodexTransport.swift` (`CodexExecutable`), `Krabzik/Services/AgentController.swift`, `Krabzik/Views/AgentPanel.swift` |
| **Depende de** | — |
| **Esfuerzo** | Medio día |

## Problema

`CodexExecutable.locate(override:)` arma su lista de candidatos así:

```swift
let search = paths.compactMap { $0 }
    + (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":").map { String($0) + "/codex" }
return search.first { FileManager.default.isExecutableFile(atPath: $0) }…
```

Es decir: **cualquier directorio del `PATH` heredado puede aportar el binario** que después se ejecuta
con `posix_spawn` y el entorno completo del usuario. No se comprueba firma, ni Team ID, ni permisos del
archivo, ni se le muestra al usuario qué se va a ejecutar. Y `AgentPanel` conecta solo con aparecer:

```swift
.background(Theme.background).task(id: controller.workspaceURL) { await agent.connect() }
```

así que abrir el panel ya lanza el proceso, y además vuelve a lanzarlo cada vez que cambia el proyecto
abierto.

> Lo que ya está bien: se elimina `OPENAI_API_KEY` del entorno del hijo, el stderr va a `/dev/null`, el
> hijo va a su propio grupo con `POSIX_SPAWN_CLOEXEC_DEFAULT`, y el `authUrl` del login se valida contra
> una lista de hosts antes de abrir el navegador.

## Objetivo

El binario que Krabzik ejecuta como agente es uno que el usuario aprobó explícitamente, identificado por
ruta y contenido; si el binario cambia o aparece otro antes en el `PATH`, se vuelve a preguntar.

## Alcance

**Incluye** orden de búsqueda, chequeos del archivo, verificación de firma informativa, aprobación
persistente por identidad del binario, y que la primera conexión no sea automática.

**No incluye** verificar los procesos que *Codex* lance a su vez (eso lo gobierna su propio sandbox, ya
configurado con `networkAccess: false` y raíces explícitas).

## Diseño

### 1. Orden de búsqueda y descarte

```swift
enum CodexExecutable {
    struct Candidate { let url: URL; let signature: SignatureInfo; let identity: BinaryIdentity }
    static func candidates(override: String?) -> [Candidate]
}
```

- Primero el `override` del usuario, después las rutas absolutas conocidas que ya están en el código, y
  **el `PATH` al final**.
- Descartar un candidato si:
  - no es un archivo regular (ni un symlink que resuelva a uno);
  - tiene permiso de escritura para grupo u otros (`st_mode & (S_IWGRP|S_IWOTH)`);
  - su directorio tiene permiso de escritura para grupo u otros;
  - no pertenece al usuario actual ni a `root`;
  - está **dentro de alguna raíz del workspace abierto** — un repositorio no puede traer su propio `codex`.
- El motivo del descarte se registra con `Log.agent` (C6) para poder explicarlo.

### 2. Identidad del binario

```swift
struct BinaryIdentity: Codable, Equatable { let path: String; let size: Int64; let mtime: Date; let inode: UInt64 }
```

Barato de calcular y suficiente para detectar que el binario cambió. No se hace hash del archivo: son
decenas de MB y habría que leerlo en cada arranque.

### 3. Firma, informativa pero visible

```swift
struct SignatureInfo { enum Kind { case developerID(team: String), appleSigned, adHoc, unsigned }; let kind: Kind }
```

Con `SecStaticCodeCreateWithPath` + `SecCodeCopySigningInformation` y `SecStaticCodeCheckValidity`.
**No se rechaza por ser ad-hoc**: el `codex` de Homebrew suele estarlo y rechazarlo rompería el caso más
común. La firma se usa para informar en el diálogo de aprobación: «firmado por Developer ID (equipo
XXXXXXXXXX)» frente a «sin firma de desarrollador». Una firma inválida (`SecStaticCodeCheckValidity`
falla sobre un binario que dice estar firmado) sí descarta el candidato: significa que fue alterado.

### 4. Aprobación

`UserDefaults` → `approvedCodexBinary: BinaryIdentity`. En `AgentController.connect()`:

- si no hay candidato → `missingExecutable = true` (como hoy);
- si el candidato no coincide con el aprobado → nuevo estado `pendingApproval(Candidate)`, sin lanzar nada;
- si coincide → arrancar.

`AgentPanel` muestra en el estado `pendingApproval` la ruta completa, el estado de firma y el tamaño, con
**Usar este ejecutable** / **Elegir otro…** (el `chooseExecutable()` que ya existe) / **Cancelar**.

### 5. Conexión no automática la primera vez

Cambiar `.task(id: controller.workspaceURL) { await agent.connect() }` por: conectar automáticamente
**solo** si ya hay un binario aprobado. El `id:` se conserva —reconectar al cambiar de proyecto es
correcto— pero la aprobación se comprueba antes de cada arranque. Si no, el panel abre mostrando el diálogo de aprobación. El botón **Conectar Codex** que ya
existe cubre el resto.

## Criterios de aceptación

1. Con un script ejecutable llamado `codex` en un directorio del `PATH` escribible por otros, `candidates`
   no lo devuelve y el log dice por qué.
2. Con un `codex` dentro de una carpeta del workspace abierto, tampoco se ofrece.
3. Abrir el panel sin binario aprobado **no** crea ningún proceso hijo (comprobable con
   `CodexTransport.running == false` y sin `pid`).
4. Aprobar un binario y reiniciar la app conecta sin volver a preguntar.
5. Tocar el binario (`touch`) o reemplazarlo hace que la próxima conexión vuelva a pedir aprobación.
6. Un binario con firma presente pero inválida se descarta.
7. Un `codex` ad-hoc de Homebrew se puede aprobar y usar, con el aviso de «sin firma de desarrollador».

## Pruebas

En `KrabzikTests/AgentTests.swift`:

- `testLocateRejectsWorldWritableAndInWorkspaceCandidates` — con directorios temporales y `chmod`.
- `testPanelDoesNotSpawnWithoutApprovedBinary`.
- `testApprovalPersistsAndIsInvalidatedByBinaryChange`.

`CodexExecutable` tiene que aceptar las dependencias por parámetro (lista de rutas, `PATH`, raíces del
workspace, un `FileManager`) para poder probarse sin tocar el sistema real.

## Riesgos y compatibilidad

- Usuarios que hoy tienen Codex funcionando verán **una** pregunta de aprobación la primera vez. Aceptable;
  el texto tiene que explicar por qué.
- Si Codex se actualiza solo (Homebrew, la app de ChatGPT), la pregunta reaparece. Es el comportamiento
  buscado, pero conviene que el diálogo diga «el ejecutable cambió desde la última vez» en lugar del texto
  de primera aprobación, para que no parezca un error.

## Resuelto

**2026-11-09** · commit `62675e6`.

`CodexExecutable` pasó a `Krabzik/Services/CodexExecutable.swift`: creció lo suficiente para no seguir
viviendo dentro de `CodexTransport.swift`.

| # | Criterio | Resultado |
|---|---|---|
| 1 | Un `codex` en un directorio del PATH escribible por otros no se ofrece, y el motivo queda | ✓ `testSearchRejectsWorldWritableAndInWorkspaceCandidates` |
| 2 | Un `codex` dentro del proyecto abierto tampoco | ✓ misma prueba |
| 3 | Abrir el panel sin binario aprobado no crea ningún proceso | ✓ `testPanelDoesNotSpawnWithoutApprovedBinary` verifica `transport.running == false` |
| 4 | Aprobar y reiniciar conecta sin volver a preguntar | ✓ la identidad se guarda en `UserDefaults` |
| 5 | Tocar o reemplazar el binario vuelve a pedir aprobación | ✓ la prueba comprueba que `identity` cambia al reescribirlo |
| 6 | Una firma presente que no valida se descarta | ✓ `CodexSignature.invalid` no es `isOfferable` |
| 7 | Un `codex` ad hoc de Homebrew se puede aprobar, con aviso | ✓ la firma se informa, no se exige |

### Decisiones

- **El PATH va último.** Era el núcleo del problema: cualquier directorio del `PATH` heredado podía aportar
  el binario. Ahora primero el override del usuario, después las rutas absolutas conocidas, y recién
  entonces el `PATH`.
- **La firma informa, no decide.** Rechazar lo ad hoc rompería el caso más común (Homebrew). Lo que sí
  descarta es `invalid`: dice estar firmado y no valida, o sea fue alterado. El diálogo muestra la etiqueta
  (`firmado por Developer ID (equipo …)`, `firma ad hoc, sin Developer ID`, `sin firma`).
- **La identidad es barata a propósito.** Ruta, tamaño, mtime e inode; no hash. Son decenas de MB y habría
  que leerlos en cada arranque, mientras que esto detecta igual que el binario cambió.
- **Los descartes se informan.** Cuando no queda ningún candidato, el mensaje de error enumera lo descartado
  con su motivo, en vez de un «no se encontró Codex» que no deja investigar nada.
- **`excludedRoots` viene de `WorkspaceController`**, que es quien conoce el proyecto; `AgentController` solo
  lo recibe.
- **`AgentController(defaults:)`**, como `WorkspaceController`, para no tocar `UserDefaults.standard` en las
  pruebas.

### Error cometido

La primera versión de la prueba fallaba con dos aserciones: `search()` incluía siempre `knownPaths` y
encontraba el `codex` real de Homebrew instalado en esta máquina, así que `candidates` nunca quedaba vacío.
La lista pasó a ser un parámetro inyectable (`known:`), que además es el diseño correcto: una función que
mira el sistema real no es probable si no se le puede decir qué mirar.

### Efecto lateral medido

Reescribir `AgentRequestView` y el bloque de aprobación bajó tres trinquetes de [C3](C3-ci-lint-warnings.md):
líneas de más de 140 columnas 64 → 57, bloques `catch` vacíos 10 → 8, avisos de SwiftLint 66 → 60. Los topes
se bajaron al nuevo nivel.

### Corrección posterior · identidad por contenido

**2026-11-10**, commit `4d86a40`.

La identidad del binario era ruta + tamaño + `mtime` + inode, elegida para no leer decenas de MB en cada
arranque. No alcanza, y lo encontró la propia prueba de S2 al fallar de forma intermitente: sobrescribir el
archivo en el lugar conserva el inode, el tamaño se puede igualar, y `mtime` lo fija cualquiera con `touch`
—además se guardaba con precisión de un segundo—. Con los tres valores iguales, un reemplazo heredaba la
aprobación del usuario, que es exactamente lo que el spec quería evitar.

`BinaryIdentity` es ahora ruta + tamaño + **SHA-256 del contenido**, leído por bloques de 1 MB. Medido: 9 ms
por 18,5 MB, una vez por conexión, contra un `posix_spawn` y un handshake JSON-RPC que ya estaban ahí. El
diálogo de aprobación muestra el prefijo del hash. Las aprobaciones guardadas con el formato anterior no
decodifican, así que se vuelve a preguntar una sola vez.

La prueba `testPanelDoesNotSpawnWithoutApprovedBinary` ahora fuerza el peor caso —mismo tamaño, mismo inode,
mismo segundo de `mtime`— y es determinista. Antes pasaba o fallaba según en qué momento del segundo
cayeran los dos `write`.
