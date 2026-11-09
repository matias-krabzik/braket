#!/bin/zsh
# Corre todo lo que CI va a correr, para no descubrir los fallos en CI.
# Uso: scripts/verify.sh [--no-tests]
#
# Los pasos marcados BLOQUEANTE devuelven código distinto de 0.
# Los marcados INFORMATIVO solo reportan: pasan a bloqueantes cuando el spec
# correspondiente los habilite (ver docs/specs/).
set -uo pipefail
cd "${0:A:h:h}"

# Trinquetes: cantidades que hoy existen en el código y que solo pueden BAJAR.
# No son objetivos, son topes para no empeorar mientras C4 y C6 no estén hechos.
BASE_LONG_LINES=57      # líneas de más de 140 columnas        -> C4 las baja a 0
BASE_SEMICOLONS=159     # líneas con varias sentencias y ';'   -> C4 las baja a 0
BASE_EMPTY_CATCH=8     # bloques catch vacíos                 -> C6 los baja a 0
BASE_LINT=60            # avisos de SwiftLint                   -> C4 los baja a 0

failures=0
skipped=()
step() { print -- "\n\033[1m$1\033[0m" }
fail() { print -- "  ✗ $1"; failures=$((failures + 1)) }
ok()   { print -- "  ✓ $1" }
info() { print -- "  · $1" }
skip() { print -- "  — $1 (omitido)"; skipped+=("$2") }

# ---------------------------------------------------------------- proyecto Xcode
step "Proyecto Xcode al día (BLOQUEANTE)"
if grep -q -- "--check" scripts/generate_project.py; then
  if python3 scripts/generate_project.py --check; then
    ok "el .pbxproj coincide con las fuentes"
  else
    fail "el .pbxproj está desactualizado: ejecutá python3 scripts/generate_project.py"
  fi
else
  skip "generate_project.py todavía no tiene --check" "C8"
fi

# ------------------------------------------------------------------- trinquetes
step "Trinquetes de estilo (BLOQUEANTE: no empeorar)"
long_lines=$(find Krabzik KrabzikTests -name '*.swift' | xargs awk 'length>140{c++} END{print c+0}')
if (( long_lines > BASE_LONG_LINES )); then
  fail "líneas de más de 140 columnas: $long_lines (tope $BASE_LONG_LINES)"
else
  ok "líneas de más de 140 columnas: $long_lines (tope $BASE_LONG_LINES)"
fi

semicolons=$(grep -rn '; ' --include='*.swift' Krabzik KrabzikTests | grep -v 'for ' | grep -v '//' | wc -l | tr -d ' ')
if (( semicolons > BASE_SEMICOLONS )); then
  fail "líneas con varias sentencias separadas por ';': $semicolons (tope $BASE_SEMICOLONS)"
else
  ok "líneas con ';': $semicolons (tope $BASE_SEMICOLONS)"
fi

empty_catch=$(grep -rn 'catch *{ *}' --include='*.swift' Krabzik KrabzikTests | wc -l | tr -d ' ')
if (( empty_catch > BASE_EMPTY_CATCH )); then
  fail "bloques catch vacíos: $empty_catch (tope $BASE_EMPTY_CATCH)"
else
  ok "bloques catch vacíos: $empty_catch (tope $BASE_EMPTY_CATCH)"
fi

step "Concurrencia sin escapes no justificados (BLOQUEANTE)"
if grep -rn "@preconcurrency\|nonisolated(unsafe)" --include='*.swift' Krabzik KrabzikTests; then
  fail "aparecieron escapes de concurrencia: justificalos por escrito o quitalos (ver C2)"
else
  ok "ningún @preconcurrency ni nonisolated(unsafe)"
fi

# ------------------------------------------------------------------------- lint
step "SwiftLint (BLOQUEANTE: sin errores, y los avisos no crecen)"
if command -v swiftlint >/dev/null; then
  lint_log=$(mktemp -t krabzik-lint)
  swiftlint lint --quiet > "$lint_log" 2>&1
  lint_status=$?
  lint_count=$(grep -cE ':[0-9]+:[0-9]+: ' "$lint_log")
  if (( lint_status != 0 )); then
    fail "SwiftLint reportó errores"
    grep -E ': error: ' "$lint_log" | head -5 | sed 's/^/      /'
  elif (( lint_count > BASE_LINT )); then
    fail "avisos de SwiftLint: $lint_count (tope $BASE_LINT)"
  else
    ok "sin errores · avisos: $lint_count (tope $BASE_LINT)"
  fi
  # Resumen por regla en vez de volcar 66 líneas en cada corrida.
  grep -oE '\(([a-z_]+)\)$' "$lint_log" | sort | uniq -c | sort -rn | sed 's/^/      /'
  (( lint_count > 0 )) && info "detalle: swiftlint lint --quiet"
  rm -f "$lint_log"
else
  skip "swiftlint no está instalado (brew install swiftlint)" "swiftlint"
fi

step "SwiftFormat (BLOQUEANTE)"
if command -v swiftformat >/dev/null; then
  if swiftformat --lint . >/dev/null 2>&1; then
    ok "formato al día según .swiftformat"
  else
    fail "hay diferencias de formato: ejecutá swiftformat ."
    swiftformat --lint . 2>&1 | grep -E "^/" | head -5 | sed 's|.*Krabzik IDE/||' | sed 's/^/      /'
  fi
else
  skip "swiftformat no está instalado (brew install swiftformat)" "swiftformat"
fi

# ----------------------------------------------------------------------- vendor
step "Integridad del vendoring (BLOQUEANTE cuando S7 esté hecho)"
if [[ -x scripts/check_vendor.sh ]]; then
  if scripts/check_vendor.sh; then ok "Vendor/MySQLNIO coincide con upstream + parches"; else fail "el vendoring no coincide"; fi
else
  skip "scripts/check_vendor.sh todavía no existe" "S7"
fi

# ---------------------------------------------------------------------- pruebas
if [[ "${1:-}" == "--no-tests" ]]; then
  step "Pruebas"
  skip "--no-tests" "tests"
else
  step "Compilación y pruebas (BLOQUEANTE)"
  if [[ -f .build/mysql-test-port ]]; then
    info "hay marcador de MySQL: las 6 pruebas de servidor real se ejecutan"
  else
    info "sin .build/mysql-test-port: se saltan las 6 pruebas de MySQL real (ver README)"
  fi
  log=$(mktemp -t krabzik-verify)
  if xcodebuild -project Krabzik.xcodeproj -scheme Krabzik -destination 'platform=macOS' \
       -derivedDataPath .build -parallel-testing-enabled NO test > "$log" 2>&1; then
    ok "$(grep -E 'Executed [0-9]+ tests' "$log" | tail -1 | sed 's/^[[:space:]]*//')"
  else
    fail "las pruebas no pasaron; log en $log"
    # Solo fallos de XCTest y errores del compilador: el log trae mucho ruido del
    # sistema que matchea "error" y tapa el fallo real.
    grep -E "^[^ ]+\.swift:[0-9]+: error:|' failed \(|^.*: error: unable to" "$log" \
      | sed 's|.*/KrabzikTests/|KrabzikTests/|' | head -10 | sed 's/^/      /'
  fi
fi

# ----------------------------------------------------------------------- cierre
print -- "\n\033[1mResumen\033[0m"
(( ${#skipped} > 0 )) && print -- "  omitidos: ${(j:, :)skipped}"
if (( failures > 0 )); then
  print -- "  \033[31m$failures paso(s) bloqueante(s) fallaron\033[0m"
  exit 1
fi
print -- "  \033[32mtodo en verde\033[0m"
