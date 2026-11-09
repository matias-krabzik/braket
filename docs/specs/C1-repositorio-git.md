# C1 · Inicializar el control de versiones

| | |
|---|---|
| **Severidad** | Crítica (para «buenas prácticas», es la base de todo lo demás) |
| **Área** | Proceso |
| **Archivos** | `.gitignore`, nuevos `.gitattributes`, `docs/contributing.md` |
| **Depende de** | — |
| **Bloquea a** | Todos los demás specs, en la práctica |
| **Esfuerzo** | 1 hora |

## Problema

```
$ git status
fatal: not a git repository (or any of the parent directories): .git
```

El proyecto **no está bajo control de versiones**. Hay un `.gitignore` escrito y correcto, lo que sugiere
que la intención estaba, pero no hay repositorio. Consecuencias concretas, hoy:

- No hay forma de ver qué cambió ni de revertir. Durante la auditoría del 2026-11-09, ocho archivos
  cambiaron en 20 minutos (16:04 → 16:30) y la única manera de saber qué se modificó fue comparar
  marcas de tiempo y recuentos de líneas.
- La historia del proyecto vive de hecho en `.build/*.log`, que está ignorado y se borra con un
  `rm -rf .build`.
- `AGENTS.md` pide instalar en `/Applications` conservando un respaldo recuperable; ese respaldo es del
  binario, no del código.
- Ningún refactor de los que piden C4 y C5 es revisable sin diff.

## Objetivo

Todo el estado del proyecto está versionado, con un historial que permita ver y revertir cada cambio.

## Alcance

**Incluye** inicializar el repositorio, revisar qué se ignora, el primer commit y las convenciones mínimas
escritas.

**No incluye** elegir ni configurar un remoto. Un repositorio local ya resuelve el problema; el remoto es
una decisión aparte (y C3 deja el workflow de CI listo para cuando exista).

## Diseño

### 1. Inicializar

```sh
git init -b main
```

### 2. Revisar `.gitignore`

El actual:

```
.build/
DerivedData/
*.xcuserstate
xcuserdata/
.DS_Store
```

Agregar:

```
# Artefactos de ejemplo que se generan al probar
Examples/**/node_modules/
Examples/**/vendor/
# Marcador local de las pruebas de MySQL
.build/mysql-test-port
```

Y **comprobar que no se esté ignorando nada que deba versionarse**, en particular:

- `Krabzik.xcodeproj/project.pbxproj` — generado, pero debe versionarse: es lo que se compila. C8 se encarga
  de que esté siempre al día.
- `Krabzik.xcodeproj/xcshareddata/` — el esquema compartido y, sobre todo, **`Package.resolved`**: es el
  pin de versiones de las dependencias del que habla el README. `xcuserdata/` sí se ignora, y está bien.
- `Krabzik/AppIcon.icon` y `Design/Icon/Source/` — fuentes del icono, versionables.
- `Krabzik/Resources/ThirdPartyNotices.txt` — 128 KB, pero es obligación de licencia: va versionado.
- `Vendor/MySQLNIO/` — completo, incluido `LICENSE` y `UPSTREAM.md`.

Verificación: `git status --ignored --short | grep '^!!'` y revisar la lista entrada por entrada **antes**
del primer commit.

### 3. `.gitattributes`

```
*.pbxproj   -merge
*.swift     text eol=lf
*.md        text eol=lf
*.patch     -text
```

El `.pbxproj` es generado: marcarlo como no fusionable evita conflictos irresolubles; ante un conflicto se
regenera con `scripts/generate_project.py`.

### 4. Primer commit

Un único commit con todo el estado actual y un mensaje que diga qué es y de dónde viene:

```
Estado inicial de Krabzik IDE 0.3.0

IDE nativo para macOS en Swift/SwiftUI/AppKit con editor TextKit 2,
ejecución de procesos por subproyecto, cliente MySQL propio sobre un
fork local de mysql-nio 1.9.1 y panel de agente Codex.

29 pruebas (6 de MySQL real, que se saltan sin .build/mysql-test-port).
```

### 5. Convenciones en `docs/contributing.md`

Corto y real, no ceremonial:

- Una rama por cambio, mensajes en imperativo y en español, igual que el resto del proyecto.
- El `.pbxproj` nunca se edita a mano: se regenera (C8).
- Antes de commitear: `scripts/verify.sh` (lo crea C3).
- Los specs de `docs/specs/` se marcan resueltos en el mismo commit que los implementa.

## Criterios de aceptación

1. `git log --oneline` muestra al menos el commit inicial.
2. `git status --short` está limpio después del primer commit.
3. `git ls-files | grep -c 'project.pbxproj'` devuelve 1, y lo mismo para `Package.resolved`.
4. `git ls-files | grep -c '^\.build/'` devuelve 0.
5. Borrar `.build/` y recompilar con `./scripts/build.sh` funciona a partir de un clon limpio del
   repositorio (es decir: nada necesario para compilar quedó ignorado).
6. Existe `docs/contributing.md` con las cuatro convenciones del punto 5.

## Pruebas

El criterio 5 es la prueba real y conviene ejecutarlo de verdad: clonar a un directorio temporal
(`git clone . /tmp/krabzik-clone`), compilar ahí y comprobar que produce el `.app`. Si falla, falta algo en
el repositorio.

## Riesgos y compatibilidad

- **El árbol se está editando mientras se trabaja.** Conviene hacer el `git init` y el primer commit en un
  momento en que no haya cambios a medias, para que el estado inicial compile. Si no es posible, commitear
  igual: un estado inicial imperfecto con historia es mejor que un estado perfecto sin historia.
- `ThirdPartyNotices.txt` (128 KB) y las fuentes vendored engordan el repositorio; es irrelevante a esta
  escala y necesario por licencia.
- No agregar `.build/` al repositorio por accidente: contiene logs con rutas locales y el puerto de pruebas.

## Resuelto

**2026-11-09** · commits `1785260` y `8883bba`.

- `1785260` «Estado inicial de Krabzik IDE 0.3.0»: repositorio inicializado en `main` con el estado tal como
  estaba, sin ninguna modificación previa. 114 archivos, 1,6 MB.
- `8883bba` «Versionar convenciones de trabajo y atributos de git»: `.gitattributes`, las entradas nuevas de
  `.gitignore` y `docs/contributing.md`.

Criterios verificados:

| # | Criterio | Resultado |
|---|---|---|
| 1 | `git log --oneline` muestra commits | 2 |
| 2 | `git status --short` limpio | sí |
| 3 | `project.pbxproj` y `Package.resolved` versionados | 1 y 1 |
| 4 | Nada de `.build/` versionado | 0 |
| 5 | Clon limpio compila | `BUILD SUCCEEDED`, `.app` de 21 MB, y el clon queda sin cambios pendientes |
| 6 | `docs/contributing.md` con las convenciones | sí |

Desviaciones respecto del diseño:

- **No se agregó `.build/mysql-test-port` al `.gitignore`.** La entrada `.build/` ya lo cubre; repetirlo solo
  sugeriría que no estaba cubierto. Anotado en el mensaje del commit.
- **Se agregó `*.xcscheme -merge`** además de `*.pbxproj -merge`: el esquema también lo genera
  `scripts/generate_project.py`, así que tiene el mismo problema de fusión.
- **Se agregaron reglas `text eol=lf`** para `.py`, `.sh`, `.json` y `.plist`, no solo para `.swift` y `.md`.
  Comprobado que no marcan ningún archivo como modificado, ni en el repositorio ni en el clon.

Pendiente, fuera del alcance de este spec: no hay remoto configurado. El repositorio es local, que es lo que
C1 se propuso resolver. El workflow de CI que escribe [C3](C3-ci-lint-warnings.md) queda listo para cuando
exista uno.
