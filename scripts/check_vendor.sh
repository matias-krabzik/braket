#!/bin/zsh
# Comprueba que Vendor/MySQLNIO sea exactamente upstream + patches/*.patch
# (docs/specs/S7-gobernanza-fork-mysqlnio.md).
#
# Las fuentes aplicadas se versionan igual, para que el proyecto compile sin pasos
# previos. Los parches son para poder rebasar: si alguien edita el vendoring sin
# agregar su parche, este script dice qué archivo y el cambio queda sin motivo escrito.
#
# Necesita red (clona el tag de upstream). Para saltarlo localmente:
#   KRABZIK_SKIP_VENDOR_CHECK=1 scripts/check_vendor.sh
set -uo pipefail
cd "${0:A:h:h}"

if [[ -n "${KRABZIK_SKIP_VENDOR_CHECK:-}" ]]; then
  print -- "omitido por KRABZIK_SKIP_VENDOR_CHECK"
  exit 0
fi

vendor=Vendor/MySQLNIO
# Un solo lugar donde cambiar la versión: la primera línea de UPSTREAM.md.
line=$(grep -m1 '^Source:' "$vendor/UPSTREAM.md")
repo=$(print -- "$line" | sed -n 's|.*(\(https://github.com/[^/]*/[^/]*\)/releases.*|\1|p')
tag=$(print -- "$line" | sed -n 's|.*/releases/tag/\([^)]*\)).*|\1|p')
commit=$(print -- "$line" | sed -n 's|.*commit `\([0-9a-f]*\)`.*|\1|p')
if [[ -z "$repo" || -z "$tag" || -z "$commit" ]]; then
  print -- "✗ no se pudo leer repo/tag/commit de $vendor/UPSTREAM.md"
  exit 1
fi

work=$(mktemp -d -t krabzik-vendor)
trap "rm -rf $work" EXIT INT TERM
print -- "upstream: $repo $tag ($commit)"
if ! git clone --quiet --depth 1 --branch "$tag" "$repo" "$work/upstream" 2>/dev/null; then
  print -- "✗ no se pudo clonar $repo en $tag (¿sin red?)"
  exit 1
fi

got=$(git -C "$work/upstream" rev-parse --short=7 HEAD)
if [[ "$got" != "${commit:0:7}" ]]; then
  print -- "✗ el tag $tag apunta a $got y UPSTREAM.md declara $commit"
  exit 1
fi

for patch in "$vendor"/patches/*.patch; do
  if ! git -C "$work/upstream" apply --whitespace=nowarn "$(cd "$(dirname "$patch")" && pwd)/$(basename "$patch")"; then
    print -- "✗ no se pudo aplicar ${patch:t} sobre upstream limpio"
    exit 1
  fi
done

# Upstream trae Tests/ y README.md, que este vendoring no incluye a propósito.
failures=0
for f in Package.swift $(cd "$vendor" && find Sources -name '*.swift' | sort); do
  if ! diff -q "$work/upstream/$f" "$vendor/$f" > /dev/null 2>&1; then
    print -- "✗ $f no coincide con upstream + parches"
    failures=$((failures + 1))
  fi
done

# Y al revés: un archivo del vendoring que upstream no tiene y ningún parche crea.
for f in $(cd "$work/upstream" && find Sources -name '*.swift' | sort); do
  if [[ ! -f "$vendor/$f" ]]; then
    print -- "✗ falta $f en el vendoring (upstream lo trae)"
    failures=$((failures + 1))
  fi
done

if (( failures )); then
  print -- "\n$failures archivo(s) editados sin parche. Generá el parche con:"
  print -- "  git -C <clon-de-upstream> diff > $vendor/patches/NNNN-motivo.patch"
  exit 1
fi
print -- "✓ el vendoring es upstream + $(ls "$vendor"/patches/*.patch | wc -l | tr -d ' ') parches"
