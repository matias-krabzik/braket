# Fixtures de las pruebas

Archivos de entrada que la suite necesita y que, por venir de afuera o por ser hostiles a
propósito, conviene tener versionados y no generados.

| Archivo | Para qué |
|---|---|
| `hostil.krabzik` | JSON válido con contenido hostil: un override bidi en el nombre de un subproyecto y una ruta relativa que sale de la carpeta. Lo usa `CoreTests.testHostileFixtureIsRejected` (C7) |

Se leen con `#filePath`, no desde el bundle de pruebas: así no hay que registrarlos en el
proyecto Xcode ni copiarlos al bundle.

## Lo que **no** está acá, y por qué

- **Esquemas JSON del protocolo de Codex.** Son unos cuarenta archivos, 4,5 MB, y ninguna
  prueba los usa: el protocolo se ejercita con un servidor falso en Python dentro de
  `AgentTests`. Se obtienen del propio ejecutable y se pueden regenerar cuando haga falta;
  versionarlos sería cargar el repositorio con material que nadie comprueba.
- **Un proyecto de ejemplo para el agente.** `testLiveCodexReadsAndEditsTwoSubprojects`
  construye el suyo en un directorio temporal, con dos subproyectos y un `estado.txt`.
- **Marcadores de las pruebas opcionales.** `.build/mysql-test-port` y
  `.build/codex-live-tests` no son fixtures: son interruptores que el desarrollador crea
  para habilitar las pruebas que necesitan un servidor MySQL o una sesión de ChatGPT. El
  README del proyecto explica cómo levantarlos.
