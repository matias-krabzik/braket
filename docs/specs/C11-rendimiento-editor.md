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

## Resuelto

**2026-11-10**, commit `101c1ce`.

### El diagnóstico del spec estaba equivocado

Antes de tocar nada se midió, sobre un archivo de 5 MB con 76.000 líneas, insertando al principio —el peor
caso— 200 veces:

| | ms/tecla |
|---|---|
| tecla completa, antes | 8,39 |
| `LineIndex.replace`, sola | **7,25** |
| leer `textView.string`, lo que este spec señalaba | **0,27** |
| `NSTextView` sin delegado: el piso de TextKit | 0,06 |

La copia del documento, que era el problema descrito, costaba el 3 % de la pulsación: `NSTextView.string`
no materializa un `String` nuevo en cada acceso como suponía el spec. El 86 % se lo llevaba
`LineIndex.replace`, que reconstruía el arreglo completo de comienzos de línea con `prefix`, `filter`, `map`
y dos concatenaciones sobre 76.000 enteros. El propio spec lo daba por bueno («`LineIndex` se actualiza de
forma incremental»): era incremental en el resultado, no en el costo.

### Qué se hizo

1. **El índice salió del camino caliente.** Primer intento: hacerlo en el lugar, con bisección para los
   límites y un solo recorrido de la cola. Bajó de 8,39 a 7,39, porque sumarle el delta a 76.000 enteros
   sigue siendo O(n). Segundo intento, el que quedó: los comienzos se guardan absolutos hasta un pivote y la
   cola lleva un desplazamiento pendiente, así que una edición solo materializa lo que hay entre el pivote
   anterior y el punto editado —escribiendo seguido, nada—. **0,83 ms por pulsación.**
2. **El texto del documento se lee bajo demanda**, como pedía el spec. Después del punto 1 es la parte
   medible que queda, y es lo que el spec diseñó: el editor marca la caché como vieja (O(1)) y el texto se
   relee al guardar, ejecutar SQL, guardar una copia o recargar. `releaseEditor()` lo lee antes de soltar la
   vista, porque después no hay de dónde.
3. **Release es universal.** `ONLY_ACTIVE_ARCH` pasó a `NO` en Release y `YES` en Debug.

| Criterio | Cómo se verificó |
|---|---|
| 1 · menos de 8 ms por pulsación con 5 MB | `testEditorKeystrokeLatencyOnLargeDocument`: 0,83 ms, con el umbral en 8. Los números de la tabla están en el comentario de la prueba |
| 2 · `document.text` es exactamente el del editor | `testDocumentTextReflectsEditorAfterEditing`, que además comprueba que soltar la vista no pierde lo escrito |
| 3 · guardar, ejecutar SQL, copia y recarga siguen bien | las pruebas que ya existían: `testSaveDoesNotOverwriteExternalChangesOrDeletedFile`, `testSQLSelectionUsesUTF16AndOriginalLine`, `testEditorReloadPreservesUnsavedChangesAndUpdatesNativeSurface` |
| 4 · `testSQLSelectionUsesUTF16AndOriginalLine` pasa sin cambios | sí, no se tocó |
| 5 · `lipo -archs` lista `x86_64 arm64` | **comprobado** el 2026-11-10 sobre el binario instalado en `/Applications`: `x86_64 arm64`, y `codesign --verify --deep --strict` pasa |
| 6 · Debug sigue en `ONLY_ACTIVE_ARCH = YES` | sí, y `scripts/generate_project.py --check` lo mantiene sincronizado |

### Errores cometidos

- Dar por bueno el diagnóstico del spec. El primer intento optimizó lo que el spec señalaba, se quedó en
  8,45 ms y el umbral de 8 ms no se cumplía; recién al medir cada parte apareció el costo real. Medir antes
  de optimizar habría ahorrado una vuelta entera.
- El umbral de 8 ms del criterio 1 se mide en la configuración de pruebas, que compila sin optimizar. No es
  el número que ve el usuario en la Release instalada —ahí es menor—, pero es el que se puede comprobar en
  cada corrida, y sirve igual como trinquete.
