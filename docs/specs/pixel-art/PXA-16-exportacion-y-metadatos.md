# PXA-16 · Exportación, GIF y metadatos de sprites

| | |
|---|---|
| **Estado / etapa** | Especificado, no implementado · [6](ETAPA-06.md) |
| **Dependencias** | PXA-01/03/07/12/13/14 |

## Contrato común

**Exportar…** abre una hoja con formato, alcance, escala, transparencia/fondo, preview y destino.
Congelar una revisión completa en memoria, aunque no esté guardada; exportar no guarda `.pxa`,
no cambia historia/paleta ni lo marca limpio. No exportar una propuesta Codex no aplicada ni un
pegado flotante. Resolver el gesto pendiente o cancelar; elegir Original/Propuesta no autoriza exportar IA.

Alcance: fotograma activo, lista elegida, secuencia o timeline completa. Imagen PNG individual
solo admite un fotograma. Por defecto componer capas visibles; «Solo capa activa» es alternativa
explícita. Sin onion skin, selección, cuadrícula, reglas ni fondo ajedrezado. No recortar a selección
implícitamente. Secuencias usan el recorrido expandido de PXA-14 y sus duraciones, incluidos IDs repetidos.

Escala entera 1–32 con vecino más cercano. Fondo transparente por defecto; fondo sólido se compone
en sRGB lineal con la misma regla del lienzo. Límites de salida: cada imagen hasta 8.192 por eje y
64 millones de píxeles; hasta 2 GiB estimados de RGBA sin comprimir sumando imágenes de un trabajo.
Estos topes son propios de exportación, no cambios en el `.pxa`. Validar antes de generar y ofrecer
menor escala/alcance si se exceden; no reducir automáticamente. Procesar fotogramas en streaming.

## Formatos

| Salida | Contrato |
|---|---|
| PNG | RGBA8 sRGB, dimensiones escaladas, alfa completo; transparencia cero normalizada |
| Secuencia PNG | Una imagen por visita del recorrido, nombres `base-0001.png` en adelante, más `animation.json` |
| Hoja de sprites | Grilla uniforme de visitas; PNG + JSON; sin rotación, trim ni packing automático |
| GIF | Animación cuantizada con política de alfa/tiempos visible; no altera la fuente |

Las secuencias PNG conservan los tiempos en JSON: el formato PNG individual no transmite por sí
solo la duración. Mantener una imagen por visita incluso si los píxeles son idénticos; no fusionar
fotogramas y alterar metadatos. En PNG no cuantizar colores para reducir tamaño por omisión.

## Grilla y metadatos JSON 1.0

Hoja: columnas elegidas entre 1 y número de visitas, filas calculadas con techo. Margen exterior
y separación horizontal/vertical enteros 0–256, medidos en píxeles de salida después de escalar.
Huecos transparentes o con el fondo elegido. Celdas vacías de la última fila no son fotogramas.

Documento JSON UTF-8, formato `braket.sprite-export`, versión 1. No incluye rutas absolutas,
prompts ni historial. Campos de contrato:

| Campo | Significado |
|---|---|
| `layout` | `sequence` o `sheet` |
| `source` | Documento-ID, revisión-ID, secuencia-ID opcional y tamaño de lienzo sin escalar |
| `scale` | Escala entera aplicada |
| `images` | Nombres relativos de archivo, ancho/alto resultantes, hash SHA-256 de cada archivo |
| `frames` | Array en orden de visita, cada elemento con índice único base 0, frame-ID fuente, imageIndex y rectángulo x/y/w/h |
| `durationMs` por frame | Duración fuente exacta de esa visita |
| `playback` | `expanded=true`, loop booleano; reproducir arrays en orden una vez por ciclo |
| `grid` | Solo sheet: columnas, filas, margen y separación de salida |

Un frame-ID puede aparecer más de una vez por pingPong; el índice de exportación es la identidad
única de cada visita. En sequence el rectángulo es la imagen completa. En sheet cada rectángulo
es la celda escalada; no repetir una dirección que haga aplicar pingPong dos veces. No emitir
referencias a secuencias fuera del alcance exportado. Nombres se validan como basenames sin rutas.

## GIF: pérdidas explícitas

GIF89a usa índices de color y transparencia por índice; sus retardos se expresan en centésimas
de segundo. Esa diferencia con RGBA y milisegundos requiere conversión visible. Referencia primaria:
[especificación GIF89a alojada por W3C](https://www.w3.org/Graphics/GIF/spec-gif89a.txt).

Decisiones de producto para 1.0:

- Una paleta global por animación, máximo 256 entradas; reservar una para transparencia si se usa.
  Cuantizar todos los fotogramas con PXA-12, sin dithering, para evitar paletas que cambien cada frame.
- Alfa parcial exige elegir **Fondo sólido** o **Transparencia por umbral**. No aplicar una opción
  con pérdida sin que aparezca en preview. Umbral predeterminado propuesto 128: alfa < umbral pasa
  a transparente; el resto se vuelve opaco con RGB resuelto. Permitir umbral 1–255.
- Si solo hay alfa 0/255 y ≤255 colores visibles, conservarlos exactamente con índice transparente.
  Un fotograma totalmente transparente sigue siendo un frame, no se omite.
- Convertir tiempos con fronteras acumuladas redondeadas a 10 ms, empates arriba. Para compatibilidad
  del producto, imponer mínimo exportado de 20 ms por visita; si una frontera exige menos, desplazarla
  y las siguientes. Mostrar duración total real, visitas ajustadas y diferencia respecto de la fuente.
- El usuario confirma ajustes al exportar; no escribir tiempos aproximados de vuelta en `.pxa`.
- Emitir frames de lienzo completo y una política de descarte que reconstruya exactamente cada
  frame convertido al decodificar, sin rastros de frames previos. Validar transparencia con dos
  decodificadores; no asumir que un índice transparente borra por sí solo el contenido anterior.
- Loop infinito solo si el alcance está configurado para loop; sin loop reproducir una vez. La
  extensión de loop elegida por el encoder se verifica en lectores, no se confunde con demora.

El preview GIF muestra píxeles/tiempos ya convertidos, no el original de mayor calidad. Comportamiento
de visores externos puede variar; la garantía del archivo se comprueba decodificando su contenido.

## Destinos, publicación y presets

PNG/GIF individual: temporal hermano, verificar decodificación y reemplazar atómicamente solo
tras resolver colisión de nombre y comprobar huella del destino. Secuencia/hoja+JSON: crear una
carpeta de entrega nueva, preparar todas las salidas en carpeta staging hermana, validar nombres,
hashes y referencias, y publicar la carpeta por renombrado. Si el destino ya existe, elegir otro
nombre; 1.0 no mezcla ni reemplaza parcialmente carpetas ajenas. No prometer atomicidad de N archivos
escritos uno a uno en una carpeta existente. Mostrar el destino exacto antes de exportar.

Cancelar/error elimina solo temporales propios y conserva originales. Un fallo no deja JSON
apuntando a imágenes incompletas en una entrega anunciada como exitosa. No usar `.pxa` como destino
de salida. Guardar preset conserva parámetros e IDs del alcance, no destino absoluto. Al reutilizar,
revalidar IDs y nombres; no reinterpretar índices viejos como otros fotogramas.

## Aceptación, pruebas y riesgos

- PNG: igualdad RGBA con renderer a escala 1 y replicación exacta a escalas enteras.
- Secuencia/hoja: revisar orden, frames vacíos, grilla, márgenes, hashes y JSON; reconstruir cada frame.
- GIF: alfa0/255/parcial, más de 256 colores, tiempos 1/16/17/125 ms, pingPong y loop.
- Imagen editada durante exportación: salida corresponde íntegra a la revisión congelada.
- Destino ocupado/cambiado, fallo de disco y cancelación en último frame: no entrega parcial declarada válida.
- Ninguna exportación altera paleta, historia ni estado de guardado del `.pxa`.

Usar encoders disponibles se decide al implementar; la elección no puede relajar estas pruebas
ni sustituirlas por comprobar solo que existe un archivo. Todos los resultados quedan pendientes.
