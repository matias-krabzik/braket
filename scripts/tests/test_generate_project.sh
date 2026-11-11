#!/bin/zsh
# Verificación del modo --check del generador (docs/specs/C8-pbxproj-sincronizado.md).
# No hay pruebas de Swift para esto: el generador es un script y se prueba como tal.
set -uo pipefail
cd "${0:A:h:h:h}"

failures=0
check() { python3 scripts/generate_project.py --check > /dev/null 2>&1 }
expect() {  # expect <esperado> <descripción>
  local got=$1 want=$2 what=$3
  if [[ "$got" == "$want" ]]; then print "  ✓ $what"; else print "  ✗ $what (exit $got, esperaba $want)"; failures=$((failures+1)); fi
}

print "Modo --check"
check; expect $? 0 "pasa sobre el árbol sincronizado"

printf 'import Foundation\n' > Krabzik/Views/__TempCheck.swift
check; expect $? 1 "falla con una fuente nueva sin registrar"
# Sin pipe: con pipefail el exit 1 esperado de --check se propagaría y ocultaría
# el resultado del grep.
output=$(python3 scripts/generate_project.py --check 2>&1)
if [[ "$output" == *"__TempCheck.swift"* ]]; then
  print "  ✓ nombra el archivo nuevo"
else
  print "  ✗ no nombra el archivo nuevo"; failures=$((failures+1))
fi
rm -f Krabzik/Views/__TempCheck.swift
python3 scripts/generate_project.py > /dev/null

hidden=$(mktemp -d)
mv Krabzik/Editor/LineIndex.swift "$hidden/"
check; expect $? 1 "falla con una fuente borrada"
mv "$hidden/LineIndex.swift" Krabzik/Editor/
rmdir "$hidden"
python3 scripts/generate_project.py > /dev/null

python3 scripts/generate_project.py --vamos > /dev/null 2>&1
expect $? 2 "rechaza un argumento desconocido"

print "\nDeterminismo"
first=$(mktemp)
python3 scripts/generate_project.py > /dev/null && cp Braket.xcodeproj/project.pbxproj "$first"
python3 scripts/generate_project.py > /dev/null
if cmp -s "$first" Braket.xcodeproj/project.pbxproj; then
  print "  ✓ dos corridas producen bytes idénticos"
else
  print "  ✗ la generación no es determinista: --check no sirve"; failures=$((failures+1))
fi
rm -f "$first"

print ""
if (( failures > 0 )); then print "$failures fallo(s)"; exit 1; fi
print "todo en verde"
