# PXA-10 · Selección, portapapeles y transformaciones

| | |
|---|---|
| **Estado / etapa** | Especificado, no implementado · [3](ETAPA-03.md) |
| **Dependencias** | PXA-01/02/03/04/06/09 |

## Objetivo y selección

Selección binaria del lienzo, independiente de píxeles y sin feathering. Ofrecer rectángulo, lazo
y varita por color; reemplazar, sumar, restar e intersectar mediante selector visible. Shift suma,
Option resta y ambos intersectan mientras el gesto está activo, salvo campos de texto. Seleccionar
todo, invertir y deseleccionar tienen acciones de menú. «Sin selección» permite toda la celda;
«selección vacía» permite ninguna: no normalizarlas al mismo estado.

Rectángulo: caja inclusiva. Lazo: polígono cerrado al soltar, incluye centros dentro según regla
par-impar, puntos en arista incluidos; intersecciones del rayo usan intervalos de Y semiabiertos
para no contar vértices dos veces. Menos de tres centros distintos da selección vacía. Varita
usa búsqueda exacta por ID/RGBA, vecindad de cuatro y opción contigua/no contigua explícita.

Crear/modificar selección es estado auxiliar; no agrega revisión artística. Confirmar una operación
sobre ella conserva máscaras anterior/posterior en el historial. Escape durante la selección
restaura la máscara previa. Cambiar de fotograma conserva la selección geométrica del lienzo.

## Copiar, cortar y pegar

Copiar toma la celda activa dentro de la máscara, nunca la composición por omisión. «Copiar
combinado» toma capas visibles y produce color libre. Copiar sin selección usa el lienzo completo.
Publicar PNG para intercambio y una representación privada versionada para preservar máscara,
dimensiones, clases de píxel y definiciones de colores usados. Tratar esa representación como
entrada validable, con límites de PXA-01; no contiene rutas, scripts ni historia del documento.

La representación privada no es un nuevo archivo de proyecto. Guarda documento-ID/revisión de
origen solo como procedencia, y una tabla local ID → definición. En la misma instancia/revisión,
reutilizar un ID únicamente si su definición coincide. Tras editar la paleta o pegar en otro
documento, no identificar colores por ID desnudo: crear entradas equivalentes o permitir al usuario
mapearlas a existentes. Conservar nombres distintos aunque RGBA coincida, salvo mapeo explícito.
Falta de capacidad ofrece pegar como libre, mapear o cancelar; nunca desvincular sin elección.

Cortar publica primero el portapapeles y luego borra los píxeles elegidos en una transacción.
Si falla la publicación o una restricción, no borra nada. El corte queda confirmado independientemente
del pegado posterior y puede deshacerse. Copiar una selección explícita vacía no cambia portapapeles.

Pegar crea una selección flotante sobre la celda activa. Coloca el contenido en el centro visible
ajustado a píxeles; «Pegar en posición original» usa coordenadas fuente si caben. Preview distingue
transparencia/recorte y vínculos nuevos. Enter o botón Aplicar confirma; Escape cancela. Guardar,
exportar, cambiar de celda/pestaña o cerrar con pegado flotante pide Aplicar/Descartar/Cancelar;
ninguna de esas acciones lo confirma implícitamente. Autoguardado conserva solo transacciones completas.

Al pegar, píxeles vacíos del payload no reemplazan destino por defecto. «Reemplazar también
transparentes» es opción explícita; un vínculo de alfa cero sigue siendo contenido y sí se pega.
La selección destino limita escritura si existe; una máscara origen conserva su forma al desplazar.
Importar imágenes del portapapeles sin representación privada produce RGBA libre, con reglas de
perfil/límites iguales a PXA-15. Esa dependencia solo habilita el pegado PNG al completar etapa 6;
en etapa 3 funciona el intercambio privado validado y Copiar PNG de salida.

## Mover y transformar

Mover selección desplaza su contenido sobre la misma celda en coordenadas enteras. Preparar desde
una instantánea: borrar origen seleccionado y escribir destino en el mismo commit, sin autoarrastre
por solapamiento. Vacíos del origen no limpian destino salvo la opción explícita anterior. Una copia
movida (Option-arrastrar) deja origen intacto. Flechas mueven 1 px y Shift-flechas 10 px mientras
hay transformación flotante; fuera de ella las flechas siguen la navegación de foco de PXA-06.

Voltear horizontal/vertical y girar 90/180/270° operan sobre la caja de selección con origen en
su esquina superior izquierda. Rotación de 90° cambia ancho/alto conservando esa esquina; se
puede recolocar antes de aplicar. Máscara y contenido se transforman juntos. Sin selección,
el comando propone la celda completa, no todo el documento animado.

Escalar selección acepta dimensiones enteras positivas dentro del lienzo máximo, sin suavizado.
Muestreo vecino más cercano por centros: índice fuente floor((destino+0,5)·origen/destinoTotal),
acotado al último índice. Se preserva el valor libre/vinculado, sin interpolar IDs. Mostrar que
reducir descarta muestras. No hay rotación arbitraria ni filtros de interpolación en 1.0.

Si hay contenido no vacío fuera del lienzo al confirmar, mostrar recuento de recorte y pedir
confirmarlo o cancelar; deshacer lo recupera. No conservar píxeles invisibles fuera del lienzo
en objetos de borde. Un bloqueo de transparencia incompatible rechaza la operación completa.

## Tamaño del documento

Distinguir «Tamaño del lienzo…» (cambia límites, con anclaje de 9 posiciones) y «Escalar imagen…»
(remuestrea todas las celdas con vecino más cercano). Ambos afectan todos los fotogramas y capas,
validan bloqueos y presupuestos antes de confirmar, y son una única revisión. La expansión agrega
vacío, no color de fondo. El anclaje central usa floor de la diferencia de tamaño por eje.

«Recortar a selección» usa su caja rectangular, no elimina píxeles dentro de la caja por quedar
fuera de la máscara. Selección vacía deshabilita recortar. Mostrar dimensiones y cantidad de celdas
afectadas; advertir recorte de contenido no vacío. Actualizar máscara/centro de vista; historia
recupera dimensiones y selección anteriores. Secuencias y duraciones se conservan.

## Aceptación, pruebas y riesgos

- Máscaras con agujeros, polígonos autointersecados, selección vacía y operaciones booleanas.
- Portapapeles entre documentos con IDs iguales/colores distintos y paleta llena; sin pérdida implícita.
- Movimiento solapado, pegado transparente, vínculos invisibles, recorte y cancelación.
- Cuatro giros de 90° y dos volteos recuperan datos exactos; escalado tiene goldens de centros.
- Cambios globales conservan todas las celdas y referencias válidas; bloqueo rechaza antes de modificar.
- Guardar/reabrir y deshacer recupera los píxeles recortados y clases originales.

El formato privado del portapapeles tendrá esquema y límite explícitos al implementar; no usar
serialización de objetos ejecutables. El requisito de confirmación se limita a recortes reales
o gestos pendientes, sin confirmación extra para cada transformación ordinaria reversible.
