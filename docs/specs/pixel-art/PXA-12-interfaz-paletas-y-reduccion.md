# PXA-12 · Inspector de paletas, extracción y reducción

| | |
|---|---|
| **Estado / etapa** | Especificado, no implementado · [4](ETAPA-04.md) |
| **Dependencias** | PXA-03/06/09/10/11 |

## Objetivo e interfaz

Habilitar creación/edición de muestras en el inspector acordado, sin confundir elegir color de
dibujo con editar una definición usada por todo el proyecto. Una muestra se selecciona con clic;
su menú contextual y botón Editar abren definición, nombre, RGBA y bloqueo. Arrastrar reordena
IDs sin cambiar píxeles. Selector libre separado, con etiquetas «Libre» y «Vinculado» explícitas.

Aceptar HEX de 6/8 dígitos con # opcional, RGBA8 y selector visual; seis dígitos implican alfa 255.
Entrada incompleta no modifica el documento; confirmar/cancelar conserva la transacción. Arrastrar
un color previsualiza desde la base y confirma una acción al terminar, no una revisión por tick.
Entrada bloqueada se puede usar para pintar y desbloquear manualmente; su definición no cambia.

Acciones: agregar, renombrar, editar, reordenar, bloquear, eliminar, fusionar, extraer del contenido,
vincular coincidencias, desvincular y adaptar a otra paleta. Eliminar/fusionar usa las reglas de
PXA-03. No limpiar entradas sin uso automáticamente. Mostrar usos globales y los del alcance activo.

## Alcances y tabla de correspondencias

Antes de una conversión, resolver selección/celda, capa en todos los fotogramas, fotograma,
secuencia o documento conforme a PXA-04. El contenido externo a ese alcance no cambia. Una edición
global de entrada no se presenta como edición de selección. El recoloreado local clona entradas
cuando es necesario y muestra capacidad antes/después.

Preview presenta Original/Resultado en el mismo viewport, una tabla fuente → destino, cantidad
de píxeles que cambian apariencia, cantidad que cambia solo vínculo y efecto en alfa. Fuente
identifica ID y nombre si es vinculada; colores libres se agrupan por RGBA exacto. El usuario
puede fijar correspondencias para conservar, por ejemplo, luces o contornos. Un destino puede ser
entrada existente/nueva o libre cuando la acción lo permite; cada fila lo dice explícitamente.

Editar un mapeo recalcula preview sobre la misma base; Aplicar confirma todo, Cancelar nada. Si
cambia revisión mientras se calcula, marcar obsoleto y recalcular sobre base actual con elección
del usuario. La validación aplica límites al estado final, no a una paleta temporal de trabajo.

## Extracción

Fuentes iniciales: píxeles de celdas del alcance (por defecto), o render compuesto de cada
fotograma elegido mediante opción explícita. La primera conserva colores antes de opacidad de
capa; la segunda puede producir colores nuevos por mezcla. Contar alfa cero como vacío para
extracción; no eliminar vínculos invisibles del documento por no aparecer en el histograma.

Con hasta 256 RGBA distintos, devolver colores exactos ordenados por frecuencia descendente y
RGBA lexicográfico como desempate, según PXA-03. Pedir menos colores o encontrar más de 256 abre
reducción, rotulada como aproximación. Extraer únicamente propone/crea muestras; no reasigna píxeles.

## Reducción determinista 1.0

Algoritmo de producto, independiente de Codex. Entrada: histograma ponderado del alcance, objetivo
K entre 1 y 256 y colores fijados por el usuario. Colores fijados cuentan dentro de K y no se
modifican. Si son más que K, rechazar. Sin píxeles visibles, no crear muestras ficticias.

1. Acumular RGBA exactos en streaming hasta 65.536 valores distintos. Si se supera, repetir el
   recorrido usando bins de 4 bits por canal RGBA (máximo 65.536). Cada bin produce el promedio
   RGBA8 ponderado por cantidad, redondeo al entero más cercano, empate arriba. Fusionar representantes
   iguales sumando pesos. Usar sumas enteras de 64 bits con validación de overflow.
2. Inicializar candidatos elegidos con los colores fijados. Si no hay ninguno, elegir el más
   frecuente, desempate RGBA lexicográfico.
3. Hasta K, elegir el candidato no elegido que maximice peso × distancia mínima a los elegidos,
   con la distancia lineal premultiplicada RGBA de PXA-03. Empates dentro de 10^-12: RGBA lexicográfico.
   Si ya no hay candidatos con distancia positiva, terminar con menos de K y mostrar el total real.
4. Orden final: fijados en su orden solicitado, luego orden de elección. Asignar IDs nuevos al
   materializar, con el asignador del documento. La tabla final de mapeo usa PXA-03 y ajustes manuales.

No hay dithering ni iteración aleatoria. Mostrar si se usaron bins y que el resultado es una
aproximación. El muestreo no puede depender del orden de iteración de un diccionario ni del hilo.
El histograma cuenta todos los píxeles del alcance; no escoger solo el primer fotograma.

Los bloqueos se validan después de calcular y antes de publicar. Si no existe una asignación que
conserve exactamente el alfa en una capa con bloqueo de transparencia, se rechaza esa conversión.
No inventar una excepción a PXA-03 para alcanzar K. Una paleta destino incompleta/invalidada nunca
se aplica parcialmente. La extracción sin aplicación sí puede proponerse como muestras independientes.

## Integración con importación y Codex

PXA-15 y PXA-16 reutilizan reducción sobre datos temporales, sin editar la paleta del `.pxa`.
La exportación GIF prepara su propia política de alfa antes de cuantizar. Una propuesta de Codex
puede aportar colores y mapeos, pero utiliza este preview/validador y no cambia el algoritmo de
una conversión manual por detrás. Guardar la tabla aplicada evita recalcular al rehacer.

## Aceptación y pruebas futuras

- UI distingue color de dibujo, definición global y reasignación local de forma verificable.
- Paletas de 0/1/16/256 entradas, RGBA duplicados con roles distintos, alfa parcial/cero y bloqueos.
- Convertir una paleta llena a otra llena en una transacción, sin exigir 512 entradas publicadas.
- Histograma exacto, umbral 65.536/65.537, bins y pesos producen resultados repetibles en varios hilos.
- Fixtures con rampa, colores raros de alto contraste, alfa y varios fotogramas; conservar fijados.
- Cancelación, revisión obsoleta, pérdida de capacidad y falta de memoria dejan intacto el documento.
- Deshacer/reabrir recupera clases e IDs; no hay limpieza invisible de entradas históricas.

## Riesgos

La reducción determinista no garantiza la mejor decisión artística; el preview y el mapeo manual
son parte del producto, no una compensación opcional. No confundir número de entradas de paleta
con número de colores compuestos visibles. Este spec cierra el algoritmo pendiente de PXA-03.
