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
- Si no se regenera, la compilación falla con `cannot find 'X' in scope`, un error que parece de código y
  no lo es. Ver [docs/specs/C8-pbxproj-sincronizado.md](specs/C8-pbxproj-sincronizado.md).
- `.gitattributes` marca el `.pbxproj` como no fusionable: ante un conflicto, se regenera.

## Antes de commitear

```sh
xcodebuild -project Krabzik.xcodeproj -scheme Krabzik \
  -destination 'platform=macOS' -derivedDataPath .build \
  -parallel-testing-enabled NO test
```

Las 6 pruebas de MySQL real se saltan sin el marcador `.build/mysql-test-port`; el README explica cómo
levantar una instancia desechable para habilitarlas.

Cuando exista `scripts/verify.sh` ([C3](specs/C3-ci-lint-warnings.md)), ese comando reemplaza al anterior y
agrega lint, chequeo del `.pbxproj` y verificación del vendoring.

## Especificaciones

Las mejoras pendientes están descritas en [docs/specs/](specs/), una por archivo, con criterios de
aceptación verificables.

- Implementar un spec incluye marcarlo resuelto: una sección `## Resuelto` al final del spec con la fecha y
  el hash del commit, y la fila correspondiente actualizada en [docs/specs/README.md](specs/README.md).
- Si el código se movió desde que se escribió el spec, se actualiza el spec en el mismo commit que lo
  implementa.
