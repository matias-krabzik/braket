# Flujo de entrega de Braket

- Preferencia explícita del usuario: al terminar cambios en la app, compilar y verificar la versión Release e instalarla siempre en `/Applications/Braket.app`.
- La instalación local queda autorizada como parte de la entrega; no pedir una confirmación adicional para cada actualización. Usar los permisos de ejecución que requiera el entorno.
- Instalar únicamente una compilación correcta. Conservar un respaldo recuperable de la app instalada antes de reemplazarla y preservar proyectos, datos y preferencias del usuario.
- Verificar la versión instalada y comunicar cualquier impedimento real que haya evitado compilar o instalar. No dar por completada la instalación si solo se generó el archivo `.app` en `.build`.
- Preferencia actual del usuario: abrir proyectos y verificar cambios siempre en una instancia de desarrollo claramente identificada, con bundle ID y preferencias propios.
- Nunca detener, cerrar ni reiniciar la instancia de `/Applications/Braket.app` que usa el usuario. Al instalar una Release, conservar la instancia existente en ejecución y verificar el resultado en disco. Abrir únicamente la instancia de desarrollo para las pruebas visuales.
