#!/usr/bin/env python3
"""Explicit, resumable release steps for Braket's automation panel. No installation."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
VERSION_FILES = ['scripts/generate_project.py', 'Braket.xcodeproj/project.pbxproj']


def run(*args, cwd=ROOT, capture=False):
    print('+', ' '.join(map(str, args)), flush=True)
    result = subprocess.run(list(map(str, args)), cwd=cwd, text=True,
                            stdout=subprocess.PIPE if capture else None)
    if result.returncode != 0:
        if capture and result.stdout:
            print(result.stdout, file=sys.stderr, flush=True)
        result.check_returncode()
    return result.stdout.strip() if capture else None


def atomic_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def increment(version, kind):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or kind not in ('patch', 'minor', 'major'):
        raise ValueError('INCREMENT debe ser patch, minor o major y la versión debe ser x.y.z.')
    parts = list(map(int, version.split('.')))
    index = {'major': 0, 'minor': 1, 'patch': 2}[kind]
    parts[index] += 1
    for subsequent in range(index + 1, 3):
        parts[subsequent] = 0
    return '.'.join(map(str, parts))


def versions(text):
    return tuple(re.search(rf"^{key} = '([^']+)'$", text, re.M)[1]
                 for key in ('MARKETING_VERSION', 'BUILD_NUMBER'))


def dirty(repo):
    # -z avoids ambiguous quoting and filenames containing newlines.
    raw = subprocess.check_output(['git', 'status', '--porcelain=v1', '-z', '--untracked-files=all'], cwd=repo)
    entries = raw.decode().split('\0')
    paths = []
    index = 0
    while index < len(entries) and entries[index]:
        entry = entries[index]
        paths.append(entry[3:])
        if 'R' in entry[:2] or 'C' in entry[:2]:
            index += 1
            paths.append(entries[index])
        index += 1
    return set(paths)


class Release:
    def __init__(self):
        self.directory = Path(os.environ['BRAKET_RUN_DIR']).resolve()
        self.manifest = self.directory / 'release.json'
        self.state = json.loads(self.manifest.read_text()) if self.manifest.exists() else {}
        self.inputs = {key: os.environ.get('BRAKET_INPUT_' + key, '') for key in
                       ('INCREMENT', 'IDENTITY', 'TEAM', 'NOTARY_PROFILE', 'SITE_REPO', 'NOTES', 'BRANCH')}
        if self.state and self.state.get('inputs') != self.inputs:
            raise ValueError('Los parámetros cambiaron respecto de esta ejecución.')

    def save(self):
        atomic_json(self.manifest, self.state)

    @property
    def site(self):
        if not self.inputs['SITE_REPO']:
            raise ValueError('Completá SITE_REPO con la carpeta de krabzik.com.')
        return Path(self.inputs['SITE_REPO']).expanduser().resolve()

    @property
    def app(self):
        return self.directory / 'export/Braket.app'

    def require(self, key):
        if not self.state.get(key):
            raise ValueError('Falta completar el paso anterior: ' + key)

    def check(self):
        if self.state:
            return
        identity, team = self.inputs['IDENTITY'], self.inputs['TEAM']
        if not identity.startswith('Developer ID Application:') or not re.fullmatch('[A-Z0-9]{10}', team):
            raise ValueError('Identidad Developer ID o equipo inválidos.')
        for repo in (ROOT, self.site):
            changes = dirty(repo)
            if changes:
                details = '\n'.join('  • ' + path for path in sorted(changes))
                raise ValueError(f'No se puede publicar: hay {len(changes)} archivos con cambios sin commit.\n'
                                 f'Repositorio: {repo}\n{details}\n'
                                 'Revisá los cambios y creá un commit antes de reintentar este paso.')
            branch = run('git', 'branch', '--show-current', cwd=repo, capture=True)
            if branch != self.inputs['BRANCH']:
                raise ValueError(f'{repo}: la rama debe ser {self.inputs["BRANCH"]}.')
            run('git', 'remote', 'get-url', 'origin', cwd=repo)
        notes = Path(self.inputs['NOTES']).expanduser()
        if not notes.is_file() or not notes.read_text().strip():
            raise ValueError('NOTES debe apuntar a un archivo de notas no vacío.')
        if not (self.site / 'public/apps/krabzik-ide/appcast.xml').is_file():
            raise ValueError('No se encontró el catálogo de actualizaciones en SITE_REPO.')
        run('xcrun', 'notarytool', 'history', '--keychain-profile', self.inputs['NOTARY_PROFILE'],
            '--output-format', 'json', capture=True)
        original = versions((ROOT / VERSION_FILES[0]).read_text())
        target = (increment(original[0], self.inputs['INCREMENT']), str(int(original[1]) + 1))
        shutil.copyfile(notes, self.directory / 'notes.md')
        self.state = {'inputs': self.inputs, 'original': original, 'target': target, 'checked': True,
                      'codeHead': run('git', 'rev-parse', 'HEAD', capture=True),
                      'siteHead': run('git', 'rev-parse', 'HEAD', cwd=self.site, capture=True)}
        self.save()

    def version(self):
        self.require('checked')
        path = ROOT / VERSION_FILES[0]
        text = path.read_text()
        current = list(versions(text))
        if current not in (self.state['original'], self.state['target']):
            raise ValueError('La versión cambió fuera de esta ejecución.')
        if dirty(ROOT) - set(VERSION_FILES):
            raise ValueError('Hay cambios ajenos a la versión; revisalos antes de continuar.')
        for key, value in zip(('MARKETING_VERSION', 'BUILD_NUMBER'), self.state['target']):
            text = re.sub(rf"^{key} = '[^']+'$", f"{key} = '{value}'", text, flags=re.M)
        path.write_text(text)
        run('python3', ROOT / 'scripts/generate_project.py')
        self.state['versioned'] = True
        self.save()

    def archive(self):
        self.require('versioned')
        if list(versions((ROOT / VERSION_FILES[0]).read_text())) != self.state['target']:
            raise ValueError('La versión cambió desde el incremento.')
        if dirty(ROOT) - set(VERSION_FILES):
            raise ValueError('El código cambió después de comenzar la publicación.')
        archive = self.directory / 'Braket.xcarchive'
        # Reuse a completed archive; never replace a binary that was already submitted.
        if self.state.get('archived'):
            run('codesign', '--verify', '--deep', '--strict', self.app)
            return
        run('xcodebuild', '-project', 'Braket.xcodeproj', '-scheme', 'Braket', '-configuration', 'Release',
            '-destination', 'generic/platform=macOS', '-derivedDataPath', '.build', '-archivePath', archive,
            'CODE_SIGN_IDENTITY=' + self.inputs['IDENTITY'], 'DEVELOPMENT_TEAM=' + self.inputs['TEAM'],
            'CODE_SIGN_STYLE=Manual', 'OTHER_CODE_SIGN_FLAGS=--timestamp', 'archive')
        options = self.directory / 'ExportOptions.plist'
        options.write_bytes(plistlib.dumps({'method': 'developer-id', 'teamID': self.inputs['TEAM'],
                                           'signingStyle': 'manual', 'signingCertificate': self.inputs['IDENTITY']}))
        run('xcodebuild', '-exportArchive', '-archivePath', archive, '-exportPath', self.app.parent,
            '-exportOptionsPlist', options)
        run('codesign', '--verify', '--deep', '--strict', self.app)
        self.state['archived'] = True
        self.save()

    def notarize(self):
        self.require('archived')
        profile = self.inputs['NOTARY_PROFILE']
        if not self.state.get('submission'):
            upload = self.directory / 'notarization.zip'
            run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', self.app, upload)
            result = json.loads(run('xcrun', 'notarytool', 'submit', upload, '--keychain-profile', profile,
                                    '--output-format', 'json', capture=True))
            self.state['submission'] = result['id']
            self.save()
        result = json.loads(run('xcrun', 'notarytool', 'wait', self.state['submission'],
                                '--keychain-profile', profile, '--output-format', 'json', capture=True))
        if result.get('status') != 'Accepted':
            raise ValueError('Apple no aceptó la app. Revisá el log de notarytool: ' + self.state['submission'])
        run('xcrun', 'stapler', 'staple', self.app)
        run('xcrun', 'stapler', 'validate', self.app)
        run('spctl', '--assess', '--type', 'execute', self.app)
        self.state['notarized'] = True
        self.save()

    def package(self):
        self.require('notarized')
        if self.state.get('public'):
            return
        output = run('python3', 'scripts/release_updates.py', '--identity', self.inputs['IDENTITY'],
                     '--team', self.inputs['TEAM'], '--notarized-app', self.app,
                     '--notes', self.directory / 'notes.md', '--previous-feed',
                     self.site / 'public/apps/krabzik-ide/appcast.xml', capture=True)
        print(output, flush=True)
        match = re.search(r'^Release verificada y preparada en: (.+)$', output, re.M)
        if not match:
            raise ValueError('El empaquetador no devolvió el directorio de publicación.')
        self.state['public'] = match[1]
        self.save()

    def push(self, repo, paths, key, original):
        branch = self.inputs['BRANCH']
        if run('git', 'branch', '--show-current', cwd=repo, capture=True) != branch:
            raise ValueError('La rama cambió durante la publicación.')
        unexpected = dirty(repo) - set(paths)
        if unexpected:
            raise ValueError('Hay cambios ajenos a la publicación: ' + ', '.join(sorted(unexpected)))
        head = run('git', 'rev-parse', 'HEAD', cwd=repo, capture=True)
        message = 'Release Braket ' + self.state['target'][0] + '\n\nBraket-Run: ' + self.directory.name
        if not self.state.get(key):
            # A crash between commit and checkpoint must not create a second commit.
            if head != self.state[original]:
                previous = run('git', 'log', '-1', '--format=%B', cwd=repo, capture=True)
                parent = run('git', 'rev-parse', 'HEAD^', cwd=repo, capture=True)
                if previous != message or parent != self.state[original]:
                    raise ValueError('HEAD cambió fuera de esta ejecución.')
            else:
                run('git', 'add', '--', *paths, cwd=repo)
                run('git', 'commit', '-m', message, cwd=repo)
                head = run('git', 'rev-parse', 'HEAD', cwd=repo, capture=True)
            self.state[key] = head
            self.save()
        if head != self.state[key] or dirty(repo):
            raise ValueError('El repositorio cambió desde el commit de publicación.')
        run('git', 'push', 'origin', 'HEAD:refs/heads/' + branch, cwd=repo)
        remote = run('git', 'ls-remote', 'origin', 'refs/heads/' + branch, cwd=repo, capture=True).split()
        if not remote or remote[0] != head:
            raise ValueError('No se pudo verificar el commit remoto.')

    def push_code(self):
        self.require('public')
        self.push(ROOT, VERSION_FILES, 'codeCommit', 'codeHead')
        self.state['codePushed'] = True
        self.save()

    def push_site(self):
        self.require('codePushed')
        public = Path(self.state['public'])
        paths = ['public/' + str(path.relative_to(public)) for path in public.rglob('*') if path.is_file()]
        paths.append('src/data/braket-release.json')
        if dirty(self.site) - set(paths):
            raise ValueError('El sitio tiene cambios ajenos a la publicación.')
        if not self.state.get('sitePrepared'):
            for source in public.rglob('*'):
                if source.is_file():
                    target = self.site / 'public' / source.relative_to(public)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, target)
            version = self.state['target'][0]
            package = public / f'downloads/krabzik-ide/{version}/Braket-{version}-macos-universal.zip'
            data_file = self.site / 'src/data/braket-release.json'
            data = json.loads(data_file.read_text())
            data.update(version=version, date=datetime.date.today().isoformat(), filename=package.name,
                        url=f'/downloads/krabzik-ide/{version}/{package.name}', sizeBytes=package.stat().st_size,
                        sha256=hashlib.sha256(package.read_bytes()).hexdigest(),
                        notes=[line.strip().lstrip('- ').strip() for line in
                               (self.directory / 'notes.md').read_text().splitlines() if line.strip()])
            atomic_json(data_file, data)
            self.state['sitePrepared'] = True
            self.save()
        run('npm', 'run', 'build', cwd=self.site)
        self.push(self.site, paths, 'siteCommit', 'siteHead')
        print('Código y sitio enviados a GitHub. El despliegue de Vercel continúa por separado.', flush=True)

    def outputs(self):
        atomic_json(Path(os.environ['BRAKET_OUTPUT_FILE']), {
            'VERSION': self.state['target'][0], 'BUILD': self.state['target'][1],
            'RELEASE_DIR': str(self.directory), 'PUBLIC_DIR': self.state.get('public', '')})


def main():
    actions = ('check', 'version', 'archive', 'notarize', 'package', 'push-code', 'push-site')
    if len(sys.argv) != 2 or sys.argv[1] not in actions:
        raise ValueError('Elegí un paso: ' + ', '.join(actions))
    release = Release()
    getattr(release, sys.argv[1].replace('-', '_'))()
    release.outputs()


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, KeyError) as error:
        sys.exit(str(error))
