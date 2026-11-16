# PXA-02 · Historial persistente y revisiones

| | |
|---|---|
| **Estado** | Motor implementado en la etapa 1 (sin interfaz); ver `docs/pixel-art-engine.md` |
| **Área** | Transacciones, deshacer/rehacer, ramas y almacenamiento |
| **Depende de** | [PXA-01](PXA-01-formato-y-persistencia.md) |
| **Relacionados** | [PXA-03](PXA-03-color-y-paletas.md), [PXA-04](PXA-04-operaciones-y-propuestas.md) |

## Problema y objetivo

El historial de un editor no debe desaparecer al cerrar ni depender de volver a ejecutar un prompt.
Deshacer debe restaurar exactamente píxeles, vínculos de paleta y estructura, aunque el programa,
el modelo de IA o el archivo importado hayan cambiado desde la edición original.

## 1. Modelo de historia

El documento conserva un árbol de revisiones inmutables con una raíz y un cursor. Cada revisión
no inicial tiene exactamente un padre. No hay fusiones de ramas en 1.0 ni referencias cíclicas.

| Campo de revisión | Regla |
|---|---|
| `id` | UUID único |
| `parentID` | UUID del padre; nulo únicamente en la raíz |
| `beforeState` | Referencia al estado del padre; nula en la raíz |
| `afterState` | Referencia a un estado artístico completo resoluble |
| `operationKind`, `operationVersion` | Tipo descriptivo de acción y versión; no código a ejecutar |
| `label` | Texto legible: «Trazo de lápiz», «Cambiar paleta», etc. |
| `source` | `manual`, `codex`, `import` o `system` |
| `createdAt` | Fecha UTC informativa |
| `affected` | IDs de capas/fotogramas/entradas y regiones, verificables contra los estados |
| `assistantRecord` | Referencia opcional al registro de propuesta aceptada |
| `focusBefore`, `focusAfter` | Capa/fotograma y selección de edición antes/después de la operación |

El índice contiene todas las referencias de revisión, `rootRevisionID`, `cursorRevisionID`, el hijo
preferido para rehacer de cada nodo que lo tenga y marcadores con nombres opcionales. `beforeState`
debe coincidir con `afterState` del padre; el estado raíz tiene las mismas invariantes que cualquier
estado posterior. Los registros `affected` ayudan a presentar cambios, pero no reemplazan la validación.

Físicamente `historyIndex` contiene raíz/cursor y referencias a páginas `historyPage`. Cada página
almacena hasta 1.024 registros, ordenados por UUID de revisión; cada registro incluye referencia
a revisión, hijo preferido opcional y marcador opcional. El índice declara rangos de IDs disjuntos
de sus páginas; todo ID aparece exactamente una vez. El orden de páginas no es orden causal.
Validar padres/preferencias globalmente, no asumir que están en la misma página. Esta paginación
mantiene cada objeto bajo el tope de 16 MiB con 100.000 revisiones y permite carga/navegación acotada.

El orden causal viene de los padres, nunca de las fechas del reloj. Las identidades se conservan
al restaurar; el contador global de entradas de paleta no forma parte de una revisión artística.

## 2. Almacenamiento por objetos compartidos

Cada revisión referencia una instantánea lógica completa. Se guardan físicamente solo los objetos
nuevos: bloques de píxeles modificados y los descriptores que los referencian. Los objetos iguales
se comparten por hash entre revisiones, celdas y propuestas, sin compartir mutabilidad.

Por ejemplo, un trazo dentro de un bloque crea un bloque nuevo, el descriptor de su celda, el del
fotograma, el estado raíz y la revisión. Las demás capas, fotogramas y bloques se reutilizan.
Una edición de paleta no reescribe los bloques vinculados: crea la nueva paleta y su estado raíz.

No se guarda una copia completa del bitmap por acción. Tampoco se depende de reproducir una lista
de comandos para abrir o deshacer: cada revisión resuelve directamente sus descriptores y bloques.
No hacen falta checkpoints cada N comandos en 1.0. Las diferencias se obtienen comparando referencias
y, donde corresponda, los bloques distintos. Son diferencias de datos, no scripts ni instrucciones.

Los bytes exactos antes/después son la autoridad. Una versión futura puede dejar de reconocer una
etiqueta descriptiva de acción y aun así navegar el historial si soporta los tipos de estado usados.

## 3. Qué constituye una transacción

| Interacción | Unidad de historial |
|---|---|
| Lápiz/borrador entre pulsar y soltar | Un trazo, incluidos todos sus bloques |
| Relleno, forma o transformación confirmada | Una acción |
| Arrastrar capa o fotograma | Una acción al soltar |
| Arrastrar deslizador de opacidad o color | Una acción al terminar el gesto |
| Editar un valor mediante teclado | Una acción al confirmar o abandonar el campo |
| Pegar/importar | Una acción cuando la ubicación y parámetros se confirman |
| Reemplazar o adaptar paleta | Una acción para todo el alcance |
| Crear/eliminar capa o fotograma | Una acción con sus referencias dependientes |
| Aplicar propuesta de Codex | Una acción, aunque internamente use muchas operaciones |

Un gesto puede renderizar resultados temporales, pero solo publica una revisión completa al
terminar. Escape/cancelar descarta el estado temporal; un error no deja medio cambio. Una operación
sin diferencia artística no crea revisión. No se fusionan trazos separados por proximidad temporal.

La selección flotante de un pegado es temporal hasta confirmar. Deshacer con un gesto pendiente
primero cancela ese gesto; una segunda acción deshace la última revisión confirmada. La interfaz
debe reflejar esta distinción, no confirmar automáticamente un pegado al guardar o deshacer.

## 4. Estado artístico frente a estado de sesión

El historial artístico incluye píxeles, dimensiones, orden y propiedades de capas, paleta, duración
de fotogramas y secuencias. Visibilidad, bloqueos y opacidad de capa son propiedades reversibles.

Mover el cursor, cambiar herramienta, hacer zoom, seleccionar píxeles, cambiar fotograma activo,
abrir un panel o escribir un borrador de prompt no agrega una revisión artística. Se conserva el
estado más reciente en `editorState` o `assistantState` al guardar/recuperar. La selección anterior
y posterior de una operación sí queda en `focusBefore/After`, para deshacer un movimiento y poder
seguir trabajando sobre su selección original. Son referencias a máscaras propias de cada estado.

La selección geométrica se guarda en coordenadas del lienzo de su estado; redimensionar/recortar
debe registrar la transformación o recorte de esa selección. Deshacer recupera la máscara anterior.
Zoom y posición de vista no se restauran al deshacer; se ajustan si el lienzo cambia de dimensiones.

Hay dos clases de cambios pendientes: artísticos/históricos y auxiliares. Solo los primeros y
las nuevas propuestas/conversaciones que aún no se guardaron generan aviso de pérdida al cerrar.
Un cambio de zoom aislado no debe provocar ese diálogo. Los auxiliares pueden recuperarse localmente
y se incluyen en el siguiente guardado explícito; copiar un archivo lleva el último estado guardado.

## 5. Deshacer, rehacer y ramas

- Deshacer mueve el cursor al padre, restaura `beforeState` y `focusBefore`.
- Rehacer mueve al hijo preferido y restaura `afterState` y `focusAfter` de ese hijo.
- Deshacer registra como hijo preferido el nodo que se abandona.
- Crear una edición desde una revisión pasada agrega otro hijo y lo convierte en preferido.
  Los hijos anteriores y sus descendientes permanecen intactos.
- Desde Historial se puede elegir un hijo alternativo o restaurar cualquier revisión retenida.
  Esa navegación no crea una nueva revisión; actualiza cursor y ruta preferida desde la raíz
  hasta el destino. Las preferencias fuera de esa ruta se conservan.
- Al reabrir se restauran cursor y preferencias: Rehacer sigue disponible si se guardó tras deshacer.

Ejemplo normativo: raíz → A → B → C. Deshacer dos veces deja A. Pintar D produce raíz → A con
dos continuaciones: B → C y D. Deshacer D vuelve a A; Rehacer elige D. Elegir B desde Historial
permite rehacer hasta C. Guardar y reabrir en cualquiera de esos puntos conserva ambas continuaciones.

La vista inicial de Historial puede ser una lista de la ruta actual con un selector «Otras ramas».
No se exige un gráfico de nodos; sí acceso a todas las revisiones conservadas. Una rama abandonada
no puede quedar almacenada pero inaccesible desde la aplicación.

## 6. Estado guardado y copias

El punto de guardado es la generación completa capturada, no únicamente el hash del bitmap.
Deshacer y volver al mismo cursor sin cambiar grafo ni datos persistentes puede dejar el documento
limpio. Crear una rama y volver al cursor guardado deja cambios pendientes: hay historia nueva.
Cambiar preferencias de rehacer es un cambio histórico persistente.

Guardar no crea una revisión artística ni borra la posibilidad de deshacer. Guardar como/copia
conserva el historial según PXA-01. Exportar tampoco crea revisión; editar un preset es auxiliar.

La recuperación local conserva revisiones completas y cursor. No incorpora un trazo parcial a
una revisión válida ni mezcla partes de generaciones distintas.

## 7. Retención, limpieza y límites

Retención completa por defecto, hasta los presupuestos de PXA-01. Se elimina automáticamente
solo un objeto que no sea alcanzable desde ninguna revisión, estado auxiliar o propuesta retenida.
Recomprimir/deduplicar sin perder datos es mantenimiento, no recorte del historial.

Al alcanzar el 80 % de un presupuesto de almacenamiento o revisiones, mostrar un aviso no modal
con el recurso que crece. Al superar un límite duro, rechazar la nueva transacción antes de
confirmarla, conservar el trabajo existente y permitir guardarlo. No eliminar las acciones antiguas
para dejar pasar la nueva. Aplicar a Codex e importación el mismo preflight de presupuesto.

La acción explícita **«Guardar copia con historial reducido…»** permite:

1. Elegir solo el estado actual, o ese estado con los últimos N ancestros de su ruta.
2. Ver que se omitirán ramas alternativas, revisiones anteriores y propuestas no aplicadas.
3. Guardar en una ruta distinta sin sobrescribir el original, con nuevo documento-ID.

La revisión más antigua conservada se convierte en raíz, con su estado completo. Se regeneran
las identidades de las revisiones retenidas y sus padres para no mutar registros inmutables;
el cursor apunta al estado actual de la copia. Se mantienen IDs de entidades y el contador de
paleta. Los registros de Codex de revisiones retenidas pueden conservarse; las referencias a
revisiones omitidas se eliminan o pasan a información textual, nunca quedan referencias rotas.

La copia informa que su historia es parcial. No existe poda automática ni eliminación irreversible
de ramas dentro del documento original en la primera versión.

## 8. Historial de Codex

El registro de una propuesta aceptada contiene prompt final y ajustes que llevaron a ella,
resumen, alcance resuelto, revisión base, identificador de propuesta y modelo reportado, si existe.
No almacena razonamiento interno, credenciales ni logs completos. Las operaciones y datos resultantes
se conservan; deshacer/rehacer nunca llama a Codex.

Descartar una propuesta o recibir una respuesta de texto sin cambios no crea revisión artística.
La conversación puede registrar esas acciones como auxiliares. Una propuesta aceptada después de
deshacer crea una rama exactamente como lo haría una edición manual.

## Criterios de aceptación y pruebas futuras

- Reabrir después de A/B/C, deshacer y rehacer devuelve estados y vínculos idénticos byte a byte.
- Guardar con cursor en A conserva B/C como rehacer disponible.
- El ejemplo A/B/C/D conserva ambas ramas y su preferencia tras reabrir.
- Una edición de paleta, recorte o eliminación recupera contenido y dependencias con un solo deshacer.
- Aplicar 100 operaciones de una propuesta crea una sola revisión; un fallo en la 99 no aplica ninguna.
- Cancelar un trazo/pegado no crea un estado parcialmente aplicado.
- Editar un píxel no duplica todos los bloques de la animación en el contenedor.
- Un reloj que retrocede no altera la relación de revisiones.
- IDs duplicados, padres inexistentes/cíclicos, estado previo divergente o cursor inválido se rechazan.
- La navegación funciona sin red y sin archivos originales importados.
- Los límites no truncan historia; la copia reducida deja el original intacto y abre sin referencias rotas.

## Riesgos y compatibilidad

Conservar ramas aumenta el tamaño y requiere una UI mínima para encontrarlas. No confundir
historia persistente con el stack temporal de un control AppKit. Si se usa un mecanismo nativo
para atajos de deshacer, debe delegar en este historial y no mantener una segunda verdad.
