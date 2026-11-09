# MySQLNIO

Source: [vapor/mysql-nio 1.9.1](https://github.com/vapor/mysql-nio/releases/tag/1.9.1), commit `7fa8530`. MIT license retained in `LICENSE`.

This directory contains the package sources and manifest. Upstream tests and examples are omitted; application integration tests live in `KrabzikTests/DatabaseTests.swift`.

Local changes for Krabzik, 2026-11-09:

- `MySQLConnectionHandler.swift`: use exactly 20 nonce bytes for `caching_sha2_password`, excluding the handshake terminator; send an empty response for an empty password. Both full RSA authentication with a password longer than 20 bytes and subsequent cached authentication are covered by real-server tests. [MySQL protocol reference](https://dev.mysql.com/doc/dev/mysql-server/8.0.46/page_caching_sha2_authentication_exchanges.html).
- Reject a requested TLS connection when the server does not advertise TLS, before sending credentials.
- `MySQLConnection.swift`: default 10-second TCP and authentication deadlines, complete authentication on premature socket closure, and close failed channels. Deadline and premature-close behavior are covered by a local TCP fixture.
- `MySQLProtocol+CapabilityFlags.swift`: negotiate `CLIENT_MULTI_RESULTS` for stored procedures. `CLIENT_MULTI_STATEMENTS` remains disabled; Krabzik executes parsed statements sequentially.
- `Package.swift`: omit the upstream test target because its test sources are not included.

Transitive dependency versions are pinned in the Xcode workspace's `Package.resolved`. Their notices, along with this package's license, are included in `Krabzik/Resources/ThirdPartyNotices.txt` and copied into the app bundle.
