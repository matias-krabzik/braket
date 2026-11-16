# PXA-21 · Validación integral y entrega Release

| | |
|---|---|
| **Estado / etapa** | Especificado; ninguna prueba de este editor ejecutada · [8](ETAPA-08.md) |
| **Dependencias** | PXA-01 a PXA-20; `AGENTS.md` del repositorio |

## Objetivo

Una entrega completa requiere comportamiento probado y app correcta instalada. Esta especificación
define evidencia y criterios; no autoriza programar/compilar/instalar durante la tarea documental.

## Matriz de validación

| Área | Evidencia requerida |
|---|---|
| Formato PXA-01 | Round-trip, hashes, límites, referencias, versiones y recuperación parcial explícita |
| Historia PXA-02 | Deshacer/rehacer offline, ramas, cursores guardados y copia reducida sin mutar original |
| Color PXA-03/12 | IDs estables, clases mixtas, conversiones, alfa, bloqueos y reducción determinista |
| Operaciones PXA-04/18 | Atomicidad, scope real, idempotencia, obsolescencia y rechazo de datos fuera de contrato |
| Integración PXA-05/06 | Finder/inicio normal, una instancia, pestañas, contexto suelto, layout y foco |
| Persistencia PXA-07/08 | Fallos en cada fase, salida/cierre cancelado, cambios externos y snapshots divergentes |
| Dibujo PXA-09/10/11 | Goldens de píxeles, selecciones/clipboard, transformaciones y capas en varios frames |
| Animación PXA-13/14 | Duraciones, secuencias, reloj simulado, onion skin y cambios estructurales |
| Intercambio PXA-15/16 | Fuentes corruptas, PNG16/perfiles, grillas, JSON y decodificación independiente de salida |
| Codex PXA-17/19 | Protocolo simulado, aislamiento real, cuenta sin acceso y corpus visual 7A/7B |
| Recursos PXA-20 | Perfil y medidas reproducibles; accesibilidad, memoria y reposo |

Tests de lógica/modelo con almacenamiento/reloj/transporte inyectables, sin abrir modales. Goldens
artísticos comparan RGBA y clases/IDs cuando corresponda; screenshots de UI no sustituyen esos tests.
Pruebas aleatorias deterministas de secuencias de operaciones verifican invariantes después de cada
commit y equivalencia al deshacer/rehacer; guardar semilla mínima de cualquier falla para reproducirla.

Fixtures propios con manifiesto esperado y casos malformados. Los archivos que exceden límites
se generan acotadamente durante pruebas; no subir gigantes ni bombas reales al repositorio.
El transporte simulado nunca consume cuenta. Las pruebas reales de Codex requieren opt-in, cuenta
y reporte explícito de si corrieron; no mantener un marcador activo que consuma inferencia en CI.

## Recorridos completos obligatorios

1. Crear sprite, dibujar, paleta vinculada, capas, guardar/reabrir y continuar undo/redo.
2. Animación con tiempos variables y secuencia, exportar los cuatro formatos, reconstruir resultados.
3. Propuesta Codex sobre selección, ajuste, aplicación, recuperación tras caída y rehacer sin red.
4. Editar manualmente durante inferencia: propuesta obsoleta no se aplica; reenviar preserva trabajo.
5. Guardar mientras se edita, conflicto externo, copia, fallo de disco y cierre cancelado más tarde.
6. Abrir varios `.pxa` por Finder, con y sin proyecto, y recuperar un borrador de igual nombre/ID
   sin mezclar trabajos ni crear otra instancia.
7. Abrir versión futura/archivo dañado: no rescribir silenciosamente ni convertirlo en imagen vacía.
8. Repetir flujo esencial con teclado/VoiceOver, escala alta y paneles compactos.

## Regresiones de Braket

Validar texto/Markdown (edición, preview y guardado), SQL (borradores, consultas y cancelación),
explorador (mover/renombrar/Papelera), proyectos múltiples/confianza, procesos, automatizaciones,
sesiones y ajustes. Un fallo previo ajeno se identifica con evidencia y baseline, sin atribuirlo
al editor ni declararlo aprobado. No reescribir cambios de trabajo ajenos para limpiar el diff.

No modificar el formato `.kzk` para almacenar bitmaps ni reintroducir pestañas antiguas de Codex.
Comprobar que abrir un proyecto/documento sigue sin ejecutar procesos o prompts. Mantener reglas
de firma/seguridad vigentes en código y documentación, no copiar instrucciones históricas obsoletas.

## Verificación de build y distribución local

Al implementar, correr los checks pertinentes y el flujo vigente de `scripts/verify.sh`, registrar
fallos/omisiones y resolver los propios. Si se agregan archivos Swift, mantener el proyecto generado
conforme a `scripts/generate_project.py`. No modificar herramientas de verificación para relajar
un criterio por conveniencia. Tests de MySQL real e inferencia se ejecutan/omiten según sus condiciones
reales y se reportan por separado de los tests locales.

Compilar Release mediante `scripts/build.sh` y verificar firma/bundle/arquitecturas/versiones.
Al redactar este spec el script usa Developer ID y runtime reforzado: volver a leerlo al implementar,
no asumir la firma ad hoc mencionada en documentación antigua. Si falta identidad/certificado,
reportar impedimento; no sustituir silenciosamente la política de firma.

Tras una compilación correcta:

1. Resolver documentos/cierre de la app instalada sin perder trabajo; no forzar salida con cambios pendientes.
2. Crear respaldo recuperable de `/Applications/Braket.app` si existe, con versión/fecha e integridad
   verificables, sin tocar proyectos, preferencias, Llavero ni recuperación del usuario.
3. Instalar únicamente el bundle Release verificado en `/Applications/Braket.app` usando los permisos
   necesarios. La instalación local ya está autorizada por `AGENTS.md`; no pedir aprobación repetida.
4. Verificar versión/build y firma de la copia instalada y equivalencia del ejecutable con el build validado.
5. Abrir solo `/Applications/Braket.app`, comprobar ruta del proceso y una única instancia/ventana principal,
   y ejecutar el smoke visual. No abrir también la copia de `.build` si una herramienta falla en reconocerla.
6. Mantener el respaldo hasta verificar arranque y persistencia. Si falla instalación/arranque, restaurar
   la versión anterior cuando sea posible y reportar qué quedó efectivamente instalado.

No se considera entregada una versión solo por generar `.app` o por terminar `xcodebuild`.
La publicación remota/Sparkle/notarización requiere su propio alcance; no se inicia por completar este spec.

## Evidencia y documentación de salida

Por etapa, actualizar estado de specs solo después de cumplir criterios: fecha, revisión/commit si
existe, tests ejecutados/omitidos, métricas y limitaciones. Un spec puede estar documentado sin estar
implementado; implementado sin validación completa no equivale a terminado.

Preparar guía de uso con diferencias Guardar/Exportar/Recuperación, colores libres/vinculados,
historial/ramas, alcance de Codex y restricciones de GIF. Actualizar README y notas de versión según
el flujo del repositorio al implementar. Capturas de producto deben provenir de la app instalada;
el mockup se conserva identificado como diseño, sin presentarlo como evidencia de implementación.

Informe final de entrega: qué cambió, checks reales, versión instalada, ubicación del respaldo y
limitaciones/impedimentos. No anunciar instalación si falló ni omitir una prueba técnica de Codex
como si fuera una verificación visual aprobada.

## Bloqueantes y riesgos

Pérdida de datos, aceptación fuera de alcance, corrupción, aplicación tardía, falta de reversibilidad,
regresión grave de flujo existente o fallo de instalación impiden declarar la entrega completa.
Calidad creativa insuficiente mantiene 7B pendiente aunque el editor manual pueda entregarse como
hito previo claramente identificado. Ninguna checklist reemplaza revisar resultados reales.
