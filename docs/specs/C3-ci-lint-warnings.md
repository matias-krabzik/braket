# C3 · CI, linter y warnings como errores

| | |
|---|---|
| **Severidad** | Alta |
| **Área** | Proceso, configuración del build |
| **Archivos** | `scripts/generate_project.py`, nuevos `scripts/verify.sh`, `.swiftlint.yml`, `.swiftformat`, `.github/workflows/ci.yml` |
| **Depende de** | C1, C2 |
| **Habilita** | C8 (chequeo del `.pbxproj`), S7 (pruebas de MySQL obligatorias) |
| **Esfuerzo** | 4–6 horas |

## Problema

No existe ninguna barrera automática:

- No hay `.github/workflows/`, ni ningún otro runner. Nada compila ni prueba el proyecto salvo a mano.
- No hay `SWIFT_TREAT_WARNINGS_AS_ERRORS` ni `GCC_TREAT_WARNINGS_AS_ERRORS` en
  `generate_project.py`.
- No hay linter ni formateador configurado, y el estilo del código es muy particular (ver C4): sin una
  regla escrita, cada archivo nuevo lo reinterpreta.
- 6 de las 29 pruebas se saltan por defecto y **nunca** se ejecutan en ningún lugar automático. Son justo
  las que cubren el fork de autenticación de MySQL (S7).

El build actual está limpio, lo cual demuestra que se cuida a mano. El problema es que no hay nada que lo
mantenga así: los avisos de concurrencia de `FileTree.swift` que aparecen en los logs de las 08:27 del
2026-11-09 estuvieron ahí sin que nada los señalara.

## Objetivo

Un cambio que rompa la compilación, introduzca un aviso, rompa una prueba, desincronice el `.pbxproj` o
viole el estilo acordado, falla de forma automática y visible, tanto local como en CI.

## Alcance

**Incluye** warnings como errores, un script de verificación local, configuración de linter y formateador,
y un workflow de CI.

**No incluye** elegir el proveedor de CI ni crear el remoto (C1 lo deja fuera a propósito). El workflow se
escribe para GitHub Actions porque es el caso más probable, y `scripts/verify.sh` hace que el proyecto sea
verificable incluso sin remoto.

## Diseño

### 1. Warnings como errores

En `generate_project.py`, dentro del diccionario `settings` común:

```python
'SWIFT_TREAT_WARNINGS_AS_ERRORS': 'YES',
'GCC_TREAT_WARNINGS_AS_ERRORS': 'YES',
```

Se aplica a Debug y Release. Si durante el desarrollo molesta en Debug, la forma correcta de desactivarlo es
en la invocación (`xcodebuild SWIFT_TREAT_WARNINGS_AS_ERRORS=NO`), no en el proyecto: así el default
versionado sigue siendo estricto.

Prerrequisito real: C2 primero. Con Swift 5 mode y warnings como errores, el estado actual compila, pero
activar los dos a la vez mezcla dos problemas.

### 2. `scripts/verify.sh`

Un solo comando que corre todo lo que CI va a correr, para no descubrir los fallos en CI:

```sh
#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

python3 scripts/generate_project.py --check      # C8
swiftformat --lint .                              # si está instalado
swiftlint --strict                                # si está instalado
scripts/check_vendor.sh                           # S7, saltable sin red
xcodebuild -project Krabzik.xcodeproj -scheme Krabzik \
  -destination 'platform=macOS' -derivedDataPath .build \
  -parallel-testing-enabled NO test
```

Las herramientas opcionales se detectan con `command -v` y se informan como «omitido» en lugar de fallar,
para que el script sirva en una máquina recién configurada. En CI se instalan, así que ahí no se omiten.

### 3. Linter y formateador

El estilo del proyecto es deliberadamente compacto. El linter **no** debe pelear con eso; debe fijar lo que
C4 define como límite:

`.swiftlint.yml`:

```yaml
only_rules:
  - line_length
  - force_unwrapping
  - force_try
  - empty_count
  - unused_import
  - redundant_optional_initialization
  - trailing_whitespace
  - vertical_whitespace
line_length:
  warning: 140
  error: 180
force_unwrapping:
  severity: warning      # hay 1 caso conocido: MySQLClient.eventLoop()
force_try:
  severity: warning      # hay 1 caso conocido: SyntaxStyler.literals
excluded:
  - Vendor
  - .build
```

`only_rules` en lugar de la lista por defecto: se opta por un conjunto chico y acordado, no por el catálogo
completo de SwiftLint, que generaría cientos de avisos y terminaría desactivado.

Regla «una sentencia por línea» (las 120 líneas con `;` que señala C4): SwiftLint no la trae; se cubre con un
chequeo propio en `verify.sh`:

```sh
grep -rn '; ' --include='*.swift' Krabzik KrabzikTests | grep -v 'for ' | grep -v '//'
```

que falla si devuelve algo, una vez que C4 haya limpiado lo existente. Hasta entonces, informativo.

`.swiftformat` con `--maxwidth 140`, `--indent 4`, `--semicolons never`, y `--exclude Vendor,.build`.

### 4. Workflow de CI

`.github/workflows/ci.yml`, en `macos-15` o superior (hace falta Xcode 27 según el README):

```yaml
on: [push, pull_request]
jobs:
  verify:
    runs-on: macos-15
    services:
      mysql:
        image: mysql:8.4
        env: { MYSQL_ALLOW_EMPTY_PASSWORD: "yes", MYSQL_DATABASE: krabzik_qa }
        ports: ['3306:3306']
        options: >-
          --health-cmd="mysqladmin ping -uroot" --health-interval=5s
          --health-timeout=3s --health-retries=20
    steps:
      - uses: actions/checkout@v4
      - run: brew install swiftlint swiftformat
      - run: mkdir -p .build && printf '3306\n' > .build/mysql-test-port
      - run: scripts/verify.sh
      - if: failure()
        uses: actions/upload-artifact@v4
        with: { name: logs, path: .build/Logs }
```

Escribir el marcador `.build/mysql-test-port` hace que las 6 pruebas de MySQL **sí** corran en CI, que es el
punto 3 de S7. El mecanismo de salto se conserva para el desarrollo local.

Nota sobre `-parallel-testing-enabled NO`: el README ya lo usa y hay pruebas que arrancan ventanas y
procesos; mantenerlo.

### 5. Hook local opcional

`docs/contributing.md` (C1) documenta cómo instalar un `pre-commit` que llame a `verify.sh`. No se instala
automáticamente: forzar hooks en el repositorio de otra persona es invasivo.

## Criterios de aceptación

1. `scripts/verify.sh` termina con éxito sobre el árbol limpio y devuelve código distinto de 0 si cualquier
   paso falla.
2. Introducir un aviso del compilador a propósito (una variable sin usar) hace fallar el build.
3. Agregar un archivo `.swift` sin regenerar el proyecto hace fallar `verify.sh` (vía C8).
4. Una línea de 200 columnas hace fallar el lint; una de 150 avisa pero no falla.
5. En CI, la salida de `xcodebuild test` dice `0 tests skipped` (las 29 corren).
6. El workflow existe y es válido (`actionlint` o equivalente), aunque todavía no haya remoto configurado.
7. `swiftformat --lint .` no reporta cambios pendientes después de C4.

## Pruebas

Este spec es infraestructura de pruebas, así que su verificación es ejercitar los criterios 2, 3 y 4 a mano
una vez, en un commit de prueba que después se descarta, y dejar anotado el resultado en el propio spec al
cerrarlo.

## Riesgos y compatibilidad

- **Warnings como errores puede frenar el desarrollo** cuando el SDK o el compilador cambian e introducen
  avisos nuevos en código que no se tocó. La válvula de escape documentada es la variable en la invocación,
  nunca editar el proyecto.
- Las pruebas de MySQL en CI dependen de un contenedor; si el servicio es inestable el pipeline se vuelve
  ruidoso. El `--health-cmd` con 20 reintentos cubre el arranque; si aun así falla, el fallo es real y hay
  que verlo, no silenciarlo.
- Dos pruebas (`testEditorHasVisibleTextGeometry`, y las de `ProcessRunner`) crean ventanas y lanzan
  procesos. En CI sin sesión gráfica pueden comportarse distinto; si aparece inestabilidad, la solución es
  marcarlas y ejecutarlas en un job aparte, no quitarlas.

## Implementado · verificación parcial

**2026-11-09** · commit `7696e36`.

Lo que el spec pedía construir está construido y funcionando. Cuatro de los siete criterios **no se pueden
verificar todavía**, y no por una falta de la implementación: dependen de specs que no están hechos o de un
remoto que no existe. Se listan abajo con quién los desbloquea, en vez de darlos por buenos.

### Entregado

| Pieza | Estado |
|---|---|
| `SWIFT_TREAT_WARNINGS_AS_ERRORS` y `GCC_TREAT_WARNINGS_AS_ERRORS` en `YES` | en las 6 configuraciones |
| `scripts/verify.sh` | 119 líneas, pasos bloqueantes e informativos separados |
| `.swiftlint.yml` | `only_rules` con 8 reglas |
| `.swiftformat` | informativo hasta C4 |
| `.github/workflows/ci.yml` | listo, sin remoto donde correr |
| `docs/contributing.md` | `verify.sh` reemplaza al comando de pruebas; trinquetes y hook documentados |

### Criterios

| # | Criterio | Resultado |
|---|---|---|
| 1 | `verify.sh` pasa en el árbol limpio y falla si algún paso falla | **✓ verificado**: exit 0 en limpio, exit 1 con un fallo inyectado |
| 2 | Un aviso del compilador rompe el build | **✓ verificado**: una variable sin usar dio `error: initialization of immutable value 'avisoDePrueba' was never used` y el build falló |
| 3 | Agregar un `.swift` sin regenerar hace fallar `verify.sh` | **pendiente de C8.** El paso existe pero se omite: `generate_project.py` no tiene `--check`. Ojo: hoy el script **ignora los argumentos y regenera**, así que llamarlo con `--check` reescribiría el `.pbxproj` en silencio. Por eso `verify.sh` detecta la capacidad con `grep -q -- "--check"` antes de invocarlo |
| 4 | Una línea de 200 columnas falla; una de 150 avisa | **desviado** (ver abajo) |
| 5 | En CI corren las 38 pruebas (`0 tests skipped`) | **no verificable**: no hay remoto ni runner. El workflow crea el marcador `.build/mysql-test-port`, que es lo que lo haría cierto |
| 6 | El workflow es válido | **parcial**: estructura y claves comprobadas con un chequeo propio; sin `actionlint` ni corrida real |
| 7 | `swiftformat --lint` sin diferencias | **pendiente de C4**, que es quien formatea |

### Desviaciones del diseño

**1. El umbral de `line_length` y el trinquete.** El diseño fijaba `warning: 140, error: 180` y el criterio 4
pedía que una línea de 200 columnas falle. Medido sobre el código real: la línea más larga tiene **468
columnas** (el patrón de palabras clave de `SyntaxStyler`) y hay **6 por encima de 200**. Con `error: 180`
el lint fallaría sobre el árbol limpio, que contradice el criterio 1 del mismo spec. El spec declaraba
depender de C1 y C2; **le faltaba declarar C4**, que es quien parte las líneas largas.

Resolución: `error: 470` como tope que impide empeorar, y un trinquete en `verify.sh` que es el gate real
—falla si la **cantidad** de líneas de más de 140 columnas sube de 64—. Comprobado: una línea de 250
columnas lleva la cuenta a 65 y `verify.sh` devuelve 1. Cuando C4 baje las líneas, se baja el tope del
script y el umbral de `line_length` a 180.

**2. `swiftlint --strict` no se usa.** Con `--strict` los avisos cuentan como errores, así que una línea de
150 columnas haría fallar el lint, lo que también contradice el criterio 1 con el código de hoy. Queda
`swiftlint lint` a secas; C4 habilita `--strict`.

**3. Trinquetes que el diseño no tenía.** Además de las líneas largas, `verify.sh` pone tope a las líneas
con varias sentencias separadas por `;` (159) y a los bloques `catch` vacíos (10). Son los gates que hacen
verificables C4 y C6 de forma incremental en lugar de todo al final. Nota: los 159 y los 10 cuentan
`Krabzik/` **y** `KrabzikTests/`; C4 y C6 medían solo `Krabzik/` (120 y 2 respectivamente).

**4. MySQL en CI viene de Homebrew, no de un contenedor.** Los `services:` de GitHub Actions solo existen en
runners Linux, y en los de macOS —necesarios para Xcode— no hay Docker preinstalado. El workflow instala
`mysql@8.4` con brew y espera a `mysqladmin ping`. [S7](S7-gobernanza-fork-mysqlnio.md) quedó corregido en
el mismo commit, porque arrastraba el mismo error.

**5. `swiftlint` y `swiftformat` no están instalados** en esta máquina, así que sus pasos se omiten con
aviso y las reglas que escriben los archivos de configuración **no se ejercitaron**. Instalarlos
(`brew install swiftlint swiftformat`) es lo que falta para cerrar de verdad los criterios 4 y 7.

### Lo que falta para cerrar C3

1. Instalar `swiftlint` y `swiftformat` y ajustar lo que reporten.
2. C8, para que el paso del `.pbxproj` deje de omitirse (criterio 3).
3. C4, para bajar los umbrales y pasar `swiftformat` a bloqueante (criterios 4 y 7).
4. Un remoto, para el criterio 5.
