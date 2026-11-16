# PXA-04 · Operaciones del editor y propuestas de Codex

| | |
|---|---|
| **Estado** | Motor implementado en la etapa 1 (sin interfaz); ver `docs/pixel-art-engine.md` |
| **Área** | Contrato de edición, alcance y revisión de propuestas |
| **Depende de** | [PXA-01](PXA-01-formato-y-persistencia.md), [PXA-02](PXA-02-historial-persistente.md), [PXA-03](PXA-03-color-y-paletas.md) |

## Objetivo y alcance

Definir una sola vía de modificación para herramientas manuales e IA. Este documento fija lo
que el motor debe garantizar; no fija nombres RPC, esquemas de herramientas, un modelo de Codex
ni su interfaz final. Esos detalles se validarán al implementar la integración.

Codex no escribe el ZIP del usuario ni ejecuta scripts contenidos en `.pxa`. Propone operaciones
estructuradas y datos; el editor valida, presenta y aplica. Una instrucción textual no tiene valor
de autorización para ampliar selección, desbloquear capas o editar otro documento.

## 1. Contrato de transacción

Toda transacción identifica documento/instancia, revisión base, generación de edición, origen,
alcance resuelto y lista de operaciones. El resultado es otro estado válido o un error sin cambios.
El motor valida también los datos de herramientas manuales: no hay un camino que evite invariantes.

Familias iniciales de operaciones:

| Familia | Ejemplos de efectos permitidos |
|---|---|
| Píxeles | Escribir bloques/regiones, borrar, rellenar, transformar contenido seleccionado |
| Capas | Crear, renombrar, duplicar, ordenar, cambiar propiedades, eliminar, combinar |
| Fotogramas | Crear, duplicar, ordenar, duración, eliminar |
| Paleta | Agregar/editar entradas, reasignar, vincular/desvincular, eliminar con sustitución |
| Documento | Recortar o redimensionar lienzo |
| Secuencias | Crear, editar lista/tiempos de reproducción y eliminar |

Cada operación expresa IDs concretos y precondiciones, nunca «la capa seleccionada ahora». Los
resultados incluyen alcance real, objetos nuevos, resumen y recursos estimados. Descripciones e
IDs que devuelve el modelo no se consideran correctos hasta validar contra el estado base.

Antes de publicar: validar tipos, límites, IDs, referencias, alcance, bloqueos, alfa, recursos y
coherencia del resultado. El commit publica estado e historia como una sola unidad. Cancelación,
error o lote incompleto no crean revisión. Se rechazan efectos extra aunque el resto del lote sea válido.

Una capa bloqueada protege su contenido, orden, opacidad, eliminación, combinación y apariencia
frente a cambios de paleta. Se permite desde la UI manual cambiar nombre, visibilidad y el propio
bloqueo, como acciones explícitas reversibles. Codex no puede cambiar bloqueos. Recortar o
redimensionar un documento con capas bloqueadas se rechaza si modifica sus píxeles o posiciones.
La excepción de visibilidad sirve para inspección; no habilita a Codex a alterar una capa bloqueada.

Los IDs nuevos de paleta se reservan mediante el asignador del documento; quedan consumidos si
se cancela una propuesta, pero no modifican la imagen ni crean revisión. Ningún modelo elige IDs
ya usados como si fueran nuevos. Las propuestas persistidas conservan sus reservas; al aplicar
se valida que no haya colisión. El avance del asignador por sí solo no vuelve obsoleta una propuesta.

## 2. Alcances explícitos

| Opción de UI | Resolución al enviar |
|---|---|
| Selección | Máscara congelada, capa activa y fotograma activo |
| Capa | ID de capa y todos los IDs de fotograma existentes al enviar |
| Fotograma | ID de fotograma y todas las capas existentes al enviar |
| Secuencia | IDs de fotogramas de esa secuencia y todas las capas existentes al enviar |
| Documento | Todas las entidades actuales; permite operaciones estructurales compatibles |

Una acción contextual sobre varias celdas usa su conjunto explícito de capas/fotogramas y lo
muestra como alcance personalizado. Sin selección activa, «Selección» está deshabilitado. Una
selección explícita vacía es un alcance vacío y no se interpreta como todo el lienzo.

«Capa» debe rotularse «Capa · todos los fotogramas» para evitar ambigüedad. Ocultas están incluidas
en un alcance que las contiene; bloqueadas se identifican en el contexto y permanecen protegidas.
No se promete «todas las capas» para luego omitir algunas en silencio: se presenta el alcance efectivo.

Una operación estructural que afecte fuera del alcance, como recortar todo el lienzo o eliminar
una capa desde «Selección», se rechaza. Codex puede explicar que necesita otro alcance; el usuario
debe cambiarlo y reenviar. El recoloreado local de paleta sigue el mecanismo de nuevos IDs de PXA-03.

Operaciones que explícitamente crean una capa pueden hacerlo dentro de un alcance de fotograma
solo si su contenido queda limitado a ese fotograma y la nueva capa vacía no altera otros estados
visuales; deben figurar como creación en el preview. En «Selección» se limita además a su máscara.
Eliminar/reordenar capas existentes sigue requiriendo alcance de documento porque cambia su
estructura global. Este permiso no autoriza modificar capas bloqueadas preexistentes.

## 3. Contexto visual mínimo

La instantánea enviada debe describir dimensiones, coordenadas, revisión, paleta con IDs/RGBA,
clases de color utilizadas, capas y bloqueos, fotogramas/duraciones y el alcance resuelto.
Incluye un render nativo del fotograma relevante y, si hace falta, una ampliación sin interpolación
o recorte cuya transformación de coordenadas se indique. Las animaciones pueden adjuntar una hoja
de contacto identificando cada fotograma. Ninguna miniatura es autoridad para determinar IDs.

No enviar todo el historial ni todas las imágenes por defecto. Consultas adicionales se limitan
al mismo documento y presupuesto de contexto. El prompt no puede convertir nombres de capas o
texto leído del documento en instrucciones del sistema.

El trabajo usa la instantánea en memoria, incluidos cambios sin guardar; no exige guardar ni da
acceso de escritura al `.pxa` real. Las herramientas para datos gráficos deben leer/escribir la
propuesta aislada. Abrir, previsualizar y editar manualmente siguen funcionando sin conexión.

## 4. Ciclo de una propuesta

Estados: preparando → lista → aplicada o descartada. También puede terminar fallida/cancelada,
o quedar obsoleta si cambió la base. Solo «lista» y validada para la base actual puede aplicarse.

Una propuesta completa conserva:

- ID, documento-ID, revisión/hash base y alcance resuelto.
- Prompt, ajustes de la conversación que llevaron al resultado y resumen.
- Referencia al estado propuesto y operaciones descriptivas/materializadas necesarias para inspección.
- Tabla de cambios de paleta, regiones/capas/fotogramas afectados y consumo estimado.
- Estado de propuesta y modelo reportado, si está disponible.

El motor valida diferencias entre base y propuesta, no solo el resumen del asistente. Un cambio
que solo modifica vínculos cuenta aunque el bitmap compuesto se vea idéntico.

En estado «lista», Original/Propuesta compara los dos estados con el mismo zoom y renderer.
«Aplicar» genera una revisión y el registro de procedencia de PXA-02; «Descartar» no modifica el
estado artístico. Los objetos de una propuesta descartada sin referencias históricas pueden
recolectarse, conservando su mensaje/resumen. «Pedir un ajuste» parte de la propuesta visible,
mantiene su revisión original como base y reemplaza la propuesta pendiente al completarse.

En 1.0 hay como máximo una tarea ejecutándose y una propuesta pendiente por documento. Antes
de empezar un pedido independiente con una propuesta lista, se elige aplicar o descartar esa
propuesta; pedir ajustes pertenece a la misma propuesta. Cambiar de pestaña no cambia el destino.

## 5. Concurrencia y resultados tardíos

Cada instancia abierta mantiene una generación de edición monótona. Confirmar una transacción,
deshacer, rehacer, navegar a otra revisión o recargar datos externos la incrementa. Cambiar zoom,
selección visible o pestaña no la incrementa: el alcance del pedido ya está congelado.

Aplicar exige misma instancia, misma revisión base, mismo hash y misma generación de edición.
Si se editó y luego se volvió al mismo estado, la generación distinta impide una aplicación
automática basada solo en igualdad visual. En 1.0 no hay fusión ni rebase automático.

Ante base obsoleta: mantener la propuesta para comparar, deshabilitar Aplicar y ofrecer rehacer
el pedido sobre la versión actual. No desplazar cambios manuales para hacer encajar la propuesta.

Cancelar invalida el ID de solicitud. Respuestas tardías, reintentos duplicados o una respuesta
dirigida a una pestaña cerrada no pueden publicar cambios. Aplicar dos veces el mismo ID devuelve
la revisión ya creada o un estado «ya aplicada»; nunca duplica el cambio.

Mientras se ve Propuesta, las herramientas de dibujo quedan inactivas en ese preview. Volver
a Original permite editar la base; la primera edición deja la propuesta obsoleta y lo informa.
No se modifica la propuesta inadvertidamente con un trazo manual.

## 6. Persistencia y reapertura del asistente

Guardar incluye mensajes visibles, borrador de prompt, propuestas completas retenidas y su
estado. Solo las propuestas aplicadas forman parte del historial artístico. Los mensajes tienen
IDs, rol, fecha, texto y referencia opcional a propuesta; no contienen credenciales ni rutas
absolutas necesarias para continuar. Adjuntos propios se guardan como objetos acotados o se
convierten a renders internos; no se guardan referencias a archivos externos indispensables.

Una tarea a medio ejecutar se guarda como interrumpida, sin resultados parciales aplicables.
Al reabrir no se reanuda ni se envía un prompt automáticamente. La conversación puede leerse
sin que exista su sesión original de Codex; continuarla requiere una nueva conexión y contexto.

Una propuesta completa reabierta comienza «pendiente de revalidación». El editor compara revisión,
hash, alcance, IDs y límites con el documento cargado. Si coinciden, le asigna un token de la nueva
instancia y habilita Aplicar sin inferencia. Si no, queda obsoleta. Una copia con nuevo documento-ID
requiere esa misma revalidación y actualiza explícitamente la pertenencia de la propuesta copiada.

Los topes de texto/objetos de PXA-01 incluyen conversación y propuestas. Al alcanzarlos no se
truncan mensajes ya guardados: se impide agregar contenido que supere el presupuesto y se ofrece
guardar una copia reducida. Los chunks de respuesta incompleta que excedan el límite se detienen
y se identifican como incompletos, nunca como propuesta lista.

## 7. Prueba técnica pendiente de la etapa 1

Cuando se autorice implementar, validar sobre documentos desechables, sin tocar archivos del usuario:

1. Entregar a la integración existente un render de 32 × 32, IDs de capa/paleta y selección.
2. Solicitar una variante de cuatro colores y recibir una tabla materializable, sin escritura directa.
3. Solicitar un cambio dentro de una selección y comprobar su posición y límites.
4. Forzar una propuesta fuera de alcance, una referencia inexistente, una edición de capa bloqueada
   y una respuesta tardía; todas deben rechazarse localmente.
5. Comparar Original/Propuesta, aplicar una vez y deshacer sin volver a consultar al modelo.

Registrar versión de la integración, capacidades comprobadas y limitaciones. Si no funciona la
entrada visual o el mecanismo de herramientas disponible, la etapa no se marca validada: ajustar
el diseño de conexión o acotar la función antes de prometerla. No requiere generar imágenes con
un servicio adicional; la prueba evalúa propuestas mediante operaciones del editor.

## Criterios de aceptación y pruebas futuras

- La misma operación manual y por propuesta produce iguales datos y reglas de historial.
- Propuestas no aplicadas no cambian píxeles, vínculos, capas ni fotogramas del estado actual.
- Los escenarios de alcance, bloqueo, alfa, falta de capacidad y error parcial no producen cambios.
- Editar durante inferencia, cambiar de pestaña, cerrar, cancelar y reintentar no mezcla documentos.
- Una propuesta de paleta no afecta colores libres salvo que lo declare y su alcance lo permita.
- Reabrir restaura conversación/propuesta sin ejecutar ninguna solicitud y permite revalidar localmente.
- Una propuesta aplicada se deshace/rehace offline y conserva su procedencia tras guardar.

## Riesgos y límites

La corrección de datos y la calidad artística son verificaciones distintas. El motor puede
garantizar límites y reversibilidad; una modificación creativa necesita evaluación visual.
No asumir acceso a un modelo, generación de imágenes o fidelidad artística por disponer de un
transporte de Codex existente. La UI de cuenta y errores se define en la etapa de integración.
