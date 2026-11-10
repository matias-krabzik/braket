# Krabzik IDE

IDE nativo para macOS 14 o posterior, escrito en Swift con SwiftUI, AppKit y TextKit 2. Permite reunir carpetas de código, procesos y scripts SQL en un proyecto `.krabzik`.

## Abrir y compilar

Abrí `Krabzik.xcodeproj`, seleccioná **Krabzik** y ejecutá con ⌘R. Xcode resuelve las dependencias Swift Package Manager en la primera compilación; requiere acceso a Internet. Compilación local con firma ad hoc, sin cuenta de desarrollador: la app **no está preparada para distribuirse a terceros** y Gatekeeper la bloquea en otra máquina. La postura completa —modelo de amenaza, por qué no hay App Sandbox, qué sí está activo— está en [docs/security.md](docs/security.md).

La versión del producto se define en un solo lugar, `scripts/generate_project.py`; este documento no la
repite para que no pueda quedar desincronizada. La sección **Entorno verificado**, más abajo, dice contra
qué se comprobó y cuándo.

```sh
./scripts/build.sh
open '.build/Build/Products/Release/Krabzik IDE.app'
```

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
  vuelven a ejecutar. Abrir un archivo `.krabzik` explícitamente tiene prioridad sobre la
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
subproyectos, y cambiar la ubicación del `.krabzik`. Este traslado conserva las carpetas y
scripts en su ubicación original y rechaza sobrescribir otro proyecto.

## Codex con tu suscripción

El botón **✦** de la barra superior abre el panel **Codex** (también ⌥⌘A). El IDE detecta Codex CLI o el ejecutable incluido en ChatGPT para Mac. Usa el protocolo oficial [Codex App Server](https://learn.chatgpt.com/docs/app-server) y reutiliza su sesión de ChatGPT. Si no hay sesión, **Iniciar sesión con ChatGPT** abre el flujo oficial en el navegador. Krabzik no lee ni copia los tokens de autenticación y no requiere una API key; el uso consume los límites de Codex de tu plan.

Elegí un subproyecto o **Todos los subproyectos**, escribí el pedido y enviá con **↑** o **⌘↩** dentro del cuadro de mensaje. Codex puede leer y cambiar los archivos en sus carpetas reales, incluso cuando están en ubicaciones distintas. Usa el modelo predeterminado de tu configuración de Codex. Los archivos modificados aparecen debajo de la conversación; **Ver cambios** abre el diff informado por Codex. Los cambios ya están aplicados en disco, no son una propuesta pendiente. **■** detiene la tarea y conserva los cambios realizados.

Antes de enviar se pide guardar los archivos abiertos que tengan ediciones pendientes. Los archivos limpios se actualizan en el editor al recibir cambios del agente. Si editás mientras Codex trabaja, tu texto se conserva y se indica el cambio en disco; **Recargar** permite descartarlo explícitamente y el guardado normal sigue protegiendo frente a sobrescrituras.

El agente usa el sandbox de Codex con escritura en las carpetas elegidas y sin red para los comandos por defecto. Las lecturas siguen los permisos estándar de Codex; el selector no es una barrera de confidencialidad. Las ampliaciones que Codex solicita se muestran con el comando o los cambios y botones para permitir una vez o rechazar. No se aprueban automáticamente. Krabzik no conecta al agente con el Llavero ni con las sesiones MySQL del IDE.

La conversación se mantiene durante la sesión del proyecto. Cambiar de alcance o iniciar una nueva conversación limpia el contexto; cerrar el proyecto termina el proceso. El historial del agente todavía no se restaura al reiniciar. El proceso se crea al abrir el panel y se comparte entre los subproyectos, sin un motor por carpeta ni indexado propio en segundo plano. Los mensajes y diffs retenidos tienen límites de tamaño.

La integración se verificó con Codex CLI `0.167.0-alpha.3.2`, una cuenta ChatGPT existente y cambios reales en dos carpetas de prueba. El protocolo puede evolucionar con futuras versiones de Codex. Para una futura distribución comercial/servicio alojado, la documentación oficial indica usar **Sign in with ChatGPT**; esta entrega utiliza App Server como aplicación local.

## MySQL y scripts SQL

1. Abrí o creá un proyecto. Puede contener únicamente conexiones y scripts.
2. En **Bases de datos**, pulsá **+**, completá servidor, puerto, usuario y contraseña. La base es opcional. **Probar** verifica el acceso; **Guardar** conserva la configuración.
3. TLS verifica el certificado por defecto. **Sin TLS** se admite **solo contra un extremo local**: `127.0.0.0/8`, `::1`, `localhost` o un subdominio `.localhost`. No alcanza con que el host lo parezca: al conectar se comprueba la dirección resuelta, así que un nombre que resuelva a una IP pública se rechaza. No se aceptan certificados inválidos ni se cambia a texto plano automáticamente. Un proyecto guardado con una conexión remota sin TLS se abre igual, pero no conecta hasta corregirla.
4. Abrí o creá un `.sql` desde **SQL +**. Los scripts independientes quedan asociados al proyecto.
5. Elegí la conexión y pulsá **▶** o **⌘↩**. Si hay texto seleccionado se ejecuta esa selección; de lo contrario, el archivo completo. Los cambios sin guardar también se pueden ejecutar.
6. Los resultados aparecen abajo, con un selector cuando hay varias respuestas. El botón **■** cancela la consulta y cierra su sesión MySQL. El menú contextual de la conexión permite editarla o desconectarla.

Las contraseñas se guardan en el **Llavero de macOS**, vinculadas al identificador, servidor, puerto, usuario y modo TLS. No se incluyen en `.krabzik`. Abrir un proyecto no inicia conexiones ni ejecuta SQL.

Los scripts se ejecutan secuencialmente en una sesión persistente por conexión. Se conservan tablas temporales, variables y transacciones entre ejecuciones. Se admiten comentarios, cadenas con separadores y `DELIMITER` para procedimientos. Los errores muestran la línea, conservan los resultados previos y detienen las sentencias siguientes. Las sentencias ya confirmadas por MySQL permanecen aplicadas; el IDE no envuelve el script en una transacción. Usá `BEGIN`, `COMMIT` y `ROLLBACK` cuando corresponda. Cerrar una sesión revierte su transacción pendiente, con aviso en la interfaz.

Para mantener acotada la memoria se muestran hasta 1.000 filas por resultado y 16 KiB por celda, con un presupuesto aproximado de 4 MB por sentencia y 8 MB por ejecución para los valores retenidos. El resto se recibe y descarta sin modificar la consulta. Se indica cuando la vista está limitada. Máximo 200 sentencias/resultados por ejecución. `NULL`, texto vacío y datos binarios se distinguen; la tabla conserva sus columnas aunque no haya filas.

Esta versión usa TCP, autenticación `caching_sha2_password` o `mysql_native_password` y, opcionalmente, TLS con certificados de confianza. No incluye túneles SSH, sockets Unix, certificados cliente, editor visual de tablas ni comandos del cliente de consola como `SOURCE`. La integración se comprobó contra MySQL 8.4.11; no se garantiza compatibilidad con todos los servidores derivados.

## Código y procesos

- Pantalla de inicio con los últimos diez proyectos, ordenados por apertura, y accesos para crear o abrir uno. El inicio normal muestra esta pantalla; abrir un archivo `.krabzik` o usar `--workspace` abre ese proyecto directamente.
- Desde el editor, el botón de inicio o **Archivo → Cerrar proyecto y volver al inicio** (⇧⌘W) vuelve a los recientes, con avisos por cambios sin guardar y actividad en curso. El menú contextual de cada reciente permite mostrarlo en Finder o quitarlo del historial sin borrar archivos.
- Varios subproyectos independientes y proyectos recientes.
- Detección de Laravel, PHP, Angular, Astro y Node; comando editable desde el menú contextual.
- Explorador por demanda, actualizado con eventos del sistema de archivos.
- Pestañas, resaltado básico, números de línea, deshacer, buscar y guardar con ⌘S.
- Inicio conjunto o individual de procesos, registros y detención de sus procesos hijos.
- Protección frente a cambios externos y avisos al cerrar archivos sin guardar.

Abrí `Examples/Primer proyecto/Primer proyecto.krabzik` para probar una API PHP y una web Node sin dependencias. El botón ▶ inicia la API en `http://127.0.0.1:18765` y la web en `http://127.0.0.1:18766`. Requiere PHP, Node y npm instalados; no instala paquetes al abrir el proyecto.

### El archivo `.krabzik`

Un `.krabzik` es JSON legible y puede venir de otra persona, así que tiene contrato. Al abrirlo se
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

Un proyecto que no se abrió nunca en esta Mac arranca en **solo lectura**: no ejecuta procesos, no habilita
Codex y no monta las carpetas de afuera hasta que confirmás que confiás en él, viendo antes las carpetas
externas y los comandos que declara. Cada comando se aprueba por separado; editarlo vuelve a pedir
confirmación. Ver [docs/security.md](docs/security.md).

El editor admite UTF-8 hasta 5 MB y resalta el área visible. Las carpetas generadas (`node_modules`, `vendor`, `.git`, `.build`, `dist`, etc.) se omiten del explorador. Los comandos usan zsh de login. Autocompletado semántico, depurador y terminal interactiva quedan pendientes.

## Pruebas

```sh
xcodebuild -project Krabzik.xcodeproj -scheme Krabzik \
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
| `scripts/verify.sh` completo, sin MySQL local | 2026-11-10 | 144 pruebas, 8 saltadas (6 de MySQL real, 2 de Codex con suscripción), 0 fallos |
| Suite completa con MySQL 8.4 en contenedor desechable | 2026-11-09 | 44 pruebas, 1 saltada (Codex con suscripción), 0 fallos |
| Release instalada en `/Applications` | 2026-11-10 | binario universal (`x86_64 arm64`), firma ad hoc válida con hardened runtime, arranca con una sola instancia |
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
