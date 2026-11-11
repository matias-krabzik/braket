#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"

identity='Developer ID Application: MATIAS IVAN KRABZIK (6P3J382F8G)'
team='6P3J382F8G'
profile="${BRAKET_NOTARY_PROFILE:-Braket}"

check_profile() {
  if ! xcrun notarytool history --keychain-profile "$profile" >/dev/null; then
    print -u2 "No se pudo usar el perfil de notarización '$profile'."
    print -u2 'Ejecutá scripts/notarize.sh setup o comprobá la conexión con Apple.'
    exit 1
  fi
}

usage() {
  print 'Uso:'
  print '  scripts/notarize.sh setup                 Guarda credenciales en el llavero (una vez)'
  print '  scripts/notarize.sh                       Firma y notariza la app Release'
  print '  scripts/notarize.sh release <notas.md>    Además prepara el ZIP y appcast'
  print 'Perfil de llavero: BRAKET_NOTARY_PROFILE (predeterminado: Braket)'
}

case "${1:-notarize}" in
  setup)
    if (( $# != 1 )); then usage; exit 2; fi
    print -n 'Apple ID de la cuenta desarrolladora: '
    read -r apple_id
    if [[ -z "$apple_id" ]]; then
      print -u2 'Falta el Apple ID.'
      exit 2
    fi
    print 'notarytool pedirá la contraseña específica de app de forma segura.'
    xcrun notarytool store-credentials "$profile" --apple-id "$apple_id" --team-id "$team"
    ;;
  notarize)
    if (( $# > 1 )); then usage; exit 2; fi
    check_profile
    python3 scripts/release_updates.py --identity "$identity" --team "$team" \
      --notary-profile "$profile" --notarize-only
    ;;
  release)
    if (( $# != 2 )); then usage; exit 2; fi
    check_profile
    feed='/Users/mati/Projects/Webs/krabzik.com/public/apps/krabzik-ide/appcast.xml'
    python3 scripts/release_updates.py --identity "$identity" --team "$team" \
      --notary-profile "$profile" --notes "$2" --previous-feed "$feed"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
