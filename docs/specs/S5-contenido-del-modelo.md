# S5 · Marcar y sanear el contenido que viene del modelo

| | |
|---|---|
| **Severidad** | Baja |
| **Área** | Agente, UI |
| **Archivos** | `Krabzik/Views/AgentPanel.swift`, `Krabzik/Services/AgentController.swift`, `Krabzik/Models/AgentModels.swift` |
| **Depende de** | — |
| **Esfuerzo** | 3–4 horas |

## Problema

Todo lo que el panel de Codex muestra —mensajes, actividad, rutas de archivos cambiados, preguntas,
comandos a aprobar— lo escribe el modelo. Hoy se renderiza sin ninguna marca de procedencia y, en el caso
de las preguntas, con un campo de entrada:

```swift
if question["isSecret"].bool {
    SecureField("Respuesta", text: Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 }))
}
```

Es decir: el modelo puede pedir un dato secreto y la app le presenta al usuario un campo de contraseña,
con el mismo aspecto que un campo legítimo de la app. La respuesta vuelve al modelo por
`answerQuestions(_:answers:)`. Las `developerInstructions` prohíben explícitamente pedir credenciales
(`AgentScope.instructions`: «No accedas al Llavero, a credenciales de bases de datos…»), pero eso es una
instrucción al modelo, no un control: no sobrevive a una inyección desde el contenido de un repositorio.

Problemas secundarios del mismo origen:

- `activity`, `AgentMessage.text` y `AgentFileChange.path` se muestran tal cual. Un path con caracteres de
  control o con marcas bidireccionales (U+202E y compañía) puede hacer que `facturas/pago.txt` se lea como
  otra cosa en el panel y en el diálogo de aprobación de cambios.
- El diálogo de aprobación de comandos muestra `request.params["command"]`, que es exactamente el texto que
  hay que leer bien para decidir. Si se puede disfrazar visualmente, la aprobación deja de valer.

> Lo que ya está bien: el prompt del sistema dice explícitamente que nombres y rutas son datos y no
> instrucciones; las aprobaciones son de un solo uso («Permitir una vez», sin opción de «siempre»);
> `item/permissions/requestApproval` se responde con permisos vacíos; las elicitaciones de MCP se cancelan;
> y los deltas se renderizan con `Text`, no con Markdown, así que no hay enlaces activos.

## Objetivo

El usuario distingue siempre qué texto escribió el modelo, el texto del modelo no puede disfrazarse
visualmente, y pedir un secreto no es una interacción silenciosa y normal.

## Alcance

**Incluye** saneado de texto del modelo, marca de procedencia en el panel, y un camino friccionado y
explicado para los campos secretos.

**No incluye** interceptar o clasificar el contenido semánticamente, ni cambiar el protocolo con Codex.

## Diseño

### 1. Saneado

Nueva función en `AgentModels.swift`:

```swift
enum ModelText {
    /// Texto del modelo listo para mostrar: sin controles, sin overrides bidi, acotado.
    static func display(_ raw: String, limit: Int) -> String
}
```

Quita: `U+0000`–`U+0008`, `U+000B`, `U+000C`, `U+000E`–`U+001F`, `U+007F`; los overrides y aislamientos
bidireccionales `U+202A`–`U+202E` y `U+2066`–`U+2069`; `U+200B`–`U+200F` y `U+FEFF`. Colapsa más de dos
saltos de línea seguidos. Trunca con `…` al límite dado. Conserva tabuladores y saltos simples, que son
legítimos en diffs y comandos.

Se aplica en el borde, al entrar en el estado observable —`AgentController.receive(_:)`— y no en la vista,
para que cualquier vista futura herede la garantía:

- `item/agentMessage/delta` y `agentMessage` completado → `limit: 120_000` (como hoy).
- `activity` → `limit: 160`.
- `AgentFileChange.path` y `.diff` → `limit: 1_024` / `100_000`.
- `turn/diff/updated` → `limit: 200_000`.
- Los `params` de las solicitudes se sanean al construir el `AgentRequest`, no al mostrarlo.

### 2. Marca de procedencia

En `AgentRequestView`, encabezado explícito con icono y color propio: «**Codex pide permiso**» o
«**Codex pregunta**», y el cuerpo del texto del modelo dentro de un bloque con fondo distinto del de los
controles de la app. En `AgentMessageView` el mensaje del asistente ya se distingue del del usuario por el
fondo; agregar el mismo tratamiento de bloque para que no se confunda con texto de la interfaz.

### 3. Campos secretos con fricción

Reemplazar el `SecureField` directo por:

```
⚠︎ Codex pide un dato secreto.
Krabzik nunca necesita tus contraseñas para trabajar, y Codex no debería pedirlas.
Si no sabés exactamente por qué lo pide, rechazá la pregunta.
[ ] Entiendo el riesgo y quiero responder
```

El `SecureField` aparece deshabilitado hasta marcar la casilla, y el botón **Responder** sigue
deshabilitado mientras haya respuestas vacías (como hoy). Agregar **Rechazar** también en la rama de
preguntas: hoy, si el modelo pregunta, las únicas salidas son responder o detener el turno —`answer(_:accept:)`
existe pero la vista solo lo usa en la rama de aprobaciones.

### 4. Registro

Cuando llega una pregunta con `isSecret`, registrar el evento con `Log.agent` (C6), incluyendo el texto de
la pregunta. Si alguna vez pasa de verdad, hay que poder reconstruir qué se pidió.

## Criterios de aceptación

1. Un mensaje del modelo que contiene `U+202E` se muestra sin ese carácter y el orden visual del resto del
   texto no cambia.
2. Un `path` de un cambio propuesto con caracteres de control se muestra saneado, tanto en la lista de
   archivos como en el diálogo de aprobación.
3. Una pregunta con `isSecret: true` no permite escribir hasta marcar la casilla de riesgo, y tiene botón
   **Rechazar** visible.
4. El texto que viene del modelo se distingue visualmente del texto de la interfaz en el panel y en los dos
   diálogos de aprobación.
5. El saneado no altera diffs legítimos: un diff con tabuladores, `\n` y caracteres acentuados se muestra
   íntegro (salvo el truncado por límite, que ya existía).
6. Ninguna vista llama directamente a `params[...]` sin pasar por el texto ya saneado.

## Pruebas

En `KrabzikTests/AgentTests.swift`:

- `testModelTextStripsControlAndBidiCharacters` — tabla de casos, incluida la comprobación de que el
  contenido legítimo sobrevive.
- `testSecretQuestionRequiresExplicitRiskAcknowledgement` — sobre el estado, no sobre la vista: el
  controlador expone `requests` y la vista deriva de eso; la prueba cubre que `AgentRequest` conserva
  `isSecret` y que el texto llega saneado.
- `testFileChangePathsAreSanitizedBeforeReachingState` — alimentar `receive(_:)` con un `item/completed`
  cuyo path tenga controles y comprobar `agent.changes`.

`receive(_:)` ya es internal justamente para esto, y `AgentTests` ya tiene el patrón
(`testAgentApprovalStreamingAndFileEvents`).

## Riesgos y compatibilidad

- El saneado podría recortar algo que el usuario quería ver literalmente (por ejemplo un diff de un archivo
  que de verdad contiene caracteres de control). El caso es raro y el diff real sigue en el archivo; el
  panel es una vista, no la fuente. Vale la pena decirlo en el spec de la UI: el bloque de diff puede
  indicar «(caracteres no imprimibles omitidos)» cuando saneó algo.
- Agregar fricción a los campos secretos puede molestar si Codex los usa para algo legítimo y frecuente.
  No se conoce ese caso hoy; si aparece, se revisa con datos.
