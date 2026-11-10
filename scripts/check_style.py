#!/usr/bin/env python3
"""Cuenta las líneas con más de una sentencia Swift, ignorando el contenido de las cadenas.

El chequeo anterior era `grep '; '`, que no distingue una sentencia de un `;` dentro de un
literal: media docena de pruebas tienen SQL o Python con punto y coma, y SQL sin punto y
coma no es SQL. Este script salta cadenas —normales, multilínea y crudas— y comentarios, y
después busca el separador. Ver docs/specs/C4-legibilidad.md.

Uso: python3 scripts/check_style.py [rutas…]
Imprime una línea por hallazgo y devuelve 1 si encontró alguno.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT = ['Krabzik', 'KrabzikTests']

# Apertura de cadena multilínea: """ con cualquier cantidad de # delante.
MULTILINE = re.compile(r'(#*)"""')


def strip_strings(line: str) -> str:
    """Devuelve la línea sin el contenido de sus cadenas ni su comentario final."""
    out, index, length = [], 0, len(line)
    while index < length:
        char = line[index]
        # Comentario de línea, fuera de cadena.
        if line.startswith('//', index):
            break
        # Cadena cruda: #"…"# con tantos # como abra.
        if char == '#':
            hashes = 0
            while index + hashes < length and line[index + hashes] == '#':
                hashes += 1
            if line.startswith('"', index + hashes):
                closing = '"' + '#' * hashes
                end = line.find(closing, index + hashes + 1)
                index = length if end < 0 else end + len(closing)
                continue
        if char == '"':
            index += 1
            while index < length:
                if line[index] == '\\':
                    index += 2
                    continue
                if line[index] == '"':
                    index += 1
                    break
                index += 1
            continue
        out.append(char)
        index += 1
    return ''.join(out)


def findings(path: Path) -> list[str]:
    found: list[str] = []
    inside_multiline = False
    for number, raw in enumerate(path.read_text(errors='replace').split('\n'), start=1):
        # Las cadenas multilínea se saltan enteras: su contenido no es código.
        delimiters = len(MULTILINE.findall(raw))
        if inside_multiline:
            if delimiters:
                inside_multiline = False
            continue
        if delimiters % 2 == 1:
            inside_multiline = True
            continue
        code = strip_strings(raw)
        if ';' in code.rstrip().rstrip(';'):
            found.append(f'{path.relative_to(ROOT)}:{number}: más de una sentencia en la línea')
    return found


def main(argv: list[str]) -> int:
    targets = argv or DEFAULT
    found: list[str] = []
    for target in targets:
        for path in sorted((ROOT / target).rglob('*.swift')):
            found += findings(path)
    for line in found:
        print(line)
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
