# Braket

IDE nativo para macOS 14 o posterior, escrito en Swift con SwiftUI, AppKit y TextKit 2. Permite reunir carpetas de código, procesos y scripts SQL en un proyecto `.kzk`.

## Abrir y compilar

Abrí `Braket.xcodeproj`, seleccioná **Braket** y ejecutá con ⌘R. Xcode resuelve las dependencias Swift Package Manager en la primera compilación; requiere acceso a Internet. `scripts/build.sh` genera la Release local con firma ad hoc y sin runtime reforzado para poder cargar Sparkle; la publicación para terceros usa Developer ID Application, runtime reforzado y notarización, como se explica en [docs/updates.md](docs/updates.md). La postura de seguridad completa está en [docs/security.md](docs/security.md).

La versión del producto se define en un solo lugar, `scripts/generate_project.py`; este documento no la
repite para que no pueda quedar desincronizada. La sección **Entorno verificado**, más abajo, dice contra
qué se comprobó y cuándo.

```sh
./scripts/build.sh
```

El bundle se genera en `.build/Build/Products/Release/Braket.app`. La entrega local
se instala en `/Applications/Braket.app`, con respaldo de la versión anterior,
según `AGENTS.md`.

La app compilada se conecta directamente a MySQL: no requiere instalar `mysql`, MySQL Workbench ni Docker. El servidor MySQL debe existir y estar accesible.

## Icono editable

Abrí `Krabzik/AppIcon.icon` con **Icon Composer** (Xcode → Open Developer Tool → Icon Composer). El diseño conserva el fondo grafito y el símbolo blanco `<>`, con dos capas SVG independientes dentro del grupo **Code — Porcelain**. Seleccioná el grupo para ajustar reflejos, sombra, refracción o translucidez; seleccioná **AppIcon** para cambiar el fondo. Podés comprobar las apariencias Default, Dark y Mono desde el lienzo.

El archivo `.icon` está integrado en los recursos del target y configurado como `AppIcon` en Debug y Release. Guardá en Icon Composer y volvé a compilar para incorporar los cambios. Xcode genera los recursos nativos y el `.icns` compatible con versiones anteriores de macOS.

Los SVG originales están en `Design/Icon/Source/`; para actualizar sus formas, usá **Image → Replace** en cada capa. `Design/Icon/Krabzik-Icon-Preview.png` es una exportación estática de referencia; el archivo editable es `Krabzik/AppIcon.icon`.

## Configuración

Abrí **Configuración** desde la parte inferior del lateral de inicio, el engranaje del editor o **⌘,**. Incluye:

- **Tema:** Grafito, inspirado en el icono, o Azul noche. Se aplica al instante al inicio,
  editor, paneles y consola; la elección se conserva al reiniciar.
- **Abrir último estado:** recupera el proyecto, los proyectos abiertos en su orden manual, las pestañas y el
  subproyecto seleccionados, y la visibilidad del explorador y los procesos. Está desactivado
  por defecto. El estado se guarda al confirmar la salida de la app; cerrar el proyecto
  vuelve al inicio y borra esa sesión. Los procesos, consultas SQL y tareas de Codex no se
  vuelven a ejecutar. Abrir un archivo `.kzk` explícitamente tiene prioridad sobre la
  sesión guardada. Los archivos que ya no estén disponibles se omiten con un aviso.

La barra izquierda del editor muestra únicamente proyectos abiertos. Cada uno se puede cerrar
con la × que aparece al pasar el mouse; al cerrar el último se vuelve al inicio.
El cierre pide confirmación y muestra el estado de los procesos mientras se detienen.
Los que sigan activos se pueden forzar con una confirmación adicional; también se puede
dejar el proyecto abierto. El orden no cambia al seleccionar otro
proyecto: arrastrá un icono sobre otro para reordenarlos. Al cambiar se conservan las pestañas,
con los diálogos habituales para guardar cambios y detener procesos si hace falta.

En **Configuración → Proyecto** podés editar el nombre, elegir un tono predefinido o
personalizado y activar el efecto glass del icono. También permite agregar, editar y quitar
subproyectos, y cambiar la ubicación del `.kzk`. Este traslado conserva las carpetas y
scripts en su ubicación original y rechaza sobrescribir otro proyecto.

## Base de IA para el editor

La interfaz de conversaciones y sesiones de Codex se retiró. El editor muestra archivos y conexiones de base de datos. La integración con Codex App Server, sus modelos, el control del ejecutable y el contexto del editor permanecen en el código para incorporar correcciones con IA directamente sobre un archivo más adelante. Las sesiones existentes no se borran; las pestañas antiguas de Codex no se restauran.

Las automatizaciones que usan Codex conservan una hoja pequeña para conectar la cuenta. Braket no lee ni copia los tokens de autenticación y no requiere una API key para la sesión de ChatGPT.

## MySQL y scripts SQL

`SET LIST` captura una columna de un SELECT como lista de Braket en memoria, por proyecto:

```sql
SET LIST organizaciones = (
    SELECT id FROM Organization WHERE name LIKE 'name%'
);
SELECT * FROM Users WHERE organization_id IN ({{organizaciones}});
```

Braket envía únicamente el SELECT de captura y sustituye `{{organizaciones}}` antes de enviar la
consulta siguiente. Una píldora azul muestra la cantidad; su tooltip incluye valores y origen.
Hacé clic en la píldora para abrir una tarjeta con búsqueda y copiar los valores en formato SQL.
Si filtrás la tabla, **Copiar filtrados** copia únicamente las coincidencias. Las píldoras de SET
normales también permiten consultar y copiar su valor, sin ejecutar otra consulta.
Los iconos pequeños de la píldora copian directamente la referencia completa (izquierda) y sus
valores (derecha); el centro conserva el acceso al detalle.
Las referencias tienen resaltado y autocompletado. Los números conservan su precisión y los textos
se citan como literales SQL. Se omiten NULL y duplicados, conservando el orden. Una lista vacía,
inexistente o truncada detiene la consulta. El máximo es 10.000 filas por captura, sin listas parciales.
No se guardan en disco y sobreviven a una reconexión de MySQL, hasta cerrar la aplicación.

La herramienta **Logs** de la barra lateral abre el historial SQL del proyecto en el panel inferior.
La pestaña **Logs** es fija, no tiene botón de cierre y comparte la barra con las pestañas de resultados.
El editor permanece visible al consultar el historial. Guarda cada consulta
enviada al servidor, incluidas las del explorador y la grilla, con fecha, conexión, base, duración,
estado, filas y error. La búsqueda encuentra palabras de SQL, conexión o base; se cargan las últimas
200 ejecuciones y el botón **Cargar 200 anteriores** permite consultar las anteriores.
Al seleccionar una ejecución se muestra el SQL completo y se puede copiar.

El historial persiste al cerrar la app en una base SQLite por ruta de proyecto, dentro de
`~/Library/Application Support/Braket/QueryHistory/`. El botón de carpeta de Logs muestra su archivo.
Usa WAL, índices y búsqueda FTS5; no almacena las filas de los resultados ni las credenciales de conexión.
El texto SQL sí se conserva tal como se envió, incluidos sus valores literales. Mover el archivo del
proyecto a otra ruta inicia un historial separado y conserva el anterior en disco.

Si falla una conexión, Braket registra los intentos en `~/Library/Logs/Braket/mysql.jsonl` (hasta 512 KiB más
una copia anterior). En **Configuración → General → Exportar diagnóstico MySQL…** se genera un archivo de texto
que podés llevar a otra computadora para consultar la causa. También está disponible cuando falla **Probar**, en la misma hoja. Registra hora, duración, etapa y códigos de error
de red/TLS, sin contraseña, usuario, servidor, IP, base de datos ni texto SQL.

1. En **Configuración → Conexiones**, agregá los perfiles MySQL. Son globales y se comparten entre proyectos.
2. Completá servidor, puerto, usuario y contraseña. La base es opcional. **Probar** verifica el acceso; **Guardar** conserva el perfil.
3. Elegí la política SSL. Podés exigir cifrado con verificación de identidad (predeterminado), verificar solo la CA, exigir SSL sin verificar el certificado, usar SSL si está disponible o desactivarlo. Las opciones menos estrictas explican su alcance en el formulario.
4. El explorador muestra un único árbol de archivos y carpetas. Los scripts SQL se abren desde allí; el menú **+** permite agregar carpetas, importar consultas o crear un script.
5. Cada script tiene su propio selector de conexión encima del editor. La elección se recuerda por ruta de archivo en esta Mac y no cambia las otras pestañas. **Conectar** abre una sesión sin ejecutar SQL; **Ejecutar** o **⌘↩** usa la selección o el archivo completo.
6. Podés mantener varias conexiones abiertas y ejecutar scripts en sesiones distintas. Cambiar el selector no cierra otras conexiones. No se puede cambiar el destino de un script mientras ejecuta.
7. Los resultados conservan el nombre de la conexión que los produjo. **Cancelar** detiene la consulta y cierra su sesión. Desde **Conexiones** podés editar, conectar o desconectar cada perfil.

Las conexiones antiguas de proyectos confiables se importan una sola vez al catálogo global.
Las contraseñas siguen en el **Llavero de macOS**, vinculadas al identificador, servidor, puerto, usuario y modo TLS.
Los perfiles y las selecciones por archivo se guardan en preferencias locales; las contraseñas no se incluyen en ellas ni en el `.kzk`.
Abrir un proyecto no inicia conexiones ni ejecuta SQL. Quitar una conexión no asigna automáticamente otra a sus scripts.
Las sesiones inactivas permanecen abiertas al cambiar de proyecto; las consultas o transacciones pendientes conservan sus confirmaciones de cierre.

Los scripts se ejecutan secuencialmente en una sesión persistente por conexión. Se conservan tablas temporales, variables y transacciones entre ejecuciones. Se admiten comentarios, cadenas con separadores y `DELIMITER` para procedimientos. Los errores muestran la línea, conservan los resultados previos y detienen las sentencias siguientes. Las sentencias ya confirmadas por MySQL permanecen aplicadas; el IDE no envuelve el script en una transacción. Usá `BEGIN`, `COMMIT` y `ROLLBACK` cuando corresponda. Cerrar una sesión revierte su transacción pendiente, con aviso en la interfaz.

Para mantener acotada la memoria se muestran hasta 1.000 filas por resultado y 16 KiB por celda, con un presupuesto aproximado de 4 MB por sentencia y 8 MB por ejecución para los valores retenidos. El resto se recibe y descarta sin modificar la consulta. Se indica cuando la vista está limitada. Máximo 200 sentencias/resultados por ejecución. `NULL`, texto vacío y datos binarios se distinguen; la tabla conserva sus columnas aunque no haya filas.

Esta versión usa TCP, autenticación `caching_sha2_password` o `mysql_native_password` y, opcionalmente, TLS con certificados de confianza. No incluye túneles SSH, sockets Unix, editor visual de tablas ni comandos del cliente de consola como `SOURCE`. La integración se comprobó contra MySQL 8.4.11; no se garantiza compatibilidad con todos los servidores derivados.

## Código y procesos

- Pantalla de inicio con los últimos diez proyectos, ordenados por apertura, y accesos para crear o abrir uno. El inicio normal muestra esta pantalla; abrir un archivo `.kzk` o usar `--workspace` abre ese proyecto directamente.
- Desde el editor, el botón de inicio o **Archivo → Cerrar proyecto y volver al inicio** (⇧⌘W) vuelve a los recientes, con avisos por cambios sin guardar y actividad en curso. El menú contextual de cada reciente permite mostrarlo en Finder o quitarlo del historial sin borrar archivos.
- Varios subproyectos independientes y proyectos recientes.
- Detección de Laravel, PHP, Angular, Astro y Node; comando editable desde el menú contextual.
- Explorador por demanda, actualizado con eventos del sistema de archivos.
- Pestañas, resaltado básico, números de línea, deshacer, buscar y guardar con ⌘S.
- Los archivos Markdown tienen edición, vista previa y dos paneles. Los botones de zoom están abajo a la derecha de cada preview; el porcentaje se comparte entre archivos y se conserva al reiniciar.
- Inicio conjunto o individual de procesos, registros y detención de sus procesos hijos.
- Protección frente a cambios externos y avisos al cerrar archivos sin guardar.

Abrí `Examples/Primer proyecto/Primer proyecto.kzk` para probar una API PHP y una web Node sin dependencias. El botón ▶ inicia la API en `http://127.0.0.1:18765` y la web en `http://127.0.0.1:18766`. Requiere PHP, Node y npm instalados; no instala paquetes al abrir el proyecto.

Los proyectos nuevos se guardan como `.kzk`. Los archivos `.krabzik` anteriores siguen abriendo y conservan su ubicación.

### El archivo `.kzk`

Un `.kzk` es JSON legible y puede venir de otra persona, así que tiene contrato. Al abrirlo se
rechaza, con un mensaje que dice qué campo y de qué subproyecto, el archivo que supere estos topes o que
traiga texto que no se puede mostrar con honestidad:

| Tope | Valor |
|---|---|
| Subproyectos | 64 |
| Conexiones | 32 |
| Scripts SQL | 512 |
| Nombres | 200 caracteres |
| Rutas | 1.024 caracteres |
| Comandos | 4.000 caracteres |

Además: nada de caracteres de control, overrides bidi ni zero-width en nombres, rutas y comandos —un
comando sí puede tener saltos de línea—, y ninguna ruta relativa que salga de la carpeta del proyecto
(`../..`). Las rutas absolutas se admiten: el proyecto puede tener carpetas afuera, y en ese caso hay que
confiar en él para que se monten. Las rutas de los scripts se normalizan, así que `sql/a.sql` y
`./sql/a.sql` son la misma entrada. Los valores son holgados respecto del uso real; si tu proyecto
legítimo supera uno, se sube el número en `WorkspaceLimits`.

Un proyecto que no se abrió nunca en esta Mac arranca en **solo lectura**: no ejecuta procesos ni
automatizaciones con Codex y no monta las carpetas de afuera hasta que confirmás que confiás en él, viendo antes las carpetas
externas y los comandos que declara. Cada comando se aprueba por separado; editarlo vuelve a pedir
confirmación. Ver [docs/security.md](docs/security.md).

El editor admite UTF-8 hasta 5 MB. Usa Tree-sitter con las gramáticas de CodeEditLanguages para resaltar según la extensión del archivo, incluidos Swift, Dart, JavaScript/JSX, TypeScript/TSX, PHP, SQL, Python, HTML, CSS, JSON y Markdown. Mantiene un árbol incremental por documento fuera del hilo de interfaz y aplica colores únicamente al área visible. En HTML, los bloques `<script>` y `<style>` tienen resaltado de JavaScript y CSS, incluidos módulos y bloques JSON según su atributo `type`. Cada bloque conserva su propio contexto y se actualiza al editar. Los formatos sin gramática quedan como texto plano. Los atributos inline (`style`, `onclick`, etc.) y las inyecciones en otros lenguajes todavía no se analizan por separado. Un análisis que excede 250 ms se interrumpe para mantener acotado el trabajo y deja esa actualización sin colores. Las carpetas generadas (`node_modules`, `vendor`, `.git`, `.build`, `dist`, etc.) se omiten del explorador. Los comandos usan zsh de login. Autocompletado semántico, depurador y terminal interactiva quedan pendientes.

## Pruebas

Hay dos niveles. La suite de siempre —unidad e integración— y, encima, el **QA automatizado
de la interfaz**: casos que montan la pantalla de verdad, usan los controles por su
identificador y afirman cómo reaccionó la app leyendo un registro de eventos que la propia
app emite en Debug. Su entrada por terminal es `scripts/qa.sh` y su catálogo
`KrabzikTests/QA/cases.json`; está documentado en [docs/qa-automation.md](docs/qa-automation.md).

```sh
scripts/qa.sh --list        # el catálogo de casos de interfaz
scripts/qa.sh               # corre los 115 casos del catálogo
scripts/qa.sh --mysql       # además, los que necesitan un MySQL desechable
```

Los 115 casos del catálogo están automatizados: 109 corren siempre y 6 esperan el MySQL
desechable.

La suite completa, que incluye los casos de QA:

```sh
xcodebuild -project Braket.xcodeproj -scheme Braket \
  -destination 'platform=macOS' -derivedDataPath .build \
  -parallel-testing-enabled NO test
```

La suite tiene 36 pruebas: navegación, editor, persistencia, procesos, SQL/MySQL y Codex. Las seis pruebas de MySQL real se omiten si no existe `.build/mysql-test-port`. La prueba de inferencia real de Codex se habilita creando `.build/codex-live-tests`; requiere una sesión de ChatGPT y consume una pequeña tarea del plan. Crea dos subproyectos temporales y comprueba cambios reales en ambos. Quitá el marcador al terminar para que las ejecuciones normales no consuman la suscripción. Las pruebas de protocolo, permisos, cancelación, Unicode y protección de archivos se ejecutan localmente con un servidor simulado, sin inferencia.

Para habilitarlas, creá una instancia desechable; nunca apuntes el marcador a una base de uso real. Las pruebas crean usuarios y procedimientos temporales en esa instancia:

```sh
mkdir -p .build
docker run -d --rm --name krabzik-mysql-tests \
  -p 127.0.0.1:23307:3306 --tmpfs /var/lib/mysql \
  -e MYSQL_ALLOW_EMPTY_PASSWORD=yes -e MYSQL_DATABASE=krabzik_qa mysql:8.4
# Esperá hasta que mysqladmin responda:
docker exec krabzik-mysql-tests mysqladmin ping -uroot
printf '23307\n' > .build/mysql-test-port
# Ejecutá xcodebuild test con el comando anterior.
docker stop krabzik-mysql-tests
rm .build/mysql-test-port
```

En la verificación final de la v0.3 pasaron 29 pruebas locales, sin fallos; se omitieron las seis de MySQL real y la de inferencia Codex por no tener sus marcadores activos. La prueba real de Codex se ejecutó por separado y pasó: lectura y modificación de dos subproyectos con una sesión ChatGPT. También se comprobó desde el panel una consulta sobre el ejemplo y la ejecución de cambios en dos archivos de prueba. La integración MySQL y la navegación de la pantalla de inicio se habían verificado previamente.

## Entorno verificado

Datos de la última comprobación, no promesas permanentes.

| Qué | Cuándo | Resultado |
|---|---|---|
| Xcode 27.1 / Swift 6.4, Swift 6 language mode | 2026-11-10 | compila sin avisos propios |
| `scripts/verify.sh` completo, sin MySQL local | 2026-11-17 | 589 pruebas, 18 saltadas (MySQL real, Codex con suscripción y los casos de QA que necesitan servidor), 0 fallos |
| Suite completa con MySQL 8.4 en contenedor desechable | 2026-11-09 | 44 pruebas, 1 saltada (Codex con suscripción), 0 fallos |
| Release instalada en `/Applications` | 2026-11-17 | 0.5.16 build 80, binario universal (`x86_64 arm64`), firma Developer ID válida, arranca con una sola instancia |
| `scripts/qa.sh`, catálogo de interfaz, sin MySQL desechable | 2026-11-17 | 115 casos: 109 en verde, 6 omitidos por falta de servidor, ninguno sin automatizar |
| swiftlint 0.65.1 / swiftformat 0.64.6 | 2026-11-10 | `--strict` sin errores y **cero avisos** |

No se garantiza compatibilidad con servidores derivados de MySQL ni con versiones de Xcode anteriores.

## Organización y dependencias

- `Krabzik/Models`: formato del proyecto, documentos y estado SQL.
- `Krabzik/Services`: archivos, procesos, cliente MySQL, análisis SQL y Llavero.
- `Krabzik/Editor`: AppKit/TextKit 2 y consola.
- `Krabzik/Views`: SwiftUI y tabla nativa de resultados.
- `Vendor/MySQLNIO`: cliente Swift con correcciones locales documentadas en `UPSTREAM.md`.
- `KrabzikTests`: pruebas unitarias e integración.

El editor evita propagar cada pulsación por SwiftUI. Los registros y resultados tienen límites; no hay sondeos periódicos en reposo. El cliente MySQL crea un único hilo de eventos cuando se usa por primera vez y mantiene una conexión por perfil utilizado. Cada proceso de código tiene su propio grupo para detener también a sus hijos.

Las versiones de las dependencias están fijadas en `Package.resolved`. Las licencias se incluyen en `Krabzik/Resources/ThirdPartyNotices.txt` y dentro de la app. Para regenerar el proyecto Xcode después de agregar archivos Swift: `python3 scripts/generate_project.py`.

### Conexiones por proyecto

Las conexiones nuevas pertenecen al proyecto abierto. En **Administrar conexiones → Compartidas** se pueden buscar y agregar perfiles reutilizables sin volver a ingresar la contraseña. La opción **Compartir con otros proyectos** de la edición habilita esa reutilización; editar un perfil compartido actualiza los proyectos que lo usan. Para una variante privada de un perfil utilizado en otros proyectos, duplicarlo.

Las conexiones de versiones anteriores se conservan como compartidas y se agregan explícitamente a cada proyecto. Las declaradas en un proyecto antiguo confiable se conservan en ese proyecto al importarlo. Quitar una compartida del proyecto no la borra del catálogo ni del llavero; desde Configuración sin proyecto abierto se puede eliminar del catálogo completo. Los perfiles, las asociaciones locales y los recientes se guardan en las preferencias de esta Mac, y las contraseñas permanecen en el llavero. Cada proyecto conserva sus propias selecciones por archivo y sus recientes.

### Pestañas de resultados

Ejecutar el archivo SQL completo reemplaza los resultados anteriores sin fijar y conserva los fijados. La ejecución de una selección o sentencia mantiene los demás resultados. Con clic derecho en una pestaña o desde el menú de tres puntos se puede cerrar la actual, las demás, las de la izquierda o derecha, las sin fijar o todas. Las acciones manuales pueden cerrar pestañas fijadas; las que cargan o envían cambios no se cierran. Si hay ediciones pendientes, se confirman antes de cerrar el grupo y cancelar conserva todas las pestañas.

### Edición con subconsultas y timeout SQL

Los resultados de un SELECT exterior de una sola tabla pueden editarse cuando las subconsultas aparecen en los filtros WHERE y el resultado conserva su clave primaria completa (o una clave única no nullable si la tabla no tiene PK). Se usan los metadatos reales de MySQL y la clave original de cada fila. Las escrituras mantienen la lectura FOR UPDATE, la comparación de valores originales y el rollback si hay conflictos. JOIN, UNION, agrupaciones exteriores, tablas derivadas y proyecciones calculadas siguen siendo de solo lectura.

El timeout inicial de la aplicación es **60 segundos por sentencia**. Se configura en Configuración → Apariencia → SQL; el proyecto puede establecer otro en su configuración. El control del editor guarda un ajuste propio para ese archivo y proyecto, recordándolo al volver a abrirlo. **Heredar** elimina ese ajuste para usar el del proyecto o, si no tiene, el de la aplicación. En un archivo completo cada sentencia tiene su propio límite, y una ejecución en curso conserva el límite con el que comenzó.
