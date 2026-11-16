# PXA-03 · Color libre y paleta vinculada

| | |
|---|---|
| **Estado** | Motor implementado en la etapa 1 (sin interfaz); ver `docs/pixel-art-engine.md` |
| **Área** | Modelo de color, herramientas y conversiones |
| **Depende de** | [PXA-01](PXA-01-formato-y-persistencia.md), [PXA-02](PXA-02-historial-persistente.md) |
| **Relacionado** | [PXA-04](PXA-04-operaciones-y-propuestas.md) |

## Problema y objetivo

Una paleta de muestras no basta para recolorear proyectos coherentemente: hace falta distinguir
un píxel que usa un color por identidad de otro que casualmente tiene el mismo RGBA.
La distinción debe persistir, ser visible y sobrevivir al historial.

## 1. Tres clases de píxel

| Clase | Almacenamiento | Efecto de editar la paleta |
|---|---|---|
| Vacío | Etiqueta vacía | Ninguno |
| Libre | RGBA sRGB de 8 bits | Ninguno |
| Vinculado | ID estable de entrada | Resuelve al RGBA actual de esa entrada |

Un píxel es de una sola clase. Dentro de una celda pueden coexistir las tres sin un «modo de capa».
La paleta pertenece al documento entero y es compartida entre capas y fotogramas del mismo estado.
No hay paletas distintas por fotograma en 1.0.

Una entrada contiene ID UInt32, nombre, RGBA y `locked` booleano. El nombre es opcional y no único;
el ID es único y no cambia al renombrar/reordenar. Colores idénticos en entradas diferentes son válidos:
«piel» y «madera» pueden ser iguales hoy y recolorearse de forma independiente mañana.

El orden de muestras se guarda por separado de sus IDs. IDs nuevos se asignan de manera monótona,
sin reutilización dentro del documento, incluidas ramas y propuestas. Deshacer recupera IDs anteriores;
no rebobina el asignador. Al agotar el rango se rechaza la creación de entradas con mensaje explícito.

## 2. Color de dibujo y cuentagotas

El color activo es un RGBA libre o una referencia de paleta. La barra muestra un indicador de
vínculo junto al color; el usuario no debe deducirlo del tono de la muestra.

- Elegir una muestra de paleta activa ese ID: pintar crea píxeles vinculados.
- Elegir un color libre en el selector/HEX activa RGBA: no altera una muestra existente.
- Para editar una entrada se usa «Editar color de paleta…», con preview del impacto.
- «Usar como color libre» copia el RGBA actual de una muestra al color de dibujo sin crear vínculo.
- «Agregar a paleta» crea una entrada; no convierte automáticamente los píxeles ya pintados.
- El cuentagotas en la capa activa recoge su valor almacenado: conserva vínculo si existe.
- El modo «Color visible» del cuentagotas muestrea la composición y siempre devuelve RGBA libre.

El lápiz reemplaza el píxel destino por el valor activo, sin mezclarlo con el anterior. El borrador
escribe vacío. El pincel vinculado no tiene opacidad parcial en 1.0; se puede usar alfa de la entrada
o una capa con opacidad. No se convierte silenciosamente a RGBA para simular ese pincel.

## 3. Alfa y espacio de color

Todo color persistido es sRGB RGBA de 8 bits sin premultiplicar. El alfa pertenece al color,
no existe un segundo alfa por píxel vinculado. Alfa de capa solo afecta la composición.

Alfa cero libre se guarda como vacío. Una entrada de paleta con alfa cero sigue existiendo,
igual que sus píxeles vinculados, incluso si visualmente parecen vacíos. El borrador elimina
esos vínculos; editar esa entrada puede volverlos visibles.

Al importar, convertir el perfil reconocido a sRGB y luego a RGBA8. Una imagen sin perfil se
interpreta como sRGB. Un perfil que no pueda convertirse requiere avisar y ofrecer interpretación
explícita como sRGB o cancelar; no corregirlo silenciosamente. La imagen importada queda en color libre
por defecto y su número de colores no está limitado a 256. Ese límite aplica solo a la paleta.

## 4. Cuatro operaciones de paleta diferentes

### Crear o agregar colores

Generar una propuesta de colores o extraerlos de una imagen no modifica píxeles. «Agregar»
incorpora nuevas entradas si hay capacidad, sin deduplicar por RGBA ni reutilizar IDs implícitamente.
Una propuesta que excede 256 entradas debe reducirse o sustituir entradas mediante otra acción.

### Editar una entrada vinculada

Cambia RGBA o nombre del mismo ID. Todos sus usos vinculados en el estado actual quedan afectados,
incluidos otros fotogramas y capas ocultas. Los píxeles libres del mismo tono no cambian. Revisiones
anteriores siguen resolviendo contra su propia paleta.

Cambiar RGBA requiere alcance de documento; el preview identifica usos afectados, capas y fotogramas.
Si hay una capa bloqueada que usa esa entrada, rechazar el cambio de RGBA mientras siga bloqueada.
Si hay bloqueo de transparencia en una capa usuaria, un cambio de alfa también se rechaza.
Renombrar no cambia píxeles ni se bloquea por el bloqueo de una capa.

### Sustituir los colores de la paleta conservando identidades

Presenta un mapa completo ID existente → nuevo RGBA. Mantiene IDs, orden y píxeles vinculados.
Entradas omitidas conservan su valor. Si cambian nombres, mostrarlo también. Es la operación
predeterminada para «Dale una paleta nocturna» cuando el alcance es todo el documento.
No incluye automáticamente los píxeles libres. El preview informa cuántos quedan sin adaptar.

### Adaptar los píxeles a una paleta destino

Resuelve cada píxel del alcance a un color y lo asigna explícitamente a una entrada destino.
El resultado puede cambiar color y vínculo. No basta con sustituir la lista de muestras.
Las entradas destino deben existir en la paleta del estado resultante; agregar colores requiere
capacidad, y quitar entradas antiguas exige demostrar que ya no tienen usos en ese estado.

El preview muestra el mapa, cuántos píxeles cambian de aspecto y cuántos solo de vínculo. Permite
corregir la correspondencia antes de confirmar. Todo se aplica como una transacción.
El límite de 256 se evalúa sobre el estado final: reemplazar por completo una paleta de 256
colores por otra de 256 es válido si se reasignan todos los usos y se retiran las entradas viejas
en la misma transacción. No exige espacio para 512 entradas en el estado publicado.

## 5. Conversión entre libre y vinculado

| Acción | Regla |
|---|---|
| Vincular coincidencias exactas | Convierte píxeles libres cuyo RGBA coincida exactamente con una entrada elegida |
| Desvincular | Sustituye cada vínculo del alcance por su RGBA actual; alfa cero pasa a vacío |
| Adaptar a paleta | Usa un mapa explícito o el cálculo determinista definido abajo |
| Reemplazar por RGBA libre | Escribe RGBA en coincidencias; puede cambiar píxeles originalmente vinculados |
| Reemplazar por entrada | Escribe el ID destino en coincidencias |

Si varias entradas tienen el mismo RGBA, la vinculación exacta pide escoger el ID; el preview
puede proponer la primera del orden de paleta, pero debe exhibir cuál. No se cambia de ID porque
una muestra se haya reordenado después de congelar la propuesta.

Desvincular conserva el aspecto actual, no el comportamiento futuro. La UI informa esa pérdida
de vínculo. Deshacer recupera IDs y clases originales, no una aproximación por color.

## 6. Asignación determinista y reducción de colores

La adaptación automática básica no usa Codex ni dithering. Para cada color fuente, elegir la
entrada destino con menor distancia RGBA. Convertir RGB sRGB normalizado a RGB lineal mediante
la curva sRGB; multiplicarlo por alfa normalizado. La distancia es la suma de los cuadrados de
las diferencias de R·A, G·A, B·A y A. Calcular en doble precisión; ante distancias cuya diferencia
sea como máximo 10^-12, gana el ID numérico menor. Fijar casos de referencia antes de publicar 1.0.

Los píxeles vacíos permanecen vacíos. Para vínculos de alfa cero, conservarlos si no están dentro
de una conversión solicitada; si se adaptan, exigir una entrada destino con alfa cero o mostrar
explícitamente que pasarán a vacío para confirmar. No hacerlos opacos por cercanía matemática.

Antes de la asignación, una correspondencia manual del usuario o propuesta y aceptada de Codex
tiene prioridad. Registrar la tabla final, no volver a calcularla al rehacer. El preview avisa
si cambiará alfa. En una capa con bloqueo de transparencia solo son destinos válidos los que
conserven exactamente el alfa del píxel fuente; si no hay ninguno, la conversión se rechaza.

Extraer una paleta sin reducción enumera colores RGBA exactos, excluye vacío y ordena por
frecuencia descendente y luego RGBA lexicográfico. Con más de 256 colores debe abrir una propuesta
de reducción; nunca descartar los restantes como si fuera una extracción completa. El algoritmo
de reducción para importación se concreta en [PXA-12](PXA-12-interfaz-paletas-y-reduccion.md),
con sus propios casos de calidad y reglas deterministas.
Una reducción generada por Codex se guarda como propuesta concreta, sin promesa de determinismo.

## 7. Alcance y colores compartidos

Selección/capa/fotograma limitan qué píxeles pueden cambiar. Editar una entrada global sería una
expansión del alcance si también altera usos externos: nunca se hace automáticamente.

Para recolorear solo una región que comparte un color:

1. Conservar el ID original para los píxeles externos.
2. Crear una entrada nueva con el color propuesto y reasignar solo los píxeles elegidos.
3. Mostrar la entrada nueva y el número de usos cambiados antes de aplicar.

Si no queda lugar en la paleta, ofrecer seleccionar otra entrada existente, liberar entradas sin
uso mediante una acción explícita, o convertir el resultado local a color libre. No aumentar
alcance ni desvincular sin elección del usuario. Una capa bloqueada no puede modificarse por
reasignación, aunque la operación se presente como una edición de paleta.

Entradas bloqueadas no pueden editarse, eliminarse ni sustituirse. Pintar con ellas está permitido.
El bloqueo protege la definición de la entrada; no bloquea los píxeles que la usan. Para proteger
los píxeles se usa el bloqueo de capa. Toda operación se evalúa contra los bloqueos al iniciarse;
no puede desbloquear y modificar en el mismo lote para eludirlos.

El bloqueo de transparencia conserva el alfa almacenado/resuelto de cada posición antes de
componer la capa, no el alfa final de la imagen. Incluye posiciones vacías con alfa cero.
Lápiz, borrador, relleno, movimiento, transformación y conversión deben conservarlo exactamente
en cada posición afectada o rechazar la operación. El pincel no adapta silenciosamente su alfa
al destino. La opacidad de capa es una propiedad independiente.

## 8. Eliminar, fusionar y reemplazar colores

- Una entrada sin usos actuales puede borrarse; las revisiones pasadas conservan su definición.
- Si tiene usos, «Eliminar» exige elegir reemplazo por otro ID o desvincular a RGBA antes de quitarla.
- Las dos acciones ocurren en una transacción y deben abarcar todos sus usos actuales; si alguno
  está bloqueado, la eliminación se rechaza.
- Fusionar entradas reasigna referencias al ID elegido y elimina las otras; si sus RGBA difieren
  debe mostrar el cambio visual. No se fusionan automáticamente por compartir tono.
- No existen referencias huérfanas ni reutilización de IDs borrados.

Reemplazar color ofrece dos formas de buscar: **por vínculo** (ID exacto) o **por color visible del
píxel** (RGBA resuelto en la capa, antes de composición). La segunda puede alcanzar píxeles libres
y vinculados, pero no equivale al color compuesto de varias capas. En 1.0 la coincidencia es exacta,
sin tolerancia implícita. El relleno contiguo usa vecindad de cuatro píxeles y el mismo criterio
elegible; el reemplazo global no requiere contigüidad. Se muestra el criterio activo en la herramienta.

## 9. Ejemplos normativos

| Situación | Resultado requerido |
|---|---|
| Píxel vinculado a ID 7 rojo y píxel libre con el mismo rojo; ID 7 pasa a azul | Solo cambia el vinculado |
| IDs 7 y 9 tienen el mismo rojo; se edita ID 7 | Los usos de ID 9 permanecen iguales |
| Se reordena la paleta | Ningún píxel cambia de vínculo o aspecto |
| Se duplica un fotograma y luego cambia ID 7 globalmente | Cambian ambos fotogramas; comparten la paleta del estado |
| Se pinta sobre la celda duplicada | Solo cambia esa celda; compartir bloques no enlaza edición |
| Se recolorea una selección que usa ID 7 también fuera de ella | Nuevo ID para la selección, ID 7 intacto fuera |
| Se borra ID 7 con usos tras elegir desvincular | Sus píxeles quedan libres con el RGBA anterior; deshacer restaura ID 7 |
| ID 7 tiene alfa cero y luego alfa 255 | Reaparecen sus usos; los píxeles vacíos no reaparecen |
| Codex propone un cambio global que afecta una capa bloqueada | Se rechaza; no se omite la capa mientras se cambia el mismo ID |

## Criterios de aceptación y pruebas futuras

Verificar todos los ejemplos anteriores antes y después de guardar/reabrir, y tras deshacer/rehacer.
Además: capacidad 256/257, ID agotado, duplicados de RGBA, empate en distancia, alfa parcial,
muestreo compuesto, capa oculta, opacidad cero, bloqueos y reasignación local sin capacidad.

Un preview debe usar el mismo renderizador y la misma tabla de asignación que la aplicación final.
Exportar resuelve los vínculos de la revisión elegida sin cambiar su almacenamiento ni clases.
La conversión a formatos de salida con menos colores se define en exportación y no reduce la paleta
del `.pxa` sin una operación explícita adicional.

## Riesgos

Los cambios globales de paleta son potentes y pueden sorprender si se confunden con elegir un
color de dibujo. La UI debe separar esas acciones y mostrar el alcance. La mezcla de colores
libres y vinculados requiere indicadores claros, pero evita conversiones destructivas al importar.
