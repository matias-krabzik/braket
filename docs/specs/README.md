# Especificaciones de mejora · Krabzik IDE

Specs derivados de la auditoría de código, seguridad y prácticas del **2026-11-09**.
Un archivo por hallazgo. Cada spec es autocontenido: se puede implementar sin leer los demás,
salvo las dependencias que declara en su encabezado.

## Cómo leer un spec

| Sección | Qué contiene |
|---|---|
| Encabezado | Severidad, área, archivos afectados, dependencias, esfuerzo estimado |
| Problema | Qué pasa hoy, con referencias al código real |
| Objetivo | La propiedad que debe valer cuando el spec esté cerrado |
| Alcance | Qué entra y qué queda explícitamente afuera |
| Diseño | Cambios concretos, archivo por archivo |
| Criterios de aceptación | Verificables, sin ambigüedad. Si no se pueden comprobar, el spec no está cerrado |
| Pruebas | Qué pruebas nuevas se agregan y dónde |
| Riesgos y compatibilidad | Qué puede romper, qué hacer con proyectos `.krabzik` existentes |

## Sobre las referencias al código

Las mediciones y referencias son del árbol al **2026-11-09, 16:35**. El proyecto se estaba editando de forma
activa mientras se escribían estos specs: entre las 16:04 y las 16:35 cambiaron once archivos, apareció
`Krabzik/Views/AgentPanel.swift`, apareció `KrabzikTests/AgentTests.swift` y el camino de apertura de
documentos se movió de `.onOpenURL` en `WorkspaceView` a un manejador de Apple Events en `AppDelegate`.

Por eso: **las referencias por nombre de tipo y de función son las que valen**; los números de línea son
orientativos. Antes de implementar un spec conviene releer el sitio que cita y, si el código se movió,
actualizar el spec en el mismo commit.

Dos hallazgos de la auditoría se resolvieron durante esa ventana y los specs ya lo reflejan:

- la cobertura del agente (`AgentController`, `CodexTransport`) pasó de 0 pruebas a 7 — ver C9;
- la versión del producto pasó a `0.3.0` en el proyecto y en el `clientInfo` del agente; solo quedó el
  README atrasado — ver C10.

## Seguridad

| Spec | Título | Severidad | Estado |
|---|---|---|---|
| [S1](S1-proyecto-no-confiable.md) | Un `.krabzik` ajeno no debe poder ejecutar código | Alta | pendiente |
| [S2](S2-verificar-ejecutable-codex.md) | Verificar el ejecutable de Codex antes de lanzarlo | Media | pendiente |
| [S3](S3-tls-solo-loopback.md) | «Sin TLS» solo para conexiones locales | Media | pendiente |
| [S4](S4-no-retener-password.md) | No retener la contraseña en memoria durante la sesión | Media-baja | pendiente |
| [S5](S5-contenido-del-modelo.md) | Marcar y sanear el contenido que viene del modelo | Baja | pendiente |
| [S6](S6-sandbox-y-firma.md) | Decidir y documentar sandbox, firma y distribución | Estructural | pendiente |
| [S7](S7-gobernanza-fork-mysqlnio.md) | Gobernanza del fork local de MySQLNIO | Proceso | pendiente |

## Calidad y prácticas

| Spec | Título | Severidad | Estado |
|---|---|---|---|
| [C1](C1-repositorio-git.md) | Inicializar el control de versiones | Crítica | **resuelto** |
| [C2](C2-swift-6-mode.md) | Migrar a Swift 6 language mode | Alta | pendiente |
| [C3](C3-ci-lint-warnings.md) | CI, linter y warnings como errores | Alta | pendiente |
| [C4](C4-legibilidad.md) | Legibilidad: estilo, nombres y constantes con nombre | Media | pendiente |
| [C5](C5-dividir-workspacecontroller.md) | Dividir `WorkspaceController` | Media | pendiente |
| [C6](C6-logging-y-errores.md) | Logging real y errores no silenciados | Media | pendiente |
| [C7](C7-validacion-formato-krabzik.md) | Validar y acotar el formato `.krabzik` | Media | pendiente |
| [C8](C8-pbxproj-sincronizado.md) | Garantizar que el `.pbxproj` generado esté al día | Media | pendiente |
| [C9](C9-cobertura-pruebas.md) | Cerrar los huecos de cobertura que quedan | Media | pendiente |
| [C10](C10-version-unica.md) | Una sola fuente de verdad para la versión | Baja | pendiente |
| [C11](C11-rendimiento-editor.md) | Rendimiento del editor y arquitecturas del Release | Baja | pendiente |

## Orden de ejecución propuesto

```
C1 ──> C2 ──> C3 ──┬──> C8
                   ├──> S1 ──> C7
                   ├──> S2, S3, S4, S5
                   ├──> C4, C5, C6
                   └──> S6, S7, C9, C10, C11
```

1. **C1** primero: sin historia de cambios ningún refactor es revisable ni reversible.
2. **C2** y **C3** después: fijan el piso de verificación para todo lo que venga.
3. **S1** es el hallazgo de seguridad con más impacto y **C7** es su continuación natural.
4. El resto es paralelizable, con la salvedad de que **C4** y **C5** tocan muchos archivos: conviene
   hacerlos cuando no haya otro cambio grande en vuelo.

## Estado

**C1 resuelto** el 2026-11-09 (commits `1785260` y `8883bba`): el proyecto ya está bajo control de versiones,
así que el resto de los specs se puede implementar con diffs revisables y reversibles.

Los otros 17 están sin implementar. Al cerrar uno, marcarlo en la tabla de este índice y dejar en el propio
spec una sección `## Resuelto` con la fecha, los commits y los criterios verificados.
