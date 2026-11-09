# C11 · Rendimiento del editor y arquitecturas del Release

| | |
|---|---|
| **Severidad** | Baja (alta si se edita un archivo cercano al límite de 5 MB) |
| **Área** | Editor, build |
| **Archivos** | `Krabzik/Editor/CodeEditor.swift`, `Krabzik/Models/EditorDocument.swift`, `scripts/generate_project.py` |
| **Depende de** | C2 (el `teardown()` toca el mismo archivo), C3 (para medir en CI si se quiere) |
| **Esfuerzo** | Medio día |

## Problema

### 1. Copia completa del texto en cada pulsación

```swift
func textDidChange(_ notification: Notification) {
    editRevision += 1
    document?.text = textView.string      // ← copia de todo el documento
    if document?.isDirty == false { document?.isDirty = true }
    …
}
```

`NSTextView.string` materializa un `String` nuevo a partir del `NSTextStorage` en cada acceso, así que cada
tecla es O(n) sobre el documento completo. Con el límite declarado de 5 MB (`EditorDocument.init` y
`DocumentIO.read`), eso es una copia de 5 MB por pulsación.

El diseño del editor es por lo demás cuidadoso en esto —el README dice «El editor evita propagar cada
pulsación por SwiftUI», y es cierto: `text` es `@ObservationIgnored`, el resaltado se limita al área visible
con un debounce de 75 ms, y `LineIndex` se actualiza de forma incremental en
`textView(_:shouldChangeTextIn:replacementString:)`— lo que hace que esta línea desentone: es el único punto
donde se paga el documento entero.

Consumidores reales de `document.text`:

| Consumidor | Cuándo |
|---|---|
| `WorkspaceController.save(_:)` | al guardar (⌘S) |
| `EditorDocument.sqlToExecute` | al ejecutar SQL (⌘↩) |
| `saveCopy()` | al guardar una copia |
| `EditorSurface.reloadFromDocument()` | al recargar desde disco |
| `LineIndex` en `init` / `reloadFromDocument` | al abrir y al recargar |

Todos son eventos puntuales del usuario. Ninguno necesita que `text` esté actualizado en cada tecla.

### 2. `ONLY_ACTIVE_ARCH = YES` también en Release

```python
'SDKROOT': 'macosx', 'ONLY_ACTIVE_ARCH': 'YES',
```

El diccionario común lo fija para las seis configuraciones. En Debug es lo correcto (compila más rápido); en
Release significa que el `.app` que `scripts/build.sh` produce e instala en `/Applications` —el flujo que
pide `AGENTS.md`— contiene **solo** la arquitectura de la máquina que compiló. Si alguna vez ese binario se
copia a un Mac con otra arquitectura, no arranca.

## Objetivo

La latencia de tecla no depende del tamaño del archivo, y el binario de Release es universal.

## Alcance

**Incluye** diferir la lectura del texto, la medición que lo demuestra, y el ajuste de arquitecturas.

**No incluye** cambiar el límite de 5 MB, ni el motor de resaltado, ni introducir edición incremental del
`NSTextStorage` más allá de lo que ya hace `LineIndex`.

## Diseño

### 1. `text` pasa a leerse bajo demanda

`EditorDocument.text` deja de ser almacenamiento y pasa a derivarse de la surface cuando existe:

```swift
@ObservationIgnored private var cachedText: String
@ObservationIgnored private var cacheIsStale = false

var text: String {
    get {
        if cacheIsStale, let surface = editorStorage as? EditorSurface {
            cachedText = surface.textView.string
            cacheIsStale = false
        }
        return cachedText
    }
    set { cachedText = newValue; cacheIsStale = false }
}

/// La llama el editor en cada cambio: O(1).
func markTextStale() { cacheIsStale = true }
```

`textDidChange` queda:

```swift
func textDidChange(_ notification: Notification) {
    editRevision += 1
    document?.markTextStale()
    if document?.isDirty == false { document?.isDirty = true }
    textView.typingAttributes = baseAttributes
    gutter.needsDisplay = true
    scheduleHighlight()
    updatePosition()
}
```

Puntos de cuidado:

- El acceso al getter tiene que ocurrir en el main actor. `EditorDocument` ya es `@MainActor`, así que está
  garantizado por el compilador (y C2 lo verifica de verdad).
- `acceptExternalData(_:discardEdits:)` escribe `text` y después llama `reloadFromDocument()`: el `set`
  limpia el flag, así que el orden sigue siendo correcto.
- Un documento sin surface (abierto pero nunca mostrado) conserva el texto inicial del `init`: el getter no
  encuentra surface y devuelve la caché, que es exacta.
- `isDirty` no puede derivarse de comparar textos en cada tecla (sería el mismo problema); se mantiene el
  booleano que ya existe, y `save(_:)` sigue comparando contra `originalData` una sola vez.

### 2. Medición

El criterio de aceptación necesita un número, no una impresión. Prueba de rendimiento con `measure`:

- generar un archivo de 5 MB de texto UTF-8 (líneas de código repetidas, no un bloque único);
- abrirlo en una `EditorSurface`;
- simular 200 inserciones de un carácter mediante `textView.insertText(_:replacementRange:)`;
- medir el tiempo total y dividir.

Umbral: **menos de 8 ms por pulsación** de media (un frame a 120 Hz). Antes del cambio, la copia de 5 MB
domina ese presupuesto; después, debería quedar en el ruido.

### 3. Arquitecturas

En `generate_project.py`, sacar `ONLY_ACTIVE_ARCH` del diccionario común y fijarlo por configuración:

```python
'ONLY_ACTIVE_ARCH': 'YES' if config == 'Debug' else 'NO',
```

Y, para que sea explícito, `ARCHS = '$(ARCHS_STANDARD)'` en Release. Nota: el build de Release pasa a tardar
más (dos arquitecturas) y `scripts/build.sh` lo notará; es el precio correcto para un binario que se
instala.

## Criterios de aceptación

1. La prueba de rendimiento del punto 2 reporta menos de 8 ms por pulsación con un archivo de 5 MB.
2. `document.text` devuelve exactamente el contenido del `NSTextView` después de editar, sin haberse leído
   en cada tecla (verificable: una prueba edita, lee `text` una vez y compara con `textView.string`).
3. Guardar (⌘S), ejecutar SQL con y sin selección (⌘↩), guardar copia y recargar desde disco siguen
   funcionando con el contenido correcto después de editar.
4. `EditorDocument.sqlToExecute` sigue devolviendo la línea de inicio correcta con selección Unicode: la
   prueba existente `testSQLSelectionUsesUTF16AndOriginalLine` pasa sin cambios.
5. `lipo -archs` sobre el binario de Release lista `x86_64 arm64`.
6. `ONLY_ACTIVE_ARCH` sigue en `YES` para Debug.

## Pruebas

En `KrabzikTests/CoreTests.swift`:

- `testEditorKeystrokeLatencyOnLargeDocument` — la del punto 2, con `measure`. Marcarla para poder aislarla
  si CI resulta demasiado variable como para sostener un umbral.
- `testDocumentTextReflectsEditorAfterEditing` — el criterio 2.
- `testDocumentTextWithoutSurfaceReturnsInitialContent` — el caso del documento nunca mostrado.

Las pruebas existentes `testSQLSelectionUsesUTF16AndOriginalLine`,
`testSaveDoesNotOverwriteExternalChangesOrDeletedFile` y
`testEditorReloadPreservesUnsavedChangesAndUpdatesNativeSurface` (en `AgentTests`) son la red de no
regresión del cambio.

## Riesgos y compatibilidad

- **Es el cambio con más riesgo de los de baja severidad**, porque toca el camino de guardado: si `text`
  devuelve algo viejo, se guarda contenido incorrecto. De ahí que los criterios 2, 3 y 4 sean obligatorios
  y que las pruebas de guardado y de selección SQL existentes se traten como bloqueantes.
- Si un umbral de tiempo en CI resulta inestable, la respuesta correcta es aislar la prueba, no subir el
  umbral hasta que pase.
- El Release universal duplica el tiempo de compilación. Si molesta en el flujo diario de `AGENTS.md`,
  `scripts/build.sh` puede pasar `ONLY_ACTIVE_ARCH=YES` explícitamente para las instalaciones locales, pero
  el default versionado tiene que ser el universal.
