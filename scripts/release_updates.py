#!/usr/bin/env python3
"""Build, notarize and stage a Sparkle release. Never deploys or exports private keys."""
import argparse
import base64
import hashlib
import importlib.util
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ORIGIN = "https://www.krabzik.com"
ACCOUNT = "com.krabzik.ide.updates"


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True, cwd=ROOT)


def validate_feed(path, version, build, archive):
    tree = ET.parse(path)
    ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
    current = [item for item in tree.findall("./channel/item")
               if item.findtext("sparkle:version", namespaces=ns) == build]
    if len(current) != 1:
        raise ValueError("El catálogo debe anunciar exactamente una entrada para el build nuevo.")
    enclosure = current[0].find("enclosure")
    expected = f"{ORIGIN}/downloads/krabzik-ide/{version}/{archive.name}"
    if enclosure is None or enclosure.get("url") != expected:
        raise ValueError("La descarga no apunta a la ruta oficial de esta versión.")
    signature = enclosure.get("{%s}edSignature" % ns["sparkle"], "")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Falta la firma Ed25519 de Sparkle.")
    if int(enclosure.get("length", "0")) != archive.stat().st_size:
        raise ValueError("El tamaño anunciado no coincide con el paquete.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identity", required=True, help="Nombre completo Developer ID Application")
    parser.add_argument("--team", required=True, help="Team ID del certificado de distribución")
    notarization = parser.add_mutually_exclusive_group(required=True)
    notarization.add_argument("--notary-profile", help="Perfil de notarytool guardado en el llavero")
    notarization.add_argument("--notarized-app", type=Path, help="App ya notarizada y exportada desde Xcode")
    parser.add_argument("--notarize-only", action="store_true", help="Dejar la app firmada y notarizada, sin preparar una actualización")
    parser.add_argument("--notes", type=Path, help="Notas de la versión en texto o Markdown")
    parser.add_argument("--previous-feed", type=Path, help="appcast.xml actual del sitio")
    args = parser.parse_args()
    if not args.identity.startswith("Developer ID Application:") or not re.fullmatch(r"[A-Z0-9]{10}", args.team):
        parser.error("Se necesita Developer ID Application y un Team ID válido; no se publica firma local.")
    if args.notarize_only and args.notarized_app:
        parser.error("--notarize-only requiere --notary-profile para enviar la app a Apple.")
    if not args.notarize_only:
        if not args.notes or not args.previous_feed or not args.notes.is_file() or not args.previous_feed.is_file():
            parser.error("Faltan las notas o el catálogo anterior.")
        ET.parse(args.previous_feed)
    spec = importlib.util.spec_from_file_location("project", ROOT / "scripts/generate_project.py")
    project = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(project)
    version, build = project.MARKETING_VERSION, project.BUILD_NUMBER
    scheme = project.SCHEME.stem
    app_name = plistlib.loads((ROOT / "Krabzik/Info.plist").read_bytes())["CFBundleName"] + ".app"
    if not re.fullmatch(r"[0-9]+(\.[0-9]+){2}", version) or not build.isdigit():
        parser.error("Versión o build inválidos.")
    if not args.notarize_only:
        ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
        for entry in ET.parse(args.previous_feed).findall("./channel/item"):
            old = entry.findtext("sparkle:version", namespaces=ns)
            if old and (not old.isdigit() or int(old) >= int(build)):
                parser.error("Incrementá BUILD_NUMBER antes de publicar otra versión.")
    run("python3", ROOT / "scripts/generate_project.py", "--check")
    output_root = ROOT / ".build/releases"
    output_root.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix=version + "-", dir=output_root))
    if args.notarized_app:
        app = output / app_name
        run("ditto", args.notarized_app.resolve(), app)
    else:
        archive_path = output / f"{scheme}.xcarchive"
        run("xcodebuild", "-project", project.PBXPROJ.parent.name, "-scheme", scheme,
            "-configuration", "Release", "-destination", "generic/platform=macOS",
            "-derivedDataPath", ".build", "-archivePath", archive_path,
            f"CODE_SIGN_IDENTITY={args.identity}", f"DEVELOPMENT_TEAM={args.team}",
            "CODE_SIGN_STYLE=Manual", "OTHER_CODE_SIGN_FLAGS=--timestamp", "archive")
        options = output / "ExportOptions.plist"
        options.write_bytes(plistlib.dumps({"method": "developer-id", "teamID": args.team,
                                           "signingStyle": "manual", "signingCertificate": args.identity}))
        exported = output / "export"
        run("xcodebuild", "-exportArchive", "-archivePath", archive_path,
            "-exportPath", exported, "-exportOptionsPlist", options)
        app = exported / app_name
    run("codesign", "--verify", "--deep", "--strict", app)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != (version, build):
        raise ValueError("La versión de la app no coincide con el proyecto.")
    signature = subprocess.check_output(["codesign", "-d", "--verbose=4", str(app)],
                                        stderr=subprocess.STDOUT, text=True)
    if f"Authority={args.identity}" not in signature or f"TeamIdentifier={args.team}" not in signature:
        raise ValueError("La app no está firmada por la identidad y el equipo esperados.")
    if info.get("CFBundleIdentifier") != "com.krabzik.ide":
        raise ValueError("Identificador de app incorrecto.")
    tools = ROOT / ".build/SourcePackages/artifacts/sparkle/Sparkle/bin"
    public_key = subprocess.check_output([str(tools / "generate_keys"), "--account", ACCOUNT, "-p"], text=True).strip()
    if info.get("SUPublicEDKey") != public_key:
        raise ValueError("La clave pública de la app no coincide con la clave de publicación.")
    if not args.notarized_app:
        upload = output / "notarization.zip"
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, upload)
        run("xcrun", "notarytool", "submit", upload, "--keychain-profile", args.notary_profile, "--wait")
        run("xcrun", "stapler", "staple", app)
    run("xcrun", "stapler", "validate", app)
    run("spctl", "--assess", "--type", "execute", "--verbose=2", app)
    if args.notarize_only:
        print(f"App firmada y notarizada: {app}")
        return
    downloads = output / "public/downloads/krabzik-ide" / version
    downloads.mkdir(parents=True)
    package = downloads / f"{Path(app_name).stem}-{version}-macos-universal.zip"
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, package)
    shutil.copy2(args.notes, package.with_suffix(".md"))
    feed_dir = output / "public/apps/krabzik-ide"
    feed_dir.mkdir(parents=True)
    feed = feed_dir / "appcast.xml"
    shutil.copy2(args.previous_feed, feed)
    run(tools / "generate_appcast", "--account", ACCOUNT, "--maximum-deltas", "0",
        "--download-url-prefix", f"{ORIGIN}/downloads/krabzik-ide/{version}/",
        "--link", f"{ORIGIN}/apps/krabzik-ide/", "--embed-release-notes", "-o", feed, downloads)
    validate_feed(feed, version, build, package)
    checksum = hashlib.sha256(package.read_bytes()).hexdigest()
    (output / "SHA256SUMS").write_text(f"{checksum}  {package.name}\n")
    print(f"Release verificada y preparada en: {output / 'public'}")
    print("Revisar y copiar public/ al sitio. Este script NO despliega a Vercel.")


if __name__ == "__main__":
    main()
