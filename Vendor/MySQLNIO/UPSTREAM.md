# MySQLNIO

Source: [vapor/mysql-nio 1.9.1](https://github.com/vapor/mysql-nio/releases/tag/1.9.1), commit `7fa8530`. MIT license retained in `LICENSE`.

This directory contains the package sources and manifest. Upstream tests and examples are omitted; application integration tests live in `KrabzikTests/DatabaseTests.swift`.

## Cómo se mantiene este fork

Las fuentes aplicadas se versionan —así el proyecto compila sin pasos previos— y la fuente de verdad de
**por qué** son distintas está en `patches/`: un parche por motivo, con su justificación y la prueba que lo
cubre en la cabecera.

`scripts/check_vendor.sh` clona el tag declarado arriba, aplica `patches/*.patch` en orden y compara el
resultado con `Sources/` y `Package.swift`. Si alguien edita el vendoring sin agregar su parche, falla y dice
qué archivo. Es un paso bloqueante de `scripts/verify.sh`; necesita red, y localmente se puede saltar con
`KRABZIK_SKIP_VENDOR_CHECK=1`.

Para cambiar algo del fork:

1. clonar el tag de upstream, editar ahí y `git diff > Vendor/MySQLNIO/patches/NNNN-motivo.patch`;
2. copiar el archivo editado a `Sources/`;
3. correr `scripts/check_vendor.sh`.

Para subir a una versión nueva: cambiar la línea `Source:` de este documento, aplicar los parches sobre el
tag nuevo, resolver lo que ya no aplique —si una corrección entró aguas arriba, se borra el parche— y copiar
el resultado a `Sources/`.

## Qué prueba cubre cada parche

| Parche | Prueba |
|---|---|
| `0001-reject-tls-when-server-does-not-advertise` | `DatabaseTests.testMySQLRejectsBadCredentialsAndUntrustedTLS` |
| `0002-caching-sha2-nonce-20-bytes` | `DatabaseTests.testMySQLPasswordAuthenticationAndStoredProcedure` (contraseña más larga que el nonce, y la autenticación en caché de la segunda conexión) |
| `0003-connection-deadlines-and-channel-cleanup` | `DatabaseTests.testHandshakeTimeoutAndEarlyServerDisconnect` |
| `0004-negotiate-client-multi-results` | `DatabaseTests.testMySQLPasswordAuthenticationAndStoredProcedure` (el `CALL` al procedimiento) |
| `0005-package-omit-upstream-test-target` | ninguna: si no estuviera, el paquete no resolvería y no compilaría nada |
| `0006-optional-tls-for-preferred-mode` | `MySQLDiagnosticsTests.testPreferredFallsBackOnlyWhenServerOmitsTLS` |

Las cinco primeras son pruebas contra un servidor MySQL real y se saltan sin
`.build/mysql-test-port` (ver el README). En CI el marcador se crea siempre, así que corren en cada cambio.

## Revisión

| | |
|---|---|
| Versión fijada | 1.9.1 (`7fa8530`) |
| Última comparación con upstream | 2026-11-10, con `scripts/check_vendor.sh`: coincide exactamente |
| Aviso automático | `.github/workflows/upstream.yml`, el día 1 de cada mes, falla si mysql-nio publicó una release más nueva |

Los parches `0001` (rechazar TLS no anunciado) y `0002` (nonce de 20 bytes en `caching_sha2_password`) son
correcciones de protocolo de interés general, no adaptaciones a Krabzik. **Todavía no se enviaron a
`vapor/mysql-nio`.** Cuando se envíen, anotar acá el número del PR para poder retirar el parche el día que
se integren.

Local changes for Krabzik, 2026-11-09:

- `MySQLConnectionHandler.swift`: use exactly 20 nonce bytes for `caching_sha2_password`, excluding the handshake terminator; send an empty response for an empty password. Both full RSA authentication with a password longer than 20 bytes and subsequent cached authentication are covered by real-server tests. [MySQL protocol reference](https://dev.mysql.com/doc/dev/mysql-server/8.0.46/page_caching_sha2_authentication_exchanges.html).
- Reject a requested TLS connection when the server does not advertise TLS, before sending credentials.
- `MySQLConnection.swift`: default 10-second TCP and authentication deadlines, complete authentication on premature socket closure, and close failed channels. Deadline and premature-close behavior are covered by a local TCP fixture.
- `MySQLProtocol+CapabilityFlags.swift`: negotiate `CLIENT_MULTI_RESULTS` for stored procedures. `CLIENT_MULTI_STATEMENTS` remains disabled; Krabzik executes parsed statements sequentially.
- `Package.swift`: omit the upstream test target because its test sources are not included.

Transitive dependency versions are pinned in the Xcode workspace's `Package.resolved`. Their notices, along with this package's license, are included in `Krabzik/Resources/ThirdPartyNotices.txt` and copied into the app bundle.
