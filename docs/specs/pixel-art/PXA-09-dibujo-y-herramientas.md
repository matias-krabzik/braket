# PXA-09 · Dibujo y herramientas básicas

| | |
|---|---|
| **Estado / etapa** | Especificado, no implementado · [3](ETAPA-03.md) |
| **Dependencias** | PXA-01/02/03/04/06 |

## Objetivo y autoridad

Producir píxeles precisos mediante las mismas operaciones que podrá utilizar Codex. PXA-03 manda
sobre color y alfa; PXA-02 sobre transacciones. El renderer no decide qué píxeles se editan.

## Coordenadas, muestreo y transacción

Convertir puntero a coordenadas del documento antes de rasterizar, usando floor para la celda
bajo el cursor. Eliminar muestras consecutivas duplicadas, sin eliminar segmentos largos. Cada
segmento conecta muestras con una línea entera de Bresenham de un píxel de ancho; normalizar sus
extremos por orden (Y,X) antes de resolver empates para obtener la misma máscara en ambos sentidos.
La capa activa y fotograma quedan fijados al empezar el gesto. Ningún evento tardío pinta otra celda.

Un gesto usa un estado temporal sobre la revisión base. Mouse-up confirma una revisión; Escape,
pérdida de captura, cierre o cambio de pestaña antes de mouse-up cancela. Salir del lienzo durante
el arrastre no confirma: recortar la máscara al lienzo/selección y mantener la captura hasta terminar.
Desconectar el dispositivo no deja el trazo en un estado parcial confirmado.

La selección limita la escritura. Fuera de ella se recorta la máscara, no se amplía automáticamente.
Dentro de la máscara restante, una violación de bloqueo/alfa o presupuesto rechaza el gesto completo.
No omitir silenciosamente posiciones protegidas. Una máscara resultante vacía es no-op sin revisión.

## Lápiz, borrador y pixel perfect

Pincel cuadrado entero de 1 a 64 píxeles. Para tamaño N, su origen en una muestra (x,y) es
(x−floor((N−1)/2), y−floor((N−1)/2)); los tamaños pares se extienden un píxel más al lado positivo.
El cursor muestra la huella real, incluso con selección/simetría. El lápiz reemplaza por color
activo y el borrador por vacío, sin mezcla repetida ni opacidad por acumulación.

Pixel perfect es opcional, predeterminado activo para lápiz de 1 píxel y no aplicable a tamaños
mayores, borrador o formas. Sobre el camino de centros rasterizado, suprimir un centro intermedio
cuando anterior/intermedio y este/siguiente son vecinos ortogonales y anterior/siguiente son
vecinos diagonales. Resolver en orden de recorrido; no suprimir extremos del gesto. Recalcular
la contribución temporal del trazo, no borrar píxeles del estado base al corregir una esquina.
Revisitas y simetrías se unen como máscara; retirar una contribución no retira otra que aún la cubra.
Congelar goldens de diagonales, escaleras, curvas y reversas antes de declarar estable el rasterizador.

## Formas

Línea, rectángulo y elipse parten de dos celdas extremas, con caja inclusiva. Preview durante el
gesto, una transacción al soltar. Línea usa Bresenham; rectángulo relleno cubre su caja, y contorno
usa borde de un píxel. Elipse rellena incluye centros de píxel dentro de la elipse inscrita en
la caja (centro a mitad de ancho/alto, radios ancho/2 y alto/2). Su contorno son los píxeles de
esa máscara con al menos un vecino ortogonal exterior. Dimensiones 1 × N y N × 1 son líneas.
No usar antialiasing. La anchura de contorno inicial es 1; la UI no ofrece una anchura sin soporte.

Shift restringe rectángulo/elipse a caja cuadrada y línea a múltiplos de 45°, usando distancia
máxima por eje y el signo del arrastre. Mostrar caja/tamaño antes de confirmar. Clic sin arrastre
produce un píxel. Color libre/vinculado se conserva igual que en el lápiz.

## Relleno, reemplazo y cuentagotas

Relleno por vecindad de cuatro posiciones; la máscara de selección también es frontera de
conectividad. Busca por ID exacto o RGBA resuelto según selector explícito de PXA-03. El vacío
es distinto de un vínculo transparente en búsqueda por vínculo. En búsqueda RGBA, transparencias
se comparan por el RGBA normalizado; alfa cero se normaliza a 0,0,0,0 solo para comparar.

El reemplazo global usa ese criterio sin contigüidad. Alcance manual predeterminado: celda activa
y selección si existe; «Todos los fotogramas de la capa» requiere elección explícita. Mostrar
recuento si sale de una celda. El relleno se prepara fuera del hilo de UI cuando lo requiera
su tamaño y se puede cancelar antes del commit. No-op si todo ya tiene el valor/clase destino.

Cuentagotas: capa activa conserva el valor almacenado; Color visible devuelve RGBA de composición.
Muestrear vacío activa libre transparente. No elimina una entrada ni crea una paleta. Mantener
distinto el vínculo de un color de paleta invisible, como exige PXA-03.

## Simetría y entrada

Ejes horizontal/vertical opcionales; por defecto pasan por el centro del lienzo. Posición del eje
en pasos de medio píxel: reflejar x como 2a−x (equivalente para y), siempre entero. Unir las
máscaras original/reflejada, recortar a lienzo/selección y validar una sola transacción. La simetría
se aplica a trazos/formas, no al relleno, cuentagotas o transformación de selecciones en 1.0.

Atajos sin modificadores con foco en lienzo: B lápiz, E borrador, I cuentagotas, G relleno,
M selección rectangular, L lazo, H mano, Z zoom. Línea/rectángulo/elipse por toolbar y menú;
no inventar ciclos de tecla no visibles. Los campos de texto consumen sus propias teclas. Los
atajos globales de PXA-06 permanecen. Tableta actúa como puntero sin presión en 1.0.

## Aceptación, pruebas y riesgos

- Goldens a zoom 100/800/1600 % producen los mismos píxeles, inclusive sobre bloques de borde.
- Trazos rápidos sin huecos, formas degeneradas, espejo sobre ejes enteros/medios y selecciones vacías.
- Cancelar/rechazar no altera base; un trazo y sus reflejos se deshacen en una acción tras reabrir.
- Rellenar una región grande no bloquea navegación/cancelación y no rebasa límites de documento.
- Probar clases libres/vinculadas con mismo aspecto, alfa cero y alfa bloqueado.

La corrección pixel perfect puede sorprender: el toggle y su limitación a 1 px deben ser visibles.
No cambiar el algoritmo silenciosamente después de fijar goldens; el historial guarda resultados,
pero las nuevas acciones deben tener semántica conocida. Todas las pruebas quedan pendientes.
