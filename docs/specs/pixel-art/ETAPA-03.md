# Etapa 3 · Dibujo, selección y capas

| | |
|---|---|
| **Estado** | Especificada; no implementada ni validada |
| **Depende de** | Etapas 1–2; sin dependencia de Codex |
| **Fecha / autorización** | 2026-11-14 · Solo documentación |

## Objetivo y specs

Poder dibujar una ilustración completa manualmente y conservarla con historia reversible.

| Spec | Contrato |
|---|---|
| [PXA-09](PXA-09-dibujo-y-herramientas.md) | Rasterización, lápiz, borrador, relleno, formas, simetría y entrada |
| [PXA-10](PXA-10-seleccion-y-transformaciones.md) | Selección, portapapeles, movimiento, transformación y tamaño del lienzo |
| [PXA-11](PXA-11-edicion-de-capas.md) | Operaciones de capas, composición, propiedades y bloqueos |

## Entrega y secuencia

Primero rasterizador y transacciones de gesto; después selecciones/transformaciones y capas.
Habilitar los controles de PXA-06 conforme cada familia esté completa. Paletas existentes pueden
usarse para pintar; editar sus definiciones corresponde a etapa 4. En documentos animados se edita
la celda activa sin modificar inadvertidamente otros fotogramas; la edición temporal llega en etapa 5.

Fuera: pinceles de textura, presión/inclinación, degradados, vectores editables, filtros generales,
texto rasterizado, rotación arbitraria, tilemaps y modos de fusión distintos de normal.

## Cierre verificable

Crear una ilustración de tres capas con dibujo/formas, seleccionar y pegar una parte, transformar,
recortar, guardar/reabrir y deshacer hasta el inicio. Verificar contenido libre/vinculado, capa
bloqueada, alfa bloqueado, cancelación y recuperación durante un gesto. La imagen y los vínculos
de cada revisión deben ser comprobables, no solo su captura visual. Pruebas pendientes de ejecución.
