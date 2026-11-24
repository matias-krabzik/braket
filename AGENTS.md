# Flujo de entrega de Braket

- Preferencia explícita del usuario: al terminar cambios en la app, compilar y verificar la versión Release e instalarla siempre en `/Applications/Braket.app`.
- La instalación local queda autorizada como parte de la entrega; no pedir una confirmación adicional para cada actualización. Usar los permisos de ejecución que requiera el entorno.
- Instalar únicamente una compilación correcta. Conservar un respaldo recuperable de la app instalada antes de reemplazarla y preservar proyectos, datos y preferencias del usuario.
- Verificar la versión instalada y comunicar cualquier impedimento real que haya evitado compilar o instalar. No dar por completada la instalación si solo se generó el archivo `.app` en `.build`.
- Preferencia actual del usuario: abrir proyectos y verificar cambios siempre en una instancia de desarrollo claramente identificada, con bundle ID y preferencias propios.
- Nunca detener, cerrar ni reiniciar la instancia de `/Applications/Braket.app` que usa el usuario. Al instalar una Release, conservar la instancia existente en ejecución y verificar el resultado en disco. Abrir únicamente la instancia de desarrollo para las pruebas visuales.
- La ubicación estable de desarrollo es `/Applications/Braket Desarrollo.app`, con bundle ID `com.krabzik.ide.development`. Actualizar esa copia; no abrir las copias intermedias de `.build`.
- Para evitar duplicados en Spotlight, `.build` está excluido de la búsqueda. Guardar los respaldos recuperables en `.build/.app-backups.noindex`, nunca dentro de `/Applications`; macOS puede volver a registrar las apps de respaldo guardadas allí.
- Al reemplazar una app, retirar el registro de la copia anterior con `lsregister -u <ruta-del-respaldo>` y registrar solo las dos ubicaciones estables de Aplicaciones. No registrar respaldos ni compilaciones intermedias como apps de uso diario.
