#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h:h}"
python3 - <<'PY'
import base64
import importlib.util
import subprocess
import tempfile
from pathlib import Path
spec = importlib.util.spec_from_file_location("release", "scripts/release_updates.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    archive = root / "Krabzik.zip"
    archive.write_bytes(b"fixture")
    feed = root / "appcast.xml"
    signature = base64.b64encode(bytes(64)).decode()
    valid = f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel><item><sparkle:version>4</sparkle:version>
    <enclosure url="https://www.krabzik.com/downloads/krabzik-ide/0.4.0/Krabzik.zip"
    sparkle:edSignature="{signature}" length="7"/></item></channel></rss>'''
    feed.write_text(valid)
    module.validate_feed(feed, "0.4.0", "4", archive)
    for broken in [valid.replace('length="7"', 'length="8"'),
                   valid.replace("https://www.krabzik.com", "http://example.com"),
                   valid.replace(signature, "bad"), valid.replace(">4<", ">3<")]:
        feed.write_text(broken)
        try:
            module.validate_feed(feed, "0.4.0", "4", archive)
        except (ValueError, TypeError):
            pass
        else:
            raise AssertionError("Accepted invalid release metadata")
    result = subprocess.run(["python3", "scripts/release_updates.py", "--identity", "-",
                             "--team", "6P3J382F8G", "--notary-profile", "unused",
                             "--notes", str(archive), "--previous-feed", str(feed)], capture_output=True)
    assert result.returncode == 2, "Must refuse ad-hoc distribution before building"
    result = subprocess.run(["python3", "scripts/release_updates.py", "--identity",
                             "Developer ID Application: Example (6P3J382F8G)",
                             "--team", "6P3J382F8G", "--notarized-app", str(archive),
                             "--notarize-only"], capture_output=True)
    assert result.returncode == 2, "Notarize-only must submit through notarytool"
print("  ✓ publicación rechaza firma local y metadatos inválidos")
PY
