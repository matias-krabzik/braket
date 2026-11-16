# Mapa de alcance y cierre del editor `.pxa`

**Estado: 8 etapas documentadas, 21 specs; implementación y comprobaciones pendientes.**
Fecha: 2026-11-14. Este mapa evita dar por cubierta una capacidad solo porque aparece en el mockup.

## Cobertura del alcance acordado

| Capacidad | Contrato principal | Se entrega en |
|---|---|---|
| Archivo autocontenido y versionado | [PXA-01](PXA-01-formato-y-persistencia.md) | 2, tras validar contrato de 1 |
| Historia persistente y ramas | [PXA-02](PXA-02-historial-persistente.md) | 2 |
| Color libre y vinculado | [PXA-03](PXA-03-color-y-paletas.md) | Modelo 2; herramientas 3–4 |
| Transacciones comunes manual/IA | [PXA-04](PXA-04-operaciones-y-propuestas.md) | Base 2–3; IA 7 |
| Apertura, Finder, pestañas y archivo suelto | [PXA-05](PXA-05-integracion-documentos.md) | 2 |
| UI del mockup, zoom y navegación | [PXA-06](PXA-06-interfaz-editor.md) | 2, controles progresivos 3–7 |
| Guardado, copias y conflictos | [PXA-07](PXA-07-guardado-y-cierre.md) | 2 |
| Recuperación y restauración | [PXA-08](PXA-08-recuperacion-y-sesion.md) | 2 |
| Lápiz, borrador, picker, relleno, formas y simetría | [PXA-09](PXA-09-dibujo-y-herramientas.md) | 3 |
| Selección, portapapeles, giro, escala y recorte | [PXA-10](PXA-10-seleccion-y-transformaciones.md) | 3; pegado PNG externo 6 |
| Capas, orden, opacidad, bloqueos y combinación | [PXA-11](PXA-11-edicion-de-capas.md) | 3 |
| Paleta editable, extracción, reducción y reemplazo | [PXA-12](PXA-12-interfaz-paletas-y-reduccion.md) | 4 |
| Fotogramas, duraciones y secuencias | [PXA-13](PXA-13-fotogramas-y-secuencias.md) | 5 |
| Reproducción y onion skin | [PXA-14](PXA-14-reproduccion-y-onion-skin.md) | 5 |
| PNG y hoja de sprites de entrada | [PXA-15](PXA-15-importacion-imagenes.md) | 6 |
| PNG, secuencia PNG, GIF y spritesheet/JSON | [PXA-16](PXA-16-exportacion-y-metadatos.md) | 6 |
| Cuenta y contexto visual de Codex | [PXA-17](PXA-17-conexion-y-contexto-codex.md) | 7, precedido por prueba de 1 |
| Operaciones editables desde prompts | [PXA-18](PXA-18-herramientas-graficas-codex.md) | 7 |
| Paletas con IA, comparación, ajustes y aplicación | [PXA-19](PXA-19-panel-codex-y-calidad.md) | 7A |
| Creación/retoque artístico localizado con IA | [PXA-19](PXA-19-panel-codex-y-calidad.md) | 7B con evaluación propia |
| Fluidez, memoria, atajos y accesibilidad | [PXA-20](PXA-20-rendimiento-y-accesibilidad.md) | Verificar en cada etapa; cierre 8 |
| Pruebas, Release e instalación autorizada | [PXA-21](PXA-21-validacion-y-entrega.md) | Cada entrega de app; cierre integral 8 |

## Orden y dependencias

Secuencia principal: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8. La prueba pequeña de contexto/herramientas
Codex definida en 1 precede a comprometer la integración, aunque el panel productivo llegue en 7.
Los presupuestos de 8 se aplican desde 2, no después de haber construido todo. Las pruebas de
funciones se agregan con cada función; 8 es integración/evidencia, no comienzo de testing.

La estructura de capas/fotogramas/colores se define desde 1. No implementar primero un bitmap
plano y migrar improvisadamente a capas/animación en 5. Los controles todavía no disponibles se
identifican como tales; no aparecen botones que simulan ejecutar una función futura.

## Invariantes transversales

1. El estado artístico publicado siempre es íntegro y cumple formato/límites.
2. Cada edición aceptada es reversible; historia usa datos guardados, no repite prompts.
3. Guardar/Exportar/Recuperar tienen destinos y efectos distintos.
4. Alcance y bloqueos se validan por diferencias reales, no por texto de la propuesta.
5. Píxeles libres y vinculados mantienen su identidad hasta conversión explícita.
6. Toda tarea asíncrona conserva instancia/base; un resultado tardío no muta otro documento.
7. Apertura/reapertura no ejecuta procesos, conexión IA ni prompts.
8. Un archivo inválido o una función futura no se «resuelve» aplanando o perdiendo datos.
9. El mockup es referencia, no evidencia de implementación.
10. Una entrega local no termina hasta verificar `/Applications/Braket.app` y una sola instancia.

## Decisiones de alcance aplazadas expresamente

No forman parte de la primera entrega: tilemaps, capas agrupadas, celdas enlazadas, paletas animadas,
blend modes adicionales, pinceles de textura/presión, filtros, rotación arbitraria, dithering,
importación PSD/Aseprite/GIF animado, packing de atlas, exportación de video, colaboración en vivo,
tareas autónomas/programadas y generación de imágenes mediante un proveedor adicional.

No son pendientes ocultos del alcance aceptado: cada spec relevante los delimita. La generación
creativa por Codex se realiza con operaciones editables y se evalúa separadamente; no equivale
a incorporar otro modelo de imágenes ni a prometer animaciones largas consistentes.

## Pendientes técnicos reales antes de implementar/publicar

- Elegir librerías/backends compatibles con la app, con licencias/dependencias verificadas al integrar.
- Formalizar los contratos escritos como tipos/esquemas ejecutables y fixtures, sin cambiar semántica.
- Validar transporte visual/herramientas/aislamiento con versión real de Codex, no solo con simulación.
- Ejecutar corpus de rendimiento y calidad; valores propuestos todavía no medidos.
- Implementar y verificar cada criterio de aceptación y el flujo de instalación.

Estas decisiones de tecnología y comprobación no se presentan como aprobadas por escribir un spec.
Si una prueba obliga a cambiar un contrato de producto, registrar la revisión y afectados antes
de implementar otra semántica. Ningún estado del índice significa «listo» sin evidencia.

## Ajustes de coherencia incorporados al completar las etapas

- La reducción de colores pendiente en PXA-03 se concreta en PXA-12.
- La UI definitiva del historial se concreta en PXA-06, sin panel permanente adicional.
- El índice de historia se pagina dentro del formato 1.0 aún no publicado para que 100.000 revisiones
  no exijan un único objeto JSON desproporcionado; PXA-01/PXA-02 son la autoridad actualizada.
- El mockup sigue representando el producto final; PXA-06 describe qué está disponible en etapa 2.
- El contrato de pipeline de firma/Release se basa en los scripts vigentes, no en referencias antiguas.
