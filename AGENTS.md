# Flujo de entrega de Braket

- Preferencia explícita del usuario: al terminar cambios en la app, compilar y verificar la versión Release e instalarla siempre en `/Applications/Braket.app`.
- La instalación local queda autorizada como parte de la entrega; no pedir una confirmación adicional para cada actualización. Usar los permisos de ejecución que requiera el entorno.
- Instalar únicamente una compilación correcta. Conservar un respaldo recuperable de la app instalada antes de reemplazarla y preservar proyectos, datos y preferencias del usuario.
- Verificar la versión instalada y comunicar cualquier impedimento real que haya evitado compilar o instalar. No dar por completada la instalación si solo se generó el archivo `.app` en `.build`.
- Para verificar visualmente la entrega, abrir únicamente `/Applications/Braket.app` y comprobar que haya una sola instancia. No abrir también la copia de `.build` como alternativa si una herramienta no reconoce la instalada: esto crea otra ventana y otra entrada en el Dock.
