# C7 · Validar y acotar el formato `.krabzik`

| | |
|---|---|
| **Severidad** | Media |
| **Área** | Modelo, robustez |
| **Archivos** | `Krabzik/Models/Workspace.swift`, `Krabzik/Services/WorkspaceController.swift`, `Krabzik/Views/DatabaseViews.swift` |
| **Depende de** | S1 (comparten la clasificación de rutas; hacer S1 primero) |
| **Esfuerzo** | Medio día |

## Problema

`Workspace.read(from:)` valida tres cosas: versión soportada, IDs de proyectos y de conexiones sin
duplicados, y que cada conexión pase `validated()`. Todo lo demás se acepta tal cual:

- **Sin límite de cantidad.** Un archivo con 100.000 entradas en `scripts` se carga completo, y
  `DatabaseSidebar` las pinta con un `ForEach` **no perezoso** dentro de un `VStack`: la ventana se congela.
  Lo mismo con `projects`, que además crean un `ProjectRun` cada uno en `install(_:at:)`.
- **Sin límite de longitud.** `name`, `path` y `command` pueden tener megabytes. `ProjectRun.output` tiene
  un tope (200 KB) pero el comando que se muestra arriba no.
- **Caracteres de control.** `DatabaseConnection.validated()` rechaza `\0` y `\n` en host, usuario y base
  —bien pensado—, pero `CodeProject.name`, `path` y `command` no tienen ese filtro. Un nombre con
  `U+202E` desordena visualmente la barra lateral y, peor, el diálogo donde S1 pide confirmar el comando.
- **Rutas relativas con `..`.** `CodeProject.directory(relativeTo:)` hace
  `appendingPathComponent(path).standardizedFileURL`, así que `"../../../../etc"` resuelve fuera del
  proyecto sin que nada lo marque. S1 lo clasifica como externa; acá se trata como entrada inválida.
- **`scripts` duplicados y no normalizados.** El `init(from:)` deduplica con `NSOrderedSet`, pero sobre el
  texto crudo: `"sql/a.sql"` y `"./sql/a.sql"` sobreviven las dos.

Nada de esto es explotable por sí solo —`JSONDecoder` no es vulnerable y el modelo es `Codable` simple—
pero el archivo es un formato de entrada de terceros (S1) y hoy no tiene contrato.

## Objetivo

El formato tiene límites escritos y verificados. Un `.krabzik` malformado, enorme o con texto hostil se
rechaza con un mensaje claro, o se normaliza, pero nunca cuelga la interfaz ni muestra texto engañoso.

## Alcance

**Incluye** límites numéricos y de longitud, filtro de caracteres, rechazo de `..`, normalización de
`scripts`, y `LazyVStack` donde hace falta.

**No incluye** el modelo de confianza (S1) ni versionar el formato a la 2 (no hace falta: los límites
rechazan archivos que hoy no existen en la práctica).

## Diseño

### 1. Límites, declarados en un solo lugar

```swift
extension Workspace {
    enum Limits {
        static let projects = 64
        static let connections = 32
        static let scripts = 512
        static let nameLength = 200
        static let pathLength = 1_024
        static let commandLength = 4_000
    }
}
```

Los valores son holgados respecto del uso real (el proyecto de ejemplo tiene 3 subproyectos) y suficientes
para que ninguna interfaz se degrade. Van documentados en el README, en la sección del formato.

### 2. Validación en `Workspace.read`

Nuevos casos en `WorkspaceError`, cada uno con su mensaje en español, como los que ya existen:

```swift
case tooManyEntries(String)   // "El proyecto declara demasiados …"
case invalidText(String)      // "El proyecto contiene texto no válido en …"
case escapingPath(String)     // "La ruta … sale del directorio del proyecto."
```

Orden de comprobaciones: versión → cantidades → longitudes → texto → rutas → IDs duplicados → conexiones.
Las cantidades primero, para no recorrer un array de 100.000 elementos validando texto.

### 3. Filtro de texto

Reutilizar la función de saneado que S5 introduce (`ModelText.display`) **no** es lo correcto acá: ahí se
sanea para mostrar, acá se **rechaza** para no aceptar un archivo mentiroso. Función propia:

```swift
extension String {
    /// Texto admisible en el formato: sin controles (salvo tab), sin overrides bidi, sin NUL.
    var isValidProjectText: Bool
}
```

Rechaza `U+0000`–`U+001F` excepto tab, `U+007F`, `U+202A`–`U+202E`, `U+2066`–`U+2069`, `U+200B`–`U+200F`,
`U+FEFF`. Se aplica a `Workspace.name`, `CodeProject.name`, `path`, `command` y a cada entrada de `scripts`.
`command` sí admite saltos de línea (un comando multilínea es legítimo), así que para ese campo el filtro
permite `\n`.

### 4. Rutas

- Relativa que contenga un componente `..` → `escapingPath`. No se intenta normalizar: si la ruta quiere
  salir, el archivo está mal formado o es hostil.
- Relativa absoluta (`/…`) → permitida en el modelo, clasificada como externa por S1.
- `scripts`: normalizar con `standardizedFileURL` relativo al directorio del proyecto antes de deduplicar,
  de modo que `"sql/a.sql"` y `"./sql/a.sql"` colapsen en una sola entrada.

### 5. UI

- `DatabaseSidebar`: el `ForEach(controller.workspace?.scripts ?? [], id: \.self)` pasa a `LazyVStack`
  dentro de un `ScrollView` con altura máxima. Mismo tratamiento para la lista de conexiones si supera unas
  pocas entradas.
- El nombre del subproyecto y el comando se muestran truncados por la vista (`lineLimit`), que ya ocurre en
  la mayoría de los sitios; verificar `CommandSheet` y el diálogo de confirmación de S1.

### 6. Escritura

`Workspace.write(to:)` no necesita validar —lo que la app genera cumple por construcción— pero conviene un
`assert` en Debug para detectar temprano que algún camino de la app está creando un modelo que la propia
lectura rechazaría.

## Criterios de aceptación

1. Un `.krabzik` con 1.000 entradas en `scripts` se rechaza con el mensaje de `tooManyEntries`, y la app
   sigue respondiendo.
2. Un `.krabzik` con `"path": "../../etc"` se rechaza con `escapingPath`.
3. Un `.krabzik` con `U+202E` en el nombre de un subproyecto se rechaza con `invalidText`.
4. Un `command` de 10.000 caracteres se rechaza; uno de 3.000 con saltos de línea se acepta.
5. `"sql/a.sql"` y `"./sql/a.sql"` en el mismo archivo producen una sola entrada en la barra lateral.
6. `Examples/Primer proyecto/Primer proyecto.krabzik` sigue abriendo sin cambios, y los proyectos creados
   por la app también (round-trip: escribir, leer, comparar).
7. La barra lateral con 512 scripts (el límite) se desplaza con fluidez.

## Pruebas

En `KrabzikTests/CoreTests.swift`, junto a `testWorkspaceRejectsFutureVersionAndDuplicateIDs`:

- `testWorkspaceRejectsOversizedCollections`
- `testWorkspaceRejectsEscapingRelativePaths`
- `testWorkspaceRejectsControlAndBidiText`
- `testWorkspaceNormalizesAndDeduplicatesScripts`
- `testWorkspaceRoundTripStillWorks` — ya existe como
  `testWorkspaceRoundTripAndRelativePaths`; ampliarla con un proyecto que tenga scripts y conexiones.

Fixtures: construirlos en código, no como archivos, salvo uno malformado a mano en
`KrabzikTests/Fixtures/` para cubrir el caso de JSON válido con contenido hostil.

## Riesgos y compatibilidad

- Si algún proyecto real del usuario ya tiene más entradas que el límite, deja de abrir. Los límites están
  puestos muy por encima del uso observado; si aparece un caso legítimo, se sube el número, no se quita la
  comprobación.
- Rechazar un archivo entero por un carácter inválido en un campo puede ser frustrante. El mensaje tiene que
  decir **qué campo** y **de qué subproyecto**, para que se pueda corregir a mano: el formato es JSON
  legible, y eso es una ventaja que conviene aprovechar.
