# Flujos visuales

El botón «Abrir automatización» del proyecto abre un flujo como pestaña del editor. En «Editar» se pueden agregar bloques Inicio, Script, Decisión y Fin, moverlos, cambiar su nombre/comando y elegir las conexiones Sí/No. «Guardar» escribe un archivo `.braket/automations/<id>.flow.json` dentro del repositorio del primer subproyecto. Aparece en el árbol y Git puede incluirlo en un commit. Al abrir un proyecto sin flujos guardados, Braket ofrece «Verificar proyecto» como ejemplo inicial.

La ejecución de un bloque Script usa zsh de login en la carpeta del primer subproyecto y el mismo corredor de procesos de Braket; puede invocar herramientas instaladas como `xcodebuild`. La ejecución se inicia solo con el botón «Ejecutar» y está deshabilitada para proyectos en solo lectura. La Decisión toma «Sí» si el último script terminó con código 0, o «No» si falló. El flujo inicial revisa `git status --porcelain` y termina en «Proyecto listo» o «Revisar cambios». No publica ni modifica archivos. La ejecución se corta tras 100 transiciones para evitar ciclos infinitos.

El panel inferior «Procesos» muestra la salida. Los nodos Script, Decisión, Inicio y Fin usan colores distintos; los nodos ejecutados muestran su estado. Esta versión inicial incluye los elementos básicos; se añadirán otros tipos más adelante.

Los flujos guardados con el formato anterior `.braket/workflows.json` junto al `.kzk` se cargan para migrarlos. «Guardar» crea los nuevos archivos en el repositorio; el archivo anterior se conserva como respaldo.

## Aprobación de scripts

Un flujo es un archivo dentro del proyecto y esa carpeta también la puede escribir Codex, así que **confiar en el proyecto no basta para ejecutar sus scripts**. Antes de arrancar, Braket recorre los bloques Script que alcanza el disparador elegido y pide aprobar cada uno que no conozca; si se rechaza alguno no se ejecuta nada. El diálogo muestra el comando, la carpeta de trabajo real —avisando si cae fuera del proyecto— y las variables de entorno.

La aprobación «siempre» se guarda por hash de comando, carpeta y variables juntos: editar cualquiera de los tres la revoca. No se transfiere a otro proyecto. Los scripts que no cuelgan del disparador no se preguntan porque no corren.

Límites del archivo: no se aceptan las variables `DYLD_*`, `LD_*`, `ZDOTDIR`, `BASH_ENV`, `ENV`, `SHELL`, `IFS` ni `PROMPT_COMMAND`, y `.braket`, `.braket/automations` y los `.flow.json` no pueden ser enlaces simbólicos. Las variables de entorno se guardan en texto plano en un archivo que Git puede commitear: no van contraseñas ni tokens.

Los disparadores Evento y Horario hoy solo se prueban a mano. Cuando se ejecuten solos tendrán que pasar por esta misma aprobación.
