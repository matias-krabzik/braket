# Etapa 6 · Importación y exportación

| | |
|---|---|
| **Estado / fecha** | Especificada; no implementada ni validada · 2026-11-14 |
| **Depende de** | Etapas 1–5 |
| **Autorización actual** | Solo documentación |

## Objetivo y specs

Intercambiar recursos con otras herramientas y motores sin perder el `.pxa` editable.

| Spec | Contrato |
|---|---|
| [PXA-15](PXA-15-importacion-imagenes.md) | PNG, hojas de sprites, límites y entrada desde portapapeles |
| [PXA-16](PXA-16-exportacion-y-metadatos.md) | PNG, secuencias PNG, GIF y spritesheet + JSON |

## Secuencia y cierre

Implementar importación/conversión y PNG primero; después secuencias/spritesheets/metadatos y GIF.
Reutilizar render y cuantización de etapas previas. Fuera: importación de GIF animado/APNG,
compatibilidad PSD/Aseprite, atlas con packing/rotación/trim automáticos, exportación de video
y sincronización con motores específicos.

Hito: importar PNG y spritesheet, editar/animar, guardar `.pxa` y exportar las cuatro salidas.
Verificar con decodificadores independientes píxeles, alfa, dimensiones, orden y duración; probar
cancelación/conflictos de salida. La exportación nunca es sustituto de Guardar. Tras esta etapa
el segundo hito del plan (animación e intercambio) está completo, sujeto a pruebas reales.
