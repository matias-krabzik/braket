# C9 · Cerrar los huecos de cobertura que quedan

| | |
|---|---|
| **Severidad** | Media |
| **Área** | Pruebas |
| **Archivos** | `KrabzikTests/`, nuevo `KrabzikTests/Fixtures/` |
| **Depende de** | C3 (sin CI, las pruebas nuevas tampoco se ejecutan solas) |
| **Esfuerzo** | 1 día |

## Estado al 2026-11-09

La suite tiene **36 pruebas** en cuatro archivos, y es de buena calidad: las pruebas son específicas,
verifican propiedades reales y varias son exhaustivas donde importa.

| Archivo | Pruebas | Qué cubre |
|---|---|---|
| `CoreTests.swift` | 10 | round-trip del formato, versión y IDs duplicados, detección de frameworks, `DocumentIO` con cambio externo y archivo borrado, `LineIndex` incremental contra reconstrucción completa con Unicode, `UTF8StreamDecoder` en **todas** las fronteras posibles, rechazo de binarios, geometría del editor, procesos (salida, código de salida, directorio con comilla) y detención de descendientes con reinicio |
| `DatabaseTests.swift` | 13 (6 requieren servidor) | parser SQL con cadenas, comentarios y `DELIMITER`, comentarios ejecutables, modo `NO_BACKSLASH_ESCAPES`, credenciales no serializadas, selección UTF-16, tipos/filas afectadas/sesión, rollback y detención en el primer error, límites y columnas duplicadas, cancelación real en el servidor, credenciales malas y TLS no confiable, `caching_sha2_password` con procedimiento, credencial ligada al endpoint, timeout de handshake |
| `WorkspaceNavigationTests.swift` | 6 | inicio en pantalla de bienvenida, apertura explícita una sola vez, recientes con orden/duplicados/límite, quitar un reciente sin borrar, volver al inicio, reciente faltante |
| `AgentTests.swift` | 7 | framing JSONL con Unicode, `AgentScope` con escape por symlink, recarga del editor preservando cambios, timeout y solicitudes pendientes del transporte, aprobaciones/streaming/eventos de archivo, Codex real sobre dos subproyectos, interrupción y turno nuevo |

> `AgentTests.swift` apareció el 2026-11-09 a las 16:30, durante la auditoría. Cierra el hueco más grande
> que tenía el proyecto: hasta ese momento, `AgentController` y `CodexTransport` no tenían ninguna prueba,
> y el comentario «Internal for deterministic protocol-fixture tests» en `AgentController.receive(_:)`
> apuntaba a pruebas que no existían. Este spec ya no incluye eso.

## Problema

Lo que queda sin cubrir, por orden de riesgo:

1. **`MySQLTextCommand`** solo se ejercita contra un servidor real, es decir: en las 6 pruebas que se
   **saltan por defecto**. Es un decodificador de protocolo binario con aritmética de longitudes
   (`readSQLLength`, `readSQLSlice`), detección de EOF ambigua (`packet.isEOF && readableBytes < 0xFF_FFFF`)
   y contabilidad de bytes para los límites. Sin paquetes sintéticos, un error de borde no se detecta.
2. **`FileTree.Coordinator`** no tiene ninguna prueba: carga perezosa, exclusiones
   (`node_modules`, `.git`, `vendor`, …), symlinks de directorio que no se siguen, el watcher de
   `DispatchSource`, y la reconciliación de hijos por URL al recargar. Es también el único sitio donde
   aparecieron avisos reales de concurrencia (ver C2).
3. **`SyntaxStyler`** no tiene pruebas. Son seis expresiones regulares aplicadas sobre el texto visible, con
   una (`/\*[\s\S]*?\*/`) que puede comportarse mal con entradas patológicas. El tope de 60.000 caracteres
   lo acota, pero no hay nada que verifique ni el tope ni los rangos de color.
4. **`CredentialStore.remove`** al cambiar el endpoint de una conexión. La prueba
   `testCredentialsStayBoundToEndpointAndTLS` cubre que la cuenta del llavero incluya host/puerto/usuario/TLS
   —que es lo importante— pero no que la credencial vieja se borre al editar, que es el camino de
   `saveConnection` con el `try?` que señala C6.
5. **Los límites del formato** que introduce C7, por definición.
6. **Fixtures fuera del repositorio.** `.build/agent-fixture/` (con `api` y `client`),
   `.build/codex-schema/` (los esquemas JSON del protocolo de Codex) y `.build/probe-codex.py` viven en un
   directorio **ignorado**: se borran con un `rm -rf .build` y no están versionados.

## Objetivo

Todo componente con lógica de protocolo, parsing o sistema de archivos tiene pruebas que corren **sin**
servidor ni red, y los fixtures que la suite necesita están versionados.

## Alcance

**Incluye** los cinco huecos de arriba y mover los fixtures al repositorio.

**No incluye** medir cobertura con un número objetivo. Un porcentaje invita a escribir pruebas de relleno;
lo que se busca es cubrir los componentes señalados.

## Diseño

### 1. `MySQLTextCommand` con paquetes sintéticos

Nuevo `KrabzikTests/MySQLProtocolTests.swift`. Construir `MySQLPacket` a mano con `ByteBuffer` y alimentar
`handle(packet:capabilities:)`:

- longitudes codificadas en los cuatro anchos (`0…250`, `252`, `253`, `254`);
- una longitud que excede `readableBytes` → debe dar `protocolError`, no leer de más;
- fila de texto que empieza con `0x00` (cadena vacía) y con `0xFE` (campo grande), que es justamente el caso
  que el comentario del código documenta;
- EOF con y sin `CLIENT_DEPRECATE_EOF`;
- paquete de error con y sin marcador `#` de SQLSTATE;
- columna binaria (charset 63) → se formatea como `0x…`;
- celda de más de 16.384 bytes → se trunca con `…` y marca `truncated`;
- `byteLimit` agotado a mitad de una fila → `truncated` y no se agrega la fila;
- `SERVER_MORE_RESULTS_EXISTS` con `resultLimit` alcanzado → `DatabaseFailure`.

Esto convierte seis pruebas que normalmente se saltan en una red que corre siempre.

### 2. `FileTree.Coordinator`

Nuevo `KrabzikTests/FileTreeTests.swift`, con directorios temporales:

- un árbol con `node_modules`, `.git` y `vendor` → no aparecen entre los hijos;
- un symlink a directorio → aparece como hoja, no se expande;
- orden: directorios primero, después archivos, con `localizedStandardCompare`;
- recargar un nodo conserva las instancias de `FileNode` ya existentes (reconciliación por URL);
- un directorio sin permiso de lectura → `children = []` y el error se reporta, no se traga;
- `generation` cambia al cambiar de workspace → una carga en vuelo del anterior se descarta.

El watcher de `DispatchSource` es difícil de probar de forma determinista; alcanza con una prueba que cree un
archivo en el directorio observado y espere con un `XCTestExpectation` con timeout generoso, marcada para
poder aislarla si resulta inestable en CI.

### 3. `SyntaxStyler`

En `CoreTests` o archivo propio:

- `testSyntaxStylerPatternsCompile` (también lo pide C4);
- un fragmento de SQL y uno de PHP → los rangos coloreados caen dentro del rango pedido y los atributos son
  los esperados para palabra clave, literal y comentario;
- texto de 60.001 caracteres → no se aplica nada (el guardia de tamaño);
- entrada patológica (`"/*" * 5_000`) → termina en un tiempo acotado (`measure` o un timeout explícito);
- `language == "Texto"` y `"Markdown"` → no se toca el `NSTextStorage`.

### 4. `CredentialStore` en el cambio de endpoint

En `DatabaseTests`, junto a la prueba existente:

- `testEditingEndpointRemovesOldCredential`: guardar con un host, editar a otro, comprobar que leer con la
  configuración vieja devuelve `""` y con la nueva devuelve la contraseña. Usa el llavero real, como ya hace
  `testCredentialsStayBoundToEndpointAndTLS`, y limpia en el `teardown`.

### 5. Fixtures versionados

```
KrabzikTests/Fixtures/
  agent/api/…            ← desde .build/agent-fixture/api
  agent/client/…          ← desde .build/agent-fixture/client
  codex-schema/…          ← desde .build/codex-schema (o un README con su origen y versión)
  workspaces/hostile.krabzik
  mysql/packets/…         ← capturas hexadecimales usadas en el punto 1
```

`probe-codex.py` pasa a `scripts/probe-codex.py` si sigue siendo útil, o se borra si ya lo reemplazan las
pruebas de `AgentTests`. Un script de diagnóstico que vive en un directorio ignorado es un script que se
pierde.

Si los esquemas de Codex son grandes, versionar solo los que las pruebas usan y anotar en un README del
directorio de qué versión de Codex provienen.

## Criterios de aceptación

1. `xcodebuild test` **sin** `.build/mysql-test-port` ejecuta pruebas de `MySQLTextCommand`,
   `FileTree` y `SyntaxStyler`: la cantidad de pruebas que corren sin servidor sube de 30 a al menos 45.
2. Las pruebas nuevas no usan red ni servidor MySQL.
3. `git ls-files KrabzikTests/Fixtures | wc -l` es mayor que 0 y las pruebas los referencian por ruta
   relativa al bundle de pruebas.
4. `.build/agent-fixture`, `.build/codex-schema` y `.build/probe-codex.py` ya no son necesarios para
   ejecutar la suite.
5. Una regresión introducida a propósito en `readSQLLength` (por ejemplo, tratar `253` como 2 bytes) hace
   fallar al menos una prueba.
6. Las 36 pruebas existentes siguen pasando sin modificaciones.

## Pruebas

Este spec **es** pruebas. Su propia verificación es el criterio 5: introducir un error deliberado en cada
componente nuevo cubierto y comprobar que la suite lo detecta. Conviene hacerlo y anotar el resultado en el
spec al cerrarlo; una prueba que no falla ante un error real no cubre nada.

## Riesgos y compatibilidad

- Construir paquetes de MySQL a mano acopla las pruebas a los detalles del protocolo. Es deliberado: esa es
  precisamente la lógica que hay que fijar, y el fork local (S7) la hace más importante, no menos.
- La prueba del watcher de archivos puede ser inestable en CI. Si lo es, se aísla en un job aparte; no se
  borra.
- Versionar fixtures del agente añade archivos al repositorio. Son chicos y hacen la suite reproducible.
