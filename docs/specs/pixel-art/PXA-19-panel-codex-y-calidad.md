# PXA-19 · Panel de Codex, revisión y calidad visual

| | |
|---|---|
| **Estado / etapa** | Especificado, no implementado · [7](ETAPA-07.md) |
| **Dependencias** | PXA-04/06/17/18 |

## Panel y conversación

Mantener ubicación del mockup: columna derecha, paleta arriba y Codex abajo, con adaptación de
PXA-06. Al completar esta etapa reemplazar el aviso de función futura por conexión/estado real,
conversación y compositor. Conservar el panel plegado/abierto como preferencia, no como permiso.

Encabezado: Codex, estado, modelo y acciones Nueva conversación/Plegar. Compositor con prompt,
alcance visible y Enviar/Cancelar. Enter envía, Shift-Enter agrega línea solo dentro del compositor;
durante composición IME Enter confirma texto y no envía. Prompt vacío no envía. Mostrar nombre
del `.pxa`, selección/capa/fotogramas resueltos y tamaño de imagen antes de solicitar inferencia.

Nueva conversación separa contexto futuro sin borrar las anteriores guardadas; lista accesible
por documento. Con propuesta pendiente requiere Aplicar/Descartar/Cancelar antes de iniciar un
pedido independiente. No agregar un explorador global de sesiones ni mezclar conversación de
otro documento al cambiar de pestaña. Historial de conversación es texto visible, no razonamiento interno.

Estados: conectar, esperando en cola, preparando contexto, trabajando, validando, lista, obsoleta,
aplicada, descartada, cancelada y error. Progreso representa eventos reales; no porcentaje inventado.
Mostrar errores junto al pedido y permitir reintento explícito. No publicar un resultado parcial
como terminado porque llegó un mensaje de texto antes de `finish`.

## Propuesta y comparación

Tarjeta con resumen, base, alcance, capas/fotogramas afectados, colores y recuentos. Paleta muestra
swatches antes/después y mapa de correspondencias; cambios de estructura listan creaciones,
eliminaciones, orden y duraciones. Dos recuentos separados: aspecto y vínculo/estructura.

Original/Propuesta alterna sobre el mismo lienzo/zoom. Opción Diferencias marca píxeles afectados
con overlay separado y lista cambios no visibles; overlay nunca se mezcla con datos. Para animación,
se puede recorrer el mismo fotograma en ambos estados y reproducir el recorrido correspondiente
con rótulo claro de fuente; cambiar a comparación no aplica la propuesta.

Botones Aplicar cambios, Descartar y Pedir ajuste. Aplicar es la única aceptación artística, sin
segunda confirmación si el alcance fue validado. No autoaplicar al terminar, al cerrar panel o al
guardar. La UI deja claro que deshacer funciona después. Mientras se ve Propuesta no se dibuja;
editar Original la vuelve obsoleta según PXA-04. No hay «aplicar igual» que eluda esa restricción.

Cerrar panel conserva conversación y propuesta; cerrar documento usa PXA-07. Guardar permite
conservar una propuesta completa sin aplicarla y la identifica como pendiente al reabrir. La
revalidación local no dispara inferencia ni convierte en actual una base distinta.

## Capacidades que se comunican

7A presenta ejemplos de paletas, sustituciones precisas, contornos, transformaciones y trabajo
por selección. 7B agrega elementos pequeños, variantes de color/forma y retoques locales. No
presentar «animación consistente garantizada» ni prometer número exacto de intentos/costo.
Una respuesta que solo explica cómo dibujar no satisface un pedido de propuesta editable.

El panel puede pedir aclaración si el pedido no especifica una decisión artística esencial. Una
aclaración no cambia alcance ni aplica nada. El usuario puede cancelar/seguir editando mientras
decide; al retomar se comprueba la base antes de inferir otra vez.

## Evaluación de 7A y 7B

Corpus versionado de fixtures propios, con prompt, alcance, paleta, bloqueos, restricciones esperadas
y capturas antes/después. Registrar modelo real, versión de integración, tiempo, operaciones y
resultado; no datos de cuenta. La prueba local simulada valida protocolo; la real, opt-in, valida
capacidad y calidad. No marcar como corrida una prueba omitida por falta de cuenta/red.

Casos 7A obligatorios: proponer paleta de 12 colores; noche conservando luces; recolorear una
selección con color compartido fuera; contorno de 1 px; aplicar en varios fotogramas. Cada caso
debe producir una propuesta materializable y pasar el 100 % de invariantes en todos los intentos.
Una violación que logre commit bloquea entrega aunque otros casos funcionen.

Casos 7B: espada 16 × 16 en capa nueva, retocar accesorio sin cambiar silueta exterior, variante
de personaje usando paleta fija. Evaluar con revisión humana legibilidad, respeto del pedido,
coherencia de paleta y conservación de región protegida. Ejecutar al menos tres intentos por caso,
registrar resultados fallidos también. Umbral de producto inicial: al menos dos de tres propuestas
consideradas utilizables con retoques menores por caso, además de todas las invariantes. Si falla,
7B queda incompleta: no convertir un demo exitoso en promesa ni esconder el caso del corpus.

## Aceptación, pruebas y riesgos

- Recorrido pedir/ajustar/aplicar/deshacer/guardar/reabrir/rehacer sin red conserva resultado exacto.
- Texto excesivo, IME, VoiceOver, panel compacto, cola y cambio de pestaña no envían pedidos por accidente.
- Una diferencia solo de vínculo o estructura se muestra aunque Original/Propuesta se vean iguales.
- Obsoleta/cancelada/fallida no habilita Aplicar ni pierde una propuesta anterior válida.
- Credenciales ausentes y límites de cuenta no inutilizan herramientas manuales.

La variación artística es esperable; la salida debe ser revisable y editable. La evaluación mide
si la función merece habilitarse, no garantiza que cada prompt futuro produzca buen arte.
