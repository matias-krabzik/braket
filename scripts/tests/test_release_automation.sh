#!/bin/zsh
set -eu
cd "${0:A:h:h:h}"
python3 - <<'PY'
import contextlib
import io
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('release_automation', 'scripts/release_automation.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
captured = io.StringIO()
with contextlib.redirect_stderr(captured):
    try:
        m.run('python3', '-c', "print('diagnóstico del proceso'); raise SystemExit(1)", capture=True)
        raise AssertionError('failed subprocess accepted')
    except subprocess.CalledProcessError:
        pass
assert 'diagnóstico del proceso' in captured.getvalue(), 'captured failure output was lost'
assert m.increment('1.2.3', 'patch') == '1.2.4'
assert m.increment('1.2.3', 'minor') == '1.3.0'
assert m.increment('1.2.3', 'major') == '2.0.0'
try:
    m.increment('1.2.3', 'bad')
    raise AssertionError('invalid increment accepted')
except ValueError:
    pass
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    subprocess.run(['git', 'init', '-q', str(root)], check=True)
    (root / 'file with spaces').write_text('a')
    assert m.dirty(root) == {'file with spaces'}
    (root / 'file with spaces').unlink()
    (root / 'scripts').mkdir()
    generator = root / m.VERSION_FILES[0]
    generator.write_text("MARKETING_VERSION = '1.2.3'\nBUILD_NUMBER = '8'\n")
    state = root / 'state'
    state.mkdir()
    with patch.dict(os.environ, {'BRAKET_RUN_DIR': str(state)}):
        release = m.Release()
        release.state = {'checked': True, 'original': ['1.2.3', '8'], 'target': ['1.2.4', '9']}
        with patch.object(m, 'ROOT', root), patch.object(m, 'dirty', return_value=set(m.VERSION_FILES)), patch.object(m, 'run'):
            release.version()
            release.version()
        assert m.versions(generator.read_text()) == ('1.2.4', '9'), 'retry incremented twice'
        generator.write_text("MARKETING_VERSION = '9.0.0'\nBUILD_NUMBER = '99'\n")
        with patch.object(m, 'ROOT', root):
            try:
                release.version()
                raise AssertionError('external version change accepted')
            except ValueError:
                pass
with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary)
    repo, remote, state = base / 'repo', base / 'remote.git', base / 'state'
    state.mkdir()
    subprocess.run(['git', 'init', '-q', '--bare', str(remote)], check=True)
    subprocess.run(['git', 'init', '-q', '-b', 'main', str(repo)], check=True)
    for key, value in [('user.name', 'Automation Test'), ('user.email', 'test@example.invalid')]:
        subprocess.run(['git', '-C', str(repo), 'config', key, value], check=True)
    (repo / 'version').write_text('1')
    subprocess.run(['git', '-C', str(repo), 'add', 'version'], check=True)
    subprocess.run(['git', '-C', str(repo), 'commit', '-qm', 'Initial'], check=True)
    subprocess.run(['git', '-C', str(repo), 'remote', 'add', 'origin', str(remote)], check=True)
    original = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
    with patch.dict(os.environ, {'BRAKET_RUN_DIR': str(state), 'BRAKET_INPUT_BRANCH': 'main'}):
        release = m.Release()
        release.state = {'target': ['1.0.1', '2'], 'codeHead': original}
        (repo / 'version').write_text('2')
        release.push(repo, ['version'], 'codeCommit', 'codeHead')
        commit = release.state['codeCommit']
        release.push(repo, ['version'], 'codeCommit', 'codeHead')
        assert subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip() == commit
        del release.state['codeCommit']  # Simulate interruption immediately after commit.
        release.push(repo, ['version'], 'codeCommit', 'codeHead')
        assert release.state['codeCommit'] == commit
        (repo / 'unrelated').write_text('preserve me')
        try:
            release.push(repo, ['version'], 'codeCommit', 'codeHead')
            raise AssertionError('unrelated changes accepted')
        except ValueError:
            pass
print('release automation: version, retry, commit recovery and scoped Git publication passed')
PY
