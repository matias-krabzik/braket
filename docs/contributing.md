# Trabajar en Krabzik IDE

## Control de versiones

- Una rama por cambio. Los mensajes van en imperativo y en español, como el resto del proyecto.
- Los commits son chicos y de un solo tema. Formato y refactor nunca van en el mismo commit.

## El proyecto Xcode es generado

`Krabzik.xcodeproj/project.pbxproj` lo produce `scripts/generate_project.py` recorriendo
`Krabzik/**/*.swift` y `KrabzikTests/**/*.swift`.

- **No se edita a mano**, ni desde la interfaz de Xcode.
- Después de agregar, mover o borrar un archivo Swift: `python3 scripts/generate_project.py` y commitear
  el `.pbxproj` resultante **en el mismo commit**.
- Si no se regenera, `scripts/build.sh` y `scripts/verify.sh` fallan temprano diciendo qué archivo falta.
  Antes de C8 el síntoma era `cannot find 'X' in scope`, un error que parece de código y no lo es.
- `python3 scripts/generate_project.py --check` no escribe nada y devuelve 1 si el proyecto está
  desactualizado. El propio modo se prueba con `scripts/tests/test_generate_project.sh`.
- `.gitattributes` marca el `.pbxproj` como no fusionable: ante un conflicto, se regenera.

## Antes de commitear

```sh
scripts/verify.sh
```

Corre lo mismo que CI: trinquetes de estilo, lint, integridad del vendoring, compilación y pruebas.
Distingue pasos **bloqueantes** de **informativos**, y omite con aviso lo que todavía no existe
(`swiftlint`, `swiftformat`, el `--check` del generador, `check_vendor.sh`). Con `--no-tests` salta la
compilación, útil para una pasada rápida.

Las 6 pruebas de MySQL real se saltan sin el marcador `.build/mysql-test-port`; el README explica cómo
levantar una instancia desechable para habilitarlas. En CI el marcador se crea siempre, así que ahí
corren las 38.

Un aviso del compilador rompe el build: `SWIFT_TREAT_WARNINGS_AS_ERRORS` está en `YES`. Si el SDK o el
compilador introducen avisos en código que no tocaste, la válvula de escape es la invocación
(`xcodebuild SWIFT_TREAT_WARNINGS_AS_ERRORS=NO`), nunca editar el proyecto.

### Trinquetes

`verify.sh` tiene topes para cantidades que hoy existen en el código y que solo pueden bajar: líneas de
más de 140 columnas, líneas con varias sentencias separadas por `;`, y bloques `catch` vacíos. No son
objetivos: impiden empeorar mientras [C4](specs/C4-legibilidad.md) y [C6](specs/C6-logging-y-errores.md)
no estén hechos. Al bajar una cantidad, bajar también el tope en el script.

### Hook opcional

Si querés que corra solo antes de cada commit:

```sh
printf '#!/bin/sh\nexec scripts/verify.sh --no-tests\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
```

No se instala automáticamente: forzar hooks en el repositorio de otra persona es invasivo.

## Especificaciones

Las mejoras pendientes están descritas en [docs/specs/](specs/), una por archivo, con criterios de
aceptación verificables.

- Implementar un spec incluye marcarlo resuelto: una sección `## Resuelto` al final del spec con la fecha y
  el hash del commit, y la fila correspondiente actualizada en [docs/specs/README.md](specs/README.md).
- Si el código se movió desde que se escribió el spec, se actualiza el spec en el mismo commit que lo
  implementa.
