# QA automatizado de la interfaz

Pruebas que ejercitan la interfaz como la usa una persona —buscan el botón, comprueban que
esté habilitado, lo usan— y después afirman **cómo reaccionó la app** leyendo un registro
de eventos que la propia app emite en Debug.

Entrada por terminal: `scripts/qa.sh`. Catálogo de casos: `KrabzikTests/QA/cases.json`.

```sh
scripts/qa.sh --list                 # el catálogo entero, con pasos y expectativa
scripts/qa.sh                        # corre todos los casos automatizados
scripts/qa.sh --suite SQL,GRI        # solo esas suites
scripts/qa.sh --case GRI-06          # un caso
scripts/qa.sh --mysql                # además, los que necesitan un MySQL desechable
scripts/qa.sh --json informe.json    # informe legible por máquina
```

## Por qué no alcanza con una prueba de unidad

Una prueba de unidad puede llamar a `controller.database.submit(...)` y pasar aunque el
botón «Guardar cambios» esté deshabilitado, o no exista. Lo que hay que poder afirmar es
otra cosa: **si la interfaz dice Editar, lo que se edita tiene que quedar en modo edición,
aceptar un cambio y poder guardarse**; y cuando no se puede, hay que decir por qué.

Por eso hay tres piezas y no una.

### 1. El registro: `QAProbe`

Una línea por cosa que pasa, en NDJSON. Los nombres van de lo general a lo particular y son
el contrato que las pruebas afirman:

| Clase | Qué es | Ejemplos |
|---|---|---|
| `action` | lo que pidió el usuario | `project.open.request`, `grid.edit.begin`, `connection.save.ok` |
| `state` | lo que quedó después | `state.workspace`, `state.connection`, `state.draft`, `state.execution` |
| `control` | lo que la interfaz ofrece | `control.appear`, `control.change`, `control.tap`, `screen.appear` |
| `dialog` | lo que se preguntó **y qué se respondió** | `dialog.project.trust answer=readOnly`, `dialog.sql.confirmWrites answer=cancel` |
| `sql` | etapas de una consulta o conexión | `sql.execute.begin`, `sql.writeGuard.rejected`, `grid.submit.plan` |
| `error` | lo que llegó al usuario | `error.reported`, `connection.connect.failed` |

Una línea de tiempo se lee así:

```
  0.001 state   state.draft       canEdit=true editing=false changes=0
  0.001 action  grid.edit.begin   row=0 column=1 value=ana
  0.001 state   state.draft       canEdit=true editing=true  changes=0
  0.002 action  grid.edit.end     committed=true value=ANA
  0.002 state   state.draft       canEdit=true editing=false changes=1 hasChanges=true
```

**Solo funciona en Debug.** En Release `QAProbe.isActive` es `false` constante y cada
método tiene cuerpo vacío, así que la app que se instala en `/Applications` no abre ningún
archivo, no escribe ninguna línea y no registra ningún control: del andamiaje quedan unas
funciones vacías y algunos literales, nada que se ejecute. `--qa-log` tampoco hace nada ahí.

**Privacidad.** Misma regla que `Log` (ver su documentación): las rutas van abreviadas con
`~`, el SQL recortado, y las contraseñas no entran por ningún campo. Lo que sí entra
—host, puerto, usuario, nombres de tabla— es lo que las aserciones necesitan, y queda en un
archivo local que la corrida crea y borra.

### 2. Los controles: `QAControls` y `.qaControl(...)`

Cada control instrumentado se registra mientras está en pantalla con su identificador, su
texto y si está habilitado:

```swift
Button("Editar") { editing = connection }
    .qaControl("connections.card.edit." + connection.name, title: "Editar",
               enabled: !state.busy && state.status != .connecting) { editing = connection }
```

`enabled` tiene que ser **la misma condición** que su `.disabled(...)` y `action` **la misma
acción** que ejecuta el control: eso es lo que hace que la prueba ejercite la interfaz y no
un camino paralelo. Un botón que desaparece, cambia de texto o queda deshabilitado rompe el
escenario, que es justo lo que se quiere.

`.qaScreen("wizard")` marca una pantalla —una hoja, un panel— para poder afirmar qué está
montado.

### 3. El arnés: `QAHarness`

Monta `WorkspaceView` en una ventana real, con preferencias aisladas (`UserDefaults` por
corrida), carpeta temporal propia y **todos los diálogos contestados por guion**
(`QADialogScript`). Un `NSAlert` de verdad cuelga la corrida: en S1 costó cuatro horas de CI,
así que ningún escenario deja que aparezca uno.

```swift
let qa = try QAHarness(self)
await qa.mount()
try await qa.tap("welcome.create")          // usa el control, falla si está deshabilitado
await qa.assertScreen("wizard")
await qa.assertControl("wizard.next", title: "Continuar", enabled: false)
await qa.assertEvent("wizard.open.request", ["switching": "false"])
```

`settle(...)` es asíncrono a propósito. Un `RunLoop.run(until:)` síncrono bombea AppKit pero
retiene el main actor, así que las tareas de la app no avanzan y la espera se agota siempre;
suspender con `Task.sleep` suelta el actor y, de paso, el run loop reevalúa las vistas.

## El catálogo

`KrabzikTests/QA/cases.json` es la fuente única. Cada caso tiene id, suite, título, los pasos
del usuario, lo que se espera, la prueba que lo ejercita (`null` si todavía no está
automatizado) y etiquetas.

| Suite | Qué cubre |
|---|---|
| `INI` | Inicio: bienvenida, recientes, restauración de sesión |
| `PRJ` | Creación de proyectos: el asistente de tres pasos |
| `ABR` | Abrir, cerrar y cambiar de proyecto, con la confianza en el medio |
| `ARC` | Archivos y pestañas del editor |
| `CON` | Conexiones de base de datos: catálogo, hoja, estado |
| `SQL` | Ejecución de consultas y la guarda de escritura (S8) |
| `GRI` | Grilla de resultados: editar una celda y guardar los cambios |
| `EXP` | Explorador de bases y carga de estructura |
| `PRO` | Procesos de los subproyectos y automatización |
| `CFG` | Configuración, ventana y persistencia de la interfaz |

`QACatalogTests` comprueba que el catálogo esté bien formado —ids únicos, suites conocidas,
clases de prueba que existen de verdad—, así que un catálogo que miente falla en
`scripts/verify.sh` y no cuando alguien corre el runner.

## Casos que necesitan un MySQL de verdad

Los etiquetados `needs-mysql` se saltan solos si no existe `.build/mysql-test-port`. Con
`--mysql`, `scripts/qa.sh` levanta un contenedor desechable (`tmpfs`, sin volumen), escribe el
marcador, corre y apaga todo al terminar.

Nunca apuntes el marcador a una base de uso real: estos casos crean y borran tablas.

A mano, si preferís manejar vos el contenedor, es el mismo procedimiento que documenta el
README para la suite de MySQL.

## Qué pasa cuando algo falla

El informe nombra el caso y la prueba, y deja el camino a la línea de tiempo:

```
  fallo     GRI-08  Un cambio habilita Guardar cambios   QAGridEditingTests/testAChangeEnablesTheSaveButton
            línea de tiempo: .build/qa/logs/QAGridEditingTests.testAChangeEnablesTheSaveButton.ndjson
```

La aserción que falla ya imprime la línea de tiempo completa en el log de xcodebuild
(`.build/qa/xcodebuild.log`): en un escenario de interfaz el valor está en ver la secuencia,
no el valor final.

## Mirar la app a mano con el mismo registro

El registro no es solo para las pruebas. La app en Debug lo enciende por línea de comandos:

```sh
.build/Build/Products/Debug/Braket.app/Contents/MacOS/Braket --qa-log /tmp/sesion.ndjson
```

`--qa` lo deja en memoria y `--qa-echo` lo escribe además en la salida de error. Sirve para
reproducir un problema a mano y leer después exactamente qué hizo la app.

## Agregar un caso

1. Agregalo a `cases.json` con sus pasos y su expectativa, y `"test": null`.
2. Si el control que necesita no está instrumentado, agregale `.qaControl(...)` en la vista,
   con el mismo `enabled` y la misma acción que ya tiene.
3. Si falta un evento para poder afirmar la reacción, emitilo en el servicio que decide
   —no en la vista— con `QAProbe.action/state/sql/dialog`.
4. Escribí el escenario en la suite que corresponda y poné su nombre en `"test"`.
5. `scripts/qa.sh --case TU-ID`.
