# Etapa 5 · Animación y línea de tiempo

| | |
|---|---|
| **Estado / fecha** | Especificada; no implementada ni validada · 2026-11-14 |
| **Depende de** | Etapas 1–4 |
| **Autorización actual** | Solo documentación |

## Objetivo y specs

Crear animaciones por fotogramas conservando el mismo modelo de capas y paleta.

| Spec | Contrato |
|---|---|
| [PXA-13](PXA-13-fotogramas-y-secuencias.md) | Matriz editable, selección temporal, duraciones y secuencias |
| [PXA-14](PXA-14-reproduccion-y-onion-skin.md) | Reloj, reproducción, onion skin y previsualización |

## Secuencia, alcance y cierre

Primero acciones de fotogramas/celdas y secuencias; luego reproducción y guías visuales. Sin
interpolación, huesos, sonido, celdas enlazadas, animación de paleta o generación automática de
fotogramas. Un documento estático sigue siendo una animación válida de un fotograma.

Hito: animación de 8 fotogramas, dos secuencias y tiempos variables; duplicar un fotograma,
editarlo independientemente, previsualizar onion skin, reproducir/pausar, guardar/reabrir y
deshacer cambios estructurales. Medir continuidad temporal y reposo sin timers sobrantes.
Exportar animación se completa en etapa 6; las verificaciones todavía no se ejecutaron.
