#!/usr/bin/env python3
"""Propose a release version and inspect local prerequisites without writing files."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")


def git(root, *args):
    result = subprocess.run(["git", *args], cwd=root, text=True,
                            capture_output=True, timeout=20)
    if result.returncode:
        raise ValueError(result.stderr.strip() or f"Git falló: {' '.join(args)}")
    return result.stdout.strip()


def current_version(root):
    source = (root / "scripts/generate_project.py").read_text()
    values = {}
    for key in ("MARKETING_VERSION", "BUILD_NUMBER"):
        matches = re.findall(rf"^{key} = '([^']+)'$", source, re.MULTILINE)
        if len(matches) != 1:
            raise ValueError(f"No se pudo leer {key} de generate_project.py.")
        values[key] = matches[0]
    if not VERSION.fullmatch(values["MARKETING_VERSION"]) or not values["BUILD_NUMBER"].isdigit():
        raise ValueError("La versión local o el build no son válidos.")
    return values["MARKETING_VERSION"], int(values["BUILD_NUMBER"])


def bump(version, policy):
    major, minor, patch = map(int, version.split("."))
    if policy == "major": return f"{major + 1}.0.0"
    if policy == "minor": return f"{major}.{minor + 1}.0"
    if policy == "patch": return f"{major}.{minor}.{patch + 1}"
    if policy == "keep": return version
    raise ValueError("versionBump debe ser keep, patch, minor o major.")


def plan(root, profile_path, input_payload):
    root = root.resolve()
    profile = json.loads(profile_path.read_text())
    published = profile["lastPublished"]
    current, current_build = current_version(root)
    last = published["version"]
    if not VERSION.fullmatch(last):
        raise ValueError("lastPublished.version no es una versión X.Y.Z.")
    if profile.get("technology") != "macos-swift":
        raise ValueError("Este adaptador de versiones es para macOS/Swift; configurá otro adaptador.")
    policy = profile.get("versionBump", "patch")
    candidate = bump(current, policy)
    blockers = []
    warnings = []
    if tuple(map(int, candidate.split("."))) <= tuple(map(int, last.split("."))):
        blockers.append("La versión propuesta debe superar la última publicada.")
    head = git(root, "rev-parse", "HEAD")
    context = input_payload.get("context") if isinstance(input_payload, dict) else None
    if context is not None and context.get("headCommit") != head:
        blockers.append("HEAD cambió desde que se preparó el contexto de publicación.")
    if context is not None and context.get("lastPublishedVersion") != last:
        blockers.append("El contexto y el perfil discrepan sobre la última versión publicada.")
    code_changes = git(root, "status", "--porcelain", "--untracked-files=normal").splitlines()
    if code_changes:
        blockers.append(f"El repositorio de Braket tiene {len(code_changes)} cambios sin commit.")
    branch = git(root, "branch", "--show-current")
    if not branch:
        blockers.append("El repositorio está en detached HEAD.")
    site_config = profile.get("site", {})
    site = Path(site_config.get("path", "")).expanduser()
    feed_relative = Path(site_config.get("feed", "public/apps/krabzik-ide/appcast.xml"))
    published_build = None
    site_changes = []
    if not site_config.get("path") or not site.is_dir():
        blockers.append("No se encontró el repositorio del sitio configurado.")
    elif feed_relative.is_absolute() or ".." in feed_relative.parts:
        blockers.append("La ruta del catálogo del sitio debe ser relativa.")
    else:
        site = site.resolve()
        if Path(git(site, "rev-parse", "--show-toplevel")).resolve() != site:
            blockers.append("La carpeta del sitio no es la raíz de su repositorio Git.")
        site_changes = git(site, "status", "--porcelain", "--untracked-files=normal").splitlines()
        if site_changes:
            blockers.append(f"El sitio tiene {len(site_changes)} cambios sin commit.")
        feed = (site / feed_relative).resolve()
        if not feed.is_relative_to(site) or not feed.is_file():
            blockers.append("No se encontró el catálogo Sparkle dentro del sitio.")
        else:
            try:
                items = ET.parse(feed).findall("./channel/item")
                entries = [(item.findtext(f"{{{SPARKLE}}}shortVersionString"),
                            item.findtext(f"{{{SPARKLE}}}version")) for item in items]
                if not entries or entries[0][0] != last:
                    blockers.append("La primera versión del catálogo no coincide con lastPublished.")
                builds = [int(build) for _, build in entries if build and build.isdigit()]
                if len(builds) != len(entries):
                    blockers.append("El catálogo contiene un build no numérico.")
                else:
                    published_build = max(builds)
            except ET.ParseError:
                blockers.append("El catálogo Sparkle no es XML válido.")
    tools = {name: shutil.which(name) is not None for name in ("xcodebuild", "codesign", "xcrun")}
    for name, available in tools.items():
        if not available: blockers.append(f"Falta la herramienta {name}.")
    warnings.append("La identidad Developer ID y el perfil notarial se validarán antes de firmar.")
    next_build = max(current_build, published_build or 0) + 1
    return {
        "mode": "dry-run", "status": "blocked" if blockers else "ready",
        "product": profile["product"], "technology": profile["technology"],
        "runID": (input_payload.get("run") or {}).get("id"),
        "baseCommit": published["ref"], "headCommit": head, "branch": branch,
        "versionBump": policy, "currentVersion": current, "currentBuild": current_build,
        "lastPublishedVersion": last, "lastPublishedBuild": published_build,
        "proposedVersion": candidate, "proposedBuild": next_build,
        "codeChanges": code_changes, "siteChanges": site_changes,
        "tools": tools, "blockers": blockers, "warnings": warnings,
        "mutatedFiles": [],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", default=".braket/publication.json")
    args = parser.parse_args()
    try:
        data = json.loads(os.environ.get("BRAKET_INPUT", "{}"))
        output = plan(Path.cwd(), Path(args.profile), data)
        print(json.dumps(output, ensure_ascii=False, indent=2))
        return 0
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        print("No se pudo calcular el dry-run de versión: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
