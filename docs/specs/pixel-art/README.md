# Editor de pixel art · Especificaciones

| | |
|---|---|
| **Estado** | Etapa 1: motor implementado (ver [`docs/pixel-art-engine.md`](../../pixel-art-engine.md)); falta la prueba técnica con Codex. Etapas 2 en adelante: solo especificadas |
| **Fecha** | 2026-11-14 |
| **Área** | Editor `.pxa` completo: modelo, UI, dibujo, animación, intercambio, Codex y entrega |
| **Referencia de producto** | Mockup acordado: herramientas junto al lienzo, capas y fotogramas abajo, paleta y Codex a la derecha |
| **Autorización actual** | Etapa 1 autorizada e implementada el 2026-11-14. Las demás etapas siguen siendo solo documentación |

## Etapas documentadas

| Etapa | Estado | Entrada |
|---|---|---|
| 1 · Formato, historial, color y operaciones | Motor implementado y probado; falta la validación contra Codex | [Etapa 1 · PXA-01 a PXA-04](ETAPA-01.md) |
| 2 · Integración en Braket, UI y persistencia | Especificada; implementación y validación pendientes | [Plan y specs de etapa 2](ETAPA-02.md) |
| 3 · Dibujo, selección y capas | Especificada; implementación y validación pendientes | [Etapa 3 · PXA-09 a PXA-11](ETAPA-03.md) |
| 4 · Paletas y conversiones | Especificada; implementación y validación pendientes | [Etapa 4 · PXA-12](ETAPA-04.md) |
| 5 · Animación y línea de tiempo | Especificada; implementación y validación pendientes | [Etapa 5 · PXA-13 y PXA-14](ETAPA-05.md) |
| 6 · Importación y exportación | Especificada; implementación y validación pendientes | [Etapa 6 · PXA-15 y PXA-16](ETAPA-06.md) |
| 7 · Codex y propuestas visuales | Especificada; implementación y validación pendientes | [Etapa 7 · PXA-17 a PXA-19](ETAPA-07.md) |
| 8 · Pulido, validación y entrega | Especificada; implementación y validación pendientes | [Etapa 8 · PXA-20 y PXA-21](ETAPA-08.md) |

El [mapa de alcance](MAPA-DE-ALCANCE.md) relaciona las capacidades con los **21 specs**, su orden,
invariantes y límites de la primera entrega. Todas las etapas tienen objetivos, contratos y
criterios de aceptación; ninguna está marcada como implementada por estar documentada.
El [estado de las etapas](ESTADO-IMPLEMENTACION.md) permite registrar por separado las revisiones
de Claude y el avance técnico.

Las siguientes secciones conservan las decisiones iniciales de etapa 1; los índices de cada
etapa son la entrada a sus contratos detallados y pruebas futuras.

## Objetivo

Cerrar las decisiones que condicionan al editor antes de programarlo. Un `.pxa` debe permitir
continuar un trabajo en otra sesión o computadora, con sus capas, animación, colores, historial
y estado de edición. La edición manual y las propuestas de Codex usan el mismo modelo de cambios.

Estos documentos son contratos para la primera versión del formato. Parte del núcleo de etapa 1
ya existe; los criterios y pruebas pendientes se distinguen de los resultados verificados en el
archivo de estado.

## Especificaciones de etapa 1

| Spec | Contrato | Dependencias |
|---|---|---|
| [PXA-01](PXA-01-formato-y-persistencia.md) | Contenedor, modelo, validación, guardado y recuperación | Convenciones de color de PXA-03 |
| [PXA-02](PXA-02-historial-persistente.md) | Revisiones, deshacer/rehacer, ramas y conservación | Objetos y estados de PXA-01 |
| [PXA-03](PXA-03-color-y-paletas.md) | Píxeles libres/vinculados, conversiones y reemplazos | Identidad y transacciones de PXA-01/PXA-02 |
| [PXA-04](PXA-04-operaciones-y-propuestas.md) | Operaciones comunes y contrato de propuestas de Codex | PXA-01 a PXA-03 |

Las dependencias describen un contrato conjunto, no un orden lineal de programación. PXA-01
define el almacenamiento; PXA-03 es la autoridad sobre el significado de los colores;
PXA-02 sobre historia; PXA-04 sobre alcance, concurrencia y aplicación de propuestas.

## Decisiones de producto

1. `.pxa` es un único archivo ZIP autocontenido, con metadatos JSON y bloques de píxeles propios.
   No depende de rutas externas, un proyecto `.kzk` ni una sesión de Codex para abrirse.
2. El formato inicial es **1.0**. La versión de Braket y la versión del formato son independientes.
3. Un documento puede mezclar píxeles libres y vinculados en la misma capa y el mismo fotograma.
   No hay una conversión implícita de todo el documento al elegir un color de la paleta.
4. Una entrada de paleta tiene identidad estable. Reordenarla no cambia qué píxeles la utilizan.
5. El historial es persistente y conserva ramas. Editar después de deshacer no destruye el futuro anterior.
6. Guardar, autoguardar, exportar y aplicar Codex son acciones diferentes. Solo una edición aceptada
   crea una revisión artística; exportar no modifica los píxeles.
7. Codex prepara una propuesta aislada sobre una versión concreta. Aplicarla es una sola acción
   reversible y no exige guardar primero el documento de trabajo.
8. No se recorta historia para cumplir límites de tamaño sin una acción explícita del usuario.

## Correspondencia con la interfaz acordada

| Zona | Estado que utiliza |
|---|---|
| Pestaña `.pxa` | Nombre del archivo, cambios pendientes y conflicto externo |
| Barra de herramientas | Herramienta, tamaño, color de dibujo libre/vinculado, simetría |
| Lienzo | Estado actual o propuesta; zoom, desplazamiento, selección y cuadrícula |
| Matriz inferior | Capas ordenadas, fotogramas ordenados, contenido por intersección |
| Paleta derecha | Entradas ordenadas, entrada activa, nombre, RGBA y estado vinculado |
| Panel Codex | Conversación, alcance congelado por pedido y propuesta pendiente |
| Historial | Lista accesible desde Edición/Historial; revisión actual y acceso a otras ramas |

No se agrega un panel permanente de historial al mockup. Su inspector transitorio se define
en [PXA-06](PXA-06-interfaz-editor.md); el acceso a ramas conservadas es requisito funcional.

## Base actual y puntos de integración futuros

- `Krabzik/Models/EditorDocument.swift`: hoy representa texto o una imagen de vista previa.
  `.pxa` necesita una variante de documento propia; no debe atravesar el decodificador UTF-8
  ni heredar el límite de 5 MB de texto.
- `Krabzik/Services/DocumentStore.swift`: apertura, guardado, cambios externos y pestañas.
  Conservar esas responsabilidades, incorporando persistencia específica para pixel art.
- `Krabzik/Views/WorkspaceView.swift`: contiene la distribución y las pestañas que se conservarán.
- `Krabzik/Services/AgentContext.swift`: el contexto actual no describe documentos gráficos.
- `Krabzik/Services/AgentBridge.swift`: el envío existente solicita guardar archivos modificados;
  el flujo `.pxa` usará una instantánea explícita del estado en memoria.
- `Krabzik/Services/AgentController.swift`: existe transporte y registro de una herramienta de contexto.
  Esto no demuestra todavía el funcionamiento de herramientas gráficas ni entradas visuales.

Las referencias son por tipo y responsabilidad, verificadas el 2026-11-14. No fijan nombres
de tipos nuevos ni obligan a extender un controlador ya grande.

## Fuera del alcance documental inicial de la etapa 1

La definición inicial de esta etapa no incluía implementar el lector/escritor, la UI funcional,
el motor de dibujo, la integración efectiva de Codex, esquemas ejecutables, fixtures binarios,
benchmarks ni compilación. Parte del núcleo se implementó después; su verificación se registra
en el archivo de estado. El spec no impone una biblioteca ZIP, un backend gráfico o un modelo de IA.

El formato 1.0 no incluye tilemaps, grupos de capas, celdas enlazadas entre fotogramas, modos
de fusión adicionales a normal, paletas animadas ni opacidad parcial del pincel vinculado.
La deduplicación interna de datos no crea enlaces de edición entre celdas.

## Cierre documental y puerta de implementación

El cierre documental exige que cada decisión tenga reglas, errores y ejemplos verificables;
que las referencias cruzadas sean consistentes; y que el índice distinga diseño de implementación.

Antes de comprometer el formato a archivos de usuarios, la implementación debe validar:

- Ida y vuelta de un documento mixto con capas, fotogramas y ramas de historial.
- Lectura acotada y guardado atómico con los límites de PXA-01.
- Costo real de bloques de 32 × 32 y del historial en un corpus representativo.
- Prueba de Codex: entregar imagen y estructura, recibir una propuesta de paleta y una edición
  localizada, y rechazar un intento fuera del alcance. No iniciar esa prueba en esta etapa documental.

Los límites son decisiones iniciales de producto, no promesas de rendimiento medidas. Si la
prueba obliga a cambiarlos, actualizar el contrato antes de publicar el primer escritor 1.0.

## Entrega futura

Cada entrega que modifique la app debe seguir `AGENTS.md`: Release verificada, respaldo de la
instalada, instalación en `/Applications/Braket.app` y comprobación de una sola instancia.
La presente entrega solo contiene documentación y no requiere reinstalar Braket.
