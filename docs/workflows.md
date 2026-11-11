# Flujos visuales

El botón «Abrir automatización» del proyecto abre un flujo como pestaña del editor. En «Editar» se pueden agregar bloques Inicio, Script, Decisión y Fin, moverlos, cambiar su nombre/comando y elegir las conexiones Sí/No. «Guardar» escribe un archivo `.braket/automations/<id>.flow.json` dentro del repositorio del primer subproyecto. Aparece en el árbol y Git puede incluirlo en un commit. Al abrir un proyecto sin flujos guardados, Braket ofrece «Verificar proyecto» como ejemplo inicial.

La ejecución de un bloque Script usa zsh de login en la carpeta del primer subproyecto y el mismo corredor de procesos de Braket; puede invocar herramientas instaladas como `xcodebuild`. La ejecución se inicia solo con el botón «Ejecutar» y está deshabilitada para proyectos en solo lectura. La Decisión toma «Sí» si el último script terminó con código 0, o «No» si falló. El flujo inicial revisa `git status --porcelain` y termina en «Proyecto listo» o «Revisar cambios». No publica ni modifica archivos. La ejecución se corta tras 100 transiciones para evitar ciclos infinitos.

El panel inferior «Procesos» muestra la salida. Los nodos Script, Decisión, Inicio y Fin usan colores distintos; los nodos ejecutados muestran su estado. Esta versión inicial incluye los elementos básicos; se añadirán otros tipos más adelante.

Los flujos guardados con el formato anterior `.braket/workflows.json` junto al `.kzk` se cargan para migrarlos. «Guardar» crea los nuevos archivos en el repositorio; el archivo anterior se conserva como respaldo.
