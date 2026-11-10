#!/usr/bin/env python3
"""Comprueba que el proyecto no se separe de lo que declara docs/security.md.

El ADR (spec S6) afirma tres ajustes del target y la ausencia de excepciones al
hardened runtime. Si el proyecto cambia sin actualizar el documento, uno de los dos
miente: este chequeo falla y hay que decidir cuál se corrige.

Uso: python3 scripts/check_security_posture.py
Devuelve 0 si todo coincide, 1 con el detalle en stdout si no.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ADR = ROOT / 'docs' / 'security.md'
GENERATOR = ROOT / 'scripts' / 'generate_project.py'

# Lo que docs/security.md declara, sección «Qué sí está activo» y «Alcance de la distribución».
DECLARED = {
    'ENABLE_APP_SANDBOX': 'NO',
    'ENABLE_HARDENED_RUNTIME': 'YES',
    'CODE_SIGN_IDENTITY': '-',
}

# Excepciones que el ADR prohíbe. Se buscan en código y configuración, no en los .md:
# el ADR y el spec S6 las nombran justamente para prohibirlas.
FORBIDDEN = ('disable-library-validation', 'allow-unsigned-executable-memory')
SEARCHED = ('*.py', '*.swift', '*.plist', '*.entitlements')


def deviations() -> list[str]:
    if not ADR.is_file():
        return ['falta docs/security.md: la postura de seguridad tiene que estar escrita (S6)']
    found: list[str] = []
    source = GENERATOR.read_text()
    for key, value in DECLARED.items():
        match = re.search(r"'%s': '([^']*)'" % key, source)
        if match is None:
            found.append(f'{key} ya no aparece en generate_project.py')
        elif match.group(1) != value:
            found.append(f'{key} = {match.group(1)}, y docs/security.md declara {value}')
    for directory in ('Krabzik', 'scripts'):
        for pattern in SEARCHED:
            for path in sorted((ROOT / directory).rglob(pattern)):
                if path == Path(__file__).resolve():
                    continue
                text = path.read_text(errors='replace')
                for name in FORBIDDEN:
                    if name in text:
                        found.append(f'excepción al hardened runtime en {path.relative_to(ROOT)}: {name}')
    return found


def main() -> int:
    found = deviations()
    for line in found:
        print(line)
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main())
