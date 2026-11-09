# C5 · Dividir `WorkspaceController`

| | |
|---|---|
| **Severidad** | Media |
| **Área** | Arquitectura |
| **Archivos** | `Krabzik/Services/WorkspaceController.swift`, nuevos en `Krabzik/Services/`, `Krabzik/Views/*` (ajuste de referencias) |
| **Depende de** | C1, C3. Conviene después de C4 (estilo ya normalizado) |
| **Esfuerzo** | 1–2 días |

## Problema

`WorkspaceController` tiene 456 líneas (medido el 2026-11-09 a las 16:35) y concentra responsabilidades que
no tienen nada que ver entre sí:

| Responsabilidad | Miembros |
|---|---|
| Ciclo de vida del proyecto | `workspace`, `workspaceURL`, `isSwitchingWorkspace`, `openWorkspace`, `createWorkspace`, `chooseWorkspace`, `closeWorkspace`, `install`, `persist` |
| Historial de recientes | `recentProjects`, `removeRecentProject`, lectura/escritura en `UserDefaults` |
| Documentos abiertos | `documents`, `selectedDocumentID`, `openingFiles`, `openFile`, `createFile`, `save`, `saveCopy`, `closeDocument`, `confirmSave`, `reloadDocument` |
| Subproyectos y procesos | `addFolders`, `updateProject`, `removeProject`, `startAll`, `toggleRun`, `runnableProjects` |
| Scripts SQL | `scripts` vía `workspace`, `importScripts`, `rememberScript`, `scriptURL`, `executeSQL` |
| Conexiones MySQL | `saveConnection`, `removeConnection`, `selectedDatabase` |
| Agente | `sendToAgent`, `refreshAgentFiles`, `openAgentFile`, `agentFileLabel` |
| Estado de UI | `sidebarVisible`, `processesVisible`, `treeRevision`, `commandProject`, `errorMessage` |

Síntomas medibles, no estéticos:

- **`errorMessage` es un único `String?`.** Dos fallos casi simultáneos —por ejemplo, el guardado de un
  documento y la lectura de un directorio en `FileTree`, que llama `controller.show(error)` desde su propio
  camino— se pisan: el usuario ve uno y el otro desaparece.
- **La presentación de errores es inconsistente.** `show(_:)` usa `error.localizedDescription`, mientras la
  capa de base de datos usa `MySQLClient.message(_:)`, que sabe desenvolver `DatabaseFailure`, `MySQLError`
  y `CancellationError`. El mismo error se ve distinto según por dónde entre.
- **Todo cambio en cualquier área toca el mismo archivo**, lo que en un proyecto que se edita en paralelo
  significa conflictos constantes.
- **`WorkspaceNavigationTests` tiene que construir el controlador entero** para probar el historial de
  recientes, que son 6 líneas de lógica.

## Objetivo

Cada responsabilidad vive en un tipo propio, probable por separado, y `WorkspaceController` queda como
coordinador. Ningún error se pierde por quedar pisado.

## Alcance

**Incluye** extraer cuatro tipos, unificar la presentación de errores, y adaptar vistas y pruebas.

**No incluye** cambiar comportamiento visible, ni rediseñar `DatabaseController`, `ProcessRunner` o
`AgentController`, que ya tienen responsabilidades acotadas.

## Diseño

### 1. `RecentProjectsStore`

```swift
@MainActor @Observable final class RecentProjectsStore {
    private(set) var urls: [URL] = []
    init(defaults: UserDefaults = .standard)
    func remember(_ url: URL)
    func forget(_ url: URL)
}
```

Se lleva la normalización (`standardizedFileURL`), la deduplicación, el límite de 10 y la persistencia que
hoy están repartidas entre `init`, `install` y `removeRecentProject`. Es el candidato más claro y el más
fácil: ya hay pruebas que lo cubren indirectamente
(`testRecentProjectsPersistInOpeningOrderWithoutDuplicatesAndStayBounded`).

### 2. `DocumentStore`

```swift
@MainActor @Observable final class DocumentStore {
    private(set) var documents: [EditorDocument] = []
    var selectedID: URL?
    var openingFiles: Set<URL> = []
    var selected: EditorDocument? { … }
    func open(_ url: URL) async throws
    func save(_ document: EditorDocument) async throws
    func saveCopy(of document: EditorDocument, to url: URL) throws
    func close(_ document: EditorDocument)
    func reload(_ document: EditorDocument) throws
    func refresh(matching predicate: (URL) -> Bool) async
    func closeAll()
}
```

Importante: los diálogos (`NSAlert` de guardar/descartar, de recargar) **no** van acá. `DocumentStore`
expone el estado y lanza; quien decide con el usuario es el coordinador, mediante el mismo closure
inyectable que S1 introduce para las confirmaciones. Así `DocumentStore` es probable sin interfaz.

`refresh(matching:)` es el actual `refreshAgentFiles`, sin saber nada del agente: recibe un predicado.

### 3. `ScriptLibrary`

```swift
@MainActor struct ScriptLibrary {
    func url(for path: String, workspaceURL: URL) -> URL?
    func remembering(_ url: URL, in workspace: Workspace, at workspaceURL: URL) -> Workspace?
}
```

Funciones puras sobre el modelo: `rememberScript` y `scriptURL` de hoy. Devuelve `nil` cuando no hay nada
que cambiar, y el coordinador decide si persiste. Acá entra el filtro de rutas de S1/C7 (`url(for:)` deja de
aceptar absolutas arbitrarias).

### 4. `ErrorCenter`

```swift
@MainActor @Observable final class ErrorCenter {
    private(set) var queue: [AppError] = []     // id, título, detalle, fecha
    func report(_ error: Error, context: StaticString = #function)
    func dismissFirst()
}
```

- `report` usa **una** función de descripción compartida para todos los errores del proyecto: mover la
  lógica de `MySQLClient.message(_:)` a `AppError.describe(_:)`, que entienda `LocalizedError`
  (`DatabaseFailure`, `AgentFailure`, `WorkspaceError`), `MySQLError` y `CancellationError`. `MySQLClient`
  pasa a usarla, no al revés.
- La vista muestra el primero de la cola y, si hay más, un «y 2 más» con acceso al detalle. Eso resuelve el
  problema del hueco único sin inventar una bandeja de notificaciones.
- `report` registra además en `Log` (C6), con el contexto, así que todo error queda rastreable.

### 5. `WorkspaceController` resultante

Conserva: `workspace`, `workspaceURL`, `isSwitchingWorkspace`, apertura/creación/cierre, `persist`,
subproyectos, conexiones, `sendToAgent`, el estado de confianza (S1), los flags de paneles, y referencias a
`runner`, `database`, `agent`, `recents`, `documents`, `errors`. Objetivo: **por debajo de 200 líneas**.

### 6. Migración de las vistas

Las vistas usan hoy `controller.documents`, `controller.selectedDocument`, `controller.recentProjects`,
`controller.errorMessage`. Para no hacer un cambio masivo de golpe, agregar propiedades de reenvío en
`WorkspaceController` (`var documents: [EditorDocument] { documentStore.documents }`), migrar las vistas en
un commit aparte, y recién entonces quitar los reenvíos. Tres commits chicos en vez de uno grande.

## Criterios de aceptación

1. `WorkspaceController.swift` tiene menos de 200 líneas; ninguno de los tipos nuevos pasa de 150.
2. Las 29 pruebas pasan. `WorkspaceNavigationTests` que prueban recientes construyen `RecentProjectsStore`
   directamente, sin controlador.
3. Dos errores reportados en el mismo ciclo de ejecución se muestran los dos (el segundo como «y 1 más»), y
   ninguno se pierde.
4. Un `DatabaseFailure`, un `MySQLError`, un `WorkspaceError` y un `CancellationError` producen el mismo
   texto llegando por `ErrorCenter.report` que por la ruta de base de datos actual.
5. `DocumentStore` se puede ejercitar en pruebas sin que aparezca ningún `NSAlert`.
6. No queda ninguna referencia a `controller.errorMessage` en las vistas.

## Pruebas

Nuevas, en archivos propios para que crezcan con cada tipo:

- `KrabzikTests/RecentProjectsTests.swift`: orden, deduplicación, límite 10, persistencia, normalización de
  rutas con `..` y con symlinks.
- `KrabzikTests/DocumentStoreTests.swift`: abrir dos veces el mismo archivo no duplica pestaña; abrir en
  paralelo respeta `openingFiles`; `save` propaga `WorkspaceError.externalChange`; `reload` descarta;
  `closeAll` limpia.
- `KrabzikTests/ErrorCenterTests.swift`: cola, orden, `describe` para los cuatro tipos de error.

Las pruebas de navegación existentes se conservan como no-regresión del coordinador.

## Riesgos y compatibilidad

- Es el spec con más superficie de conflicto. Hacerlo cuando S1 ya esté cerrado (comparte el mecanismo de
  confirmaciones inyectables) y en commits por tipo extraído.
- Riesgo de sobre-ingeniería: el objetivo no es «arquitectura limpia» sino que cada pieza se pueda probar y
  que los errores no se pisen. Si una extracción no mejora ninguna de esas dos cosas, no se hace.
- `@Observable` anidado: las vistas que observan `controller.documentStore.documents` tienen que leer la
  propiedad a través del controlador para que el seguimiento funcione; verificar que la lista de pestañas se
  siga actualizando al abrir un archivo (es justamente lo que cubre `DocumentStoreTests` más una pasada
  manual).
