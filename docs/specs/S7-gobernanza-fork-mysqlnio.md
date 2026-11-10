# S7 · Gobernanza del fork local de MySQLNIO

| | |
|---|---|
| **Severidad** | Proceso (el riesgo es que el parche se desactualice o se pierda, no un defecto conocido) |
| **Área** | Dependencias, autenticación |
| **Archivos** | `Vendor/MySQLNIO/`, `Vendor/MySQLNIO/UPSTREAM.md`, nuevos `Vendor/MySQLNIO/patches/`, `scripts/check_vendor.sh`, CI |
| **Depende de** | C1 (sin historia no hay forma de saber qué se tocó), C3 (CI que lo ejecute) |
| **Esfuerzo** | Medio día |

## Problema

`Vendor/MySQLNIO` es una copia de `vapor/mysql-nio` 1.9.1 (commit `7fa8530`) con cinco cambios locales, y
dos de ellos están **en el camino de autenticación**:

- uso de exactamente 20 bytes de nonce para `caching_sha2_password`, excluyendo el terminador del
  handshake, y respuesta vacía cuando la contraseña está vacía;
- rechazo de la conexión cuando se pidió TLS y el servidor no lo anuncia, antes de enviar credenciales;
- plus deadlines de TCP/autenticación, cierre de canales fallidos y negociación de `CLIENT_MULTI_RESULTS`.

`UPSTREAM.md` los documenta bien —mejor que la media— pero el estado actual tiene tres huecos de proceso:

1. **No hay parches.** Los cambios están aplicados directamente sobre las fuentes copiadas. Para subir a
   mysql-nio 1.10 habría que redescubrir a mano qué se tocó, comparando con el upstream.
2. **Nada impide editar las fuentes vendored sin anotarlo.** El próximo cambio puede quedar sin registro.
3. **Las pruebas que cubren esos parches se saltan por defecto.** Las seis pruebas de MySQL real requieren
   `.build/mysql-test-port`; sin CI (C3), nadie las ejecuta nunca. Es decir: código de autenticación
   modificado a mano, cubierto solo por pruebas que normalmente no corren.

## Objetivo

Rebasar el fork sobre una versión nueva de upstream es una operación mecánica y verificable, y los parches
del camino de autenticación se ejercitan en cada corrida de CI contra un servidor real.

## Alcance

**Incluye** extraer los cambios a parches, un script que verifique la integridad del vendoring, y hacer
obligatorias en CI las pruebas de MySQL.

**No incluye** eliminar el fork (varios parches no tienen equivalente upstream todavía) ni enviar los
cambios aguas arriba, aunque conviene hacerlo y queda como nota.

## Diseño

### 1. Parches como fuente de verdad

```
Vendor/MySQLNIO/
  UPSTREAM.md
  patches/
    0001-caching-sha2-nonce-20-bytes.patch
    0002-reject-tls-when-server-does-not-advertise.patch
    0003-connection-deadlines-and-channel-cleanup.patch
    0004-negotiate-client-multi-results.patch
    0005-package-omit-upstream-test-target.patch
  Sources/…            ← resultado de aplicar los parches, versionado
```

Cada parche se genera con `git diff` contra el tag upstream y lleva en su cabecera **por qué** existe y qué
prueba lo cubre, con el enlace al documento del protocolo que ya está en `UPSTREAM.md`. Un parche, un
motivo: no mezclar cambios.

Las fuentes aplicadas se siguen versionando (así el proyecto compila sin pasos previos); los parches son
para poder rebasar.

### 2. `scripts/check_vendor.sh`

```sh
# 1. clona/descarga el tag upstream declarado en UPSTREAM.md en un directorio temporal
# 2. aplica patches/*.patch en orden
# 3. compara el árbol resultante con Vendor/MySQLNIO/Sources (diff -r)
# 4. falla si hay diferencias, indicando qué archivo se editó sin parche
```

La versión y el commit de upstream se leen de `UPSTREAM.md` para que haya un solo lugar donde cambiarlos.
El script necesita red; en CI eso está bien, y localmente se puede saltar con una variable.

### 3. Las pruebas de MySQL dejan de ser opcionales en CI

En el workflow (C3):

```yaml
steps:
  - run: brew install mysql@8.4 && brew services start mysql@8.4   # + espera a mysqladmin ping
  - run: mkdir -p .build && printf '3306\n' > .build/mysql-test-port
  - run: scripts/verify.sh
```

> **Corregido el 2026-11-09 al implementar C3.** La versión anterior de este punto usaba un contenedor de
> servicio (`services: mysql:8.4`). No funciona: los `services:` de GitHub Actions **solo existen en
> runners Linux**, y en los de macOS —que son los que hacen falta para compilar con Xcode— no hay Docker
> preinstalado. MySQL tiene que venir de Homebrew en el propio runner. Para el desarrollo local el
> contenedor desechable del README sigue siendo la mejor opción, y es el que se usó para verificar C2.

El mecanismo de salto por `.build/mysql-test-port` se conserva para el desarrollo local —es una buena
decisión, y el README ya explica cómo levantar la instancia desechable— pero en CI el archivo se crea
siempre, así que las seis pruebas corren en cada cambio. Entre ellas están las que cubren el handshake
`caching_sha2_password` con contraseña larga, la autenticación en caché, el rechazo de TLS no confiable y
los deadlines.

### 4. Seguimiento de upstream

En `UPSTREAM.md`, una sección **Revisión** con: versión fijada, fecha de la última comparación, y la
instrucción de revisar cuando mysql-nio publique una release. Si existe CI, un job programado mensual que
consulte la última release y falle (o abra un aviso) si no coincide con la fijada.

### 5. Nota para aguas arriba

Los parches 1 y 2 son correcciones de protocolo de interés general. Dejar anotado en `UPSTREAM.md` si se
enviaron a `vapor/mysql-nio` y con qué número, para poder retirar el parche cuando se integren.

## Criterios de aceptación

1. `scripts/check_vendor.sh` pasa sobre el estado actual del repositorio.
2. Editar una línea de `Vendor/MySQLNIO/Sources/` sin actualizar el parche correspondiente hace fallar el
   script, y el mensaje nombra el archivo.
3. Cada parche de `patches/` aplica limpio sobre el tag declarado en `UPSTREAM.md`.
4. En CI, las 6 pruebas de MySQL se ejecutan (no se saltan): la salida del test dice
   `0 tests skipped`.
5. `UPSTREAM.md` indica, por cada parche, cuál es la prueba que lo cubre.

## Pruebas

Las pruebas de este spec son el propio script y la corrida de CI. Además, para que el criterio 5 sea real,
conviene renombrar las pruebas de `DatabaseTests` que cubren los parches de modo que la relación sea
evidente, por ejemplo `testMySQLPasswordAuthenticationAndStoredProcedure` →
mencionar `caching_sha2` en el nombre o en un comentario con el número de parche.

## Riesgos y compatibilidad

- `check_vendor.sh` depende de la red y de que el tag siga publicado. Si falla por eso, no debe bloquear el
  build local; en CI sí debe fallar, pero distinguiendo «no pude verificar» de «el árbol no coincide».
- Al rebasar a una versión nueva de mysql-nio puede que algún parche ya no aplique porque upstream lo
  arregló. Ese es el resultado buscado: se borra el parche y se anota en `UPSTREAM.md`.
- Hacer obligatorias las pruebas de MySQL en CI alarga la corrida (arranque del contenedor, ~30 s). Vale la
  pena: son las únicas que cubren el código de autenticación parcheado.

## Resuelto

**2026-11-10**, commit `f7e5594`.

| Criterio | Cómo se verificó |
|---|---|
| 1 · `check_vendor.sh` pasa sobre el repositorio | sí: clona 1.9.1, aplica los cinco parches y el árbol coincide exactamente con `Sources/` y `Package.swift` |
| 2 · editar sin parche hace fallar el script, nombrando el archivo | comprobado agregando una línea a `MySQLRow.swift`: `✗ Sources/MySQLNIO/MySQLRow.swift no coincide con upstream + parches`, exit 1. Restaurado, vuelve a pasar |
| 3 · cada parche aplica limpio sobre el tag declarado | es lo que hace el paso 1 del script, en orden |
| 4 · en CI las 6 pruebas de MySQL se ejecutan | el workflow instala `mysql@8.4` por Homebrew, espera el `ping` y crea `.build/mysql-test-port` antes de `verify.sh`. **La redacción del criterio no se puede cumplir tal cual**: la salida no va a decir «0 tests skipped», porque las dos pruebas de Codex en vivo se siguen salteando sin un `codex` instalado y una sesión. Lo que vale es que las 6 de MySQL dejan de saltarse |
| 5 · `UPSTREAM.md` dice qué prueba cubre cada parche | tabla «Qué prueba cubre cada parche». Además cada parche lo repite en su cabecera y las tres pruebas lo dicen en un comentario con el número |

### Decisiones

- **Los parches van numerados por posición en el archivo, no por el orden del spec.** El spec proponía
  `0001` para el nonce y `0002` para el rechazo de TLS; los dos tocan `MySQLConnectionHandler.swift` y el de
  TLS está antes en el archivo. Numerarlos al revés los hace aplicar en secuencia sin depender de que
  `git apply` acomode los desplazamientos.
- **El script compara en los dos sentidos**: archivos del vendoring que no coinciden, y archivos de upstream
  que faltan. Lo segundo no estaba en el spec y es la mitad del problema: borrar un archivo también es
  editar el fork.
- **No hay prueba en `scripts/tests/` para este chequeo.** Las demás pruebas de scripts corren en cada
  `verify.sh` y esta necesitaría clonar upstream dos veces más. La verificación del criterio 2 se hizo una
  vez, a mano, y queda escrita arriba.
- **El aviso mensual es un workflow aparte** (`Upstream`), no un paso de CI: no tiene que ver con un cambio
  del repositorio y no debe fallar un push.
- **Las pruebas no se renombraron.** El spec lo sugería como alternativa a un comentario; el comentario con
  el número de parche dice más —qué parche y por qué— y no toca nombres que ya están citados en otros specs.
