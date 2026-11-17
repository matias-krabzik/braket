#!/bin/zsh
# Corre los casos de QA de la interfaz desde la terminal.
#
# El catálogo está en KrabzikTests/QA/cases.json y es la fuente única: cada caso dice qué
# hace el usuario, qué tiene que pasar, y cuál es la prueba que lo ejercita. Cada prueba
# monta la interfaz de verdad, usa los controles por su identificador y afirma la reacción
# que quedó en el registro de QA (.build/qa/logs/*.ndjson).
#
# Uso:
#   scripts/qa.sh                      corre todos los casos automatizados
#   scripts/qa.sh --list               lista el catálogo entero y sale
#   scripts/qa.sh --suite SQL,GRI      solo esas suites
#   scripts/qa.sh --case GRI-06        solo ese caso
#   scripts/qa.sh --tag needs-mysql    solo los que necesitan el MySQL desechable
#   scripts/qa.sh --mysql              levanta el MySQL desechable y lo apaga al terminar
#   scripts/qa.sh --json informe.json  además, informe legible por máquina
#   scripts/qa.sh --no-build           no recompilar (usa lo que ya está en .build)
#
# Ver docs/qa-automation.md.
set -uo pipefail
cd "${0:A:h:h}"

list_only=false
with_mysql=false
build=true
json_out=""
filters=()

while (( $# )); do
  case "$1" in
    --list) list_only=true; shift ;;
    --suite|--case|--tag|--skip-tag) filters+=("$1" "$2"); shift 2 ;;
    --pending|--automated) filters+=("$1"); shift ;;
    --mysql) with_mysql=true; shift ;;
    --no-build) build=false; shift ;;
    --json) json_out="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 "opción desconocida: $1 (probá --help)"; exit 2 ;;
  esac
done

if $list_only; then
  python3 scripts/qa_report.py list "${filters[@]}"
  exit $?
fi

# Sin --tag explícito no se piden los casos que necesitan servidor, salvo que haya uno.
if ! $with_mysql && [[ ! -f .build/mysql-test-port ]]; then
  has_tag=false
  for argument in "${filters[@]}"; do [[ "$argument" == "--tag" ]] && has_tag=true; done
  $has_tag || print -- "· sin MySQL desechable: los casos needs-mysql se van a omitir"
fi

container="braket-qa-mysql"
cleanup_mysql() {
  docker stop "$container" >/dev/null 2>&1
  rm -f .build/mysql-test-port
}

if $with_mysql; then
  command -v docker >/dev/null || { print -u2 "docker no está instalado"; exit 2 }
  print -- "· levantando MySQL desechable (tmpfs, se borra al apagarlo)"
  docker rm -f "$container" >/dev/null 2>&1
  mkdir -p .build
  docker run -d --rm --name "$container" -p 127.0.0.1:23307:3306 --tmpfs /var/lib/mysql \
    -e MYSQL_ALLOW_EMPTY_PASSWORD=yes -e MYSQL_DATABASE=krabzik_qa mysql:8.4 >/dev/null || exit 2
  trap cleanup_mysql EXIT INT TERM
  for _ in {1..60}; do
    docker exec "$container" mysqladmin ping -uroot >/dev/null 2>&1 && break
    sleep 2
  done
  if ! docker exec "$container" mysqladmin ping -uroot >/dev/null 2>&1; then
    print -u2 "el MySQL desechable no respondió a tiempo"
    exit 2
  fi
  printf '23307\n' > .build/mysql-test-port
  print -- "· MySQL desechable listo en 127.0.0.1:23307"
fi

only_testing=("${(@f)$(python3 scripts/qa_report.py select "${filters[@]}")}")
if (( ${#only_testing} == 0 )) || [[ -z "${only_testing[1]}" ]]; then
  print -u2 "ningún caso automatizado coincide con el filtro"
  exit 3
fi

mkdir -p .build/qa/logs
rm -f .build/qa/logs/*.ndjson(N)
log=".build/qa/xcodebuild.log"
action=(test)
$build || action=(test-without-building)

print -- "· corriendo ${#only_testing} prueba(s) · log completo en $log"
xcodebuild -project Braket.xcodeproj -scheme Braket -destination 'platform=macOS' \
  -derivedDataPath .build -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
  -maximum-test-execution-time-allowance 300 \
  "${only_testing[@]}" "${action[@]}" > "$log" 2>&1
run_status=$?

if (( run_status != 0 )) && ! grep -q "Test Case '-\[" "$log"; then
  print -u2 "\nno se pudo compilar o arrancar la suite:"
  grep -E "error:|Testing failed:" "$log" | head -20 | sed 's/^/      /'
  exit 1
fi

python3 scripts/qa_report.py report "$log" "${filters[@]}"
report=$?

if [[ -n "$json_out" ]]; then
  python3 - "$log" "$json_out" "${filters[@]}" <<'PY'
import json, re, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
log, destination, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
import importlib.util
spec = importlib.util.spec_from_file_location('qa_report', Path('scripts/qa_report.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
suites, cases = module.load()
filters, _ = module.parse_filters(rest)
text = Path(log).read_text(errors='replace')
results = {}
for klass, method, state in module.RESULT.findall(text):
    results.setdefault('%s/%s' % (klass, method), state)
payload = []
for item in module.selected(cases, filters):
    state = 'pendiente' if not item['test'] else {
        'passed': 'ok', 'failed': 'fallo', 'skipped': 'omitido'}.get(results.get(item['test']), 'no corrió')
    payload.append({'id': item['id'], 'suite': item['suite'], 'title': item['title'],
                    'test': item['test'], 'tags': item['tags'], 'state': state})
Path(destination).write_text(json.dumps({'cases': payload}, ensure_ascii=False, indent=2) + '\n')
print('· informe JSON en ' + destination)
PY
fi

exit $report
