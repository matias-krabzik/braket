# PXA-18 · Herramientas gráficas y materialización de propuestas

| | |
|---|---|
| **Estado / etapa** | Especificado, no implementado · [7](ETAPA-07.md) |
| **Dependencias** | PXA-01/02/03/04/09–17 |

## Objetivo y transporte

Exponer operaciones internas del editor, nunca acceso de escritura al contenedor del usuario.
Los nombres siguientes son contratos propios de Braket; al implementar se registrarán con esquemas
versionados compatibles con el transporte validado de PXA-17. No son APIs que hoy existan.

| Herramienta propuesta | Entrada/salida contractual |
|---|---|
| `braket_pxa_get_context` | Token de turno; devuelve revisión base, alcance, IDs, dimensiones, paleta y límites |
| `braket_pxa_read_region` | Capa-ID, frame-ID y rectángulo; devuelve valores de píxeles libre/vinculado y definiciones necesarias |
| `braket_pxa_render` | Estado base/propuesta, frame-ID, región y escala; devuelve PNG con transformación de coordenadas |
| `braket_pxa_propose` | Token, operation-ID y lote de operaciones tipadas; valida y modifica únicamente la propuesta temporal |
| `braket_pxa_finish` | Token y resumen; congela, valida diferencias completas y produce propuesta lista |

No existe herramienta Aplicar/Guardar/Exportar/Desbloquear. Solo la UI puede aceptar una propuesta.
Lecturas de contexto necesario fuera de la selección (por ejemplo composición del fotograma) se
declaran en el contexto; alcance de escritura sigue restringido a lo elegido. No leer otra pestaña.

## Envelope, operaciones y resultados

Todas las llamadas llevan versión 1, request-ID, proposal-ID y token opaco asociado a la sesión.
El servidor local comprueba esos campos; repetir IDs adivinados no concede acceso. Una operación
especifica entidades por IDs estables, geometría entera y colores tipados (libre RGBA / vínculo ID).
Entidades nuevas usan referencias temporales que el host resuelve a IDs propios; no reutilizar
IDs de otras ramas ni confiar en el valor propuesto por el modelo.

Operaciones permitidas en 7A: crear/editar propuesta de paleta, mapeo/reasignación de color,
escribir/borrar región, relleno, contorno exterior de selección, voltear/desplazar, crear/duplicar
capa, cambiar contenido de celdas dentro del alcance. En 7B se combinan esas operaciones para
dibujar elementos. Crear/eliminar/reordenar fotogramas y cambiar duraciones solo con alcance que
lo permita y preview estructural; no generar grandes secuencias automáticamente en 1.0.

El contorno exterior de 1 px es dilatación de la máscara de contenido/selección elegida por vecindad
de cuatro, menos la máscara original. No sobreescribe contenido existente fuera de ella por
omisión; colisiones se reportan para proponer otra capa. Recortar el resultado al alcance no
equivale a autorizar ampliarlo. Línea/formas llaman al mismo rasterizador manual de PXA-09.

Píxeles se entregan como runs por fila con etiqueta/valor o bloques tipados, no millones de
llamadas individuales. Rectángulos usan origen inclusivo y tamaño; clips fuera de lienzo o alcance
son errores de propuesta, no correcciones silenciosas del payload. No se aceptan programas,
expresiones, paths de escritura ni URLs remotas como píxeles.

Límites por llamada: hasta 1 MiB de payload serializado, 128 operaciones, lectura de región hasta
128 × 128 píxeles y render hasta 4.096 por eje dentro del presupuesto visual. Por turno: hasta
16 MiB de payloads de edición, 4.096 operaciones y los topes de PXA-17. Una creación grande debe
usarse por bloques; alcanzar el límite devuelve error con estado temporal conservado, no truncado.
El presupuesto final de documento sigue siendo PXA-01, aunque los payloads quepan.

Respuesta: éxito con número de operaciones/objetos afectados y revisión temporal, o error tipado
con campo/entidad y motivo. Errores mínimos: invalidInput, staleBase, outOfScope, locked,
alphaConstraint, missingReference, paletteCapacity, resourceLimit, cancelled y unsupportedCapability.
Una corrección puede reintentarse con nuevo operation-ID mientras el turno siga vigente.

## Atomicidad e idempotencia

Un lote inválido no modifica la propuesta temporal. Un lote válido actualiza solo ese estado
aislado; no crea revisión artística del usuario. Mismo operation-ID y mismo payload devuelve el
resultado ya calculado; mismo ID con otro payload es error. El hash/idempotencia se mantiene
durante el turno y las operaciones aceptadas en su registro de propuesta.

`finish` valida el resultado completo contra base, incluyendo diferencias de vínculos que no
cambian el render. Recalcular alcance y uso de colores: no confiar en `affected` del modelo.
Sin diferencias, devolver respuesta informativa sin botón Aplicar; una propuesta que solo agrega
paleta sí tiene diferencia artística aunque ningún píxel cambie.

Aplicar desde UI vuelve a validar el token de instancia/generación y crea una sola revisión.
Errores de commit no dejan media paleta o capas parciales. Repetir Aplicar la misma propuesta es
idempotente conforme a PXA-04. Cancelar el turno invalida toda posibilidad de finalizar tarde.

## Ajustes, lectura y recursos

Pedir ajuste usa la propuesta previa como estado de trabajo pero la misma revisión original
como base de aceptación. Conservar el último resultado listo mientras se prepara el ajuste; un
fallo permite volver a él, si su base no cambió. No encadenar revisiones del usuario por cada ajuste.

Un render de herramienta se obtiene del renderer común, incluyendo paleta de la propuesta; no
confundirlo con la imagen original enviada al inicio. Purgar temporales por propietario al terminar
y conservar solo objetos alcanzables desde una propuesta guardada o revisión aceptada. No guardar
tokens opacos de autorización de runtime en `.pxa`; persistir IDs/datos de propuesta revalidables.

## Aceptación, pruebas y riesgos

- Tests de contrato por herramienta: entradas mínimas, excesivas, mal tipadas y versiones desconocidas.
- Mismo cambio manual/IA produce iguales píxeles y vínculos; no requiere ejecutar código generado.
- Payload que declara solo selección pero toca una paleta global es rechazado por diff real.
- Repetición/desorden, referencias temporales inválidas, lote fallido y cancelación no publican cambios.
- Contorno, recoloreado, nueva capa y cambio en varios fotogramas respetan máscaras/bloqueos.
- Resultados completos sobreviven a guardar/reabrir; las credenciales/capabilities locales no.

El protocolo puede ser formalizado como esquemas JSON durante implementación, con fixtures y
tests. Esta entrega fija campos, unidades y semántica, sin añadir herramientas ejecutables al proyecto.
