# Automatizaciones por proyecto

En el panel inferior, **Automatizaciones → Configurar**, elegí la carpeta de código y agregá una automatización. También está en Configuración → Automatizaciones. Guardá los cambios antes de compartirlos. El archivo `.braket/automations.json` se puede versionar con el repositorio; no se ejecuta al abrirlo. Braket pide revisar comandos y parámetros antes de ejecutar, y respeta el modo de proyecto no confiable.

Cada paso tiene comando, carpeta relativa a la raíz elegida (o absoluta), variables de entorno, versión de Node mediante nvm, tiempo límite y opciones de confirmación y reintento. Los pasos se ejecutan en orden y se detienen al primer error. Cancelar termina el grupo de procesos; al cerrar el proyecto se integra con la pantalla de detención existente.

Los parámetros llegan como `BRAKET_INPUT_NOMBRE`. No se interpolan dentro del comando: usá comillas, por ejemplo `echo "$BRAKET_INPUT_VERSION"`. Un paso puede escribir un objeto JSON de cadenas en `$BRAKET_OUTPUT_FILE`; los siguientes reciben esos valores como `BRAKET_OUTPUT_NOMBRE`. `BRAKET_PROJECT_DIR` es la raíz y `BRAKET_RUN_DIR` el directorio local de esa ejecución.

La configuración, los parámetros y los logs no son un almacén de secretos. Para credenciales usá referencias a perfiles del llavero o herramientas de autenticación. El historial local está en `~/Library/Application Support/Braket/AutomationRuns/`, separado del repositorio. La consola conserva una cola acotada de salida, no un registro ilimitado. Una ejecución interrumpida se muestra como tal al volver a abrir la app. Solo se puede retomar el paso pendiente si fue marcado como reintentable; los pasos anteriores completados no vuelven a correr. Los scripts deben tolerar reintentos, incluso después de una interrupción entre el efecto externo y el guardado del estado.

## Plantilla Publicar Braket

Seleccioná la raíz de este repositorio. Completá `SITE_REPO` (checkout local de krabzik.com), `NOTES` (archivo Markdown), identidad Developer ID, equipo, perfil de notarytool y rama. La plantilla exige repositorios limpios: hacé commit también de su configuración antes de iniciarla.

1. Verifica repositorios y acceso al perfil de notarización.
2. Reserva e incrementa versión/build y regenera el proyecto Xcode.
3. Compila Release y exporta con Developer ID.
4. Envía a Apple, conserva el identificador de la solicitud, espera y verifica el ticket.
5. Genera y firma el paquete Sparkle con el empaquetador existente.
6. Tras confirmación, hace commit de los archivos de versión y push del código.
7. Tras confirmación, copia únicamente los archivos de publicación al sitio, actualiza sus metadatos, compila el sitio y hace commit/push. GitHub inicia el despliegue de Vercel.

No incluye instalación sobre la app que está ejecutando la automatización ni comprobación del despliegue remoto. Si un envío a Apple se interrumpe antes de guardar su ID, un reintento puede crear otra solicitud del mismo binario. Un rechazo requiere revisar el log de Apple y corregir la causa. No hay rollback automático de versiones o publicaciones. Los commits y pushes no hacen reset, force-push ni incluyen cambios ajenos.

## Android e iOS

El motor es independiente de la plataforma. Se pueden crear pasos para Gradle, xcodebuild, Flutter o fastlane, con parámetros de variante, versión y destino. Esta primera versión incluye scripts genéricos y la plantilla de Braket; no incluye todavía editores específicos de Play Console, App Store Connect ni almacenamiento de sus credenciales.
