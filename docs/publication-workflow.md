# Publicar Braket: flujo y pendientes

La automatización **Publicar Braket · preparación y TODO** vive en
`.braket/automations/80e6fbd0-8195-4bb9-8148-36b05f0a86ab.flow.json`.
Es un archivo del proyecto y se puede commitear. No reemplaza «Verificar proyecto».

## Qué funciona hoy

Inicio manual → leer contexto de publicación → comprobar resultado → Codex →
comprobar resultado → guardar archivos → comprobar resultado → verificar los
dos archivos → planificar versión en dry-run → fin «Dry-run calculado · revisar bloqueos».

El contexto incluye los mensajes completos de los commits desde la última versión
publicada y sus notas anteriores. Incluye commits pusheados; no incluye cambios
sin commit. `.braket/publication.json` registra explícitamente la versión 0.5.14 y
su commit de publicación. No se infiere la versión publicada desde `origin/HEAD`,
el último push ni el último tag arbitrario. Por ahora ese registro se mantiene a mano.

Codex usa `gpt-6-luna` y entrega dos Markdown equivalentes, sin guardar archivos.
El nodo Guardar archivos los crea en `docs/releases/drafts`, con sufijos numéricos
si ya existen. El verificador consume las rutas reales de `fileResults`, no supone
que se sobrescribieron los nombres originales. Verifica contenido, cantidad y
estado de escritura; la calidad de la traducción requiere revisión editorial.
El flujo corta la rama si falla un paso. Sin commits nuevos finaliza sin llamar a IA.

El nodo Contexto tiene activada la opción «Usar salida JSON como contexto»; los
siguientes nodos reciben ese objeto en `context`, un ID único en `run.id` y los
resultados breves de cada paso en `steps`. Los scripts nuevos pueden leerlos desde
`BRAKET_INPUT`. El ID cambia en cada ejecución, incluso al probar un nodo solo.
El bloque Codex exige exactamente dos archivos Markdown, uno por idioma, antes
de entregar la respuesta al bloque que guarda archivos.

El nodo «Planificar versión · dry-run» ejecuta
`scripts/publication_version_plan.py`. Lee `versionBump` de
`.braket/publication.json` (`keep`, `patch`, `minor`, `major`) y propone versión y
build sin modificar archivos. Calcula el build sobre el máximo entre el local y
el catálogo Sparkle. Comprueba HEAD, rama, repositorios de código y sitio, cambios
sin commit, versión publicada del catálogo y disponibilidad de Xcode. Entrega un
JSON con `status`, `blockers` y `mutatedFiles: []`; `blocked` significa que todavía
no se puede publicar, aunque el cálculo del dry-run haya terminado correctamente.
La identidad de firma y el perfil notarial se verificarán antes de firmar.

El adaptador `scripts/publication_context.py` solo consulta Git y lee archivos.
Falla explícitamente si falta la referencia, no es ancestro de HEAD o el contexto
supera los límites de IA.

## Cómo leer los TODO del gráfico

Debajo del recorrido ejecutable quedan los nodos Script `TODO` 01 y 03–09.
Están **desconectados del Inicio**. Cada nodo contiene su objetivo, entrada,
salida y criterio de aceptación en el propio comando y termina con código 78 si
se prueba manualmente. Ninguno ejecuta comandos de publicación ni simula éxito.
Las flechas de esa secuencia indican el orden futuro, no pasos ya implementados.

Al completar un TODO se reemplaza su comando, se agrega una Decisión que compruebe
el resultado y se conecta al recorrido principal. No conectar toda la secuencia
antes de implementar la detención ante errores y la conservación del contexto.

## Pendientes en orden de trabajo

1. **Contrato JSON y contexto de ejecución (base resuelta).** `context` conserva
   el perfil, base/head SHA, versión publicada e idiomas; `run.id` identifica cada
   ejecución y `steps` conserva estado y código de cada nodo. Codex valida los dos
   archivos antes de escribir. Para publicar falta un manifiesto persistente con
   referencias a artefactos de cualquier paso y validación semántica del contenido.
2. **Versión y comprobaciones previas (dry-run disponible).** Ya propone la versión
   y el build de forma estable sin escribir ni commitear, y señala rama, cambios
   sin commit, herramientas y catálogo. Falta comprobar la identidad Developer ID,
   el perfil notarial y fijar el plan aprobado antes de la publicación real.
3. **Compilar y probar según tecnología.** Script ya puede ejecutar las herramientas;
   falta el adaptador con salida JSON de artefactos y pruebas. En Braket, reutilizar
   `scripts/verify.sh` y la compilación Release. Flutter/Android/iOS deben tener sus
   propias configuraciones, sin nombres de tecnologías fijados en el motor.
4. **Firmar y validar distribución.** Script puede invocar `scripts/notarize.sh` para
   macOS. Separar o envolver su resultado para entregar rutas y estado; no repetir
   compilaciones innecesariamente. Guardar identificadores del llavero, nunca claves.
   Android usa su firma; iOS, archivo/exportación y la validación del canal elegido.
5. **Empaquetar actualización bilingüe.** Reutilizar `scripts/release_updates.py`
   para ZIP, firma y Sparkle. Actualmente consume un solo Markdown: falta definir
   y validar cómo incluir ES/EN en el catálogo, además de versión, checksum y URLs.
   El resultado debe ser un manifiesto de artefactos independiente de la tecnología.
6. **Preparar el destino de publicación.** Para krabzik.com: copiar solo artefactos
   de esta ejecución, actualizar `src/data/braket-release.json` y el catálogo,
   incorporar novedades por idioma y correr check/build/ide:check. El nodo Archivos
   actual crea archivos dentro del proyecto y no actualiza JSON existente ni escribe
   en otro repositorio; falta un adaptador de destino con operaciones explícitas.
7. **Commit y push de la entrega.** Git ya puede ejecutarse desde Script. Falta
   seleccionar únicamente archivos de la release, registrar SHA/tag y respetar
   cambios ajenos. Ordenar código y sitio, detectar publicación concurrente y
   conservar el estado si uno de los pushes falla. No usar `git add .`.
8. **Esperar y comprobar publicación.** Falta un bloque de espera/polling con límite,
   reintentos y cancelación. Comprobar el despliegue que corresponde al SHA enviado,
   URLs, versión, tamaño/hash y catálogo; después probar la actualización real de
   Braket. Una respuesta HTTP 200 por sí sola no prueba que el release esté publicado.
9. **Cerrar la release y habilitar ejecución automática.** Solo tras verificar el
   destino, actualizar lastPublished, conservar manifiesto/historial y marcar éxito.
   Faltan reanudación segura, bloqueo de publicaciones simultáneas y disparadores
   reales: Evento/Horario hoy son manuales. No habilitar un disparador que publique
   hasta definir permisos previos, recuperación ante fallos y política de reintentos.

Los pasos 2–7 son posibles mediante scripts; no requieren inventar nodos nativos
para cada tecnología. Están pendientes de integración, no bloqueados por Xcode o Git.
Los puntos 1, 8 y 9 describen capacidades del motor que conviene resolver de forma
reutilizable. El mismo recorrido debe recibir un perfil de producto, un adaptador
de compilación/firma y un adaptador de destino (web, tienda, TestFlight, etc.).

## Criterio de publicación completa

No basta con generar notas ni con terminar un push. El éxito final exige artefacto
verificado, entrega disponible en el canal seleccionado y registro de la versión
y commit publicados. Hasta completar los TODO, este flujo prepara borradores y
finaliza indicando **publicación pendiente**.
