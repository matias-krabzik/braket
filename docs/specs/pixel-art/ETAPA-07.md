# Etapa 7 · Codex y propuestas visuales

| | |
|---|---|
| **Estado / fecha** | Especificada; no implementada ni validada · 2026-11-14 |
| **Depende de** | Etapas 1–6; prueba de capacidad de PXA-04 pendiente |
| **Autorización actual** | Solo documentación; no iniciar inferencias |

## Objetivo y specs

Trabajar por prompts sobre el mismo documento editable, con preview, alcance y aplicación reversible.

| Spec | Contrato |
|---|---|
| [PXA-17](PXA-17-conexion-y-contexto-codex.md) | Conexión, capacidades, aislamiento, contexto y cancelación |
| [PXA-18](PXA-18-herramientas-graficas-codex.md) | Herramientas internas, operaciones, validación e idempotencia |
| [PXA-19](PXA-19-panel-codex-y-calidad.md) | Panel, conversación, comparación, aplicación y evaluación artística |

## Secuencia y alcance

7A: paletas y operaciones precisas, con el gate de contexto visual/herramientas validado antes
de habilitar Enviar. 7B: modificaciones creativas pequeñas y localizadas, sometidas a evaluación
visual aparte. Proponer una paleta sin aplicarla es un resultado válido; editar regiones o agregar
elementos usa operaciones del editor, no un servicio de generación de imágenes adicional.

Fuera: edición autónoma sin preview, tareas programadas, mensajes a terceros, navegación por otros
proyectos, generación de animaciones largas, colaboración en tiempo real y generación raster remota
como nueva dependencia. Un modelo/conexión no disponibles no bloquean el editor manual.

## Cierre verificable

Pedir paleta → ajustar → comparar → aplicar → deshacer → guardar/reabrir → rehacer sin red.
Repetir con edición de selección, capas bloqueadas, respuesta tardía, cambio manual concurrente y
sesión sin cuenta. Ninguna violación estructural/de alcance es aceptable aunque el resultado se vea
bien. No afirmar calidad creativa garantizada por pasar pruebas del protocolo. La etapa se cierra
con evidencias de 7A y 7B o se reporta explícitamente cuál incremento sigue incompleto.
