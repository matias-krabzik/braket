# Etapa 1 · Formato, historial, color y operaciones

| | |
|---|---|
| **Estado / fecha** | Spec terminada; núcleo implementado, validación técnica pendiente · 2026-11-14 |
| **Dependencias** | Alcance y mockup acordados; base documental para etapas 2–8 |
| **Alcance de esta entrega** | Documentación y seguimiento; sin cambios en la app |

## Contratos

| Spec | Responsabilidad |
|---|---|
| [PXA-01](PXA-01-formato-y-persistencia.md) | Contenedor, entidades, versionado, límites y persistencia |
| [PXA-02](PXA-02-historial-persistente.md) | Revisiones, ramas, retención y deshacer/rehacer |
| [PXA-03](PXA-03-color-y-paletas.md) | Píxeles libres/vinculados y semántica de paleta/alfa |
| [PXA-04](PXA-04-operaciones-y-propuestas.md) | Transacciones, alcance y propuestas aisladas |

## Cierre

La definición documental está escrita y existe un núcleo implementado. Su estado técnico y las
validaciones pendientes se registran en [Estado de las etapas](ESTADO-IMPLEMENTACION.md).
La etapa no se declara técnicamente validada solo por disponer de specs o pruebas unitarias:
faltan contrastar todos los límites del contrato y la prueba visual real con Codex antes de
publicar archivos 1.0. No reinterpretar decisiones de etapas posteriores como capacidad ya existente.

La [matriz de alcance](MAPA-DE-ALCANCE.md) relaciona todos los contratos y sus ampliaciones. Las
etapas posteriores concretan algoritmos/UI; si requieren cambiar una invariante de formato,
actualizarla aquí antes de entregar el primer escritor compatible.
