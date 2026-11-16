# PXA-08 · Recuperación automática y restauración de sesión

| | |
|---|---|
| **Estado** | Especificado; no implementado |
| **Etapa** | [2](ETAPA-02.md) |
| **Área** | Recuperación local, reinicio, borradores y preferencias de sesión |
| **Depende de** | PXA-01/PXA-02, PXA-05/PXA-07 |

## Problema y objetivo

`SavedWorkspaceState` actual conserva rutas y selección de la última salida confirmada; excluye
borradores y no guarda contenido. No sirve como recuperación de ediciones perdidas por un cierre
inesperado. Mantener separados tres mecanismos:

| Mecanismo | Fuente y propósito |
|---|---|
| Archivo `.pxa` | Documento portable guardado explícitamente; contiene historia y estado de trabajo |
| Recuperación local | Instantáneas de trabajo confirmado aún no guardado, incluidos borradores |
| Restauración de sesión | Qué contextos/pestañas se abren y cómo se distribuyen al iniciar |

Desactivar «Abrir último estado» no desactiva ni elimina la recuperación. Restaurar pestañas no
significa ejecutar tareas, aplicar propuestas de Codex ni elegir una recuperación sin consultar.

## 1. Almacenamiento local

Ubicación de producto: `~/Library/Application Support/Braket/PixelArt/Recovery/`, obtenida mediante
el directorio de soporte de aplicación del sistema, no concatenando un home asumido. Es local a
esta Mac y no se embebe en el proyecto, `.pxa`, repositorio ni configuración de Codex.

Cada trabajo recuperable tiene un `recoveryID` y un directorio propio. Su índice versionado
contiene metadatos y referencias a un máximo de dos snapshots válidos. Cada snapshot es un `.pxa`
completo conforme a PXA-01 y puede inspeccionarse sin el archivo original. Un temporal en curso
no cuenta como snapshot válido.

Metadatos locales mínimos:

- Versión del índice de recuperación (1), `recoveryID`, instancia/sesión propietaria y estado
  activo, pendiente o descartado. Una nueva sesión reclama el registro con un nuevo propietario.
- Documento-ID, nombre sugerido, URL original opcional y tipo de contexto propietario.
- Identidad del proyecto `.kzk` por ubicación si existe; no su contenido ni autorización de confianza.
- Huella de bytes de la versión base del archivo y su `saveID`, o marca de borrador sin base.
- Por snapshot: número de generación monotónico, nombre local generado por la app, longitud,
  hash del archivo completo, fecha informativa y clasificación de cambios respecto del baseline.
- Referencia a la última instantánea guardada explícitamente y un registro de cierre/descarte
  confirmado cuando corresponda. Ninguna entrada ejecuta una ruta o un comando.

El índice no acepta rutas relativas que salgan de su directorio. URLs originales son metadatos
para comprobar destino, no instrucciones para escribir allí. Nombres visibles no determinan el
nombre físico del snapshot. Validar el índice antes de usarlo y abrir snapshots con el mismo
validador y presupuestos del formato; una carpeta local no implica confianza de su contenido.

Los directorios no se deduplican solo por documento-ID: dos copias Finder o dos trabajos con
igual nombre deben mantener recuperaciones distintas. Un cambio de ruta dentro de Braket conserva
`recoveryID` y actualiza asociación solo después de confirmar el cambio de ubicación. Guardar copia
no transfiere ni elimina la recuperación del original.

## 2. Captura y publicación

Después de crear un borrador o confirmar una operación relevante, programar una captura tras
2 segundos sin cambios. Durante actividad continua, capturar al menos cada 30 segundos si no hay
escritura en curso. No capturar un gesto parcial ni publicar estados artísticos sin transacción.

Si una escritura tarda más de 30 segundos, mantener una solicitud coalescida del estado más reciente
y ejecutarla al terminar; no iniciar copias completas simultáneas ni prometer un plazo incumplido.
Mostrar retraso/fallo cuando la protección deje de actualizarse. Datos auxiliares de vista pueden
incluirse en estas capturas; cambios solo de vista se agrupan tras inactividad y no disparan un
aviso de «trabajo perdido» si el contenido relevante ya estaba guardado.

Publicación por generación:

1. Capturar estado consistente y metadatos de base de la misma instancia.
2. Escribir en temporal propio, verificar/sincronizar el `.pxa` completo y calcular su hash.
3. Publicar el snapshot con nombre único y actualizar el índice de forma atómica.
4. Solo después retirar la generación válida más vieja si ahora hay tres.

Un fallo entre pasos deja disponibles las anteriores. Al arrancar, un temporal o snapshot sin
referencia confirmada no se ofrece como generación completa automáticamente. Puede analizarse
como candidato huérfano en una acción de recuperación explícita, nunca sobreescribir al más nuevo.

Ordenar por generación verificada, no por reloj. La recuperación se coordina con el guardado
como en PXA-07. Guardar explícitamente la generación N puede retirar snapshots cubiertos por N,
pero no una captura posterior que contiene trabajo aún no guardado. El evento de limpieza comprueba
propietario y generación para no borrar datos de una sesión que ya reemplazó a la anterior.

Cuando un guardado explícito cambia el baseline, actualizar también el índice de recuperación de
los estados posteriores que dependían del baseline previo. No cambiar los bytes del snapshot ni
atribuirle el estado recién guardado: actualizar su referencia operativa de comparación con disco
solo si se demuestra que pertenece a la misma instancia y cadena de generaciones. Si no puede
demostrarse, conservarlo como candidato independiente que se recupera como copia.

## 3. Presupuesto y fallos

Cada snapshot cumple los topes de PXA-01. Conservar dos generaciones puede ocupar hasta 2 GiB
comprimidos por documento, más el temporal de publicación. No cargar esos archivos enteros a RAM;
usar verificación en streaming y cachés acotadas. No hay borrado global por edad o por cerrar otro proyecto.

Antes de escribir, comprobar espacio disponible cuando el sistema lo informe; aun con ese control
se deben manejar errores durante la escritura. Si falta espacio, mantener las generaciones válidas
y avisar **«La recuperación automática no pudo actualizarse»**, con Reintentar y Guardar como opciones.
Un guardado manual que tampoco puede completarse debe reportar su propio error.

Un fallo automático no dispara modales repetidos ni bucles de reintento. Reintentar en la próxima
captura relevante tras una espera mínima de 30 segundos, o inmediatamente por acción del usuario.
Mantener en el estado del documento la fecha de la última recuperación válida. No decir «Protegido»
si solo existe un temporal o si la última generación es anterior a cambios pendientes.

No recortar historial, conversaciones ni píxeles para hacer que una captura entre. No eliminar
recuperaciones pendientes de otros trabajos para liberar espacio. La gestión de descartes pendientes
se ofrece en Archivo → Recuperar trabajo de pixel art… y requiere decisión explícita.

## 4. Descubrimiento y aviso al iniciar

Al iniciar, revisar índices locales con lectura acotada y cancelable. No escanear todo el disco
buscando `.pxa` ni abrir automáticamente los proyectos indicados en metadatos. Si hay registros
con cambios relevantes no cerrados/guardados, mostrar un aviso no modal de trabajos recuperables
y acceso a la lista. También se consulta al abrir explícitamente una URL que tenga recuperación.

La lista presenta nombre, contexto, última captura, ubicación original si existe y estado de
integridad/conflicto. No afirmar cuál versión es «más nueva» basándose solo en la fecha de sistema.
Validar el snapshot al seleccionarlo antes de habilitar recuperación.

Acciones:

- **Recuperar:** inspeccionar/adoptar la generación elegida, según la matriz siguiente.
- **Abrir versión guardada:** abrir el archivo actual en disco, conservar la recuperación pendiente.
- **Más tarde:** cerrar el aviso conservando candidatos; no insistir de nuevo en la misma sesión
  salvo apertura explícita de ese documento.
- **Descartar recuperación…:** mostrar qué trabajo/snapshots se eliminarán y confirmar; nunca borrar
  el archivo `.pxa` original ni recuperaciones de otro registro con igual documento-ID.

## 5. Matriz de recuperación

| Situación comprobada | Resultado permitido |
|---|---|
| Original existe y coincide con huella base | Recuperar en instancia asociada a esa ruta, con cambios pendientes respecto del original |
| Original existe pero difiere | Recuperar como borrador independiente, nuevo documento-ID y nombre `nombre-recuperado.pxa` |
| Original falta/no es legible | Recuperar como borrador independiente; no recrear el original automáticamente |
| Trabajo era borrador | Recuperar borrador con nombre e historia, pedir ubicación al guardar |
| Registro solo contiene vista auxiliar de contenido guardado | Recuperar vista local si corresponde; no presentarlo como edición perdida |
| Última generación está dañada y la anterior es válida | Ofrecer la anterior con aviso explícito de su generación/fecha |
| Ninguna generación válida | Informar fallo, conservar candidatos; no abrir lienzo vacío como recuperación |
| Snapshot con historia dañada y estado actual íntegro | Solo copia recuperada explícita sin historial completo, según PXA-01 |

En conflicto, la copia recuperada conserva historial y propuestas verificables del snapshot,
actualiza pertenencia de propuestas como indica PXA-04 y no altera el original ni su historial.
No existe merge automático entre una versión externa y una recuperación.

Si la URL ya está abierta, no crear otro editor del mismo recurso: enfocar la sesión y resolver
sus cambios antes de sustituirla, u ofrecer copia recuperada independiente. No sustituir trabajo
en memoria por el snapshot en nombre de «recuperar». Cada snapshot adoptado recibe un nuevo token
de instancia/sesión; los callbacks de la sesión anterior quedan invalidados.

Un proyecto no confiable sigue solo lectura. Su recuperación puede inspeccionarse y guardarse
como copia independiente en Archivos sueltos si el usuario elige ese flujo; no elevar confianza
ni montar sus rutas externas. La recuperación directa nunca ejecuta procesos, SQL o Codex.

Tras recuperar, conservar el snapshot fuente hasta que se complete un guardado o descarte
explícito del trabajo recuperado. Abrir versión guardada crea su propio registro de recuperación
si se edita; no recicla y sobrescribe la recuperación pendiente que el usuario decidió posponer.

## 6. Descartes y cierres confirmados

No limpiar recuperación cuando se elige No guardar en el primer diálogo de un cierre múltiple.
Esperar a que PXA-07 confirme toda la transición. Antes de liberar la sesión, registrar de manera
durable que ese trabajo se descartó; luego eliminar sus snapshots de forma acotada a su registro.
Si la app cae entre el registro y la limpieza, el próximo inicio respeta el descarte y no vuelve
a ofrecer ese trabajo como perdido.

Si no se puede registrar el descarte, mantener la sesión y avisar del error; el cierre no se
anuncia completado. La limpieza que falla después de registrar el descarte puede reintentarse
en el próximo inicio sin volver a ofrecer recuperación. Una identidad de generación impide que
esa limpieza toque contenido nuevo creado después.

Guardar correctamente permite marcar cubierta la recuperación correspondiente; no eliminar una
generación posterior. Si la app cae después de guardar el `.pxa` pero antes de limpiar, comparar
la instantánea/salida verificada para evitar ofrecer como perdido trabajo que ya está en disco.
Si no se puede demostrar equivalencia, mantener el candidato en vez de descartarlo por fecha.

## 7. Restauración de sesión de Braket

Separar los índices de recuperación del estado general de sesión. Extender el almacenamiento de
sesión con una envoltura versión 2 que represente contextos `workspace` y `loosePixelArt`, su orden
en el rail, contexto seleccionado, rutas de archivos guardados, pestaña activa y preferencias locales
de paneles. No guardar snapshots ni recuperación dentro de UserDefaults.

Leer la versión 1 existente y traducir sus proyectos a contextos `workspace`. No recuperar las
viejas pestañas de conversación Codex que ya se retiraron ni reinterpretarlas como panel gráfico.
Escribir versión 2 solo después de una salida/transición confirmada; durante la migración conservar
el valor anterior como respaldo hasta verificar la nueva representación.
Mantener el presupuesto actual de 1 MiB para el estado de sesión, validando recursivamente todos
los contextos/rutas y sin truncar pestañas en silencio. Una versión no soportada se informa y no
se reescribe automáticamente como versión 2. Fallar la restauración no elimina recuperación local.

Pueden restaurarse documentos `.pxa` sueltos guardados sin crear `.kzk`. Los borradores pendientes
se descubren a través de recuperación y requieren elección del usuario; no introducir rutas falsas
en `openFiles`. Archivos faltantes se omiten con resumen, conservando sus candidatos de recuperación.

Precedencia:

1. Solicitud explícita de abrir archivo/proyecto: respetar su contexto y pestaña solicitados.
2. Recuperación que el usuario elige: abrir/enfocar ese trabajo sin iniciar ejecuciones.
3. Restauración automática: solo si «Abrir último estado» está activa y no desplazará una solicitud
   explícita. Cancelar el trabajo de restauración que quedó obsoleto; no borrar su estado guardado.

La lista de recuperaciones no roba foco a la apertura explícita; un aviso permite acceder después.
Sesión restaurada, documento abierto manualmente y recuperación convergen en un único registro de
instancias para evitar pestañas duplicadas. Reaplicar permisos actuales, no los de la sesión guardada.

Capturar las rutas definitivas después de guardar borradores/Guardar como durante salida, conforme
a PXA-07. «Abrir último estado» desactivado elimina/omite la restauración de pestañas, no el contenido
guardado ni recuperaciones pendientes. Preferencias de tema o conexión no forman parte del `.pxa`.

## 8. Estado visible y diagnóstico

En el editor: «Sin guardar», «Guardando…», «Guardado» o motivo del fallo pertenecen al archivo;
la recuperación se comunica por separado como «Recuperación: hace …» o su error. El punto de la
pestaña no desaparece tras autoguardado. Tooltip permite ver la última captura válida y su estado.

Diagnóstico de persistencia registra tipo de operación, duración, códigos de error y tamaños.
No registrar bitmap, prompts, mensajes, nombres privados ni rutas absolutas en logs generales.
El registro local de recuperación sí contiene la ubicación necesaria para resolver el trabajo;
no se envía a Codex ni se exporta automáticamente en diagnósticos.

## Criterios de aceptación y pruebas futuras

- Cierre forzado después de crear un borrador, navegar historia o modificar estado relevante;
  recuperar la última transacción completa sin aplicar nada parcial.
- Cortar el proceso en cada paso de publicación y limpieza; sobrevive una generación válida.
- Dos documentos con igual ID/nombre y rutas diferentes nunca intercambian snapshots.
- Cambios continuos, escrituras lentas y disco lleno no crean escrituras concurrentes ni borran respaldo.
- Probar cada fila de la matriz, especialmente conflicto externo y última generación dañada.
- Posponer/abrir versión guardada conserva el trabajo pendiente y editar después no lo sobrescribe.
- No guardar seguido de cancelar el cierre del proyecto mantiene recuperación; descarte confirmado
  no vuelve a ofrecerse tras una caída durante limpieza.
- Guardado correcto seguido de caída antes de limpiar no aparece como trabajo perdido duplicado.
- Activar/desactivar restauración de sesión no altera recuperación ni ejecuta procesos/IA.
- Migrar sesión v1, restaurar sesión v2 con proyectos y archivos sueltos, y abrir por Finder durante
  restauración sin duplicar documentos ni perder la selección explícita.
- Validar índices malformados, versiones no soportadas, rutas de snapshot fuera del directorio y
  snapshots fuera de presupuesto, sin eliminarlos como si fueran descartes del usuario.

## Riesgos

Dos snapshots completos por documento pueden consumir espacio significativo. La UI debe exponer
el fallo de protección y permitir descartar candidatos elegidos sin ocultar esa pérdida. La huella
base y el registro de descarte durable son necesarios: basarse solo en `mtime` o en un flag de
«salida limpia» global puede perder o resucitar trabajo de otro documento.
