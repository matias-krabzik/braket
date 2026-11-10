# S6 · Decidir y documentar sandbox, firma y distribución

| | |
|---|---|
| **Severidad** | Estructural (no hay un defecto explotable; falta la decisión escrita) |
| **Área** | Configuración del target, distribución |
| **Archivos** | `scripts/generate_project.py`, nuevo `docs/security.md`, `README.md`, posible `Krabzik/Krabzik.entitlements`, posible `scripts/release.sh` |
| **Depende de** | C1 (para que el ADR tenga historia), C8 (el `.pbxproj` se regenera) |
| **Esfuerzo** | 2–3 horas la opción A; 1 día la opción B |

## Problema

El target se construye hoy con:

```python
'ENABLE_APP_SANDBOX': 'NO', 'ENABLE_HARDENED_RUNTIME': 'YES',
'CODE_SIGN_IDENTITY': '-', 'CODE_SIGN_STYLE': 'Manual',
```

y **no existe ningún archivo `.entitlements`** en el repositorio. Es decir: hardened runtime activado (bien)
pero sin sandbox, con firma ad-hoc y sin notarización.

Para un IDE que ejecuta procesos del usuario, lanza un agente externo y abre carpetas arbitrarias, el App
Sandbox completo es inviable sin un rediseño profundo (habría que usar `NSOpenPanel` para todo acceso,
mantener bookmarks con permiso, y renunciar a `posix_spawn` de binarios arbitrarios). La decisión de no
usarlo es defendible. El problema no es la decisión: es que **no está escrita en ninguna parte**, así que
nadie puede saber si fue deliberada, y no hay criterio para decir si la app se puede distribuir.

El README solo menciona «Compilación local con firma ad hoc, sin cuenta de desarrollador», que describe el
cómo pero no la postura.

## Objetivo

Existe un documento que declara qué garantías ofrece y qué no ofrece el binario que se instala, y la
configuración del target coincide con lo declarado.

## Alcance

**Incluye** el ADR, la revisión de los ajustes de firma y hardened runtime, y la decisión sobre
distribución.

**No incluye** adoptar el App Sandbox. Si alguna vez se decide, es un spec aparte con su propio rediseño.

## Diseño

### 1. ADR en `docs/security.md`

Documento corto con estas secciones, escritas como afirmaciones verificables:

- **Modelo de amenaza.** De qué protege Krabzik: de que un proyecto o un contenido de terceros actúe sin
  que el usuario lo apruebe (S1, S2, S5). De qué **no** protege: de un usuario que ejecuta a propósito un
  comando dañino en su propia máquina. La app corre con todos los permisos del usuario, por diseño.
- **Por qué no hay App Sandbox.** Ejecución de procesos arbitrarios del usuario, acceso a carpetas de
  trabajo sin diálogo por cada archivo, y lanzamiento de un binario externo (Codex). Enumerar lo que se
  perdería y lo que habría que construir.
- **Qué sí está activo.** Hardened runtime; contraseñas en el llavero con
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` y ligadas al endpoint; TLS verificado por defecto; sandbox
  propio de Codex con `networkAccess: false` y raíces explícitas; hijos en grupo de procesos propio.
- **Alcance de la distribución.** Ver punto 3.
- **Revisión.** Este documento se revisa cuando se agregue cualquier capacidad nueva que ejecute código o
  acceda a la red.

### 2. Hardened runtime explícito

Hoy `ENABLE_HARDENED_RUNTIME = YES` funciona sin entitlements porque nada necesita excepciones. Hay que
dejarlo comprobado y documentado en el ADR: **no se agrega ninguna excepción**, en particular
`com.apple.security.cs.disable-library-validation` ni `allow-unsigned-executable-memory`. Si en algún
momento el build empieza a pedir una, es señal de que algo cambió de forma relevante y hay que revisar el
ADR antes de agregarla.

Si se decide crear el `.entitlements` igualmente (por claridad, aunque esté vacío de excepciones), hay que
sumar `CODE_SIGN_ENTITLEMENTS` a `generate_project.py` y versionar el archivo.

### 3. Elegir el camino de distribución

**Opción A — uso local (recomendada hoy).** La app se compila e instala en la máquina del autor, como ya
hace el flujo de `AGENTS.md`. El ADR dice explícitamente: «este binario no está preparado para distribuirse
a terceros; no está notarizado y Gatekeeper lo bloqueará en otra máquina». No hace falta tocar nada de la
configuración. Esfuerzo: solo escribir el documento.

**Opción B — distribuible.** Agregar a `generate_project.py` que `CODE_SIGN_IDENTITY` y
`DEVELOPMENT_TEAM` se tomen de variables de entorno, con el default actual (`-`) para que el build local
siga funcionando sin cuenta de desarrollador. Nuevo `scripts/release.sh`: build Release, firma con
Developer ID, `notarytool submit --wait`, `stapler staple`, y verificación final con `spctl -a -vvv`.
Documentar en el README cómo se produce una versión firmada.

La decisión se toma **una vez** y queda en el ADR. Este spec no la fuerza; sí exige que esté escrita.

## Criterios de aceptación

1. Existe `docs/security.md` con las cinco secciones del punto 1, y el README lo enlaza.
2. El ADR dice qué opción de distribución se eligió y con qué fecha.
3. `grep -r "disable-library-validation\|allow-unsigned-executable-memory"` sobre el repo no devuelve nada,
   o el ADR explica cada aparición.
4. Si se eligió la opción B: `scripts/release.sh` produce un `.app` que pasa `spctl -a -vvv`, y el build
   local sin variables de entorno sigue funcionando con firma ad-hoc.
5. El estado de `ENABLE_APP_SANDBOX` y `ENABLE_HARDENED_RUNTIME` en `generate_project.py` coincide con lo
   que afirma el ADR.

## Pruebas

No hay pruebas unitarias para esto. La verificación es el punto 3 y 5 de los criterios, y conviene
automatizarla en `scripts/verify.sh` (C3): un chequeo que compare los ajustes del `.pbxproj` generado
contra los valores que el ADR declara, de modo que cambiarlos sin actualizar el documento falle.

## Riesgos y compatibilidad

- Escribir «no distribuible» puede sonar a limitación, pero es la situación real y declararla evita que
  alguien comparta el `.app` y se encuentre con un bloqueo de Gatekeeper sin explicación.
- La opción B introduce secretos en el flujo de release (credenciales de notarización). Si se toma, deben ir
  en el llavero o en variables de entorno del entorno de firma, nunca en el repositorio, y el ADR tiene que
  decirlo.

## Resuelto

**2026-11-10**, commit `b18a1ca`. Se eligió la **opción A: uso local**.

| Criterio | Estado |
|---|---|
| 1 · `docs/security.md` con las cinco secciones, enlazado desde el README | hecho: modelo de amenaza (con la tabla de vectores y su spec), por qué no hay App Sandbox, qué sí está activo, alcance de la distribución, revisión |
| 2 · dice qué opción se eligió y con qué fecha | opción A, 2026-11-09, en «Alcance de la distribución» |
| 3 · no hay excepciones al hardened runtime | `scripts/check_security_posture.py` las busca en `*.py`, `*.swift`, `*.plist` y `*.entitlements` bajo `Krabzik/` y `scripts/`. Las únicas apariciones son en `.md` —este spec y el ADR— que las nombran para prohibirlas, y el ADR lo dice |
| 4 · opción B | no aplica |
| 5 · la configuración coincide con lo que afirma el ADR | lo comprueba el chequeo nuevo, que es un paso bloqueante de `scripts/verify.sh` |

### Decisiones

- **No se creó un `.entitlements` vacío.** El spec lo dejaba como opcional. Un archivo sin excepciones no
  agrega información y sí agrega un lugar donde alguien puede meter una sin pensarlo; el chequeo
  automático cubre el caso mejor que el archivo.
- **El chequeo vive en un script aparte**, no embebido en `verify.sh`: así tiene su propia prueba
  (`scripts/tests/test_check_security_posture.sh`), que inyecta las cuatro desviaciones posibles y
  comprueba que cada una falle. Un gate que solo sabe decir «todo bien» no es un gate.
- **`verify.sh` ahora corre `scripts/tests/*.sh`.** Estaban escritos desde C8 y no los corría nadie, ni
  local ni CI. Esto no estaba en el spec; apareció al querer que el chequeo nuevo fuera verificable.
