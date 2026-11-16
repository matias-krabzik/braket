# PXA-14 · Reproducción y onion skin

| | |
|---|---|
| **Estado / etapa** | Especificado, no implementado · [5](ETAPA-05.md) |
| **Dependencias** | PXA-06/13 y renderer PXA-01 |

## Reloj y recorrido

Reproducir usa reloj monotónico y límites acumulados de duración. No avanzar una columna cada
tick ni usar tiempo de pared. Si un render se retrasa, mostrar el fotograma que corresponde al
tiempo actual; no alargar toda la animación. No modificar los tiempos almacenados para ocultar
un rendimiento insuficiente. Una pausa conserva posición temporal; Detener vuelve al primer
fotograma del recorrido y termina el reloj.

Recorrido: forward A,B,C; reverse C,B,A; pingPong A,B,C,B, repitiendo sin duplicar extremos.
Para uno es A; para dos es A,B. Sin loop, pingPong termina regresando a A una vez (A,B,C,B,A)
y luego se detiene. Cada visita usa la duración del fotograma visitado. Loop normal regresa al
principio después de consumir la duración final. El spec de exportación usa exactamente esta
expansión y no inventa otro significado de pingPong.

Con «Todos los fotogramas» sin secuencia, usar orden global hacia adelante y loop activado por
defecto; el toggle loop es estado auxiliar de reproducción, guardado en `editorState`. Una
secuencia usa su propio loop/dirección persistidos. Exportar muestra cuál de esos recorridos toma.

Reproducir desde celda activa comienza en su primera visita dentro del recorrido; si no pertenece,
comienza al inicio. «Reproducir desde inicio» lo hace explícito. UI muestra playhead de reproducción
separado de la celda de edición; pausar selecciona el fotograma mostrado para continuar trabajando.
Playhead/timer no forman revisiones; solo el fotograma activo final se conserva como vista auxiliar.

## Interacción y ciclo de vida

Space alterna reproducir/pausar cuando la matriz tiene foco y no hay texto en edición; en lienzo
Space-arrastre sigue siendo mano. Botones tienen nombres inequívocos. Cambiar de pestaña/contexto,
minimizar ventana, entrar a revisión histórica o perder sesión pausa la reproducción; volver no
reanuda solo. Antes de una edición artística, detener/pausar sobre el fotograma visible y congelar
su ID. Una selección flotante pendiente se resuelve antes de reproducir.

No hay timer activo con una imagen estática en reposo ni para Codex. Cachear render actual y
vecinos con presupuesto; precargar un número acotado, no todos los fotogramas. Reducir precarga
ante presión de memoria. No reducir resolución ni cambiar colores del documento silenciosamente.

## Onion skin

Guía visual fuera de la imagen artística: hasta 3 fotogramas anteriores y 3 siguientes, por defecto
1/1, opacidad máxima 30 %. Vecinos según lista activa (timeline o secuencia) sin envolver extremos,
independiente de la dirección de reproducción. Un ID se muestra una vez. Vecino a distancia d
usa opacidad máxima/d; dibujar lejanos antes de cercanos, anteriores antes de siguientes.

Dos modos: color original o tinta (anteriores rojo, siguientes azul, configurables localmente).
Tinta usa el alfa de composición como cobertura y sustituye RGB de guía; no altera bloques ni
paleta. Renderizar guías debajo del fotograma actual. Alcance de guía: capa activa por defecto
o composición visible elegida explícitamente. Ignorar capas ocultas en modo composición.

Ocultar guías durante playback, exportación, cuentagotas «Color visible», copiado combinado y
renders que se envíen como imagen artística a Codex. Si el usuario solicita ver guías en contexto
para IA, enviar un adjunto claramente separado/rotulado, nunca usarlo como fuente de píxeles.

Preferencias de onion skin (modo, alcance, vecinos, intensidad) forman parte de `editorState`;
colores de tinta por tema son preferencias locales. Cambiarlas no agrega revisión artística.

## Aceptación, pruebas y riesgos

- Reloj simulado: límites exactos, pausas, reanudación, retrasos y saltos; ningún drift acumulativo.
- Recorridos de 1/2/3/8 fotogramas en ambas direcciones y pingPong con/sin loop.
- No hay escritura ni historia al reproducir y cero reproducción automática después de reabrir.
- Guías visibles coinciden con vecinos y alfa; no aparecen en export, picker o imagen fuente de IA.
- Cambiar pestaña/cerrar durante reproducción libera el reloj y no publica un render en otra instancia.
- Medir frames perdidos y memoria en PXA-20; no prometer fluidez de 120 FPS con cualquier documento.

La duración mínima almacenada de 1 ms no implica que el monitor pueda presentar cada fotograma.
El reloj preserva el tiempo lógico y la UI informa cuando la reproducción omite presentaciones.
