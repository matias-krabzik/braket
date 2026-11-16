# PXA-01 · Formato `.pxa` y persistencia

| | |
|---|---|
| **Estado** | Motor implementado en la etapa 1 (sin interfaz); ver `docs/pixel-art-engine.md` |
| **Área** | Modelo de documento, almacenamiento y recuperación |
| **Depende de** | [PXA-03](PXA-03-color-y-paletas.md) para interpretación del píxel |
| **Relacionados** | [PXA-02](PXA-02-historial-persistente.md), [PXA-04](PXA-04-operaciones-y-propuestas.md) |

## Problema y objetivo

La vista previa actual de imágenes no conserva estructura editable. PNG y GIF son salidas,
no el documento de trabajo. `.pxa` debe conservar por sí mismo el estado actual, todas sus
revisiones retenidas y el estado necesario para continuar la edición.

## 1. Contenedor

Un archivo regular con extensión `.pxa`, contenedor ZIP, métodos Store o Deflate, sin cifrado
ni archivos multipartes. ZIP64 se admite cuando lo requiera el número de entradas. El formato
se identifica por el manifiesto, no solo por la extensión o la firma ZIP.

| Entrada | Obligatoria | Contenido |
|---|---|---|
| `manifest.json` | Sí | Identidad, versiones, referencias raíz y contadores |
| `objects/<sha256>` | Según referencias | Objetos JSON o binarios inmutables, identificados por hash |
| `preview.png` | No | Miniatura derivada del fotograma activo, máximo 512 × 512 |

Cada hash es SHA-256 del contenido descomprimido exacto del objeto, en hexadecimal minúsculo
de 64 caracteres. Referencias tipadas: tipo esperado, hash y cantidad de bytes descomprimidos.
Los hashes verifican integridad y deduplicación; no acreditan autoría ni confianza.

No se extrae el ZIP a rutas elegidas por su contenido. Se rechazan entradas duplicadas, rutas
absolutas, `..`, barras invertidas, enlaces, archivos especiales y entradas fuera de los nombres
permitidos. El manifiesto es JSON UTF-8 sin BOM, igual que todos los objetos JSON. Se rechazan
claves duplicadas, números no finitos y profundidad superior a 64 niveles.

Los objetos JSON contienen `type` y `version`. Para escribir, ordenar claves por sus bytes UTF-8,
sin espacios superfluos; arrays conservan su orden semántico. Para leer, el hash siempre se
comprueba contra los bytes recibidos, nunca contra una reserialización. No se necesita comparar
JSON entre implementaciones para decidir si dos referencias son iguales.

Los tipos de objeto del núcleo son `documentState`, `layer`, `frame`, `cel`, `palette`,
`sequences`, `historyIndex`, `historyPage`, `revision`, `editorState`, `assistantState`, `proposal`,
`assistantRecord` y `exportPresets`, todos con versión 1. Sus referencias solo pueden apuntar
al tipo indicado por el campo. `pixelTile` y `selectionTile` son binarios con versión en la
referencia. Adjuntos visuales del asistente usan `assistantImage`, PNG sRGB de hasta 4.096 por
eje y 32 MiB descomprimidos por objeto; al decodificar se aplica también el límite de píxeles.
No se admiten tipos binarios arbitrarios. Las colecciones auxiliares vacías son objetos válidos.

## 2. Manifiesto

| Campo | Regla |
|---|---|
| `format` | Literal `braket.pixel-art` |
| `formatVersion` | Mayor 1, menor 0 |
| `requiredFeatures` | Lista de capacidades obligatorias; vacía para el núcleo 1.0 |
| `documentID` | UUID estable, independiente del nombre/ruta |
| `saveID` | UUID nuevo por guardado completo; identifica esa generación del archivo |
| `createdAt`, `savedAt` | Fechas UTC RFC 3339; informativas, no ordenan el historial |
| `writer` | Nombre y versión de la app, solo informativo |
| `currentState` | Referencia a la raíz artística actual |
| `history` | Referencia al índice de historial con cursor y ramas |
| `editorState` | Referencia al estado de edición |
| `assistantState` | Referencia opcional a conversación y propuestas conservadas |
| `exportPresets` | Referencia a ajustes portables de exportación; lista vacía permitida |
| `nextPaletteEntryID` | Próximo entero de entrada de paleta, superior a cualquiera ya asignado |
| `objectCount`, `uncompressedBytes` | Totales declarados de objetos; se contrastan con lo real |

`currentState` debe coincidir con el estado de la revisión señalada por el cursor del historial.
No hay un segundo documento artístico editable independiente del historial. El contador de paleta
es global al documento, no retrocede al deshacer y contempla todas las ramas y propuestas guardadas.

## 3. Modelo artístico

Todos los IDs de entidades son UUID, excepto los IDs enteros de entrada de paleta. Las referencias
siempre usan IDs, nunca posición visual ni nombre. Renombrar o reordenar no cambia una identidad.

| Entidad | Campos y reglas del núcleo 1.0 |
|---|---|
| Estado raíz | Dimensiones, colorSpace=`sRGB`, listas ordenadas de capas y fotogramas, referencias a paleta y secuencias |
| Capa | ID, nombre, visible, bloqueada, bloqueo de transparencia, opacidad entera 0–255, blendMode=`normal` |
| Fotograma | ID, duración entera en milisegundos y mapa capa-ID → referencia de celda |
| Celda | Contenido de una capa en un fotograma; mapa disperso coordenada de bloque → referencia |
| Paleta | Nombre, orden de IDs y entradas definidas en PXA-03 |
| Secuencia | ID, nombre, lista no vacía de IDs de fotograma, reproducción `forward`, `reverse` o `pingPong`, loop booleano |

La lista de capas va de fondo a frente. La lista de fotogramas define el orden de la línea de tiempo.
Una intersección sin celda es transparente; nunca hereda automáticamente el fotograma anterior.
Cada celda tiene el tamaño del lienzo, sin desplazamiento propio en 1.0. Duplicar una celda crea
independencia de edición aunque sus objetos compartan hashes hasta la primera modificación.

Duraciones: 1 a 60.000 ms. El control de FPS calcula duraciones enteras para el conjunto elegido;
la duración por fotograma es la autoridad. Una secuencia no puede repetir IDs ni referir a
fotogramas eliminados. Eliminar un fotograma lo retira de secuencias en la misma transacción;
una secuencia que quede vacía se elimina, y deshacer recupera ambos.

Coordenadas enteras, origen arriba a la izquierda, X hacia la derecha e Y hacia abajo.
La composición es de fondo a frente, alfa source-over en sRGB lineal, usando RGB sin premultiplicar
como almacenamiento. La opacidad de capa multiplica el alfa al componer; no altera el píxel guardado.
La salida se convierte a sRGB con redondeo al entero más cercano, empates hacia arriba.
Los colores efectivos por píxel se resuelven antes de componer, según PXA-03.

## 4. Bloques de píxeles

Bloques dispersos de **32 × 32**, alineados con el origen del lienzo. Solo se almacenan los que
contienen al menos un píxel distinto de vacío. Cada bloque es un objeto binario de exactamente
5.120 bytes: 1.024 píxeles, orden por filas, 5 bytes por píxel.

| Etiqueta, primer byte | Cuatro bytes restantes | Significado |
|---|---|---|
| 0 | Todos cero | Vacío transparente |
| 1 | R, G, B, A, cada uno de 8 bits | Color libre sRGB sin premultiplicar |
| 2 | ID de entrada como UInt32 little-endian | Color vinculado |

Los bytes fuera del lienzo en bloques de borde deben ser cero. Un color libre con alfa cero se
normaliza a vacío. Una referencia vinculada cuyo color tiene alfa cero **se conserva**: puede
volver a ser visible si cambia la entrada. Etiquetas desconocidas o referencias inexistentes
son errores, no se convierten a transparente.

El tipo y la versión del bloque están en su referencia tipada: `pixelTile`, versión 1. El binario
no incluye encabezado adicional. La compresión se aplica en ZIP; no se embebe PNG para el modelo
editable porque perdería la identidad de colores vinculados.

## 5. Estado de edición y contenido auxiliar

`editorState` guarda capa y fotograma activos, IDs seleccionados, selección de píxeles, herramienta,
color de dibujo, tamaño de pincel, simetría, cuadrícula, onion skin, zoom y centro de vista en
coordenadas del lienzo. Una selección de píxeles es una máscara binaria dispersa de bloques
32 × 32: 128 bytes por bloque, filas consecutivas, bit más significativo primero en cada byte;
bit 1 seleccionado. No hay selección suavizada en 1.0. Ausencia de máscara significa sin selección,
distinta de una selección explícita vacía, que no permite pintar ningún píxel.

Dentro de ese estado se incluyen el modo de zoom (porcentaje fijo/Ajustar), ejes de simetría
en medios píxeles, opciones de onion skin, secuencia activa opcional y loop de reproducción
de timeline completa. Se concretan en PXA-06/PXA-09/PXA-14; nunca se guarda un timer en ejecución.

Una selección flotante pegada debe confirmarse o cancelarse antes de guardar; el guardado no
la aplica sin intervención. Una herramienta en gesto conserva solo su última transacción terminada.
Referencias de UI que dejaron de existir se ajustan a una entidad válida y se informa cuando
el estado proviene de un archivo defectuoso. Esto no autoriza reparar referencias artísticas.

El documento guarda la vista para portabilidad. Anchos de paneles, tema, cuenta de Codex,
credenciales, permisos, rutas absolutas y destinos recientes son preferencias locales, fuera de `.pxa`.
Los presets de exportación incluyen formato, escala, alcance por IDs, margen, separación y nombre
de salida, pero no una ruta absoluta. Al exportar se revalida que sus IDs aún existan.

Las conversaciones se conservan como texto y propuestas conforme a PXA-04, sin tokens de acceso,
logs del transporte ni dependencia de un thread remoto. Abrir el archivo nunca ejecuta prompts.
Las imágenes importadas se convierten a contenido propio; no quedan enlaces al archivo fuente.

## 6. Límites iniciales y validación

Son topes simultáneos, no una garantía de que todos sus máximos puedan combinarse. MiB/GiB son
potencias de 1024. Se aplican antes de asignar memoria o descomprimir sin límite.

| Recurso | Tope 1.0 |
|---|---|
| Lienzo | 1–4.096 por eje; máximo 16.777.216 píxeles |
| Capas / fotogramas / secuencias por estado | 128 / 1.024 / 256; al menos una capa y un fotograma |
| Entradas activas de paleta | 256; puede estar vacía |
| Bloques de píxeles referidos por estado | 65.536, contando cada posición de cada celda, aunque comparta hash |
| Revisiones retenidas | 100.000 |
| Archivo comprimido / suma descomprimida | 1 GiB / 2 GiB |
| Objetos / tamaño de un objeto JSON / manifiesto | 250.000 / 16 MiB / 1 MiB |
| Nombres | 200 caracteres Unicode, máximo 800 bytes UTF-8 |
| Mensaje o prompt / total de texto del asistente | 64 KiB / 16 MiB, incluido texto asociado al historial |
| ID de entrada | 1 a 4.294.967.294; 0 reservado; contador admite 4.294.967.295 como agotado |

Nombres sin controles C0/C1, saltos de línea, NUL ni controles de dirección bidi. Mensajes admiten
tabulador y saltos de línea; se muestran como datos, nunca HTML ejecutable. Contadores, índices y
dimensiones son enteros. Se comprueban desbordamientos de sumas/productos y longitudes reales.
Etiquetas de operaciones, marcadores históricos y resúmenes cortos usan el límite de nombres;
descripciones extensas usan el límite de mensaje. Todas las referencias y metadatos cuentan para
los presupuestos globales, incluso los que no afectan la imagen visible.

Validación: envoltorio y presupuesto → manifiesto/versión → hashes y tipos → entidades y límites
→ referencias → grafo histórico → concordancia del cursor → datos auxiliares. Ningún estado
retenido, incluso una rama inactiva, puede incumplir los límites del modelo. La lectura puede
verificar objetos en streaming y conservarlos en caché acotada; no requiere materializar todas
las revisiones a la vez. Cancelar una apertura deja intacto el archivo.

Un error identifica sección y causa. No se sustituye un bloque roto por vacío. Una miniatura
inválida se descarta con aviso y se regenera; nunca es fuente de verdad.

Si falla solo el historial y el estado actual se puede verificar por completo, ofrecer abrir
una **copia recuperada** con ese estado como origen y un nuevo documento-ID. No sobrescribir
el original ni presentar la copia como poseedora del historial completo. La recuperación requiere
selección explícita; si la integridad del estado actual tampoco se demuestra, rechazar la apertura.

## 7. Guardado, autoguardado y conflictos

1. Capturar una instantánea consistente: cursor, grafo, estado, contador y auxiliares de una misma
   generación en memoria. Las ediciones posteriores no se mezclan en ese guardado.
2. Escribir un archivo temporal hermano en el mismo volumen, incluyendo todos los objetos
   alcanzables desde historial, UI y propuestas guardadas. Validar el resultado y completar la
   sincronización de datos antes de reemplazar el destino mediante una operación atómica.
3. Coordinar acceso con los mecanismos de documentos de macOS y comparar la huella del archivo
   con la leída/guardada anteriormente dentro de la sección coordinada. Tamaño y fecha solos no bastan.
4. Ante cambio externo, disco lleno, error de permisos o validación, conservar el destino anterior
   y el estado en memoria. Ofrecer reintentar, recargar o guardar una copia; nunca sobrescribir sin aviso.
5. Registrar como guardada solo la generación capturada. Si se editó durante el guardado, mantener
   cambios pendientes. La atomicidad no garantiza durabilidad frente a cualquier fallo físico del disco.

No se modifica un ZIP existente en el lugar. La primera versión prioriza un guardado completo
consistente; cualquier optimización debe preservar el mismo contrato.

Autoguardado es recuperación local: copia completa consistente tras 2 segundos sin cambios, con
una captura al menos cada 30 segundos de edición continua cuando no haya otra escritura en curso.
No reemplaza el archivo del usuario ni equivale a pulsar Guardar. Conserva las dos últimas
generaciones válidas por documento/ubicación y nunca recicla la anterior antes de verificar la nueva.
No promete conservar un trazo interrumpido antes de confirmar su transacción.

La recuperación incluye la huella base del archivo; si el original cambió externamente se ofrece
como copia separada. Cerrar y elegir descartar elimina las recuperaciones de esa sesión solo después
de confirmar el descarte. Tras guardar correctamente, una recuperación cubierta por ese guardado
puede retirarse. Los borradores sin ruta tienen identidad local propia y también son recuperables.

Guardar como traslada el documento activo a otra ruta conservando identidad e historia.
Guardar una copia crea otro documento-ID, mantiene la historia y registra el ID de origen como
metadato informativo. Una copia hecha en Finder puede conservar el mismo ID: la app distingue
instancias por ubicación canónica y no fusiona sesiones por el ID embebido.

## 8. Evolución

Mayor desconocida: rechazar con mensaje de actualización, sin guardar. Menor superior: permitir
solo lectura si todas las capacidades obligatorias son conocidas y la estructura núcleo es válida;
si no, rechazar. Nunca guardar desde un lector que descartó campos desconocidos.

En 1.0 los campos inesperados se rechazan, salvo un mapa explícito de extensiones opcionales
en el manifiesto, preservado sin interpretación y sujeto al límite del manifiesto. Una extensión
no puede alterar la interpretación artística sin declararse en `requiredFeatures`.

Una migración futura conserva el original y verifica la copia migrada antes de ofrecer reemplazo.
Los presets exportados o miniaturas no sustituyen una migración de datos editables.

## Criterios de aceptación y pruebas futuras

- Ida y vuelta exacta de entidades, píxeles mixtos, selección, cursor histórico y propuestas.
- Abrir el mismo `.pxa` en otra ubicación sin sus fuentes ni sesión de Codex produce el mismo estado.
- Duplicar una celda y editar la copia no modifica la original.
- Validar bordes de bloques, alfa cero libre/vinculado e IDs de paleta sin resolver.
- Rechazar ZIP con rutas peligrosas, duplicados, expansión excesiva, hash incorrecto o referencias cíclicas.
- Verificar máximos, máximos + 1 y overflow antes de reservas de memoria grandes.
- Simular fallo en cada fase de guardado: queda disponible la última versión válida.
- Editar durante guardado y cambiar el archivo externamente no pierde ninguna edición silenciosamente.
- Recuperar después de cierre forzado; probar conflicto con el original y recuperación parcial explícita.
- Una versión futura no puede ser reescrita perdiendo información por un lector 1.0.

## Riesgos

ZIP con muchas entradas y validación completa pueden hacer lenta la apertura. Medir antes de
publicar 1.0; no resolverlo suprimiendo historial. La especificación binaria fija un costo de
5 bytes por píxel almacenado antes de compresión: medir contra sprites, ilustraciones y animaciones.
Se necesitan pruebas de composición y color compartidas entre lienzo, preview y exportación.
