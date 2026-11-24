# Base de pruebas de relaciones de Braket

Datos ficticios en MySQL 8.4, contenedor `braket-relations-demo`, volumen persistente `braket-relations-demo-data`.

- Servidor: `127.0.0.1:23308`
- Base: `braket_relations_demo`
- Usuario: `braket_demo`
- Contraseña: vacía (solo esta base local de pruebas, accesible únicamente desde esta Mac)
- TLS: desactivado para este servidor local
- Conexión del proyecto: **Pruebas locales · Relaciones**

Abrí **Prueba relaciones.sql** en el proyecto **Krabzik IDE - Braket**. Ejecutá la primera consulta para probar una tarjeta sencilla; el archivo completo también incluye varias relaciones por fila, NULL, claves compuestas, un ID mayor a 2^53 y 120 pedidos con paginación. Podés editar los datos de prueba.

Si Docker estaba cerrado, abrí Docker Desktop y ejecutá `docker start braket-relations-demo`. El contenedor tiene reinicio automático mientras Docker esté funcionando. Para detener solo esta base: `docker stop braket-relations-demo`.

`seed.sql` conserva los registros existentes al volver a ejecutarse. No se elimina el volumen ni se usan otras bases de datos.
