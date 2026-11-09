# S3 · «Sin TLS» solo para conexiones locales

| | |
|---|---|
| **Severidad** | Media |
| **Área** | MySQL, red |
| **Archivos** | `Krabzik/Models/DatabaseConnection.swift`, `Krabzik/Services/MySQLClient.swift`, `Krabzik/Views/DatabaseViews.swift`, `README.md` |
| **Depende de** | — |
| **Esfuerzo** | 2–4 horas |

## Problema

`DatabaseConnection.TLSMode` tiene dos valores, y el cliente los aplica así:

```swift
tlsConfiguration: config.tls == .verified ? .makeClientConfiguration() : nil,
serverHostname:   config.tls == .verified ? config.host : nil,
```

`.disabled` desactiva TLS **para cualquier host**. El README presenta la opción como «conexión local sin
cifrar», pero nada la limita a loopback: alcanza con elegir «Sin TLS» y escribir un host remoto para que
las consultas, los resultados y los nombres de objetos viajen en claro por la red. La UI
(`ConnectionSheet`) muestra el picker sin ninguna advertencia, y `validated()` no mira la combinación.

> Lo que ya está bien y no hay que tocar: con `.verified` se usa la verificación completa por defecto de
> `TLSConfiguration.makeClientConfiguration()` y se pasa `serverHostname`, no hay opción de aceptar
> certificados inválidos, y si el servidor no ofrece TLS cuando se pidió, la conexión se rechaza **antes**
> de enviar credenciales (parche local documentado en `Vendor/MySQLNIO/UPSTREAM.md`).

## Objetivo

`.disabled` solo es posible contra un extremo loopback, comprobado también en el momento de conectar, y
el usuario ve la advertencia antes de guardar.

## Alcance

**Incluye** validación textual del host, comprobación de la dirección resuelta al conectar, advertencia en
la UI y nota en el README.

**No incluye** agregar modos nuevos (certificados de cliente, `verify-ca` sin hostname, túnel SSH): siguen
fuera de esta versión, como dice el README.

## Diseño

### 1. Validación en el modelo, con dos niveles

`DatabaseConnection.validated()` se usa hoy en dos contextos distintos: al **guardar** desde la hoja y al
**leer** un `.krabzik` (`Workspace.read` la llama por cada conexión). Si la regla nueva se aplica igual en
los dos, un proyecto existente con una conexión remota sin TLS deja de abrirse. Por eso:

```swift
enum ValidationLevel { case lenient, strict }   // lenient = lectura, strict = guardar/conectar
func validated(_ level: ValidationLevel = .strict) throws -> Self
```

- `strict` agrega: si `tls == .disabled` y el host no es loopback → `DatabaseFailure("Sin TLS solo se permite para conexiones locales (127.0.0.1, ::1 o localhost).")`
- `lenient` no agrega nada: `Workspace.read` sigue aceptando el archivo.
- Nueva propiedad `var isLoopbackHost: Bool`: `127.0.0.1`, cualquier `127.x.y.z`, `::1`, `localhost`,
  y los nombres que terminan en `.localhost`. Comparación sin distinción de mayúsculas, sobre el host ya
  recortado.

`WorkspaceController.saveConnection(_:password:)` ya llama `validated()`; queda en `.strict` sin cambios.

### 2. Comprobación real al conectar

La comparación textual no alcanza: un nombre arbitrario puede resolver a loopback, y al revés. En
`MySQLClient.open(_:password:)`, donde ya se resuelve la dirección:

```swift
let address = try await Task.detached { try SocketAddress.makeAddressResolvingHost(config.host, port: config.port) }.value
if config.tls == .disabled, !address.isLoopbackAddress {
    throw DatabaseFailure("\(config.host) no es una dirección local: activá TLS para conectar.")
}
```

`isLoopbackAddress` se implementa sobre `SocketAddress` comparando el octeto/los bytes de la dirección
(`127.0.0.0/8` y `::1`), no el texto. Esto cubre el caso del `.krabzik` leído en modo `lenient`: el
archivo se abre, la conexión aparece en la barra lateral, y al intentar conectar da un error claro que
dice qué hay que cambiar.

### 3. UI

En `ConnectionSheet`, debajo de la fila de TLS, cuando `connection.tls == .disabled`:

- host loopback → texto secundario: «Sin cifrado. Aceptable solo porque el servidor es local.»
- host no loopback → texto en naranja: «Sin TLS solo se permite para conexiones locales.» y **Guardar** y
  **Probar** deshabilitados.

El mensaje se calcula de una propiedad derivada del estado, no en el closure del botón, para que cambie en
vivo al escribir el host.

### 4. README

En la sección de MySQL, reemplazar «**Sin TLS** permite una conexión local sin cifrar» por una frase que
diga explícitamente que la opción **solo** se admite contra 127.0.0.1, ::1 o localhost, y que se comprueba
contra la dirección resuelta.

## Criterios de aceptación

1. Guardar una conexión con `tls = .disabled` y host `db.interno.example` falla con el mensaje del spec, y
   la hoja no se cierra.
2. Guardar la misma conexión con host `127.0.0.1` funciona.
3. Un `.krabzik` existente con una conexión remota sin TLS **se abre** sin error, y el intento de conectar
   falla con el mensaje que indica activar TLS.
4. Una conexión con `tls = .disabled` cuyo host es un nombre que resuelve a una IP pública falla al
   conectar aunque el texto del host no sea reconocible como remoto.
5. `tls = .verified` no cambia de comportamiento en ningún caso: las pruebas de MySQL existentes siguen
   pasando sin tocarlas.

## Pruebas

En `KrabzikTests/DatabaseTests.swift`:

- `testDisabledTLSRejectedForNonLoopbackHostOnSave` — sin red, solo `validated(.strict)`.
- `testWorkspaceWithRemoteInsecureConnectionStillLoads` — `validated(.lenient)` vía `Workspace.read`.
- `testLoopbackDetectionCoversAliasesAndRanges` — tabla de casos: `127.0.0.1`, `127.1.2.3`, `::1`,
  `localhost`, `LOCALHOST`, `foo.localhost`, `localhost.attacker.example` (debe dar falso),
  `0.0.0.0` (falso), `192.168.1.10` (falso).
- La comprobación de la dirección resuelta entra en el grupo de pruebas que ya se saltan sin servidor:
  `testDisabledTLSRejectedWhenResolvedAddressIsNotLoopback`.

## Riesgos y compatibilidad

- Alguien puede estar usando hoy «Sin TLS» contra un servidor en la red local (`192.168.x.x`) a propósito.
  Ese caso deja de funcionar y es intencional: la alternativa sería un modo «sin cifrado, acepto el riesgo»
  explícito, que este spec deja fuera a propósito para no reintroducir el agujero con otro nombre. Si más
  adelante se decide agregarlo, tiene que ser un tercer `TLSMode` con nombre inequívoco, persistido en el
  `.krabzik` y visible en la barra lateral.
- `SocketAddress` para un socket Unix no aplica (no se soportan), pero conviene que `isLoopbackAddress`
  devuelva `false` en el caso `.unixDomainSocket` en lugar de romper.

## Resuelto

**2026-11-09** · commit `c4ce3ab`.

| # | Criterio | Resultado |
|---|---|---|
| 1 | Guardar con host remoto y sin TLS falla | ✓ `testDisabledTLSRejectedForNonLoopbackHostOnSave` |
| 2 | Con `127.0.0.1` funciona | ✓ misma prueba |
| 3 | Un `.krabzik` con conexión remota insegura **se abre**, y conectar falla | ✓ `testWorkspaceWithRemoteInsecureConnectionStillLoads` + el chequeo de `open` |
| 4 | Un nombre que resuelve a IP pública falla al conectar | ✓ `testDisabledTLSRejectedWhenResolvedAddressIsNotLoopback` |
| 5 | `.verified` sin cambios de comportamiento | ✓ las pruebas de MySQL existentes no se tocaron |

### Decisiones de implementación

- **Los dos niveles de validación** son la pieza central. Sin ellos, aplicar la regla nueva en
  `Workspace.read` haría que un proyecto existente con una conexión remota sin TLS dejara de abrirse, que es
  peor que el problema que se quería resolver. El rechazo llega al conectar, con un mensaje que dice qué
  cambiar.
- **Doble comprobación, textual y real.** `isLoopbackHost` filtra en la UI y al guardar; la dirección
  resuelta se comprueba en `MySQLClient.open`, antes de abrir el socket. La primera da un mensaje temprano;
  la segunda es la que de verdad cierra el agujero, porque un host puede resolver a cualquier parte.
- **`127.` no se acepta por prefijo.** `127.malicioso.example` empieza con `127.` y no es una IP: se exige
  que las cuatro partes sean octetos. Igual con `.localhost`, que no matchea `localhost.attacker.example`.
- **Ninguna prueba nueva necesita red ni servidor.** La del extremo remoto usa la IP literal
  `93.184.216.34`, que no requiere DNS, y el rechazo ocurre antes de conectar.

### Lo que quedó fuera, a propósito

No se agregó un tercer modo «sin cifrado, acepto el riesgo» para extremos remotos. El spec lo dejaba fuera
y se respetó: reintroducirlo con otro nombre sería volver al mismo agujero. Si alguna vez se decide, tiene
que ser un `TLSMode` con nombre inequívoco, persistido en el `.krabzik` y visible en la barra lateral.

Caso que deja de funcionar y es intencional: «Sin TLS» contra un servidor en la red local
(`192.168.x.x`). La alternativa es activar TLS.
