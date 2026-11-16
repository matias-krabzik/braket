# PXA-06 · Interfaz del editor de pixel art

| | |
|---|---|
| **Estado** | Especificado; no implementado |
| **Etapa** | [2](ETAPA-02.md) |
| **Área** | Layout, renderer, interacción de navegación y accesibilidad |
| **Depende de** | PXA-05 para sesión; PXA-01/PXA-03 para render y estado |

## Objetivo

Integrar el editor con el lenguaje visual de Braket y el mockup acordado. El lienzo es la zona
principal; las herramientas, paleta, capas y Codex tienen posiciones estables. La interfaz usa
los temas, escala de UI, controles nativos y separadores actuales, sin introducir un tema paralelo.

El mockup muestra el producto final. La etapa 2 construye su estructura y las funciones enumeradas
en ETAPA-02; no anuncia como operativos el dibujo, exportación o envío a Codex.
Referencia portable: [mockup acordado](assets/editor-pixel-art-mockup.png).

## 1. Jerarquía de la superficie

| Zona | Ubicación y comportamiento |
|---|---|
| Barra de título/rails | Los de Braket; acciones de proyecto siguen perteneciendo al proyecto |
| Explorador | Columna actual; se puede plegar sin cerrar documentos |
| Pestañas | Compartidas con otros archivos, encima del área específica del documento |
| Ruta/avisos | Breadcrumb y banners de solo lectura/conflicto; afectan al documento activo |
| Barra contextual | Herramienta, tamaño, color/vínculo, simetría, deshacer/rehacer y accesos a paneles |
| Herramientas | Columna estrecha junto al borde izquierdo del lienzo, dentro del editor |
| Lienzo | Centro, fondo de trabajo, regla/cuadrícula y controles de zoom |
| Matriz inferior | Capas como filas y fotogramas como columnas; debajo del lienzo |
| Inspector derecho | Paleta arriba; panel Codex plegable debajo |
| Estado inferior | Dimensiones, color, fotograma actual, posición del puntero y estado de guardado |

El inspector empieza debajo de la fila de pestañas y se extiende hasta el estado inferior. La
matriz inferior ocupa solo la columna de lienzo, no el ancho de Codex o del explorador. Los
controles de la matriz no cambian el estado del panel global de procesos/SQL.

## 2. Dimensiones y adaptación

Medidas iniciales en puntos a escala de interfaz 100 %, no píxeles del bitmap. Respetar la escala
de Braket y el espacio disponible; los valores son objetivos de diseño a verificar, no mediciones.

| Elemento | Medida inicial | Rango/condición |
|---|---|---|
| Explorador | Ancho existente recordado; 270 por defecto | Mantener rango actual 230–420 |
| Herramientas | 48 de ancho | Un control por fila; overflow desplazable si hace falta |
| Barra contextual | 40 de alto | Acciones secundarias van a menú si no caben |
| Inspector | 340 de ancho | 280–480; Codex abierto necesita al menos 320 |
| Matriz inferior | 180 de alto | 112–320, sin quitar al lienzo su mínimo visible |
| Lienzo útil | Al menos 320 × 160 | Excluye herramientas, barras y matriz |
| Columna de lienzo | Al menos 420 de ancho | Incluye herramientas y controles |
| Paleta en inspector dividido | 180–240 de alto | Divisor ajustable; Codex necesita al menos 240 |

Adaptar por medidas del área real después de aplicar la escala, no por un modelo de pantalla:

1. Respetar paneles elegidos mientras caben. Si falta ancho, plegar temporalmente el explorador.
2. Si aún no caben lienzo e inspector, mostrar el inspector como cajón derecho superpuesto,
   abierto solo por su botón. No reducir el bitmap con suavizado para hacer sitio.
3. Con altura de inspector menor de 480, Paleta/Codex se alternan mediante pestañas internas;
   no apilar dos paneles con contenido ilegible. Su estado se conserva al alternar.
4. Reducir la matriz hasta 112 antes de quitar al lienzo sus 160 de alto. Si sigue sin caber,
   plegarla a una cabecera que muestra capa/fotograma y permite abrir el navegador de celdas.
5. Si el área sigue siendo insuficiente por escala de UI/pantalla, usar presentación compacta
   de una sola superficie: lienzo y botones de panel; cada panel se consulta como cajón accesible.

Un cajón cierra con su botón o Escape y devuelve foco al control que lo abrió. No cierra por una
edición ni descarta estado. Los ajustes temporales por tamaño no sobrescriben preferencias de
ancho/visibilidad; al ampliar vuelven los paneles que el usuario había elegido. No redimensionar
la ventana automáticamente al cambiar de pestaña.

Validar 900 × 580, 1280 × 800 y 1920 × 1080 a escala 100 %, y el mayor zoom de UI permitido que
quepa en la pantalla disponible. No exigir que toda la UI del mockup aparezca simultáneamente
en el tamaño mínimo. La app no fuerza una ventana mayor que el área visible del monitor.

## 3. Panel global de procesos y resultados

Al activar `.pxa`, ocultar por defecto la superficie global inferior para dar espacio al editor,
sin detener procesos ni cambiar la preferencia de las pestañas de código. Recordar una preferencia
de visibilidad de procesos propia del modo pixel art, inicialmente falsa. ⌘J sigue controlando
ese panel global; nunca la línea de tiempo. Volver a código/SQL restaura su comportamiento previo.

Si se muestra Procesos en modo `.pxa`, reservarle su tamaño mínimo y compactar la matriz/inspector
según espacio. Si ambas superficies no caben, plegar la matriz del editor, no ocultar el panel
que el usuario acaba de pedir. Resultados SQL de otra pestaña no aparecen como datos del `.pxa`.

## 4. Lienzo y navegación disponibles en etapa 2

- Dibujar la composición del fotograma activo conforme a PXA-01, no estirar `preview.png`.
- Escalar con vecino más cercano, sin antialiasing de píxeles. El fondo ajedrezado es UI y no
  se exporta ni agrega al historial. Cada cuadro claro u oscuro ocupa exactamente un píxel del
  documento al zoom actual: un lienzo transparente de 8 × 8 muestra 8 × 8 cuadros. Las reglas
  muestran coordenadas de documento.
- Zoom con botones, porcentaje editable, 100 % y Ajustar. Rango 1 %–6.400 %; entrada inválida
  no se aplica. Ajustar es un modo que recalcula al cambiar el viewport, no al editar colores.
- Al crear, Ajustar usa el mayor zoom entero que cabe si cabe al menos 100 %; si no, la fracción
  necesaria dentro del rango. Al restaurar, respetar porcentaje/centro guardados y mantener al
  menos un borde del lienzo accesible si la vista quedó fuera de pantalla.
- «100 %» significa un píxel de imagen por punto lógico del lienzo, independiente del zoom de UI;
  en pantalla Retina se representa con la escala de respaldo correspondiente. UI zoom no altera
  el valor de zoom artístico. El porcentaje guardado tiene esta misma semántica en otra pantalla.
- Rueda/trackpad sin modificadores desplaza; gesto de pellizco y controles de zoom conservan el
  punto bajo el cursor, o el centro cuando no hay cursor en lienzo. Espacio + arrastre mueve la vista
  solo si el lienzo tiene foco y no hay un campo de texto editándose.
- Cuadrícula visible por defecto desde 800 %, control para activarla/desactivarla y separación
  de un píxel en esta etapa. Por debajo se oculta para no cubrir la imagen y se conserva su preferencia.
- La selección guardada se representa como contorno; no se puede crear/editar hasta etapa 3.
- Coordenadas de puntero solo dentro del lienzo; fuera mostrar «—», no coordenadas inválidas.

Reglas, selección y cuadrícula no forman parte del render artístico. Renderizar por invalidación;
sin animación de documento, gesto ni cambios no hay un timer continuo de redibujo. La visualización
debe admitir pan/zoom sin materializar simultáneamente todos los fotogramas o revisiones.

## 5. Herramientas y barra contextual

Conservar posiciones del mockup: lápiz, borrador, cuentagotas, relleno, selección rectangular,
lazo, línea, rectángulo, elipse, mano y zoom. Mano/zoom funcionan en esta etapa. Las herramientas
de dibujo tienen estado deshabilitado y ayuda «Disponible en la etapa de dibujo», sin alterar
el color del lienzo al pulsarlas. No asociar atajos de dibujo todavía.

El tamaño de pincel y simetría pueden mostrarse como valores de un archivo existente, pero sus
controles de edición están deshabilitados hasta etapa 3. Color activo puede elegirse entre las
muestras existentes como estado auxiliar; no implica cambiar píxeles ni editar la paleta.

El control **Lienzo…** permite cambiar ancho y alto con los presets 8, 16, 32, 64 y 128 o
valores personalizados dentro de los límites del formato. El contenido permanece anclado arriba a
la izquierda; reducir recorta los bordes derecho e inferior en todas las capas y fotogramas. El
diálogo advierte ese efecto y la operación se puede deshacer desde el historial.

Deshacer/rehacer funcionan sobre revisiones existentes en archivos compatibles y editables.
Exportar está deshabilitado con ayuda sobre su etapa. El botón Codex abre/cierra el panel; su
estado seleccionado solo indica visibilidad, nunca que haya una conexión de IA disponible.

## 6. Capas y fotogramas

Matriz con nombres de capa, indicadores de visibilidad/bloqueo/opacidad y columnas de fotogramas.
Nombres se muestran de frente a fondo (inverso al almacenamiento de PXA-01). Desplazamientos de
encabezado y celdas se mantienen sincronizados; nombres y números permanecen visibles al desplazar.

Una celda selecciona capa y fotograma activos. La columna marca fotograma y la fila marca capa;
no depender solo del color. Clic en un nombre cambia capa; clic en número cambia fotograma.
Mostrar duración al inspeccionar. En archivos sin secuencia, el selector muestra «Todos los fotogramas».
Con secuencias existentes, seleccionarlas filtra/navega su lista sin alterar datos. En `pingPong`,
la lista sigue mostrando IDs una sola vez; reproducción queda fuera de esta etapa.

El indicador de celda distingue vacía/con contenido con ayuda accesible. Los símbolos del mockup
no significan interpolación automática ni keyframes generados. No agrupar implícitamente celdas
de contenido igual como celdas enlazadas.

En etapa 2 son de solo inspección los ojos/candados, nombre y opacidad; no alternan propiedades.
Agregar/duplicar/ordenar/eliminar y reproducción/onion skin están deshabilitados. Ver un `.pxa`
con 8 fotogramas permite inspeccionar los 8, aunque el documento nuevo tenga solo uno.

## 7. Inspector de paleta y Codex

Paleta: nombre, número de entradas, muestras, entrada seleccionada, nombre/HEX/RGBA, ID y vínculo.
Paleta vacía: «Este documento todavía no tiene paleta». Contar colores distintos del render no
equivale a contar muestras: la barra distingue «16 entradas de paleta» de «Color libre»/«Mixto».
Permitir inspeccionar usos por capa/fotograma; los campos de definición son de solo lectura en etapa 2.

Codex: encabezado y control de plegado, sin iniciar conexión al abrir. Para un documento sin
conversación: «Codex se integrará en una próxima etapa» y explicación breve del futuro flujo de
propuestas. No mostrar caja de envío que aparente funcionar, selector de modelo ni login ficticio.

Si un archivo ya contiene conversación, mostrar sus mensajes y resúmenes como registro de solo
lectura, con etiqueta «Conversación guardada». Una propuesta retenida se informa como pendiente
sin habilitar Aplicar/Revalidar/Enviar hasta etapa 7; su contenido se conserva al guardar.
Original/Propuesta y las tarjetas de aplicación del mockup solo aparecen cuando esa función esté
implementada; no simular una aprobación en etapa 2.

## 8. Historial y estado persistente de vista

**Edición → Historial de pixel art…** abre un inspector transitorio dentro del área del documento:
lista de la ruta actual, selector Otras ramas, origen de cada revisión y marcador del punto guardado.
Seleccionar una revisión permite previsualizar; **Restaurar esta revisión** mueve el cursor con
las reglas de PXA-02. Cerrar la inspección sin restaurar conserva el cursor original. Deshacer/rehacer
se refieren al documento, no a la selección temporal de la lista. En solo lectura solo hay preview.

La inspección usa un render aislado y no cambia la celda/vista principal hasta restaurar.
Al cambiar de pestaña se cierra la inspección sin restaurar. No agrega un panel permanente al mockup.
No abre otra ventana de Braket. Mientras se inspecciona, la navegación del historial tiene foco;
los atajos artísticos del documento no modifican una revisión que solo está previsualizada.

Zoom, centro, capa/fotograma y selección van en `editorState` conforme a PXA-01. Anchos, plegado,
inspector dividido/compacto y preferencia de procesos se guardan localmente por modo de editor,
con valores por defecto compartidos; no se serializan en `.pxa`. Una adaptación por tamaño no
es una elección manual y no reemplaza esos valores.

## 9. Foco, teclado y accesibilidad

- ⌘S y ⇧⌘S conservan Guardar/Guardar copia; Guardar como tiene entrada sin nuevo atajo.
- ⌘Z y ⇧⌘Z llegan al historial solo si el foco no está editando texto en un campo nativo.
- ⌘W cierra la pestaña activa mediante el coordinador de documentos; el botón rojo sigue el
  flujo de salir de la app. No cerrar la ventana al intentar cerrar una pestaña `.pxa`.
- ⌘+, ⌘− y ⌘0 conservan el zoom global de interfaz de Braket. Zoom del lienzo usa sus controles
  y gestos; no reasignar esos atajos según el archivo activo.
- ⌘F no abre búsqueda textual sobre un bitmap. Acciones SQL siguen deshabilitadas en `.pxa`.
- Tab recorre controles por zona; flechas navegan celdas cuando la matriz tiene foco. Escape
  cierra primero cajón/inspección temporal, no descarta cambios artísticos confirmados.
- Iconos con nombres accesibles, ayudas y foco visible; estados no comunicados solo por color.
  Muestras anuncian nombre, ID, RGBA y vínculo. Celdas anuncian capa, fotograma y presencia de contenido.
- El lienzo anuncia dimensiones y fotograma, no millones de elementos por píxel.
- La escala de UI y temas claro/oscuro existentes funcionan; no introducir pulsos/decoraciones
  animadas mientras el editor está en reposo.

## Criterios de aceptación y pruebas futuras

- Comparación visual con el mockup a tamaño amplio, respetando las funciones aún deshabilitadas.
- Ningún control esencial queda fuera de alcance en los tamaños y escalas definidos.
- Texto/SQL/Markdown recuperan sus paneles y preferencias al salir de `.pxa`.
- Activar Procesos no detiene ni reinicia ejecuciones y no se confunde con la línea de tiempo.
- Cambiar de pestaña conserva vista, celda y estado; no recrea el modelo documental.
- Render de paleta vinculada, libre, alfa y capas coincide con fixtures de PXA-01/PXA-03.
- Verificar zoom/pan/puntero sobre Retina y escala 100 % con coordenadas enteras correctas.
- Historial preview no modifica el documento; Restaurar sí permite guardar el nuevo cursor.
- Probar teclado, VoiceOver, tema claro/oscuro y ausencia de red/inferencia al abrir Codex.
- Medir repintado y memoria con fixtures de 64 × 64, 512 × 512 y un documento disperso de
  4.096 × 4.096. Registrar hardware, escala y resultados; no afirmar rendimiento sin medir.

## Riesgos

Superponer el panel global y el del editor puede dejar un lienzo inutilizable si no se compactan
por espacio real. La UI debe representar los datos que abre aunque aún no permita editarlos:
deshabilitar herramientas no autoriza simplificar capas, descartar historia ni aplanar el archivo.
