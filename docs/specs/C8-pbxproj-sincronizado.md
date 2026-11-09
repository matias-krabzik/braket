# C8 · Garantizar que el `.pbxproj` generado esté al día

| | |
|---|---|
| **Severidad** | Media |
| **Área** | Proceso, build |
| **Archivos** | `scripts/generate_project.py`, `scripts/verify.sh`, CI |
| **Depende de** | C1, C3 |
| **Esfuerzo** | 1–2 horas |

## Problema

`Krabzik.xcodeproj/project.pbxproj` **se genera** con `scripts/generate_project.py`, que recorre
`Krabzik/**/*.swift` y `KrabzikTests/**/*.swift` con `rglob` y arma el proyecto entero. Es una buena
decisión: el archivo de proyecto deja de ser un artefacto editado a mano y propenso a conflictos, y todos
los ajustes de build viven en un script legible.

El problema es que **hay que acordarse de ejecutarlo**. El README lo dice al final («Para regenerar el
proyecto Xcode después de agregar archivos Swift»), pero nada lo verifica.

Esto no es hipotético. Durante la auditoría del 2026-11-09, la primera compilación de prueba en modo Swift 6
falló con:

```
WorkspaceController.swift:26:17: error: cannot find 'AgentController' in scope
WorkspaceView.swift:34:25:      error: cannot find 'AgentPanel' in scope
```

No era un problema de Swift 6: era que `Krabzik/Views/AgentPanel.swift` se había creado a las 16:22:03 y el
`.pbxproj` se regeneró a las 16:22:07, cuatro segundos después de que arrancara la compilación. Un archivo
nuevo sin regenerar produce un error que **parece** de código y manda a investigar en el lugar equivocado.

## Objetivo

Agregar, mover o borrar un archivo Swift sin regenerar el proyecto se detecta de inmediato y con un mensaje
que diga exactamente qué hacer.

## Alcance

**Incluye** un modo de verificación en el generador, su integración en el script de verificación y en CI, y
el mensaje de error.

**No incluye** generar el proyecto durante el build (un paso de build que reescriba el `.pbxproj` mientras
Xcode lo tiene abierto es una mala idea).

## Diseño

### 1. `--check` en el generador

Refactor mínimo de `generate_project.py`: hoy el script termina con dos `write_text`. Separar la
construcción del contenido de su escritura:

```python
def render() -> tuple[str, str]:
    """Devuelve (pbxproj, scheme) sin escribir nada."""

def write(pbxproj: str, scheme: str) -> None: ...

def check(pbxproj: str, scheme: str) -> int:
    """0 si los archivos en disco coinciden; 1 si no, informando qué difiere."""
```

`python3 scripts/generate_project.py` mantiene el comportamiento actual (escribe e imprime
`Krabzik.xcodeproj generated`). `--check` no escribe nada y devuelve 1 si hay diferencia, con un mensaje
accionable:

```
project.pbxproj está desactualizado.
  Archivos nuevos no registrados: Krabzik/Views/AgentPanel.swift
  Ejecutá: python3 scripts/generate_project.py
```

Para que el mensaje pueda nombrar los archivos, comparar además la lista de fuentes que `rglob` encuentra
contra las que el `.pbxproj` en disco menciona; es una comparación de conjuntos barata y es la información
que realmente hace falta.

### 2. Determinismo

El `--check` solo sirve si el generador es determinista. Hoy lo es: los UIDs se derivan de
`hashlib.sha1(name)` y las listas se construyen con `sorted(rglob(...))`. **Dejarlo documentado como
invariante** en la docstring del script: cualquier cambio futuro que introduzca orden de diccionario no
determinista, marcas de tiempo o UUIDs aleatorios rompe esta verificación.

Prueba del invariante: ejecutar el generador dos veces y comparar la salida (criterio 4).

### 3. Integración

- `scripts/verify.sh` (C3) lo llama como primer paso: es el más rápido y el que explica mejor un fallo
  posterior de compilación.
- El workflow de CI lo corre vía `verify.sh`.
- `docs/contributing.md` (C1) dice: *el `.pbxproj` no se edita a mano; después de agregar un archivo,
  regenerar y commitear el resultado en el mismo commit.*

### 4. Ayuda en el momento del error

Opcional pero útil: cuando `xcodebuild` falla con `cannot find 'X' in scope` y existe un archivo
`*/X.swift` que no está en el `.pbxproj`, el mensaje de `--check` ya lo explica. Para cerrar el círculo,
`scripts/build.sh` puede llamar `--check` antes de compilar, y así nadie vuelve a perder tiempo con ese
error.

## Criterios de aceptación

1. `python3 scripts/generate_project.py --check` devuelve 0 sobre el árbol sincronizado.
2. Crear `Krabzik/Views/Nuevo.swift` y ejecutar `--check` devuelve 1 y nombra ese archivo.
3. Borrar un archivo Swift sin regenerar también devuelve 1 y lo nombra.
4. Ejecutar el generador dos veces seguidas produce bytes idénticos en `project.pbxproj` y en el `.xcscheme`.
5. `scripts/build.sh` falla temprano, con el mensaje del generador, si el proyecto está desactualizado.
6. El modo sin argumentos sigue haciendo exactamente lo de hoy.

## Pruebas

No hay pruebas de Swift para esto; la verificación es de shell y conviene dejarla escrita:

`scripts/tests/test_generate_project.sh` (o los pasos en el propio spec, si no se quiere una carpeta de
pruebas de shell):

```sh
python3 scripts/generate_project.py --check                      # espera 0
touch Krabzik/Views/__Temp.swift
python3 scripts/generate_project.py --check && exit 1             # espera 1
rm Krabzik/Views/__Temp.swift
python3 scripts/generate_project.py && python3 scripts/generate_project.py --check   # espera 0
```

## Riesgos y compatibilidad

- Si alguien abre el proyecto en Xcode y Xcode toca el `.pbxproj` (por ejemplo al añadir un archivo desde la
  interfaz), `--check` fallará. Eso es correcto y es el comportamiento buscado: hay que agregar el archivo en
  disco y regenerar. Conviene que el mensaje lo diga para que no se interprete como un bug del script.
- El `.gitattributes` de C1 marca `*.pbxproj -merge`, así que un conflicto se resuelve regenerando. Las dos
  piezas se apoyan.
