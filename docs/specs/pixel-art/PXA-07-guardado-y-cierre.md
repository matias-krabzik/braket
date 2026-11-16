# PXA-07 · Guardado, conflictos y cierre

| | |
|---|---|
| **Estado** | Especificado; no implementado |
| **Etapa** | [2](ETAPA-02.md) |
| **Área** | Comandos de archivo, consistencia y transiciones |
| **Depende de** | PXA-01/PXA-02, PXA-05; recuperación en PXA-08 |

## Objetivo

Todas las entradas de Guardar/Cerrar deben usar el mismo contrato. Ninguna trata un `.pxa` como
texto, guarda solo un preview, pierde historia o limpia cambios que ocurrieron durante una escritura.
Los errores dejan una salida útil sin reemplazar la última versión válida.

## 1. Comandos

| Acción | Resultado |
|---|---|
| Guardar, ⌘S | Guarda generación actual en su ubicación; si es borrador pide ubicación |
| Guardar como… | Escribe en otra ubicación y pasa la instancia activa a ella; conserva documento-ID |
| Guardar copia…, ⇧⌘S | Escribe documento independiente con nuevo documento-ID; no cambia la pestaña original |
| Guardar copia con historial reducido… | Contrato explícito de PXA-02; no sobrescribe el original |
| Recargar desde disco | Sustituye la sesión por el archivo validado tras resolver pérdida de cambios |

Guardar como conserva el archivo de origen; cambiar ubicación activa no equivale a mover/borrar
el origen. Para mover físicamente se usa el comando de archivos del explorador. Guardar copia
usa el estado en memoria, incluidos cambios sin guardar, no copia la versión vieja del disco.
No abre la copia automáticamente ni deja limpio el original. Reducir historial tampoco limpia
el original. Guardar como sobre la misma ubicación canónica equivale a Guardar.

En un formato futuro abierto solo lectura, **Copiar archivo original…** hace una copia literal
verificada del archivo, sin reserializar, sin nuevo documento-ID y sin incluir el estado local
de vista. Se distingue de Guardar copia editable; no habilita escritura sobre el formato desconocido.
En solo lectura por confianza/permisos se puede guardar una copia del archivo autorizado a leer,
pero no se usa esa acción para montar otras carpetas, habilitar Codex ni alterar la confianza.

## 2. Primer guardado y selección de destino

Panel de guardado nativo, nombre del borrador y extensión `.pxa` obligatoria. La carpeta invocante
de creación tiene prioridad; si ya no está disponible, usar el último destino de pixel art válido
o Documentos. La ubicación es una preferencia local distinta de la carpeta SQL.

Cancelar deja borrador y recuperación intactos. Seleccionar un nombre ocupado requiere la decisión
nativa de reemplazo y una huella del destino en ese momento; si vuelve a cambiar antes del commit,
detenerse por conflicto. Si otra instancia de Braket ya tiene abierto el destino, no sobrescribir:
informar y permitir enfocarla o elegir otra ruta. Aplicar lo mismo a Guardar como y Guardar copia.

Solo tras escritura correcta se asigna URL al borrador, se actualizan pestaña/explorador y la
asociación de recuperación. No aparece en disco ni se modifica `.kzk` antes de completar. La copia
se guarda en cualquier carpeta elegida explícitamente que permita escribir; no necesita estar montada.

## 3. Generaciones y serialización de trabajos

Mantener por instancia:

- Generación de edición monotónica de PXA-04, para invalidar resultados basados en otro estado.
- Identidad de la última instantánea persistente relevante para cambios pendientes: grafo/cursor,
  contenidos artísticos y auxiliares que requieren aviso de pérdida según PXA-02.
- Revisión auxiliar de vista, que no activa por sí sola el aviso de pérdida.
- Huella base del archivo y `saveID` observado; son distintos del hash del estado artístico.

El contador monotónico no determina por sí solo «sin guardar»: deshacer/rehacer hasta una instantánea
idéntica a la guardada puede dejarla limpia. Crear una rama nueva conserva cambios pendientes aunque
el render y el cursor coincidan con los guardados. La comparación debe incluir lo indicado por PXA-02.

Una cola por instancia coordina guardado explícito y recuperación; una sola publicación por destino
a la vez. Capturar estados inmutables en memoria y escribirlos fuera del hilo de UI. Guardar explícito
tiene prioridad sobre una recuperación aún no iniciada; si la recuperación ya está escribiendo, puede
terminar antes. No ejecutarlos simultáneamente para aumentar uso de memoria o invertir generaciones.

Pulsaciones repetidas de ⌘S se agrupan: esperar la escritura en curso y guardar como máximo una
instantánea adicional con los cambios recientes. El estado «Guardando…» informa la actividad y no
bloquea pan ni cambios de pestaña. Edición/navegación histórica ordinaria puede continuar; completar
el guardado anterior no limpia el punto de cambios de una generación posterior.

Un guardado rechazado/cancelado devuelve un resultado explícito distinto de éxito. Los coordinadores
de cierre no pueden tratar «ya estaba guardando» como «ya está guardado» ni cerrar sin esperar.

## 4. Publicación atómica

Aplicar la secuencia de PXA-01: instantánea → temporal hermano → validar/sincronizar → coordinar
y volver a comprobar destino → reemplazo atómico → actualizar huella y baseline de lo realmente escrito.
El nombre temporal no debe aparecer como documento `.pxa` en el explorador. Su limpieza no borra
temporales de otras instancias ni un archivo que no sea propio.

La validación cubre historia, paleta, propuestas y objetos alcanzables. Nunca guardar una versión
aplanada para que pase el presupuesto. Un preview faltante puede regenerarse; el contenido editable
no es opcional. Reabrir/verificar el resultado antes de declarar completada la operación.

Tras éxito, ignorar el evento de observador correspondiente a esa misma publicación por huella,
no por una ventana temporal ciega. Un evento distinto inmediato sigue siendo un cambio externo.
Si falla validación de la copia temporal, no reemplazar el destino. Si el fallo de verificación
ocurre después de reemplazar, informar error, conservar memoria y recuperación y no marcar limpio;
la estrategia de sustitución debe conservar recuperable la generación previa hasta verificar la nueva.

## 5. Cambios externos

Observar la ubicación activa con los mecanismos existentes de archivos, sin sondeo continuo.
La comparación definitiva se repite al guardar, aunque no haya llegado una notificación.

| Situación | Comportamiento |
|---|---|
| Documento limpio, archivo reemplazado | Banner «El archivo cambió en disco»; Recargar o conservar la vista local. No recargar sin aviso |
| Documento con cambios locales | Banner «Hay cambios locales y externos»; Recargar, Guardar copia o posponer |
| Archivo eliminado o ubicación inaccesible | Mantener sesión; mostrar «Archivo no disponible» y ofrecer Guardar como/Reintentar |
| Solo cambian metadatos de archivo, mismos bytes | Actualizar datos de recurso, sin conflicto artístico |
| Renombrado dentro de Braket | Reubicar instancia y recuperación sin recargar contenido |
| Movimiento externo con identidad verificable | Mostrar nueva ubicación, retomar observación; no cambiar contenido ni documento-ID |
| Movimiento externo no identificable | Tratar como no disponible; no buscar por nombre en todo el disco |

Guardar sobre un destino distinto de la huella base se bloquea. «Conservar la vista local» no
autoriza sobrescribir la versión externa. En etapa 2 la salida es Guardar copia/Guardar como en
otra ruta o Recargar; no hay fusión automática ni botón ambiguo «Forzar».

Recargar valida primero una nueva sesión candidata. Si falla, la sesión anterior sigue completa,
incluido su historial. Si hay cambios relevantes locales, pedir confirmación de descarte; no borrar
recuperación hasta que la candidata se haya adoptado. Recargar no agrega la historia externa a la
local: sustituye el documento entero. La interfaz debe decirlo explícitamente.

Un archivo eliminado no se recrea con el siguiente ⌘S sin que el usuario confirme la ubicación
mediante Guardar como. Si reaparece un archivo diferente en la ruta, se considera conflicto externo.

## 6. Cierre de pestaña

Una ruta única atiende ×, ⌘W, cerrar proyecto y salida. Pestañas cargando solo cancelan su lectura.
Para una sesión lista:

1. Resolver cualquier gesto temporal pendiente según PXA-02; en etapa 2 no hay pegado/dibujo activo.
2. Si hay un guardado en curso, esperar su resultado o cancelar el cierre, sin abortar el commit
   a mitad de reemplazo. Mostrar actividad y evitar abrir diálogos repetidos.
3. Si hay cambios relevantes o borrador, ofrecer Guardar / No guardar / Cancelar.
4. Guardar continúa solo al completar el destino más reciente; error o cancelación mantienen la pestaña.
5. No guardar marca una intención de descarte, pero su limpieza solo se confirma cuando el cierre
   efectivamente se realiza. Cancelar no altera el modelo ni limpia recuperaciones.
6. Al cerrar, invalidar solicitudes pendientes, soltar renderer/cachés y seleccionar la pestaña vecina.

Mientras se completa el guardado final de cierre, deshabilitar nuevas mutaciones de esa instancia;
se puede cancelar el cierre para seguir trabajando. No guardar una instantánea y luego cerrar
perdiendo una edición que entró entre el guardado y la liberación.

Un borrador recién creado pide guardar aunque siga vacío. Un documento que solo cambió de zoom
puede cerrarse sin aviso; guardar su vista local recuperable no convierte eso en una edición artística.

## 7. Cambio de contexto, cierre de proyecto y salida

Mantener el flujo actual de Braket para cambiar/cerrar proyectos: resolver documentos, actividad
de procesos/automatizaciones y bases según sus coordinadores. El contexto Archivos sueltos pasa
por el mismo gate de documentos; no tiene procesos o bases propios. Cambiar de pestaña dentro de
un contexto no solicita guardar; cambiar de contexto puede hacerlo, como en la app actual.

Para operaciones que afectan varios documentos, preparar decisiones de cierre/descarte primero
y liberar sesiones/limpiar recuperación solo después de que se apruebe toda la transición.
Si se cancela un diálogo posterior, documentos descartables siguen abiertos con su trabajo. Los
guardados ya completados no se revierten: son persistencia real, no un descarte prematuro.

En salida de la app se conserva la preferencia actual de **guardar antes de salir**. El coordinador
intenta guardar los `.pxa` modificados y pide destino a borradores; un fallo o cancelar un destino
cancela la salida y permite resolverlo desde la pestaña. No añadir un autodescarte ni cambiar el
comportamiento de salida para todos los tipos de documento. El usuario puede elegir No guardar
al cerrar explícitamente una pestaña antes de salir.

Capturar la sesión que se restaurará después de resolver los guardados y nuevas ubicaciones,
antes de liberar las sesiones. La captura previa usada hoy al iniciar el cierre no basta si el
usuario acaba de asignar nombre a un borrador o elegir Guardar como. Cancelar la salida no publica
un estado de sesión «cerrado». Para cierre del proyecto actual tampoco se limpia una recuperación
si una consulta/proceso pendiente acaba cancelando la transición.

Mover un archivo a Papelera desde el explorador usa el mismo gate de documentos antes del movimiento.
La confirmación de Papelera no sustituye la decisión sobre cambios sin guardar. Si falla el traslado,
mantener sesión y recuperación; no tratarlo como cierre confirmado.

## 8. Errores y mensajes

El error de guardado se ancla al documento con nombre y motivo legible. Ejemplos: «No se pudo
guardar bosque.pxa: no hay espacio suficiente» o «El archivo cambió en disco; guardá una copia
o recargá la versión externa». Ofrecer solo acciones que puedan resolver ese caso.

No producir un modal por cada intento de recuperación automática. Los errores persistentes de
recuperación se muestran conforme a PXA-08. Nunca decir «Guardado» por haber generado un temporal,
una miniatura, una copia de recuperación o un archivo de exportación.

## Criterios de aceptación y pruebas futuras

- Guardar/Guardar como/Copia/primer guardado respetan las diferencias de identidad y destino.
- Guardar una copia de un documento modificado incluye ese estado y no limpia el original.
- Guardar como no borra el origen; una copia literal de versión futura conserva exactamente sus bytes.
- Pulsar Guardar repetidamente y navegar historia durante escritura no limpia ni pierde cambios recientes.
- Inyectar disco lleno, permisos, validación fallida, cambio externo y error de reemplazo: queda trabajo recuperable.
- El éxito solo se anuncia con un `.pxa` completo verificable en la ubicación elegida.
- Rechazar destino abierto en otra instancia y detectar sustitución entre elección de destino y commit.
- Recargar fallido conserva el estado anterior; recargar exitoso tras confirmación adopta la nueva historia.
- Cierre individual y por lote cubre Guardar/No guardar/Cancelar y fallo en un documento posterior.
- Cancelar una salida por actividad SQL/procesos no elimina recuperaciones de documentos aún abiertos.
- Salir tras guardar un borrador restaura luego su URL real, no una ruta temporal ni ninguna omisión.
- Los cierres de texto/SQL y la ejecución de procesos conservan sus protecciones existentes.

## Riesgos

El guardado de snapshots puede coincidir con navegación histórica o cierre: sin identidades y
generaciones explícitas, un callback tardío puede marcar limpio otro estado. La coordinación de
cierres múltiples requiere retrasar el descarte efectivo, no confiar en que todos los diálogos
posteriores se aceptarán.
