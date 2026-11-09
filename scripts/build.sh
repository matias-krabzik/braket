#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodebuild -project Krabzik.xcodeproj -scheme Krabzik -configuration Release -destination 'platform=macOS' -derivedDataPath .build build
printf '\nApp: %s/.build/Build/Products/Release/Krabzik IDE.app\n' "$PWD"
