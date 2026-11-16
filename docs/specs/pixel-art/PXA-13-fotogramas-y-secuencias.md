# PXA-13 · Fotogramas, celdas y secuencias

| | |
|---|---|
| **Estado / etapa** | Especificado, no implementado · [5](ETAPA-05.md) |
| **Dependencias** | PXA-01/02/04/06/11 |

## Modelo y selección

Fotogramas como columnas, capas como filas. Un ID de fotograma tiene duración propia y referencia
celdas por capa-ID. La selección temporal es una lista de IDs, independiente de la selección de
píxeles. Clic selecciona uno, Shift rango contiguo en orden visible, Command alterna pertenencia;
siempre hay una celda activa para dibujo. El inspector muestra qué cambia el comando: contenido
de celdas, fotogramas completos o secuencia. No equiparar un marcador de contenido con un keyframe.

## Operaciones

| Acción | Regla |
|---|---|
| Nuevo fotograma | Insertar después del activo, ID nuevo, todas sus celdas vacías; hereda duración activa |
| Duplicar fotogramas | Copia de todas las capas y duraciones, IDs nuevos, independencia de edición |
| Reordenar | Cambia orden global conservando IDs/duraciones; una selección múltiple conserva su orden interno |
| Eliminar | Quita fotogramas y sus referencias en secuencias; última columna no se puede eliminar |
| Vaciar celdas | Elimina contenido de las celdas seleccionadas, sin eliminar capas/fotogramas |
| Copiar/pegar celdas | Copia valores, conserva huecos explícitos y ofrece reemplazo de destinos |
| Duración | Entero 1–60.000 ms, una operación para todos los IDs elegidos |

Duplicar agrega después del último seleccionado en orden de línea de tiempo. No modifica las
secuencias automáticamente: ofrecer incluir duplicados en la secuencia activa mediante opción
explícita del mismo comando, inicialmente desactivada. Crear/duplicar inicia con celda activa en
la primera columna nueva. Eliminar selecciona la vecina y deshacer restaura IDs originales.

Mover/copiar celdas se limita a un documento y a un rectángulo temporal de la matriz en 1.0;
si hay huecos no seleccionados, conservar una máscara de celdas. No aplastar destinos no elegidos.
No expandir el número de fotogramas implícitamente: el usuario elige crear los que faltan o cancelar.
Un movimiento solapado se evalúa contra snapshot previo y publica una sola transacción.

Capas bloqueadas: leer/duplicar sus celdas a fotogramas nuevos está permitido; vaciar/reemplazar
o eliminar un fotograma que contenga contenido suyo se rechaza. Reordenar fotogramas o cambiar
tiempos no modifica sus píxeles y está permitido como operación temporal explícita. Una eliminación
que solo quitaría celdas vacías de capas bloqueadas puede continuar. Bloqueo de transparencia se
evalúa por posición al reemplazar/vaciar celdas existentes; no aplicarlo a una nueva celda como si
fuese un destino vacío bloqueado. La excepción autoriza duplicar sin cambios; dibujar o proponer
contenido nuevo distinto en una capa bloqueada sigue prohibido aunque la celda sea nueva.

## FPS y duraciones

El campo FPS es una forma de asignar tiempos, no otra fuente de verdad. Aceptar 1–120 FPS con
hasta tres decimales, representado como racional decimal exacto. Para N fotogramas, calcular
fronteras t(i)=redondear(i·1000/FPS) y duración(i)=t(i+1)−t(i), con empates hacia arriba, usando
el orden de selección. Así 24 FPS no acumula el error de redondear cada columna a 42 ms.

Aplicar FPS requiere selección explícita de alcance y confirma una transacción. Si se modificó
una duración individual, mostrar «Tiempos variables» en vez de afirmar un FPS uniforme. Se puede
mostrar FPS medio como dato secundario, nunca usarlo para sobrescribir duraciones al guardar.

## Secuencias

ID/nombre, lista ordenada única de fotogramas, dirección y loop según PXA-01. Crear desde selección
en su orden de timeline; un fotograma puede pertenecer a varias secuencias. Reordenar la timeline
no reordena automáticamente la lista de una secuencia existente. Editar la lista es acción separada.
Eliminar un fotograma lo retira de todas; secuencia vacía se elimina en la misma transacción.

Duración pertenece al fotograma: cambiarla afecta a todas las secuencias que lo contienen. Mostrar
esa relación en inspector. No agregar una duración por secuencia que el formato no pueda representar.
Nombres repetidos son válidos; IDs desambiguan exportación. Alcance «Todos» usa la timeline global;
alcance de secuencia usa exactamente su lista, no un rango implícito entre extremos.

## Aceptación, pruebas y riesgos

- Operaciones sobre 1/8/1.024 fotogramas, con rechazo del 1.025 antes de modificar.
- Solapamientos, selección temporal discontinua, máscaras de celdas y celdas vacías transparentes.
- Duplicar no enlaza edición; reordenar no intercambia imágenes al reutilizar índices de UI.
- 24/30/60 FPS y tiempos variables: duración total coincide con fronteras calculadas.
- Secuencias superpuestas y eliminación/undo restauran membresía, IDs y duraciones.
- Bloqueos y falta de memoria no dejan medio rango aplicado; guardar/reabrir conserva todo.

Es fácil confundir selección temporal y geométrica: cada comando indica ambas y congela su
alcance al empezar. No iniciar reproducción para verificar un cambio estructural sin acción del usuario.
