# S1 · Un `.krabzik` ajeno no debe poder ejecutar código

| | |
|---|---|
| **Severidad** | Alta |
| **Área** | Modelo de confianza, procesos, agente |
| **Archivos** | `Krabzik/Models/Workspace.swift`, `Krabzik/Services/WorkspaceController.swift`, `Krabzik/Services/ProcessRunner.swift`, `Krabzik/Models/AgentModels.swift`, `Krabzik/KrabzikApp.swift`, `Krabzik/Views/WorkspaceView.swift`, `Krabzik/Info.plist` |
| **Depende de** | — (conviene tener C1 para poder revertir) |
| **Continúa en** | C7 (límites y validación del formato) |
| **Esfuerzo** | 1–2 días |

## Problema

Un archivo `.krabzik` es JSON editable que contiene, por cada subproyecto, una ruta y un **comando de
shell arbitrario**:

```json
{ "name": "api", "path": "/Users/otro/cualquier/parte", "kind": "PHP", "command": "curl … | sh" }
```

Hoy:

- `Workspace.read(from:)` valida versión, IDs duplicados y conexiones, pero **no valida `projects[].path`
  ni `scripts[]`**: una ruta absoluta a cualquier lugar del disco se acepta tal cual
  (`CodeProject.directory(relativeTo:)` la devuelve sin más).
- La app está registrada como `LSHandlerRank = Owner` del tipo `com.krabzik.project` en `Info.plist`,
  y `AppDelegate` abre el archivo directo: el manejador de Apple Events guarda la URL en
  `pendingProjectURL` y `openPendingProject()` llama `controller.openWorkspace(url)` sin preguntar nada.
  El argumento `--workspace` hace lo mismo en `WorkspaceController.start(arguments:)`, y **Abrir
  proyecto…** también. Ninguno de los tres caminos confirma nada.
  (Hasta el 2026-11-09 16:30 esto estaba en `WorkspaceView` con `.onOpenURL`; se movió al delegado.
  El hallazgo no cambia: los tres caminos desembocan en `openWorkspace(_:)`, que es donde va la puerta.)
- `ProcessRunner.start(_:workspaceURL:)` interpola `project.command` sin filtro en
  `["/bin/zsh", "-l", "-c", "cd -- <ruta> && <comando>"]`, con el entorno completo del usuario y un
  `PATH` ampliado con Homebrew.
- Esas mismas rutas se usan como `writableRoots` del sandbox de Codex (`AgentScope.sandbox` y
  `AgentController.send`), así que un archivo de terceros puede conceder escritura sobre `$HOME`.

El resultado es que **abrir un proyecto recibido por correo o clonado de un repositorio ajeno y pulsar
▶ ejecuta código arbitrario**, y el usuario nunca vio el comando. Es la cadena de riesgo más corta del
proyecto.

> Lo que ya está bien y hay que conservar: la ruta del `cd` se escapa con `Shell.quote`, el hijo arranca
> en su propio grupo de procesos, y las contraseñas de MySQL no viajan en el `.krabzik`.

## Objetivo

Abrir un `.krabzik` que el usuario no creó ni marcó como confiable **no puede** ejecutar un proceso, ni
dar acceso de escritura al agente, ni montar carpetas fuera del directorio del propio archivo, hasta que
el usuario lo apruebe viendo exactamente qué aprueba.

## Alcance

**Incluye**
- Clasificación de rutas internas/externas al leer el modelo.
- Estado de confianza por archivo de proyecto, persistido.
- Hoja de confirmación al abrir un proyecto no confiable, que muestra carpetas externas y comandos.
- Modo solo lectura para proyectos no confiables.
- Confirmación de un comando la primera vez que se ejecuta, y de nuevo si cambia.

**No incluye**
- Sandbox de la app (S6) ni límites de tamaño del formato (C7).
- Firmar o verificar los binarios que el comando invoca.
- Analizar el contenido del comando para decidir si es peligroso: no se intenta clasificar, se muestra.

## Diseño

### 1. Clasificación de rutas en el modelo

En `Workspace.swift`, agregar:

```swift
enum PathScope: Equatable {
    case internalToProject   // relativa, sin "..", resuelta dentro del directorio del .krabzik
    case external            // absoluta, o relativa que escapa del directorio
}

extension CodeProject {
    func scope(relativeTo workspaceURL: URL) -> PathScope
}
```

Reglas: la ruta se resuelve con `standardizedFileURL` **y** `resolvingSymlinksInPath()`; es interna si el
resultado es el propio directorio del `.krabzik` o tiene su ruta más `/` como prefijo. Un symlink que
apunta afuera cuenta como externa. La misma función se aplica a `scripts[]`.

`Workspace.read` **no rechaza** las externas: los proyectos legítimos del usuario suelen tener carpetas
afuera. Solo deja de confiar en ellas (punto 3).

### 2. Estado de confianza

Nuevo tipo en `Krabzik/Services/`:

```swift
@MainActor final class TrustStore {
    enum Trust { case trusted, untrusted }
    func trust(for workspaceURL: URL) -> Trust
    func markTrusted(_ workspaceURL: URL)
    func forget(_ workspaceURL: URL)
    func isApproved(command: String, project: UUID, workspaceURL: URL) -> Bool
    func approve(command: String, project: UUID, workspaceURL: URL)
}
```

Persistencia en `UserDefaults` (clave `trustedWorkspaces`), inyectable igual que hoy hace
`WorkspaceController(defaults:)` para que las pruebas usen un suite propio. La aprobación de comandos se
guarda por `SHA-256(comando)` junto al UUID del subproyecto: **editar el comando revoca la aprobación**.

- `createWorkspace()` marca el proyecto nuevo como confiable (lo creó el usuario).
- `addFolders()` y `updateProject(_:)` marcan como aprobado el comando que el usuario acaba de escribir.
- Los proyectos ya presentes en `recentProjects` al migrar se consideran confiables una sola vez, en una
  migración con marca en `UserDefaults` (ver Riesgos).

### 3. Apertura de un proyecto no confiable

`WorkspaceController.openWorkspace(_:)`, antes de `install(_:at:)`: si
`trustStore.trust(for: url) == .untrusted`, mostrar una hoja (no un `NSAlert`: hay que listar texto
seleccionable) con

- nombre del proyecto y ruta del archivo;
- la lista de carpetas **externas**, con su ruta completa;
- la lista de comandos, en monoespaciada, uno por subproyecto;
- la cantidad de conexiones MySQL que trae (sin credenciales: no las tiene).

Tres salidas: **Cancelar**, **Abrir solo lectura**, **Confiar y abrir**.

En modo solo lectura (`workspaceTrust == .untrusted` en el controlador):

- `runnableProjects` devuelve `[]` → los botones ▶ y el menú **Proyecto** quedan deshabilitados.
- `agent.visible` no se puede activar y `sendToAgent()` sale temprano con un mensaje.
- `FileTree` monta solo las raíces internas; las externas se muestran en gris con el motivo en el tooltip.
- `scriptURL(_:)` no resuelve rutas absolutas (devuelve `nil` y la fila queda deshabilitada).
- Una barra persistente arriba del editor: «Proyecto no confiable · solo lectura» con un botón **Confiar**.

### 4. Puerta en la ejecución

`WorkspaceController.toggleRun(_:)` y `startAll()`:

```swift
guard workspaceTrust == .trusted else { errorMessage = "…"; return }
guard trustStore.isApproved(command: project.command, project: project.id, workspaceURL: url)
   || (await confirmCommand(project)) else { return }
runner.start(project, workspaceURL: url)
```

`confirmCommand(_:)` muestra el comando completo y la carpeta de trabajo, con **Ejecutar una vez** /
**Ejecutar siempre este comando** / **Cancelar**. `ProcessRunner` no cambia: la puerta vive en el
controlador, que es quien ya conoce el workspace.

### 5. Agente

`AgentScope.make(workspace:url:projectID:)` recibe el estado de confianza y descarta las raíces externas
no confiables; si no queda ninguna, lanza `AgentFailure("Confiá en el proyecto para trabajar con Codex.")`.
Así `writableRoots` nunca incluye una ruta que el usuario no aprobó viéndola.

## Criterios de aceptación

1. Un `.krabzik` nunca abierto antes, con `"command": "touch /tmp/krabzik-rce"`, abierto por doble clic,
   por `--workspace` y por **Abrir proyecto…**: en los tres casos aparece la hoja de confirmación y el
   archivo `/tmp/krabzik-rce` **no** existe mientras no se confíe y se confirme el comando.
2. En modo solo lectura, el botón ▶ de la barra, el del panel de procesos y ⌘R están deshabilitados, y
   `agent.visible` no se puede poner en `true`.
3. Confiar en un proyecto y aprobar un comando sobrevive a cerrar y reabrir la app.
4. Editar el comando de un subproyecto ya aprobado hace que la próxima ejecución vuelva a pedir
   confirmación.
5. Un `.krabzik` con `"path": "/"` abierto en modo confiable no monta `/` en el explorador sin que la
   hoja lo haya listado como carpeta externa.
6. `AgentScope.make` sobre un proyecto no confiable con una raíz externa lanza, y nunca produce un
   `sandbox` cuyo `writableRoots` contenga esa raíz.
7. Un proyecto creado con **Nuevo proyecto…** y carpetas agregadas con **Agregar subproyecto…** no pide
   ninguna confirmación extra: el flujo normal no se vuelve más molesto.

## Pruebas

En `KrabzikTests/WorkspaceNavigationTests.swift` (ya tiene el patrón de `UserDefaults` por suite):

- `testUntrustedWorkspaceCannotRunProcesses`
- `testTrustSurvivesRelaunchAndCommandEditRevokesApproval`
- `testExternalRootsAreNotMountedUntilTrusted`
- `testAgentScopeRejectsUntrustedExternalRoots`
- `testFreshlyCreatedWorkspaceNeedsNoConfirmation`
- `testLegacyRecentProjectsAreMigratedAsTrusted`

Las hojas modales no se pueden ejercitar desde XCTest: la decisión se inyecta como un closure
`confirm: (TrustPrompt) async -> TrustDecision` en `WorkspaceController`, con el default que muestra la
hoja real. Las pruebas pasan un closure determinista.

## Riesgos y compatibilidad

- **Proyectos existentes del usuario.** Si todo lo ya abierto pasa a «no confiable», el flujo se rompe de
  golpe. Migración: la primera vez que arranca la versión nueva, todas las rutas en `recentProjects` se
  marcan confiables y se deja la marca `trustMigrationDone`. Documentarlo en el README.
- **Falsa sensación de seguridad.** El modo solo lectura sigue abriendo y mostrando archivos de las
  carpetas internas; eso es intencional y hay que decirlo en la hoja: lo que se bloquea es *ejecutar*.
- **Fatiga de confirmaciones.** Por eso la aprobación es por comando y persistente, y el proyecto propio
  no pide nada. Si durante la implementación aparece un caso que pide confirmar seguido, es un bug del
  spec, no del usuario.
