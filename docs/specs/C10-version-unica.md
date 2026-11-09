# C10 · Una sola fuente de verdad para la versión

| | |
|---|---|
| **Severidad** | Baja |
| **Área** | Configuración, documentación |
| **Archivos** | `scripts/generate_project.py`, `Krabzik/Services/AgentController.swift`, `README.md` |
| **Depende de** | C8 (el `.pbxproj` se regenera), C3 (el chequeo corre solo) |
| **Esfuerzo** | 1 hora |

## Problema

La versión está escrita en tres lugares, y durante la auditoría del 2026-11-09 los tres no coincidían.

Estado al momento de escribir este spec:

| Lugar | Valor |
|---|---|
| `scripts/generate_project.py` → `MARKETING_VERSION` | `0.3.0` |
| `scripts/generate_project.py` → `CURRENT_PROJECT_VERSION` | `3` |
| `AgentController.connect()` → `clientInfo.version` | `"0.3.0"` (literal) |
| `README.md`, primera línea | `# Krabzik IDE · 0.2` |

Es decir: el `.pbxproj` y el literal del agente ya se pusieron al día (a las 16:16 de ese día), y **el README
quedó atrás**. La inconsistencia se movió de lugar en vez de desaparecer, que es exactamente lo que pasa
cuando el mismo dato vive en varios sitios.

El literal del agente es el más propenso a quedar viejo: `"version": .string("0.3.0")` está embebido en el
medio de la carga de `initialize`, donde nadie lo busca al subir una versión. Y es el valor que el servidor
de Codex registra como identificación del cliente, así que un número equivocado ahí ensucia el diagnóstico
de cualquier problema de protocolo.

## Objetivo

La versión se define en un solo lugar; todo lo demás la deriva, y una discrepancia falla de forma
automática.

## Alcance

**Incluye** leer la versión del bundle en runtime, definirla una vez en el generador, y un chequeo que
compare el README.

**No incluye** automatizar el incremento de versión ni generar notas de versión.

## Diseño

### 1. La fuente de verdad es `generate_project.py`

Al principio del script, con un comentario que lo diga:

```python
# Fuente de verdad de la versión del producto. Todo lo demás la deriva:
#   - MARKETING_VERSION / CURRENT_PROJECT_VERSION del target
#   - CFBundleShortVersionString del Info.plist (ya usa $(MARKETING_VERSION))
#   - el clientInfo que la app envía a Codex (lo lee del bundle en runtime)
#   - la primera línea del README (verificado por --check)
MARKETING_VERSION = '0.3.0'
BUILD_NUMBER = '3'
```

`Krabzik/Info.plist` ya hace lo correcto: usa `$(MARKETING_VERSION)` y `$(CURRENT_PROJECT_VERSION)`. No hay
nada que cambiar ahí.

### 2. El agente lee del bundle

En `AgentController.connect()`:

```swift
private static var clientVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
}
```

y usarla en lugar del literal. En el bundle de pruebas `Bundle.main` es el host de la app, así que el valor
también es correcto al ejecutar la suite.

### 3. El README deja de repetir el número… o se verifica

Dos opciones, elegir una:

- **A (preferida).** La primera línea del README pasa a `# Krabzik IDE` y la versión no se menciona. El
  número vive en la app y en los tags de git (C1). Menos lugares, menos deriva.
- **B.** Se conserva `# Krabzik IDE · 0.3` y `generate_project.py --check` (C8) verifica que la primera
  línea del README contenga `MARKETING_VERSION` recortado a *major.minor*. Falla si no coincide.

La opción B tiene la ventaja de que el README sigue diciendo de qué versión habla, lo cual es útil en un
documento que describe comportamiento con bastante detalle. En ese caso, el chequeo es obligatorio: sin él
volvemos al punto de partida.

### 4. Nota en el README sobre lo verificado

El README afirma «Verificado con Xcode 27.1 / Swift 6.4» y «La integración se comprobó contra MySQL
8.4.11». Son datos con la misma propensión a quedar viejos. No hace falta automatizarlos, pero conviene
ponerlos juntos en una sección **Entorno verificado** con la fecha de la última comprobación, para que se
lea como una medición y no como una promesa permanente.

## Criterios de aceptación

1. `grep -rn '0\.3\.0' Krabzik scripts` devuelve exactamente una línea: la definición en
   `generate_project.py`.
2. `AgentController` no contiene ningún literal de versión.
3. La app, ejecutada, envía a Codex el mismo valor que `CFBundleShortVersionString` del bundle.
4. Si se eligió la opción B: cambiar `MARKETING_VERSION` sin tocar el README hace fallar
   `generate_project.py --check`.
5. El README tiene una sección **Entorno verificado** con fecha.

## Pruebas

- `KrabzikTests/AgentTests.swift`: `testClientVersionComesFromBundle` — comprobar que el valor que el
  controlador usaría coincide con `Bundle.main.infoDictionary?["CFBundleShortVersionString"]` y que no es la
  cadena de respaldo `"0"`.
- El criterio 1 y el 4 son chequeos de shell, en `verify.sh`.

## Riesgos y compatibilidad

- Si `Bundle.main` no tiene `CFBundleShortVersionString` (nunca debería: el `Info.plist` lo define), el
  respaldo `"0"` haría que Codex registre una versión inútil. Es preferible a un crash y la prueba del punto
  anterior lo detecta.
