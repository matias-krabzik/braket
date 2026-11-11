#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Un archivo .swift nuevo sin regenerar produce "cannot find 'X' in scope", un
# error que parece de código y no lo es. Mejor fallar acá, con el motivo claro.
python3 scripts/generate_project.py --check

xcodebuild -project Braket.xcodeproj -scheme Braket -configuration Release -destination 'platform=macOS' -derivedDataPath .build build
printf '\nApp: %s/.build/Build/Products/Release/Braket.app\n' "$PWD"
