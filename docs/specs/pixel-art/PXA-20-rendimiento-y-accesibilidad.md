# PXA-20 · Rendimiento, memoria y accesibilidad

| | |
|---|---|
| **Estado / etapa** | Especificado, no medido ni implementado · [8](ETAPA-08.md) |
| **Dependencias** | Todos los contratos funcionales; aplica durante etapas 2–7 |

## Objetivo y método

Mantener herramientas precisas y UI reactiva con documentos representativos y límites conocidos.
Los objetivos siguientes son presupuestos iniciales a comprobar, no resultados ya obtenidos.
Medir Release sin debugger, registrar Mac/CPU/RAM, macOS, escala, monitor y revisión del código.
Tomar 30 muestras tras calentamiento para acciones interactivas, reportar mediana/p95 y pico de
memoria. Separar tiempo local del tiempo de inferencia de Codex y del acceso a disco.

Baseline de producto propuesta: Apple Silicon M1 con 8 GB, monitor 60 Hz, sistema soportado por
la app. Probar también Intel si la entrega mantiene binario universal; no afirmar métricas Intel
por medir solo ARM. Si el equipo no está disponible, registrar la cobertura faltante y equipo real;
el estado de validación debe reflejar esa limitación, no inventar equivalencia.

## Corpus reproducible

| ID | Contenido |
|---|---|
| PERF-A | 64 × 64, 8 capas, 32 fotogramas, paleta de 16, 1.000 revisiones mixtas |
| PERF-B | 512 × 512, 16 capas, 64 fotogramas, 5 % de bloques ocupados, 256 entradas y píxeles libres |
| PERF-C | 4.096 × 4.096, 1 capa/fotograma denso, RGBA y vínculos alternados |
| PERF-D | 128 × 128, 8 capas, 1.024 fotogramas dispersos con tiempos variables |
| PERF-E | 32 × 32, 4 capas, 100.000 revisiones pequeñas compartidas, varias ramas |
| PERF-F | Fixture que excede un límite, y variante comprimida cuyo presupuesto descomprimido se excede |

Generar determinísticamente al implementar, con semilla registrada, sin imágenes personales.
Cada fixture válido debe respetar todos los topes simultáneos de PXA-01; si un generador excede
objetos/bytes, corregirlo, no invalidar un límite para completar la tabla. PERF-E reutiliza un
conjunto pequeño de estados para cumplir el máximo de objetos junto con sus revisiones.

## Presupuestos iniciales

| Escenario | Objetivo a medir |
|---|---|
| Pan/zoom y feedback de trazo en PERF-A/B | Trabajo de frame UI p95 ≤16,7 ms; evitar bloqueos individuales >100 ms |
| Confirmar trazo hasta 10.000 posiciones en A/B | p95 ≤50 ms para publicar; serialización posterior fuera del hilo UI |
| Activar celda de frame ya cacheado | p95 ≤50 ms |
| Cancelar relleno/importación/exportación/carga larga | Reconocer cancelación en UI ≤100 ms; detener trabajo local en ≤500 ms en un punto seguro |
| Historial A/B | Mostrar listado/navegar a estado cacheado p95 ≤100 ms, sin recorrer todas las revisiones |
| Reproducción A a 60 Hz / B a 30 Hz durante 30 s | <1 % de presentaciones esperadas omitidas y sin drift del reloj |
| Reposo por 60 s, sin reproducción/inferencia/trabajo | Ningún timer de renderer/playback propio activo; CPU adicional media objetivo <1 % de un núcleo |
| Memoria adicional A/B/D/E tras calentamiento | Objetivo ≤512 MiB sobre el mismo workspace vacío |
| C y operaciones grandes | Presupuesto explícito; objetivo pico adicional ≤1 GiB, cancelable, sin crecimiento sin límite |

No prometer máximo tiempo total fijo para guardar 1 GiB en cualquier disco. Registrar tiempos de
abrir/guardar/recuperar/exportar por fixture y bytes; requerir UI disponible y progreso. En pruebas
regresivas del mismo equipo, investigar empeoramientos >20 % en p95/bytes retenidos con varias
ejecuciones antes de cambiar el presupuesto. Un objetivo que no se alcanza requiere corrección o
decisión de producto documentada, nunca subir silenciosamente el umbral del test.

## Memoria y trabajos

Cachés con presupuesto explícito y expulsión: propuesta inicial 128 MiB de bloques decodificados
y 96 MiB de renders/miniaturas combinados. Compartir objetos inmutables entre revisiones y propuestas.
La operación activa puede reservar memoria adicional preflight, contabilizada contra el pico de
trabajo, no esconderla en una caché sin límite. Ante presión de memoria, expulsar renders/precarga
antes de rechazar una operación; nunca borrar historia persistida ni píxeles.

Leer/hash/descomprimir/serializar en streaming. La paleta y los descriptores pueden cargarse por
demanda, validando referencias; no decodificar toda la animación para seleccionar un frame. Render
por regiones dañadas, índices de uso de paleta actualizados al cambiar celdas; un recoloreado no
recorre el historial artístico para cambiar sus estados pasados.

Virtualizar capas, frames, muestras numerosas y revisiones; no reconstruir todo SwiftUI por cada
movimiento de cursor. Una cola acotada por documento y presupuesto global impiden que abrir varias
pestañas multiplique trabajo hasta agotar RAM. Si falta presupuesto, aplazar/cancelar con motivo,
sin degradar resolución o historia. Cerrar pestaña libera observadores, callbacks, temporales y caches.

## Accesibilidad y ergonomía

Completar recorrido por teclado para crear/abrir, herramientas, selección de capa/frame/color,
historial, prompts, aplicar/descartar, guardar/exportar y resolver recuperación. Campos de texto
mantienen IME y undo propios. Atajos no capturan entrada cuando hay modales/pickers o foco en texto.
Todos los controles tienen nombre/estado/ayuda y foco visible; ninguna acción solo por hover.

VoiceOver anuncia capa/frame y acción; el lienzo tiene resumen y navegación por coordenadas mediante
inspector, sin exponer millones de píxeles accesibles. Selección/capas/errores se distinguen por texto
o forma además del color. Probar alto contraste, reducir movimiento, tema claro/oscuro y tamaños
de PXA-06. No animar el checker ni usar parpadeos para señalar errores; respetar reducir movimiento
en transiciones decorativas sin impedir reproducción solicitada de la animación.

Ampliar controles no cambia coordenadas del bitmap. El inspector de coordenadas permite leer
RGBA/ID en una posición introducida y mover el cursor de inspección por teclado; edición artística
sigue su herramienta/selección explícitas. Las ayudas y mensajes describen acciones del usuario,
sin exponer hashes/JSON como pasos de un flujo cotidiano.

## Aceptación, pruebas y riesgos

- Informe de corpus/métricas con valores y limitaciones reales, pruebas de fugas tras 20 ciclos abrir/cerrar.
- Presión de memoria durante preview, guardado y Codex mantiene estados y cancela sin corrupción.
- Perfil de reposo y reproducción demuestra ausencia de timers sobrantes y drift.
- Revisión visual/teclado/VoiceOver en tamaños mínimos, con procesos globales visibles y panel Codex compacto.
- Carga excepcional fuera de presupuesto falla de manera recuperable; guardar trabajo previo sigue disponible.

El máximo formal del archivo no es una promesa de rendimiento instantáneo. El producto debe explicar
limitaciones reales y conservar datos, en lugar de cambiar el formato para ocultar falta de optimización.
