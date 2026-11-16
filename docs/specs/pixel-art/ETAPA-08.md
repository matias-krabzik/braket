# Etapa 8 · Pulido, rendimiento y entrega

| | |
|---|---|
| **Estado / fecha** | Especificada; no implementada ni validada · 2026-11-14 |
| **Depende de** | Etapas 1–7; también fija presupuestos a respetar desde cada etapa |
| **Autorización actual** | Solo documentación; no compilar/instalar en esta tarea |

## Objetivo y specs

Comprobar que el editor completo funciona en Braket sin pérdida de trabajo, con UI accesible,
rendimiento medido y entrega local verificable.

| Spec | Contrato |
|---|---|
| [PXA-20](PXA-20-rendimiento-y-accesibilidad.md) | Presupuestos, corpus, memoria, respuesta, accesibilidad y ergonomía |
| [PXA-21](PXA-21-validacion-y-entrega.md) | Matriz de pruebas, regresiones, Release, instalación y evidencia |

## Trabajo final y cierre

Consolidar controles/atajos/ayudas, medir cargas reales, resolver regresiones y completar manual
de uso/release notes. No posponer a esta etapa la corrección básica de guardado ni las pruebas
unitarias de cada función: aquí se valida el conjunto y escenarios cruzados.

El hito requiere pruebas pertinentes aprobadas, limitaciones documentadas, Release correcta,
respaldo recuperable e instalación en `/Applications/Braket.app`, verificada en una sola instancia.
Una compilación en `.build` o un mockup no cumplen. Publicación/notarización/distribución remota
no forman parte de la instalación local pedida. Los documentos presentes no autorizan inferencias,
programación ni instalación ahora; esas acciones pertenecen a la implementación futura.
