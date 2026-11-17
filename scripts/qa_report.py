#!/usr/bin/env python3
"""Catálogo de casos de QA de la interfaz: listarlos, elegir cuáles correr, informar.

Lo usa scripts/qa.sh, que es la puerta de entrada. Acá no se compila ni se ejecuta nada:
este script solo lee KrabzikTests/QA/cases.json y la salida de xcodebuild.

Uso:
    qa_report.py list   [filtros]            tabla del catálogo
    qa_report.py select [filtros]            imprime los -only-testing: que hay que correr
    qa_report.py report LOG [filtros]        informe por caso; devuelve 1 si algo falló

Filtros: --suite A,B  --case ID,ID  --tag T  --skip-tag T  --pending  --automated
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / 'KrabzikTests/QA/cases.json'
BUNDLE = 'KrabzikTests'
LOGS = ROOT / '.build/qa/logs'

GREEN, RED, YELLOW, GREY, BOLD, OFF = '\033[32m', '\033[31m', '\033[33m', '\033[90m', '\033[1m', '\033[0m'

# Una línea por prueba en la salida de xcodebuild: clase, método y resultado.
RESULT = re.compile(r"Test Case '-\[\w+\.(\w+) (\w+)\]' (passed|failed|skipped)")
SKIP_REASON = re.compile(r"-\[\w+\.(\w+) (\w+)\] : Test skipped - (.*)$")


def load():
    data = json.loads(CATALOG.read_text())
    return data['suites'], data['cases']


def parse_filters(argv):
    filters = {'suite': None, 'case': None, 'tag': None, 'skip_tag': None,
               'pending': False, 'automated': False}
    rest = []
    index = 0
    while index < len(argv):
        token = argv[index]
        if token in ('--suite', '--case', '--tag', '--skip-tag'):
            if index + 1 >= len(argv):
                sys.exit('falta el valor de ' + token)
            key = token[2:].replace('-', '_')
            filters[key] = [value.strip().upper() for value in argv[index + 1].split(',') if value.strip()]
            index += 2
            continue
        if token == '--pending':
            filters['pending'] = True
        elif token == '--automated':
            filters['automated'] = True
        else:
            rest.append(token)
        index += 1
    return filters, rest


def selected(cases, filters):
    out = []
    for item in cases:
        if filters['suite'] and item['suite'].upper() not in filters['suite']:
            continue
        if filters['case'] and item['id'].upper() not in filters['case']:
            continue
        if filters['tag'] and not any(tag.upper() in filters['tag'] for tag in item['tags']):
            continue
        if filters['skip_tag'] and any(tag.upper() in filters['skip_tag'] for tag in item['tags']):
            continue
        if filters['pending'] and item['test']:
            continue
        if filters['automated'] and not item['test']:
            continue
        out.append(item)
    return out


def command_list(cases, suites, filters):
    chosen = selected(cases, filters)
    suite = None
    for item in chosen:
        if item['suite'] != suite:
            suite = item['suite']
            print('\n%s%s · %s%s' % (BOLD, suite, suites[suite], OFF))
        state = ('%sautomatizado%s' % (GREEN, OFF)) if item['test'] else ('%spendiente%s   ' % (YELLOW, OFF))
        tags = ('  [%s]' % ' '.join(item['tags'])) if item['tags'] else ''
        print('  %-7s %s  %s%s' % (item['id'], state, item['title'], tags))
        for step in item['steps']:
            print('          %s· %s%s' % (GREY, step, OFF))
        for expect in item['expect']:
            print('          %s→ %s%s' % (GREY, expect, OFF))
    automated = [item for item in chosen if item['test']]
    print('\n%d casos · %d automatizados · %d pendientes' %
          (len(chosen), len(automated), len(chosen) - len(automated)))
    return 0


def command_select(cases, filters):
    tests = []
    for item in selected(cases, filters):
        if item['test'] and item['test'] not in tests:
            tests.append(item['test'])
    for test in tests:
        print('-only-testing:%s/%s' % (BUNDLE, test))
    return 0 if tests else 3


def command_report(cases, suites, filters, log_path):
    text = Path(log_path).read_text(errors='replace')
    results, reasons = {}, {}
    for klass, method, state in RESULT.findall(text):
        key = '%s/%s' % (klass, method)
        # Un reintento deja dos líneas: queda el peor resultado.
        order = {'passed': 0, 'skipped': 1, 'failed': 2}
        if key not in results or order[state] > order[results[key]]:
            results[key] = state
    for klass, method, reason in SKIP_REASON.findall(text):
        reasons['%s/%s' % (klass, method)] = reason.strip()

    chosen = selected(cases, filters)
    counts = {'ok': 0, 'fallo': 0, 'omitido': 0, 'no corrió': 0, 'pendiente': 0}
    suite = None
    for item in chosen:
        if item['suite'] != suite:
            suite = item['suite']
            print('\n%s%s · %s%s' % (BOLD, suite, suites[suite], OFF))
        if not item['test']:
            state, colour, note = 'pendiente', YELLOW, 'sin automatizar'
        else:
            raw = results.get(item['test'])
            if raw == 'passed':
                state, colour, note = 'ok', GREEN, ''
            elif raw == 'failed':
                state, colour, note = 'fallo', RED, item['test']
            elif raw == 'skipped':
                state, colour, note = 'omitido', GREY, reasons.get(item['test'], '')
            else:
                state, colour, note = 'no corrió', YELLOW, item['test']
        counts[state] += 1
        print('  %s%-9s%s %-7s %s%s' % (colour, state, OFF, item['id'], item['title'],
                                        ('  %s%s%s' % (GREY, note, OFF)) if note else ''))
        if state == 'fallo':
            log = LOGS / (item['test'].replace('/', '.') + '.ndjson')
            if log.is_file():
                print('            %slínea de tiempo: %s%s' % (GREY, log.relative_to(ROOT), OFF))

    print('\n%sResumen%s' % (BOLD, OFF))
    print('  ' + ' · '.join('%s %d' % (name, value) for name, value in counts.items() if value))
    if counts['fallo']:
        print('  %s%d caso(s) fallaron%s' % (RED, counts['fallo'], OFF))
        return 1
    print('  %stodo en verde%s' % (GREEN, OFF))
    return 0


def main(argv):
    if not argv:
        sys.exit(__doc__)
    command, rest = argv[0], argv[1:]
    suites, cases = load()
    if command == 'report':
        if not rest:
            sys.exit('falta el log de xcodebuild')
        log_path, rest = rest[0], rest[1:]
        filters, _ = parse_filters(rest)
        return command_report(cases, suites, filters, log_path)
    filters, _ = parse_filters(rest)
    if command == 'list':
        return command_list(cases, suites, filters)
    if command == 'select':
        return command_select(cases, filters)
    sys.exit('comando desconocido: ' + command)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
