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
| `PixelArtDocument`, `PixelArtFile`, `PixelArtFileStore`, `PixelArtPreview` | Documento abierto, lectura/validación/escritura del `.pxa`, guardado atómico con huella y miniatura |
| `PixelArtRecovery`, `PixelArtRecoveryPlanner` | Recuperación local por trabajo (`recoveryID`, índice, generaciones, descarte durable) y la matriz de decisión de PXA-08 |

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
- **Recuperación local por trabajo** (PXA-08): `<carpeta>/<recoveryID>/index.json` + `g<generación>-<UUID>.pxa`.
  El `recoveryID` es propio y **sobrevive a un cambio de ruta**; nunca se deriva de la ruta ni del documento-ID. El
  índice es versionado (1), con propietario, estado (activo/pendiente/descartado), ruta original como metadato, huella
  base y hasta dos generaciones ordenadas por número, no por reloj. Se reemplaza de forma atómica; un descarte se
  registra antes de borrar, así una caída durante la limpieza no lo resucita. Carpeta 0700, archivos 0600. Un índice
  ilegible o de otra versión se informa y no se borra. `PixelArtRecoveryPlanner` decide cada fila de la matriz de
  PXA-08 §5 (recuperar en el original, copia, borrador, solo vista, enfocar, nada válido) sin tocar disco.

## Qué falta

- **Etapa 3**: relleno contiguo, formas, simetría, transformaciones de selección, combinar capas y la
  rasterización de gestos. El motor ya acepta `writePixels` y `resizeCanvas`; las herramientas los usarán.
- **Prueba técnica de PXA-04 §7** (render de 32 × 32 a Codex, tabla de cuatro colores, edición localizada, rechazos
  y respuesta tardía contra el transporte real). Los rechazos se comprueban en local con estados sintéticos; **no**
  se probó contra Codex, así que esta puerta de la etapa 1 sigue abierta.
- **Recuperación y cuotas**: el almacén no impone una cuota global (E3 de la revisión de seguridad) y no hay
  planificador de capturas que lo use; eso es de la etapa 2.

## Mediciones (2026-11-14)

`KrabzikTests/PixelArt/PixelArtCorpusTests.swift`. El spec pide medir antes de publicar el formato.

| Documento | Confirmar un trazo | Guardar | Abrir | Archivo |
|---|---|---|---|---|
| Sprite 64 × 64, 3 capas, 8 fotogramas, 150 trazos | 3 ms (Release) · 11 ms (Debug) | 0,2 s · 1,6 s | 0,13 s · 1,4 s | 513 KB (3,4 KB por revisión) |
| Ilustración 512 × 512, 4 capas, 60 trazos de 400 px, 768 bloques | 17 ms · 130 ms | 0,37 s · 5,9 s | 0,25 s · 5,4 s | 962 KB |

Hallazgo y corrección: **confirmar un trazo reescribía el estado entero** (recodificaba y volvía a hashear todos los
bloques). Con 16.384 bloques (8 capas × 8 fotogramas de 512 × 512) costaba **416 ms** en Release, 16 veces lo de
1.024 bloques. `PixelEncodingMemo` guarda, por fotograma, celda y bloque, el valor codificado y su referencia; al
confirmar, lo que es igual al valor anterior reutiliza la referencia sin hashear ni serializar. El resultado es
idéntico byte a byte al de una codificación completa (lo comprueban las pruebas de equivalencia y las secuencias
aleatorias). Ahora:

| Documento | Confirmar un trazo de 200 px (Release) |
|---|---|
| 1.024 bloques | 1,5 ms |
| 16.384 bloques | 6,4 ms (antes 416 ms) |

Queda una parte lineal pequeña: copiar el almacén (un diccionario por hash) y sumar sus bytes en cada confirmación,
y la comparación de bloques contra la memoria, que es instantánea cuando comparten almacenamiento. Con los 65.536 del
tope se estima ~25 ms (extrapolado, no medido). **La primera confirmación tras abrir un archivo codifica el estado
entero una vez**, porque la memoria empieza vacía. Deshacer y rehacer no la invalidan: la memoria solo se usa si el
valor es igual. No se resuelve recortando historia.

Los topes de PXA-01 §6 se mantienen: nada de lo medido obliga a moverlos.

## Cómo se prueba

`scripts/verify.sh` corre todo. Para iterar sin compilar la app entera, un paquete SwiftPM temporal puede apuntar
a `Krabzik/PixelArt` y `KrabzikTests/PixelArt` con el módulo llamado `Krabzik` (las pruebas hacen
`@testable import Krabzik`); solo hace falta Foundation, CryptoKit, Compression, CoreGraphics e ImageIO.

Las pruebas incluyen mutaciones deliberadas de las reglas de alcance, bloqueo, base obsoleta, conflicto de archivo,
huérfanos y CRC: cada una hace fallar al menos una prueba.
