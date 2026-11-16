# PXA-15 · Importación de imágenes y hojas de sprites

| | |
|---|---|
| **Estado / etapa** | Especificado, no implementado · [6](ETAPA-06.md) |
| **Dependencias** | PXA-01/03/10/12/13 |

## Entradas y destino

Comando **Importar imagen…** desde Archivo y editor `.pxa`, selección PNG individual. Abrir un
PNG mediante el explorador sigue siendo preview; ofrecer «Editar como pixel art…» para crear un
borrador `.pxa` sin modificar PNG. Arrastrar PNG al lienzo abre opciones de importación; arrastrar
`.pxa` sigue abriendo documento. No reinterpretar un PNG como `.pxa` por cambiar su extensión.

Opciones: nuevo documento, nueva capa del fotograma activo, o hoja de sprites a nuevos fotogramas.
Si no hay documento, solo nuevo documento. Importar a capa existente se hace mediante pegado
confirmado con PXA-10, no reemplazando silenciosamente la celda activa. Nunca necesita conexión IA.

## Decodificación y color

Inspeccionar formato real, dimensiones y tamaño antes de decodificar. PNG estático; si contiene
animación, informar «PNG animado no admitido como animación» y ofrecer importar solo la imagen
predeterminada de forma explícita o cancelar. No tratar un archivo truncado como un lienzo vacío.

Límites de entrada propuestos: archivo hasta 256 MiB, eje hasta 16.384 y total hasta 64 millones
de píxeles decodificados; cada fotograma resultante cumple el máximo 4.096 por eje y todos los
límites globales de PXA-01. No asignar memoria usando tamaños no validados. Decodificar fuera del
hilo de UI con cancelación, sin dependencias del archivo después de confirmar.

Convertir perfil a sRGB RGBA8 según PXA-03. PNG de 16 bits se convierte con redondeo al entero
más cercano y aviso de reducción a 8 bits; no truncar bits altos sin indicar conversión. Mostrar
el render convertido en preview. Por defecto todos los píxeles son libres; PNG indexado no
crea vínculos automáticamente. Opción «Crear/vincular paleta» utiliza propuesta de PXA-12.

## Imagen individual

Nuevo documento: dimensiones fuente si cumplen límites, una capa con contenido y un fotograma
de 125 ms, revisión raíz identificada como importación. La raíz contiene lo importado; no permite
deshacer hasta un estado anterior inexistente. Destino activo: crear capa nueva, insertar en
fotograma activo y conservar vacíos los demás. Se puede elegir origen de colocación en píxeles.

Si no cabe, ofrecer recortar con preview o escalar explícitamente mediante vecino más cercano;
no expandir el lienzo ni suavizar automáticamente. Una expansión elegida afecta todo el documento
y usa la transacción global de PXA-10. En un documento existente toda importación es una acción
reversible, con colores/capas/fotogramas nuevos incluidos en el mismo commit.

## Hoja de sprites

Formulario: ancho/alto de celda, margen X/Y, separación X/Y, número de filas/columnas y orden por
filas o por columnas. Valores enteros no negativos salvo celda/filas/columnas positivos. Rectángulo
de celda (c,r): origen margen+(índice×(tamaño+separación)); tiene exactamente el tamaño elegido.
Marcar sobre la imagen todas las celdas; no inferir geometría usando el contenido transparente.

Validar que todas las celdas completas que se importan caben. Si hay remanentes de imagen fuera
de la grilla, mostrar y pedir ignorarlos explícitamente. Permitir seleccionar celdas; por defecto
todas. Mantener celdas transparentes como fotogramas vacíos, sin omitirlas automáticamente.

Nuevo documento: tamaño de celda, una capa y fotogramas en orden elegido. Documento existente:
nueva capa y fotogramas insertados después del activo; el resto de capas queda vacío en las
columnas nuevas. No sobrescribir columnas preexistentes. Si la celda no coincide con tamaño del
lienzo, exigir colocar/recortar/escalar explícitamente con preview, sin distorsión implícita.

Duración común inicial 125 ms, editable antes de importar. Opción crear una secuencia que agrupe
los nuevos IDs, nombre editable. No cargar automáticamente archivos JSON vecinos del disco. La
lectura de atlas de terceros queda fuera; la grilla visual basta para reimportar las hojas emitidas.

## Confirmación y errores

La UI muestra dimensiones, capas/fotogramas que se agregarán, estimación de recursos, conversiones
de color y recortes. Elegir archivo no modifica el documento. Congelar base y fuente validada;
si el documento cambia antes de Aplicar, recalcular con nueva base mediante elección explícita.
Si el archivo fuente cambia durante lectura, reintentar sobre una nueva copia coherente, sin
combinar bytes de dos versiones. Cancelar libera temporales y no crea una revisión.

Pegar PNG del portapapeles reutiliza esta decodificación, termina en selección flotante de PXA-10
y nunca agrega una ruta externa al `.pxa`. Si hay representación privada válida, tiene prioridad
para conservar vínculos; si está inválida, avisar antes de usar PNG como alternativa libre.

## Aceptación y pruebas futuras

- PNG RGBA/indexado/grises, 8/16 bits, perfil válido/ausente/inválido y alfa parcial/cero.
- Corruptos, dimensiones desbordadas, expansión excesiva y cancelación antes de confirmar.
- Grillas con margen/separación, orden por columnas, remanentes y fotogramas completamente transparentes.
- Documento existente y nuevo, límite de capas/fotogramas/bloques y varias capas bloqueadas.
- Guardar/reabrir no depende de la fuente y deshacer la importación completa restaura IDs/estado previo.

## Riesgos

La fuente puede ser mucho mayor que las celdas útiles. Inspeccionar/decodificar con presupuestos
antes de presentar miniaturas masivas. Importar un gráfico no justifica agregar metadatos ajenos
o contenido ejecutable al documento.
