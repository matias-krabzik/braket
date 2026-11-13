# Postura de seguridad de Braket

ADR. Escrito el **2026-11-09** (spec [S6](specs/S6-sandbox-y-firma.md)). Declara qué garantiza y qué no
garantiza el binario que se instala, y la configuración del target tiene que coincidir con lo que dice acá.

## Modelo de amenaza

Krabzik es un IDE: su trabajo es abrir carpetas del usuario, ejecutar los comandos del usuario y hablar con
un agente externo. Eso define la frontera.

**De qué protege.** De que algo que el usuario no aprobó actúe por su cuenta:

| Vector | Control | Spec |
|---|---|---|
| Un `.kzk` ajeno con un comando dentro | El proyecto se abre en solo lectura hasta que el usuario lo confía, viendo las carpetas externas y los comandos. Cada comando se aprueba una vez, por hash | [S1](specs/S1-proyecto-no-confiable.md) |
| Un flujo plantado en `.braket/automations/` —por un repositorio ajeno o por el agente, que puede escribir ahí— | Confiar en el proyecto no alcanza: cada script se aprueba por hash de **comando, carpeta y variables de entorno**, y cambiar cualquiera vuelve a preguntar. El diálogo muestra la carpeta real (resuelta, marcando las de fuera del proyecto) y el entorno completo. Se rechazan `DYLD_*`, `LD_*`, `ZDOTDIR`, `BASH_ENV`, `ENV`, `SHELL`, `IFS` y `PROMPT_COMMAND`, y no se siguen enlaces simbólicos en `.braket` ni en los archivos de flujo | [Aprobación de flujos](workflows.md#aprobación-de-scripts) |
| Un binario `codex` plantado en el PATH o en el proyecto | Se rechaza lo que sea escribible por grupo u otros, lo que no sea del usuario o de root, y lo que esté dentro del workspace. La identidad y la firma se muestran antes del primer lanzamiento y se recuerdan | [S2](specs/S2-verificar-ejecutable-codex.md) |
| Credenciales de base de datos viajando en claro | «Require and Verify Identity» es el valor predeterminado. «If available» y «No» permiten texto plano por elección explícita y muestran una advertencia | [S3](specs/S3-tls-solo-loopback.md) |
| La contraseña viva en memoria más de lo necesario | No se retiene durante la sesión; se relee del llavero cuando hace falta | [S4](specs/S4-no-retener-password.md) |
| Texto del modelo que se hace pasar por interfaz de la app | Todo lo que viene del modelo se sanea (control, bidi, zero-width), se acota y se muestra marcado como contenido del modelo | [S5](specs/S5-contenido-del-modelo.md) |

**De qué no protege.** De un usuario que ejecuta a propósito un comando dañino en su propia máquina. La app
corre con todos los permisos del usuario, por diseño: si el comando del proyecto borra archivos, los borra.
La aprobación del usuario es la única frontera, y por eso los specs de arriba se ocupan de que esa
aprobación sea informada y explícita en vez de implícita.

## Por qué no hay App Sandbox

`ENABLE_APP_SANDBOX = NO`, deliberadamente. Las tres capacidades centrales del producto son incompatibles
con el sandbox completo:

1. **Ejecutar procesos arbitrarios del usuario.** `ProcessRunner` lanza con `posix_spawn` el comando que el
   usuario escribió (`npm run dev`, `php artisan serve`). Bajo sandbox hay que declarar los binarios de
   antemano, y no se puede: el comando lo escribe el usuario.
2. **Acceder a las carpetas de trabajo sin un diálogo por archivo.** El explorador recorre el árbol del
   proyecto y abre cualquier archivo. Bajo sandbox haría falta un `NSOpenPanel` por raíz y mantener
   security-scoped bookmarks para cada una, renovados en cada arranque.
3. **Lanzar un binario externo.** El agente es el ejecutable `codex` instalado por fuera de la app.

Lo que habría que construir para adoptarlo: un sistema de bookmarks con permiso para cada raíz, un
XPC service con su propio perfil para la ejecución de procesos, y renunciar a lanzar binarios que la app no
trae. Es un rediseño, no un ajuste: si alguna vez se decide, es un spec aparte.

## Qué sí está activo

- **Hardened runtime** (`ENABLE_HARDENED_RUNTIME = YES`) **sin ninguna excepción**. No hay archivo
  `.entitlements` en el repositorio y no se agrega `com.apple.security.cs.disable-library-validation` ni
  `allow-unsigned-executable-memory`. Si el build empieza a pedir una, algo cambió de forma relevante: hay
  que revisar este documento antes de agregarla. Las únicas apariciones de esos nombres en el repo son el
  spec S6 y esta línea, que los nombran para prohibirlos.
- **Contraseñas en el llavero**, con `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` y ligadas al endpoint:
  cambiar host o puerto invalida la credencial guardada (`CredentialStore`).
- **TLS verificado por defecto** en MySQL, con el handler de NIOSSL comprobado en la conexión. Los modos
  compatibles con Workbench permiten cifrado sin verificación o texto plano si el usuario los elige.
- **Sandbox propio de Codex**: `workspaceWrite` con `writableRoots` explícitas, `networkAccess: false`,
  `excludeSlashTmp` y `excludeTmpdirEnvVar`. Las raíces escribibles nunca incluyen una ruta que el usuario
  no aprobó viéndola.
- **Hijos en su propio grupo de procesos** (`POSIX_SPAWN_SETPGROUP`) y descriptores cerrados por defecto
  (`POSIX_SPAWN_CLOEXEC_DEFAULT`): al cerrar el proyecto se termina el grupo completo, no solo el proceso
  raíz, y ningún hijo hereda descriptores de la app.

## Alcance de la distribución

**Uso local firmado y preparación de distribución.** Actualizado el 2026-11-10.

Las instalaciones locales Release usan `scripts/build.sh` con la misma identidad **Developer ID
Application** y equipo que la distribución, y hardened runtime activo. La identidad puede configurarse
con `BRAKET_SIGN_IDENTITY` y `BRAKET_SIGN_TEAM`. Si el certificado no está disponible, la compilación
falla; no se sustituye por firma ad hoc. Esto permite que Keychain reconozca la app entre compilaciones.
Una credencial autorizada para una antigua compilación ad hoc puede requerir una última autorización
con «Permitir siempre» al pasar a la identidad estable. No se amplían las ACL del llavero ni se almacenan
contraseñas fuera de él.

La compilación local no se notariza automáticamente. La distribución pública usa
`scripts/release_updates.py` con Developer ID, `notarytool`, `stapler` y verificación con `spctl`.
Las credenciales de notarización permanecen en el llavero, nunca en el repositorio.

## Revisión

Este documento se revisa cuando se agregue cualquier capacidad nueva que **ejecute código** o **acceda a la
red**: otro agente, un gestor de plugins, un cliente de otra base de datos, sincronización remota. También
cuando cambie `ENABLE_APP_SANDBOX`, `ENABLE_HARDENED_RUNTIME` o la firma en `scripts/generate_project.py`:
`scripts/verify.sh` compara esos tres ajustes contra lo que declara esta sección y falla si se separan.

## Actualizaciones con Sparkle

Sparkle 2.10.1 se fija por versión exacta. El catálogo HTTPS vive en
https://www.krabzik.com/apps/krabzik-ide/appcast.xml. Los paquetes se autentican
con Ed25519; la clave pública está en Info.plist y la privada permanece en el
llavero de publicación (cuenta com.krabzik.ide.updates), nunca en el sitio web.
Las búsquedas automáticas son optativas; no se envía el perfil del sistema ni se
instala sin intervención. El reinicio conserva applicationShouldTerminate y
su confirmación de documentos/procesos. No hay excepciones de library validation.
La compilación local necesita Apple Development para cargar el framework.
La publicación exige Developer ID Application, notarización y stapling.
