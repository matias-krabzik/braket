#!/bin/zsh
# Verificación del chequeo de postura de seguridad (docs/specs/S6-sandbox-y-firma.md).
# Lo que importa: que el chequeo FALLE cuando el proyecto se separa del ADR. Un gate
# que solo sabe decir "todo bien" no es un gate.
set -uo pipefail
cd "${0:A:h:h:h}"

failures=0
posture() { python3 scripts/check_security_posture.py > /dev/null 2>&1 }
expect() {  # expect <obtenido> <esperado> <descripción>
  local got=$1 want=$2 what=$3
  if [[ "$got" == "$want" ]]; then print "  ✓ $what"; else print "  ✗ $what (exit $got, esperaba $want)"; failures=$((failures+1)); fi
}

backup=$(mktemp -t krabzik-generator)
cp scripts/generate_project.py "$backup"
restore() { cp "$backup" scripts/generate_project.py; rm -f "$backup" }
trap restore EXIT INT TERM

print "Postura de seguridad"
posture; expect $? 0 "pasa sobre el árbol declarado"

sed -i '' "s/'ENABLE_APP_SANDBOX': 'NO'/'ENABLE_APP_SANDBOX': 'YES'/" scripts/generate_project.py
posture; expect $? 1 "falla si el sandbox no coincide con el ADR"
restore; cp scripts/generate_project.py "$backup"

sed -i '' "s/'ENABLE_HARDENED_RUNTIME': 'YES'/'ENABLE_HARDENED_RUNTIME': 'NO'/" scripts/generate_project.py
posture; expect $? 1 "falla si el hardened runtime no coincide con el ADR"
restore; cp scripts/generate_project.py "$backup"

sed -i '' "s/'CODE_SIGN_IDENTITY': 'Apple Development'/'CODE_SIGN_IDENTITY': 'Developer ID Application'/" scripts/generate_project.py
posture; expect $? 1 "falla si la firma no coincide con el ADR"
restore; cp scripts/generate_project.py "$backup"

cat > Krabzik/__TempEntitlements.entitlements <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
XML
posture; expect $? 1 "falla con una excepción al hardened runtime"
rm -f Krabzik/__TempEntitlements.entitlements

posture; expect $? 0 "vuelve a pasar al quitarla"

if (( failures )); then print "\n$failures fallo(s)"; exit 1 else print "\ntodo en verde"; fi
