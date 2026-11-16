# PXA-05 · Documento `.pxa` en Braket

| | |
|---|---|
| **Estado** | Especificado; no implementado |
| **Etapa** | [2](ETAPA-02.md) |
| **Área** | Documento, navegación, apertura y contexto |
| **Depende de** | PXA-01/PXA-02; comportamiento visual en PXA-06; persistencia en PXA-07/PXA-08 |

## Problema y objetivo

`EditorDocument` representa texto o preview y su identidad actual deriva de la URL.
`DocumentStore.open` distingue esos dos casos. `FileCommands.save` trata los borradores mediante
una carpeta de scripts SQL. El receptor Finder de `AppDelegate` toma un único archivo y lo
envía como proyecto. Estos caminos no deben interpretar `.pxa` como texto, preview ni `.kzk`.

La integración debe preservar el comportamiento existente y dar a los documentos gráficos su
propia sesión, con identidad estable mientras se renombran, guardan por primera vez o recuperan.

## 1. Documento tipado y responsabilidades

| Componente existente | Responsabilidad a conservar/ampliar |
|---|---|
| `EditorDocument` | Cabecera común de pestaña y variante de contenido: texto, preview o pixel art |
| `DocumentStore` | Registro de instancias, selección, apertura/lectura por tipo y ciclo de vida |
| `FileCommands` | Comandos de usuario, decisiones de guardado/cierre y reporte de errores |
| `WorkspaceController` / `WorkspaceSession` | Contexto activo, transiciones y permisos; no bitmap ni serialización |
| `WorkspaceView` | Elegir superficie por variante; alojar el editor sin lógica de archivo |
| `SessionRestoration` | Rutas/contextos y preferencias, separado de la recuperación de contenido |
| `AppDelegate` / `Info.plist` | Enrutamiento de eventos de apertura y asociación `.pxa` |
| `FileIcons` / explorador | Icono y entrada de creación; mismas rutas de apertura que Archivo/Finder |

La sesión gráfica posee el modelo de PXA-01, historial, vista, estado de archivo y recursos del
renderer. La elección de nombres Swift queda para implementación. Separar lectura/escritura,
recuperación y presentación, con dependencias que permitan pruebas sin diálogos reales.

No usar un `NSImage` reducido como fuente editable ni decodificar el contenedor como UTF-8.
La compresión, hashes, validación y decodificación intensiva se hacen fuera del hilo de interfaz;
solo la publicación de estados y coordinación visual pertenece a ese hilo. Se publica una
instantánea íntegra, no colecciones que cambian mientras el renderer las está leyendo.

## 2. Tres identidades distintas

- **Instancia de edición:** UUID local estable desde que se abre/crea hasta cerrar. Es la identidad
  de pestaña, trabajos asíncronos y recuperación; no cambia con Guardar como ni renombrar.
- **Ubicación:** URL canónica opcional. Un borrador no tiene URL de usuario. No se inventa una
  ruta `.sql` o una ubicación temporal para simular que ya existe en el explorador.
- **Documento:** UUID interno del manifiesto. Sirve para filiación, no para deduplicar archivos
  que Finder haya copiado a otra ruta.

Una URL ya abierta se enfoca, sin crear otra instancia. Normalizar componentes y resolver enlaces
simbólicos permitidos; las rutas deben pasar los mismos controles de acceso del contexto. En un
volumen que informe identidad estable, hard links al mismo archivo se detectan como el mismo
recurso durante apertura. El reemplazo atómico posterior actualiza esa identidad de recurso sin
cambiar la instancia. Copias reales, aunque tengan el mismo documento-ID, abren por separado.

Un mismo recurso tiene un solo editor propietario en la ventana. Si se solicita desde otro
proyecto abierto, activar su contexto propietario con el flujo normal de transición, no crear
dos buffers. Si se cancela la transición, cancelar esa apertura sin cerrar el trabajo actual.

## 3. Crear documento

Puntos de entrada: **Archivo → Nueva imagen pixel art…**, menú `+` del explorador y menú contextual
de una carpeta editable. No reutilizar el diálogo que escribe un archivo de texto vacío. Se
conservan ⌘N y ⇧⌘N actuales; la entrada específica no recibe un atajo nuevo en esta etapa.

Formulario: nombre sugerido `Sin título.pxa`, ancho y alto enteros (64 × 64 por defecto), presets
8, 16, 32, 64 y 128 cuadrados más Personalizado. Fondo transparente en esta etapa. Valida límites de
PXA-01 y nombre con las reglas de archivos de Braket. No acepta `.png` como extensión editable;
un nombre sin extensión recibe `.pxa`, y una extensión diferente exige corregirla explícitamente.

Al crear:

- Nueva instancia y documento-ID, capa `Capa 1`, fotograma 1 con duración 125 ms.
- Paleta y secuencias vacías, sin bloques de píxeles, sin conversación ni propuestas.
- Revisión raíz válida, con el estado inicial completo; no una operación de dibujo ficticia.
- Capa/fotograma activos, sin selección, zoom inicial 800 % y vista centrada.
- Color de dibujo libre negro opaco; guardar selección de color no agrega entradas a la paleta.
- Desde el árbol de un proyecto editable, el `.pxa` se escribe en la carpeta elegida y se abre en
  una pestaña de la misma ventana. Sin proyecto, se crea un borrador para guardar después.

Cancelar el formulario no crea archivo ni pestaña. Crear en solo lectura
de proyecto está deshabilitado; crear desde inicio usa el contexto Archivos sueltos.

## 4. Abrir documentos

Se admite explorador, **Archivo → Abrir imagen pixel art…**, arrastrar un `.pxa` al área de
pestañas/lienzo, Finder y restauración. El diálogo permite selección múltiple y filtra `.pxa`
sin distinguir mayúsculas. ⌘O sigue abriendo proyectos. El arrastre de archivos a esta superficie
abre documentos; no importa PNG ni agrega capas. El drop del explorador conserva su función de
gestión de archivos y no se redefine para importar sprites.

El tipo declarado para macOS será `com.krabzik.pixel-art`, conforme a `public.data`, extensión
`.pxa`, nombre «Documento de pixel art de Braket», rol Editor. Se registra en `Krabzik/Info.plist`
junto a los tipos existentes, no reemplazándolos. No afirmar propiedad exclusiva de la extensión:
el manifiesto `braket.pixel-art` decide compatibilidad. Quick Look/miniaturas Finder quedan fuera.

Proceso de apertura:

1. Resolver contexto y acceso, deduplicar la solicitud por recurso y reservar posición de pestaña.
2. Mostrar carga cancelable; la vista previa opcional debe rotularse como provisional.
3. Validar y decodificar el archivo según PXA-01 dentro de presupuestos.
4. Publicar sesión completa únicamente si la instancia/contexto/solicitud siguen vigentes.
5. Reemplazar el estado de carga por lienzo o por error con Reintentar/Cerrar; no fabricar documento vacío.

Cerrar una pestaña en carga invalida su solicitud. Su resultado tardío no reaparece. Aperturas
múltiples conservan orden de solicitud, no de finalización; seleccionar inicialmente la primera
y no robar foco cuando terminen las demás. Cada error pertenece a su pestaña, con resumen único
si el lote falla por completo. Una apertura válida puede completarse aunque otra falle.

## 5. Finder y contexto sin proyecto

El receptor recorre todas las URLs del evento y distingue `.kzk`/`.krabzik` de `.pxa`. Mantiene
una cola si aún no existe el controlador. Una solicitud explícita tiene prioridad sobre la
restauración automática, sin borrar recuperaciones pendientes. Los lotes mixtos se tramitan en
orden: abrir un proyecto cambia el destino de los `.pxa` que le siguen si la transición se acepta.
Si esa apertura de proyecto falla/se cancela, los documentos asociados al tramo se dejan pendientes
y se informa; no se anexan silenciosamente al proyecto anterior. Otro proyecto explícito posterior
puede iniciar un tramo nuevo. No se crean ventanas o procesos extra de Braket.

Con proyecto activo, el archivo explícito abre en sus pestañas. Si está fuera de las carpetas
montadas, se muestra como **Archivo externo** con ruta en el tooltip; no se monta su directorio,
no se agrega a scripts SQL ni se modifica `.kzk`. Un proyecto no confiable no permite abrir rutas
externas a través de sus referencias, restauración o arrastres al contexto. El flujo explícito
puede ofrecer **Abrir en Archivos sueltos**; no marca el proyecto como confiable.

Sin proyecto activo, reutilizar/crear un único contexto local **Archivos sueltos** en la misma
ventana. Muestra una entrada de documentos en el rail y una lista de `.pxa` abiertos en lugar
del árbol de carpetas. No crea `.kzk`, procesos, automatizaciones, conexiones ni raíces de acceso
implícitas. El documento seleccionado directamente por el usuario puede editarse si el formato
y los permisos lo permiten. No se habilita Codex en esta etapa.

El contexto puede convivir con los proyectos abiertos y se selecciona por el mismo rail. Cambiar
de contexto usa las reglas de transición/guardado actuales detalladas en PXA-07; no se promete
retener borradores en memoria de contextos inactivos. Cerrar su último documento vuelve al inicio
si no hay otro contexto activo, sin cerrar ni eliminar proyectos conservados en el rail.
El tamaño de ventana se decide por si existe una superficie de documentos, no solo por `workspaceURL`.

## 6. Pestañas y comandos por capacidades

Nombre y punto de cambios pendientes, icono `.pxa`, tooltip con ubicación o «Borrador sin guardar».
Un estado solo lectura/conflicto tiene indicador separado del punto de cambios. El punto sigue
las reglas de PXA-02 y no se enciende solo por zoom o elegir otro fotograma.

Pestañas de código, SQL, Markdown, imágenes y `.pxa` siguen coexistiendo. Al cambiar entre ellas
se conserva la sesión gráfica y su vista. Al renombrar/mover dentro de Braket se actualizan URL,
explorador y recuperación sin recrear bitmap/historial; conservar `.pxa` en renombrado normal.
Cambiar a otra extensión no convierte el formato y requiere un aviso explícito.

Guardar/cerrar/reubicar se resuelve por instancia y capacidades del documento. Los controles SQL,
buscar texto o ejecutar consultas no se habilitan para `.pxa` ni se usa su `SQLExecution` como
identidad indirecta. En solo lectura no se habilitan operaciones artísticas ni historial mutable.

## 7. Estados y transiciones visibles

Estado documental base: cargando, error de apertura, borrador, listo, solo lectura o cerrando.
Guardando, recuperación pendiente/fallida y conflicto externo son condiciones adicionales;
pueden coexistir con un documento listo. Evitar un enum que haga imposible «editado mientras guarda».

En solo lectura se permite pan, zoom, inspección de paleta y fotogramas e historia como preview,
sin mover el cursor histórico persistente. La causa se muestra: formato futuro, proyecto no
confiable o acceso al archivo. Guardar copia byte a byte de un formato futuro se distingue de
reserializar; no intentar convertirlo con el escritor 1.0.

El renderer debe mostrar la composición real del estado, incluyendo alfa, opacidad, paleta
vinculada y capas ocultas, sin depender de `preview.png`. El validador maneja el historial completo
aunque las herramientas que crearon sus revisiones todavía no estén disponibles en la interfaz.

## Criterios de aceptación y pruebas futuras

- Crear desde cada entrada genera el mismo borrador válido; cancelar no escribe archivos.
- Primer guardado no pregunta por «Carpeta de scripts SQL» ni incorpora `.pxa` a `workspace.scripts`.
- Un `.pxa` mayor de 5 MB abre por su lector específico, dentro de los límites del formato.
- Abrir dos veces el mismo recurso enfoca una instancia; una copia con igual documento-ID abre otra.
- Renombrar/Guardar como no pierde selección, historia ni trabajos dirigidos a la instancia.
- Cancelar carga, cambiar contexto o cerrar durante decodificación impide publicaciones tardías.
- Finder abre uno o varios `.pxa`, con app iniciada o cerrada, en una sola ventana/instancia.
- Sin `.kzk` se puede crear, abrir y guardar; no se crea un proyecto en disco ni se escanea una carpeta.
- Las rutas de solo lectura/confianza siguen vigentes y los formatos defectuosos nunca abren como vacíos.
- Texto, Markdown, SQL, automatizaciones y navegación de proyectos mantienen sus rutas existentes.

## Riesgos

La identidad ligada a URL y la dependencia de SQL del cierre actual pueden producir pestañas
duplicadas o cierres incorrectos si se parchean solo por extensión. El contexto sin proyecto debe
ser un host mínimo; no ampliar esta etapa a un explorador general o a otra política de confianza.
