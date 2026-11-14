# Motor de pixel art (etapa 1)

Implementa en código los contratos PXA-01 a PXA-04 de `docs/specs/pixel-art/`. Es solo el motor: no hay
interfaz, ni integración con `DocumentStore`, ni herramientas de dibujo. La etapa 2 lo conecta a la ventana.

Todo vive en `Krabzik/PixelArt/` y sus pruebas en `KrabzikTests/PixelArt/`. Son valores sin hilos propios: los
posee y serializa el actor que abra el documento.

## Mapa

| Archivo | Responsabilidad |
|---|---|
| `PixelArtJSON`, `PixelArtError` | JSON canónico y estricto (sin BOM, sin claves repetidas, profundidad 64); errores con sección y causa; topes de PXA-01 §6 |
| `PixelArtColor`, `PixelArtTile`, `PixelArtModel` | RGBA, píxel libre/vinculado/vacío, bloques de 32 × 32 de 5 bytes, selección, capas, fotogramas, estado y composición en luz lineal |
| `PixelArtObjects`, `PixelArtStateCodec` | Almacén de objetos por hash SHA-256, alcanzabilidad, codificación determinista y decodificación validada con caché |
| `PxaZip`, `PxaManifest` | Contenedor ZIP propio (Store/Deflate, ZIP64 solo para el número de entradas) y manifiesto con política de versiones |
| `PixelArtHistory`, `PixelArtHistoryCodec` | Árbol de revisiones, cursor, ramas, marcadores, presupuesto y copia reducida |
| `PixelArtScope`, `PixelArtRules` | Alcance explícito y diferencias entre estados; reglas de alcance y bloqueo que comparan base y resultado |
| `PixelArtOperations`, `PixelArtPaletteOperations`, `PixelArtPaletteTools` | Operaciones con IDs concretos; paleta, adaptación determinista y extracción |
| `PixelArtDocumentCore` | Una sola vía de modificación, atómica, para edición manual y propuestas |
| `PixelArtAssistant`, `PixelArtAssistantCodec` | Conversación y propuestas de Codex, con alcance congelado y revalidación al reabrir |
| `PixelArtEditorState` | Estado de edición portable y ajustes de exportación |
| `PixelArtDocument`, `PixelArtFile`, `PixelArtFileStore`, `PixelArtRecovery`, `PixelArtPreview` | Documento abierto, lectura/validación/escritura del `.pxa`, guardado atómico con huella, recuperación local y miniatura |

## Decisiones que el spec dejaba abiertas

- **Esquema JSON de cada objeto.** Los specs fijan los tipos y sus campos conceptuales, no los nombres. Los que
  usa el código están en los `encode`/`decode` de cada tipo; un campo desconocido se rechaza en 1.0.
- **Zoom y centro de vista como enteros**: porcentaje y milésimas de píxel. Así el formato no depende de cómo se
  escriben los decimales.
- **Herramienta como texto**, validado como un nombre. El conjunto de herramientas es de la etapa 3.
- **Un objeto que nada referencia se rechaza.** El escritor solo guarda lo alcanzable desde las raíces del
  manifiesto, así que un sobrante indica un archivo manipulado.
- **Las propuestas se aplican por estado, no por reproducción.** Una propuesta guarda su estado completo y
  descripciones de las operaciones; aplicarla valida la diferencia con las mismas reglas de una edición manual.
- **Huella de archivo = tamaño + SHA-256 del contenido.** El conflicto se decide dentro de la sección
  coordinada de `NSFileCoordinator`, justo antes de reemplazar.
- **Recuperación local**: `<carpeta>/<clave>/<n>.pxa` + `<n>.json`; la clave es el hash de la ruta canónica, o
  `draft-<UUID>` para un borrador sin ruta.

## Qué falta

- **Etapa 3**: relleno contiguo, formas, simetría, transformaciones de selección, combinar capas y la
  rasterización de gestos. El motor ya acepta `writePixels` y `resizeCanvas`; las herramientas los usarán.
- **Prueba técnica de PXA-04 §7** (render de 32 × 32 a Codex, tabla de cuatro colores, edición localizada, rechazos
  y respuesta tardía contra el transporte real). Los rechazos se comprueban en local con estados sintéticos; **no**
  se probó contra Codex, así que esta puerta de la etapa 1 sigue abierta.
- **Optimización de la confirmación**: ver mediciones.

## Mediciones (2026-11-14)

`KrabzikTests/PixelArt/PixelArtCorpusTests.swift`. El spec pide medir antes de publicar el formato.

| Documento | Confirmar un trazo | Guardar | Abrir | Archivo |
|---|---|---|---|---|
| Sprite 64 × 64, 3 capas, 8 fotogramas, 150 trazos | 3 ms (Release) · 11 ms (Debug) | 0,2 s · 1,6 s | 0,13 s · 1,4 s | 513 KB (3,4 KB por revisión) |
| Ilustración 512 × 512, 4 capas, 60 trazos de 400 px, 768 bloques | 17 ms · 130 ms | 0,37 s · 5,9 s | 0,25 s · 5,4 s | 962 KB |

Hallazgo: **confirmar un trazo reescribe el estado entero** (recodifica y vuelve a hashear todos los bloques,
copia el almacén y el mapa de revisiones). El costo crece con la cantidad de bloques: con los 65.536 del tope sería
del orden de segundos por trazo. No bloquea la etapa 1, pero hay que resolverlo antes de la etapa 3, que es
donde un trazo tiene que sentirse inmediato: codificar de forma incremental reutilizando las referencias de las
celdas y fotogramas que la diferencia (`PixelStateDiff`) ya identifica como sin cambios. No se resuelve recortando
historia.

Los topes de PXA-01 §6 se mantienen: nada de lo medido obliga a moverlos.

## Cómo se prueba

`scripts/verify.sh` corre todo. Para iterar sin compilar la app entera, un paquete SwiftPM temporal puede apuntar
a `Krabzik/PixelArt` y `KrabzikTests/PixelArt` con el módulo llamado `Krabzik` (las pruebas hacen
`@testable import Krabzik`); solo hace falta Foundation, CryptoKit, Compression, CoreGraphics e ImageIO.

Las pruebas incluyen mutaciones deliberadas de las reglas de alcance, bloqueo, base obsoleta, conflicto de archivo,
huérfanos y CRC: cada una hace fallar al menos una prueba.
