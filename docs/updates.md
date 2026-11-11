# Actualizaciones de Braket

La app nativa usa Sparkle 2.10.1. La versión y el build se definen únicamente en
scripts/generate_project.py; cada publicación necesita un BUILD_NUMBER mayor.

El producto y los paquetes se llaman Braket. Se conservan el identificador de la app,
la cuenta de firma y las rutas históricas del catálogo y de descargas para que las
instalaciones anteriores mantengan sus preferencias y su canal de actualizaciones.

- Catálogo: https://www.krabzik.com/apps/krabzik-ide/appcast.xml
- Descargas: https://www.krabzik.com/downloads/krabzik-ide/<versión>/
- Sitio local: /Users/mati/Projects/Webs/krabzik.com
- Clave Sparkle: llavero de inicio de sesión, cuenta com.krabzik.ide.updates.
- Solo la clave pública queda en Info.plist. Respaldar la privada de forma segura
  fuera del repositorio, del hosting y de los logs.

## Compilar localmente

Se necesita un certificado Apple Development con clave privada en el llavero.
La integración conserva Hardened Runtime y Library Validation. El equipo local
predeterminado es el del certificado instalado; se puede reemplazar con
DEVELOPMENT_TEAM y CODE_SIGN_IDENTITY en la invocación de xcodebuild.

## Firmar y notarizar desde la terminal

Para firmar y notarizar desde la terminal sin abrir Xcode Organizer:

1. Una sola vez, ejecutar `scripts/notarize.sh setup`. Ingresar el Apple ID
   desarrollador y, cuando `notarytool` la pida, una contraseña específica de app.
   La credencial queda en el llavero bajo el perfil `Braket`; no guardarla en el
   repositorio. Si ya existe un perfil con otro nombre, usar
   `BRAKET_NOTARY_PROFILE=<nombre> scripts/notarize.sh`.
2. Ejecutar `scripts/notarize.sh`. Compila Release, firma con Developer ID,
   envía a Apple, adjunta el ticket y verifica la app. Imprime la ruta final.
   No modifica la instalación local ni publica una actualización.
3. Para preparar también los archivos de una nueva actualización, incrementar
   antes el build y ejecutar `scripts/notarize.sh release <notas.md>`.
   Requiere el catálogo anterior en el repositorio local del sitio. Este comando
   tampoco despliega al sitio.

El modo terminal requiere conexión a Apple durante la notarización. Si Apple
rechaza la entrega, `notarytool` devuelve un error y no se prepara la descarga.

## Publicar

1. Usar Developer ID Application: MATIAS IVAN KRABZIK (6P3J382F8G),
   instalado con su clave privada en el llavero de esta Mac. Apple Development
   no sirve para distribuir. No exportar claves al repositorio ni al hosting.
2. Guardar la autenticación de notarización en el llavero usando
   xcrun notarytool store-credentials. Usar un perfil, no contraseñas en scripts.
3. Incrementar versión/build y ejecutar scripts/verify.sh.
4. Preparar notas y ejecutar python3 scripts/release_updates.py con los argumentos
   --identity (nombre completo Developer ID Application), --team (Team ID),
   --notary-profile (perfil de llavero), --notes (archivo Markdown) y
   --previous-feed (public/apps/krabzik-ide/appcast.xml del sitio).
   Consultar --help para la sintaxis.

Como alternativa al perfil de notarytool, abrir el archivo .xcarchive en Xcode,
elegir Distribute App → Direct Distribution y exportar cuando Apple acepte la
notarización. Ejecutar el mismo script con --notarized-app /ruta/Braket.app en lugar
de --notary-profile. Verifica identidad, equipo, versión, ticket y Gatekeeper antes
de preparar la descarga; no vuelve a compilar la app exportada.

El script archiva, firma, notariza, adjunta el ticket, verifica Gatekeeper y genera
el ZIP y el catálogo Ed25519. Solo prepara archivos locales; no publica.
Revisar y copiar el public/ generado al public/ del sitio. Ejecutar npm run check,
npm run build y npm run ide:check en el sitio. Desplegar ZIP y feed juntos.
Verificar HTTPS, tamaño/firma y una actualización real entre dos builds firmados
antes de anunciar el sistema como listo para distribución.

## Compatibilidad

latest.json y updater.json pertenecen a la app anterior de Tauri (0.1.x).
No cambiar sus formatos, firmas ni paquetes. La migración a la aplicación nativa
requiere una primera instalación separada; no mezclar los dos actualizadores.

## Comportamiento

Búsqueda automática optativa, sin perfil del sistema ni instalaciones silenciosas.
El reinicio de Sparkle pasa por applicationShouldTerminate: conserva el diálogo
de documentos sin guardar, la detención de procesos y la cancelación del cierre.
La app debe posponer o cancelar el reinicio si el usuario cancela ese flujo.
Un catálogo vacío significa que aún no hay versiones nativas publicadas.
