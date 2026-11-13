#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Un archivo .swift nuevo sin regenerar produce "cannot find 'X' in scope", un
# error que parece de código y no lo es. Mejor fallar acá, con el motivo claro.
python3 scripts/generate_project.py --check

# La instalación local usa firma ad hoc y no activa el runtime reforzado:
# Sparkle también lleva firma ad hoc y macOS rechaza cargarlo si el ejecutable
# exige validación de bibliotecas. La publicación usa Developer ID y runtime
# reforzado en release_updates.py.
xcodebuild -project Braket.xcodeproj -scheme Braket -configuration Release -destination 'platform=macOS' -derivedDataPath .build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=NO build
printf '\nApp: %s/.build/Build/Products/Release/Braket.app\n' "$PWD"
