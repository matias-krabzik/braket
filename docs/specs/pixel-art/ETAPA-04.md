# Etapa 4 · Paletas y conversiones de color

| | |
|---|---|
| **Estado / fecha** | Especificada; no implementada ni validada · 2026-11-14 |
| **Depende de** | Etapas 1–3, especialmente PXA-03 |
| **Autorización actual** | Solo documentación |

## Objetivo

Completar el inspector de paleta y permitir recolorear proyectos manualmente con preview,
alcance explícito y deshacer exacto. [PXA-12](PXA-12-interfaz-paletas-y-reduccion.md) concreta UI,
extracción, reducción y tabla de mapeo; PXA-03 sigue siendo la autoridad del modelo de color.

## Secuencia, alcance y cierre

Implementar edición de entradas, operaciones de vínculo/reemplazo y, después, extracción/reducción.
No depender de Codex para calcular una paleta ni cambiar el color. Se deja preparado el mismo
tipo de propuesta que usará la etapa 7. Fuera: paletas animadas, bibliotecas de paletas en nube,
importadores de formatos de paleta de terceros y dithering automático.

Hito: imagen con mezcla de libres/vinculados → crear paleta → vincular → recolorear global y
localmente → reducir a 16 colores → deshacer → guardar/reabrir. Verificar bloqueos y capacidad,
no solo similitud visual. Al cerrar esta etapa ya es usable el editor estático del plan original.
Todas las comprobaciones permanecen pendientes hasta implementar.
