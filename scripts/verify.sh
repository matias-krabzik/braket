#!/bin/zsh
# Corre todo lo que CI va a correr, para no descubrir los fallos en CI.
# Uso: scripts/verify.sh [--no-tests]
#
# Los pasos marcados BLOQUEANTE devuelven código distinto de 0.
# Los marcados INFORMATIVO solo reportan: pasan a bloqueantes cuando el spec
# correspondiente los habilite (ver docs/specs/).
set -uo pipefail
cd "${0:A:h:h}"

# Trinquetes: cantidades que solo pueden BAJAR. C4 y C6 los dejaron todos en 0, así que
# hoy no son topes sino reglas: cualquier aparición falla. Si alguna vez hay un motivo
# para subir uno, va con el motivo escrito acá al lado.
BASE_LONG_LINES=0       # líneas de más de 140 columnas (C4)
BASE_EMPTY_CATCH=0      # bloques catch vacíos en Krabzik/ (C6)
BASE_LINT=0             # avisos de SwiftLint, con --strict (C4)

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

# ------------------------------------------------------- pruebas de los scripts
# Los generadores y chequeos son scripts, y se prueban como scripts. Hasta ahora
# existían pero nadie los corría.
step "Pruebas de los scripts (BLOQUEANTE)"
for prueba in scripts/tests/*.sh; do
  if salida=$(zsh "$prueba" 2>&1); then
    ok "${prueba:t}"
  else
    fail "${prueba:t}"
    print -- "$salida" | grep '✗' | sed 's/^/      /'
  fi
done

# --------------------------------------------------------- postura de seguridad
step "Postura de seguridad declarada (BLOQUEANTE)"
postura=$(python3 scripts/check_security_posture.py)
if [[ -z "$postura" ]]; then
  ok "sandbox, hardened runtime y firma coinciden con docs/security.md"
else
  fail "la configuración no coincide con docs/security.md (ver S6)"
  print -- "$postura" | sed 's/^/      /'
fi

# ------------------------------------------------------------------- trinquetes
step "Trinquetes de estilo (BLOQUEANTE: no empeorar)"
long_lines=$(find Krabzik KrabzikTests -name '*.swift' | xargs awk 'length>140{c++} END{print c+0}')
if (( long_lines > BASE_LONG_LINES )); then
  fail "líneas de más de 140 columnas: $long_lines (tope $BASE_LONG_LINES)"
else
  ok "líneas de más de 140 columnas: $long_lines (tope $BASE_LONG_LINES)"
fi

# El `grep '; '` de antes no distinguía una sentencia de un punto y coma dentro de una
# cadena: media docena de pruebas tienen SQL o Python, y SQL sin punto y coma no es SQL.
if sentencias=$(python3 scripts/check_style.py); then
  ok "una sentencia por línea"
else
  fail "hay líneas con más de una sentencia"
  print -- "$sentencias" | sed 's/^/      /'
fi

# Solo el código de producción: en una prueba, `do { ... XCTFail() } catch {}` es la
# forma idiomática de decir «esto tiene que lanzar», y ahí el catch vacío es correcto.
empty_catch=$(grep -rn 'catch *{ *}' --include='*.swift' Krabzik | wc -l | tr -d ' ')
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
# --strict: C4 dejó el conteo en 0, así que un aviso nuevo es un error y no una deuda
# que se acumula sin que nadie la mire.
step "SwiftLint (BLOQUEANTE: --strict, cero avisos)"
if command -v swiftlint >/dev/null; then
  lint_log=$(mktemp -t krabzik-lint)
  swiftlint lint --strict --quiet > "$lint_log" 2>&1
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
  # Resumen por regla en vez de volcar el log entero en cada corrida.
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
    swiftformat --lint . 2>&1 | grep -E "^/" | head -5 | sed 's|.*Braket/||' | sed 's/^/      /'
  fi
else
  skip "swiftformat no está instalado (brew install swiftformat)" "swiftformat"
fi

# ----------------------------------------------------------------------- vendor
step "Integridad del vendoring (BLOQUEANTE · necesita red)"
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
  mkdir -p .build/Logs/Verification
  log=$(mktemp "$PWD/.build/Logs/Verification/xcodebuild.XXXXXX")
  signing_args=()
  if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    # Los runners no tienen certificados privados; XCTest admite firma ad hoc.
    # Esta excepción solo afecta al comando de pruebas, nunca a una distribución.
    signing_args=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual)
  fi
  # Tope por prueba: un diálogo modal que se cuele en una prueba cuelga la corrida
  # indefinidamente. Con el tope falla en 2 minutos y dice cuál fue.
  if xcodebuild -project Braket.xcodeproj -scheme Braket -destination 'platform=macOS' \
       -derivedDataPath .build -parallel-testing-enabled NO \
       -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
       -maximum-test-execution-time-allowance 300 "${signing_args[@]}" test > "$log" 2>&1; then
    ok "$(grep -E 'Executed [0-9]+ tests' "$log" | tail -1 | sed 's/^[[:space:]]*//')"
  else
    fail "las pruebas no pasaron; log en $log"
    # Incluye errores de firma, resolución de paquetes y compilación con columna.
    # El final conserva contexto incluso cuando Xcode usa otro formato de error.
    info "Errores detectados:"
    grep -E "error:|' failed \(|Testing failed:|TEST FAILED" "$log" \
      | sed -n '1,30p' | sed 's/^/      /'
    info "Últimas 60 líneas de xcodebuild (log completo en el artefacto logs de CI):"
    tail -60 "$log" | sed 's/^/      /'
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
