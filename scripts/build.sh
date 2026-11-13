#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Un archivo .swift nuevo sin regenerar produce "cannot find 'X' in scope", un
# error que parece de código y no lo es. Mejor fallar acá, con el motivo claro.
python3 scripts/generate_project.py --check

# La identidad debe ser estable entre instalaciones para conservar la autorización
# de Keychain. Usamos la misma Developer ID de distribución; nunca firma ad hoc.
# Se puede elegir otra identidad/equipo explícitamente en otra máquina.
local_identity="${BRAKET_SIGN_IDENTITY:-Developer ID Application: MATIAS IVAN KRABZIK (6P3J382F8G)}"
local_team="${BRAKET_SIGN_TEAM:-6P3J382F8G}"
xcodebuild -project Braket.xcodeproj -scheme Braket -configuration Release -destination 'platform=macOS' -derivedDataPath .build "CODE_SIGN_IDENTITY=$local_identity" "DEVELOPMENT_TEAM=$local_team" CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=YES build
codesign --verify --deep --strict .build/Build/Products/Release/Braket.app
printf '\nApp: %s/.build/Build/Products/Release/Braket.app\n' "$PWD"
