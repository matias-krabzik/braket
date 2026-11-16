# PXA-11 · Edición de capas

| | |
|---|---|
| **Estado / etapa** | Especificado, no implementado · [3](ETAPA-03.md) |
| **Dependencias** | PXA-01/02/03/04/06 |

## Objetivo y modelo

Una pila de capas compartida por todos los fotogramas, sin grupos en 1.0. Cada operación estructural
actúa sobre la pila completa aunque el usuario vea un solo fotograma. Los píxeles se editan en la
celda activa. Listar de frente a fondo, almacenar de fondo a frente como define PXA-01.

## Acciones y reglas

| Acción | Efecto en todos los fotogramas |
|---|---|
| Nueva capa | ID nuevo encima de la activa; todas las celdas vacías; activa en el fotograma actual |
| Duplicar capa | ID/nombre nuevos, copia de todas sus celdas y opacidad/visibilidad; inicialmente desbloqueada |
| Renombrar | Mismo ID; nombre dentro del límite; nombres repetidos permitidos |
| Reordenar | Nueva posición única; las celdas siguen sus IDs, nunca los índices visuales |
| Eliminar | Quita capa y todas sus celdas del estado actual; historia las retiene |
| Visibilidad/opacidad | Propiedad global de capa; preview y commit al terminar gesto |
| Bloquear / bloquear transparencia | Propiedad global y reversible; respeta PXA-03/PXA-04 |

Al eliminar la activa, seleccionar la vecina más cercana conservando fotograma. No eliminar la
última capa; ofrecer borrar su contenido mediante acción distinta si está desbloqueada. Duplicar
una capa bloqueada solo la lee y crea otra editable; no modifica la protegida. Mostrar cantidad
de fotogramas afectados en eliminación/duplicación, sin una confirmación destructiva para cada
operación recuperable. Eliminar con presupuesto insuficiente para registrar historia se rechaza.

Reordenar no puede cambiar la posición relativa a una capa bloqueada: ni moverla ni atravesarla.
Mover dos capas desbloqueadas dentro del mismo segmento permitido sí es válido. Crear/duplicar
no cambia la posición relativa de las capas preexistentes. Visibilidad, nombre y desbloqueo manual
son las excepciones explícitas de PXA-04; Codex no adquiere estas excepciones para capas bloqueadas.

Opacidad en UI 0–100 %, cuantizada a 0–255 al confirmar (redondeo más cercano, empate arriba).
Mostrar el porcentaje resultante, sin acumular error al reabrir. Capa opacidad cero conserva píxeles
y vínculos. Bloqueo de transparencia protege alfa por posición, no opacidad de capa.

## Combinar con la capa inferior

Disponible para dos capas adyacentes, visibles y sin bloqueo de contenido/transparencia. Combina
sus celdas de todos los fotogramas con el renderer común; mantiene ID/nombre de la inferior, elimina
la superior y deja opacidad 255 y visibilidad verdadera en la resultante. No hay aplanado general,
mezcla de modos ni combinación con capa oculta en 1.0.

Como la composición puede depender de colores vinculados y opacidades, el resultado se materializa
como RGBA libre. Preview informa número de vínculos que se perderán y posibles diferencias por
cuantización al componer luego con otras capas. No prometer igualdad matemática del resultado sobre
cualquier fondo con solo RGBA8. Antes/después muestra la composición completa y las diferencias
reales; aplicar es una decisión explícita. Deshacer recupera ambas capas, IDs, propiedades y vínculos.

No se cambia la paleta ni se eliminan sus entradas sin uso al combinar. Las celdas vacías siguen
dispersas. Si el resultado excede límites se rechaza completo, sin combinar solo algunos fotogramas.

## UI, historia y validación

Botones y menú contextual en encabezado/nombre de capa; arrastrar muestra línea de inserción y
alcance global. Ojos/candados de etapa 2 pasan a interactivos con accesibilidad y ayudas. Atajos
globales no se alteran. Un arrastre de orden, opacidad o confirmación de nombre es una revisión.
Cancelar una edición vuelve al valor anterior, sin producir revisiones intermedias.

La matriz puede contener muchas capas: virtualizar filas sin cambiar selección al reciclar vistas.
Los cambios estructurales actualizan presets/alcances que referencian IDs; presets inválidos se
marcan para revisión, no se reasignan al índice que ocupó la capa eliminada. Propuestas pendientes
de Codex quedan obsoletas al cambiar cualquier revisión, conforme a PXA-04.

## Aceptación, pruebas y riesgos

- Crear/duplicar/eliminar/reordenar con 1, 3 y 128 capas; intento 129 rechazado sin cambios.
- Duplicar/editar una celda no altera original ni otros fotogramas; conservar capas vacías.
- Bloqueos, transparencias, opacidad cero, capas ocultas e IDs referidos por presets/propuestas.
- Combinar a varios fotogramas muestra/deshace pérdida de vínculos y cuantización.
- Guardar/reabrir y recorrer ramas conserva estructura exacta, no solo el bitmap compuesto.

El alcance global de capa puede sorprender en animación: indicarlo en la UI y no crear una
pila distinta por fotograma para evitar el aviso. Los riesgos se resuelven en el contrato del
modelo, no con ajustes visuales que oculten celdas afectadas. Pruebas pendientes de implementación.
