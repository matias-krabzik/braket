# PXA-17 · Conexión, contexto y ciclo de Codex

| | |
|---|---|
| **Estado / etapa** | Especificado, no implementado · [7](ETAPA-07.md) |
| **Dependencias** | PXA-04/05/07/08; herramientas PXA-18 y UI PXA-19 |

## Base comprobada y documentación

El repositorio conserva `AgentController`, `CodexTransport`, `CodexExecutable`, `AgentBridge`
y `CodexConnectionSheet`. El contexto actual de `AgentContext` es textual; no demuestra soporte
operativo de pixel art. Reutilizar conexión/validación de ejecutable, sin revivir el panel antiguo
de sesiones generales ni mezclar el flujo gráfico con automatizaciones SQL.

La documentación oficial consultada el 2026-11-14 admite entradas `image`/`localImage` y describe
herramientas dinámicas mediante `dynamicTools` e `item/tool/call`; las herramientas dinámicas son
experimentales y requieren opt-in de capacidades. El contrato debe comprobarse contra la versión
local elegida, no asumirse por la existencia del método. Fuente:
[Codex App Server, documentación oficial](https://learn.chatgpt.com/docs/app-server).

La misma documentación permite restringir raíces de lectura del sandbox. Un modo llamado
`readOnly` no implica por sí solo lectura limitada al documento; la configuración y sus límites
deben comprobarse. El resto de este spec son requisitos propios de Braket, no garantías del servidor.

## Conexión y capacidades

Estados: desconectado, conectando, listo, incompatible, sesión vencida y fallo recuperable.
Conectar mediante el flujo actual de la cuenta de Codex; no leer/copiar credenciales del usuario
al `.pxa`, no pedir una API key por defecto ni dar por disponible inferencia por poder listar modelos.
No iniciar login o turno automáticamente al abrir archivo/panel. Mostrar modelo elegido y errores
de cuenta de forma comprensible; el acceso real se verifica al completar la prueba o turno solicitado.

Antes de habilitar Enviar, el adaptador identifica versión del ejecutable y capacidades verificadas:
entrada visual, herramientas requeridas, cancelación, aislamiento y respuesta estructurada. Mantener
una matriz de versiones probadas con evidencias. Una actualización incompatible deshabilita envío
con motivo y opción de reconectar; no degradar a escritura libre de archivos o a interpretar texto
arbitrario como comandos. No fijar un nombre comercial de modelo ni límites de suscripción en el formato.

Conversación local por documento. Thread remoto/identificadores de transporte son estado de conexión
local, no autoridad ni requisito para leer `.pxa`. Reanudar solo si el thread pertenece a esta
instancia/cuenta y dispone de herramientas compatibles; en otro caso crear contexto remoto nuevo
con mensajes visibles pertinentes, sin importar permisos ni tareas del thread anterior.

## Aislamiento y permisos

El modelo trabaja sobre un workspace temporal de instantáneas/renders preparado por Braket, sin
montar el proyecto real, sus rutas externas, archivos `.env`, recuperaciones o credenciales. Dar
acceso solo a esos datos y a las herramientas de propuesta. No se habilitan escritura del `.pxa`,
terminal general, red de herramientas, exploración del equipo, plugins ajenos o subagentes para
esta función. La conexión al proveedor para inferencia es distinta del acceso de red de herramientas.

Exigir aislamiento comprobable por runtime/sandbox y registro de herramientas, no solo instrucciones
en el prompt. Rechazar peticiones de aprobación para acciones fuera del contrato gráfico; no
presentarlas como requisito para recolorear. Si una versión no puede cumplir este límite, no se
habilita el flujo de pixel art hasta adaptar y verificar el aislamiento. No usar `approvalPolicy`
sin verificar su semántica ni asumir que negar solicitudes impide acciones ya iniciadas.

Un proyecto no confiable no puede enviar a Codex. En Archivos sueltos se permite el documento
seleccionado expresamente y los renders aportados, sin convertir su carpeta en proyecto confiable.
Primera utilización explica qué contexto visual/textual se envía; Enviar es la acción del usuario
que solicita la inferencia. Abrir/guardar/recuperar no envía nada.

## Contexto y límites del turno

Congelar revisión, hash, generación, selección y entidades al enviar. Contexto inicial: dimensiones,
IDs/nombres de capas, visibilidad/bloqueos, fotogramas/duraciones, paleta, modo libre/vinculado,
alcance y render actual. No adjuntar historial completo, otras pestañas ni fuentes originales.

Para animación adjuntar hasta 8 fotogramas representativos con IDs y orden explícitos; pedir
otros a través de herramientas acotadas. Mostrar que la hoja de contacto es una muestra, no toda
la animación. Cada render declara tamaño nativo, región y factor de ampliación para no confundir
coordenadas del PNG con píxeles del documento. Sin guías visuales salvo adjunto separado solicitado.

Presupuestos iniciales de producto: prompt hasta 16 KiB UTF-8 (el formato puede conservar mensajes
de hasta 64 KiB), contexto textual inicial hasta 64 KiB, hasta 8 imágenes y 16 MiB PNG total por
turno, hasta 50 llamadas gráficas y 5 minutos de duración total. Menores límites del modelo/runtime
tienen prioridad y se informan antes de enviar si son conocidos. Nunca recortar el prompt o un
alcance sin avisar; ofrecer reducir adjuntos/alcance. Estas son decisiones del cliente, no cuotas del proveedor.

El temporizador arranca al enviar al servidor, no al esperar en cola. Un solo turno de pixel art
ejecutándose en toda la ventana en 1.0; otros documentos pueden quedar en cola visible y cancelable,
con un máximo de una tarea por documento. Antes de empezar una tarea en cola revalidar su base;
si cambió, no gastar inferencia para aplicar sobre un estado obsoleto.

## Cancelación y errores

Correlacionar todos los eventos con request-ID, instancia, thread y turn. Cancelar invalida primero
el token local, luego solicita interrupción remota. Si no se confirma interrupción, cerrar el
transporte dedicado sin afectar archivos; nunca aceptar resultados tardíos como propuestas listas.
Caída, cuota, timeout o rechazo no aplican operaciones parciales. Reintentar es una acción explícita
y crea un nuevo request-ID: no reenvío automático que duplique consumo o cambios.

Cambiar pestaña mantiene destino original, sin robar foco. Cerrar documento con turno activo ofrece
cancelar turno y continuar el cierre o cancelar cierre, antes de PXA-07. Cerrar conexión no borra
conversación/propuesta ya guardadas. Mientras no hay IA, todas las funciones manuales siguen activas.

## Aceptación, pruebas y riesgos

- Servidor simulado para eventos fuera de orden, duplicados, timeout, cuota y cancelación.
- Prueba real opt-in: render y operación precisa, registrando versión/modelo sin credenciales.
- Intentar leer fuera del workspace temporal, escribir `.pxa` y ejecutar comandos ajenos: bloqueo
  comprobado, no solo una respuesta del modelo diciendo que no lo hará.
- Dos documentos/colas, cambio de cuenta/modelo, cierre y recuperación no cruzan contexto.
- No red automática al abrir, inspeccionar, guardar, recuperar ni deshacer una propuesta.

La API experimental puede cambiar. Mantener adaptador y pruebas de contrato desacoplados del
motor artístico; cualquier falla de compatibilidad debe degradar únicamente el envío a Codex.
