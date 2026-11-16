# S8 · Guarda de escritura por perfil de conexión MySQL

| | |
|---|---|
| **Severidad** | Media |
| **Área** | MySQL, interfaz de ejecución |
| **Archivos** | `Krabzik/Models/DatabaseConnection.swift`, `Krabzik/Services/SQLWriteGuard.swift`, `Krabzik/Services/SQLScript.swift`, `Krabzik/Services/DatabaseController.swift`, `Krabzik/Models/SQLResultEditing.swift`, `Krabzik/Views/DatabaseViews.swift` |
| **Depende de** | S3 (perfiles de conexión), S4 |
| **Esfuerzo** | 1 día |

## Problema

La revisión del camino SQL del 2026-11-15 concluyó que no hay inyección: todo lo que la app compone pasa
por `SQLValue.literal` o `SQLValue.identifier`, las credenciales viven en el llavero y las ediciones de la
grilla van en una transacción con bloqueo optimista, `LIMIT 1`, verificación `FOR UPDATE` y rollback ante
cualquier aviso.

Lo que quedaba abierto era otra cosa: **el editor manda cualquier sentencia sin ninguna barrera**. No había
modo de solo lectura por perfil ni confirmación para `DELETE`, `UPDATE`, `DROP` o `TRUNCATE`. Elegir una
conexión de producción en el selector del script y pulsar ⌘↩ con el cursor en la línea equivocada alcanzaba
para escribir en producción. La única señal de «esto es producción» era el color del perfil, y la protección
real quedaba delegada por completo a los `GRANT` del servidor —que en la práctica suelen ser los de un
usuario con permisos de escritura, porque es el mismo usuario con el que se trabaja.

## Objetivo

Un perfil puede declarar qué le permite al editor. Apuntar el editor a una base de producción deja de estar
a un clic de distancia de un `DELETE` sin `WHERE`, sin que eso cambie en nada el comportamiento de los
perfiles que ya existen.

## Alcance

Entra: la política por perfil, la clasificación de sentencias, el punto de control antes de ejecutar, el
bloqueo de las ediciones de la grilla, el selector en la hoja del perfil y el indicador en la barra de
ejecución.

Queda afuera: cualquier promesa de que la app impida escribir. La guarda es local y por eso es evitable
—basta cambiar la política del perfil—; no sustituye a los `GRANT` del servidor, que siguen siendo el único
control que un usuario no puede desactivar desde la app. Tampoco entra una política por base de datos ni
por tabla, ni recordar la confirmación durante la sesión.

## Diseño

### 1. `DatabaseConnection.writePolicy`

Campo **opcional** `writePolicy: String?` con tres niveles (`unrestricted`, `confirm`, `readOnly`), y
`effectiveWritePolicy` que lo interpreta. Dos decisiones:

- **Ausente significa `unrestricted`.** Los perfiles guardados antes de que existiera el campo se comportan
  exactamente como antes, y un `.kzk` viejo se lee sin migración.
- **Se guarda como texto, no como enum.** Un valor que esta versión no conozca no puede impedir que el
  proyecto se abra: `effectiveWritePolicy` lo lee como `readOnly`, el nivel más restrictivo, y
  `validated(.strict)` lo rechaza recién al guardar. Es el mismo reparto strict/lenient de S3.

### 2. Clasificación: `SQLWriteGuard`

`SQLWriteGuard.effect(of:)` recibe el texto de **una** sentencia ya separada por `SQLScript` y dice si
escribe. **Falla cerrada**: solo una lista corta de formas cuenta como lectura —`SELECT` sin bloqueo ni
`INTO`, `WITH … SELECT`, `SHOW`, `DESCRIBE`/`DESC`, `EXPLAIN`, `USE`, `SET` de variables de sesión y
`START TRANSACTION`/`COMMIT`/`ROLLBACK`—; todo lo demás es escritura, incluida una sentencia cuya primera
palabra no se reconoce, una sin ninguna palabra y un comentario ejecutable `/*!`.

Casos que la lista de lecturas **no** incluye, porque no son lecturas inocuas: `SELECT … FOR UPDATE`,
`SELECT … FOR SHARE` y `LOCK IN SHARE MODE` bloquean filas; `SELECT … INTO` escribe en un archivo, una
variable o una tabla; `EXPLAIN ANALYZE` ejecuta la consulta de verdad; `WITH … DELETE` es un DML (MySQL 8
admite CTE delante de `UPDATE` y `DELETE`); `SET GLOBAL`, `SET PERSIST` y `SET PASSWORD` tocan el servidor
y no la sesión; `BEGIN`, `TABLE t` y `SAVEPOINT` no están en la lista y por lo tanto cuentan como escritura.

`SQLWriteGuard.audit(_:)` clasifica el script completo con el mismo cursor `SQLScript` que usa la ejecución,
así que respeta cadenas, comentarios, `DELIMITER` y rutinas.

**Un solo recorrido léxico.** La clasificación no trae su propio parser: `SQLScript.scan(_:)` saltea
cadenas, identificadores entre backticks y comentarios con las mismas reglas que `next()` y devuelve las
palabras desnudas con su profundidad de paréntesis. `SQLPagination` pasó a usarlo también, así que donde
antes había dos recorridos con reglas parecidas ahora hay uno. Dos recorridos distintos sobre el mismo
texto, uno para decidir qué se ejecuta y otro para decidir si escribe, serían dos reglas que se separan.

### 3. Punto de control: `DatabaseController.execute(...)`

Antes de cualquier trabajo de conexión —antes de leer el llavero y de crear la `Task`—, `execute` clasifica
todas las sentencias del script:

- `unrestricted`: **no se clasifica nada**. El camino es byte por byte el de antes, incluida la forma en que
  hoy se informa un script que no se puede partir (la primera sentencia se parsea acá y el resto en
  `MySQLClient`), así que un script cuya quinta sentencia tiene una cadena sin cerrar sigue ejecutando las
  cuatro primeras.
- `readOnly` con escrituras: `execution.error` nombra el perfil, cuántas sentencias se rechazaron, la línea
  de la primera y dice que no se abrió ninguna conexión. No se abre sesión, no se lee el llavero.
- `confirm` con escrituras: un `NSAlert` con el perfil, el host y la base de destino, cuántas sentencias
  escriben y las primeras tres recortadas. El botón destructivo **no** es el predeterminado: ⏎ cancela.

La confirmación es **por ejecución**: no se recuerda nada entre ejecuciones ni durante la sesión.

### 4. Ediciones de la grilla

El camino de `apply(...)` ya tiene su propia hoja de revisión, y con `confirm` eso alcanza. Con `readOnly`
queda bloqueado por dos lados: `SQLResultDraft.readOnlyReason` devuelve un motivo —así `canEdit` es `false`
y la grilla, el menú contextual y el botón de enviar quedan apagados con el motivo a la vista— y
`DatabaseController.submit` vuelve a comprobar la política antes de mandar, por si el perfil cambió entre
ejecutar y enviar.

### 5. Interfaz

Selector de la política en la hoja del perfil, junto al tinte, que es la otra pieza que ya hablaba de
producción. Indicador permanente en la barra de ejecución, al lado del destino: «Solo lectura» o «Confirmar
escrituras», con su icono. Las tarjetas de la ventana de conexiones muestran la política junto al usuario y
el modo de TLS. `unrestricted` no muestra nada: es lo normal y un indicador para el caso normal se vuelve
invisible.

## Criterios de aceptación

1. Un perfil en `readOnly` rechaza un `UPDATE` del editor **sin abrir conexión**, con un mensaje que nombra
   el perfil.
2. Un perfil en `confirm` pregunta una vez por ejecución y ejecuta solo si el usuario acepta; ⏎ cancela.
3. Un perfil `unrestricted` —y uno guardado antes de que el campo existiera— se comporta exactamente como
   antes.
4. Con `readOnly` la grilla no permite editar ni enviar cambios, y el motivo se ve en el panel.
5. Una sentencia que la clasificación no reconoce con certeza cuenta como escritura.
6. Un `.kzk` con una política desconocida se abre y queda en `readOnly`; guardarla desde la hoja falla.

## Pruebas

`KrabzikTests/SQLWriteGuardTests.swift`: la clasificación sobre lecturas, escrituras, casos ambiguos,
cadenas, comentarios, `DELIMITER`, rutinas y `NO_BACKSLASH_ESCAPES`; el round trip del perfil con y sin el
campo; la política desconocida en un `.kzk` real. `KrabzikTests/SQLWorkspaceTests.swift`: que `readOnly`
rechace un `UPDATE` sin abrir conexión ni leer el llavero, que deje pasar un `SELECT` y que `unrestricted`
no clasifique nada.

## Riesgos y compatibilidad

El riesgo real es un falso positivo: una lectura clasificada como escritura hace que un perfil en `confirm`
pregunte de más y que uno en `readOnly` rechace algo legítimo. Es el precio de fallar cerrada, y la salida
está a la vista del usuario —cambiar la política del perfil—. El riesgo inverso, una escritura clasificada
como lectura, sería la falla grave: por eso la lista de lecturas es corta, explícita y está cubierta por
pruebas, y por eso `SELECT … FOR UPDATE`, `SELECT … INTO` y los comentarios ejecutables están afuera.

Los `.kzk` y los perfiles guardados no necesitan migración.
