#!/usr/bin/env python3
"""Read-only adapters for the publication workflow; never build, commit or deploy."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def git(root, *arguments):
    result = subprocess.run(
        ["git", *arguments], cwd=root, capture_output=True, text=True, timeout=20
    )
    if result.returncode:
        raise ValueError(result.stderr.strip() or "Git no pudo completar la consulta.")
    return result.stdout.strip()


def local_file(root, relative):
    path = Path(relative)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError("Se esperaba una ruta relativa dentro del proyecto.")
    resolved = (root / path).resolve()
    if not resolved.is_relative_to(root):
        raise ValueError("El archivo está fuera del proyecto.")
    return resolved


def context(root, profile):
    if Path(git(root, "rev-parse", "--show-toplevel")).resolve() != root:
        raise ValueError("Ejecutá este nodo desde la raíz del repositorio.")
    settings = json.loads(local_file(root, profile).read_text())
    if settings.get("schemaVersion") != 1 or settings.get("languages") != ["es", "en"]:
        raise ValueError("El perfil requiere schemaVersion 1 e idiomas es, en.")
    published = settings["lastPublished"]
    base = git(root, "rev-parse", "--verify", "--end-of-options", published["ref"] + "^{commit}")
    head = git(root, "rev-parse", "HEAD")
    git(root, "merge-base", "--is-ancestor", base, head)
    previous_notes = []
    for relative in published["notes"]:
        path = local_file(root, relative)
        if path.stat().st_size > 12000:
            raise ValueError("Las notas anteriores superan 12 KB; ajustá el contexto.")
        previous_notes.append({"path": relative, "content": path.read_text()})
    # JSON-encode records instead of splitting commit bodies on a custom delimiter.
    hashes = git(root, "rev-list", "--reverse", base + ".." + head).splitlines()
    if len(hashes) > 100:
        raise ValueError("Hay más de 100 commits; hace falta dividir el contexto antes de usar IA.")
    commits = [{"sha": sha, "message": git(root, "show", "-s", "--format=%B", sha)}
               for sha in hashes]
    result = {
        "product": settings["product"], "technology": settings["technology"],
        "languages": settings["languages"], "lastPublishedVersion": published["version"],
        "baseCommit": base, "headCommit": head, "commits": commits,
        "previousNotes": previous_notes,
        "scope": "Committed changes since the last published release, including pushed commits.",
        "workingTreeDirty": bool(git(root, "status", "--porcelain")),
    }
    encoded = json.dumps(result, ensure_ascii=False)
    # The Script node wraps stdout in another JSON object before sending it to Codex.
    envelope = json.dumps({"stdout": encoded, "stderr": "", "exitCode": 0}, ensure_ascii=False)
    if len(envelope.encode()) > 20000:
        raise ValueError("El contexto supera 20 KB; hace falta resumirlo por lotes. No se truncó.")
    return result, 0 if commits else 3


def verify_saved(root, raw):
    payload = json.loads(raw)
    summary = payload.get("fileSummary", {})
    results = payload.get("fileResults", [])
    files = payload.get("files", [])
    expected = {"publication-notes.es.md", "publication-notes.en.md"}
    if (summary.get("failed") != 0 or summary.get("processed") != 2
            or summary.get("total") != 2 or summary.get("preview") is not False
            or len(results) != 2 or len(files) != 2
            or {item.get("name") for item in files} != expected):
        raise ValueError("Se esperaban dos notas guardadas, sin errores, en español e inglés.")
    paths = []
    for source, saved in zip(files, results):
        content = source.get("content")
        if (source.get("mimeType") != "text/markdown" or not isinstance(content, str)
                or not content.strip() or not content.lstrip().startswith("#")
                or saved.get("status") != "saved"):
            raise ValueError("Las notas necesitan contenido Markdown y estado saved.")
        path = local_file(root, saved["path"])
        if path.read_text() != content:
            raise ValueError("El archivo guardado no coincide con la salida de Codex.")
        paths.append(saved["path"])
    return {"status": "drafts_verified", "files": paths,
            "publication": "pending", "todo": "docs/publication-workflow.md"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["context", "verify-saved"])
    parser.add_argument("--profile", default=".braket/publication.json")
    args = parser.parse_args()
    root = Path.cwd().resolve()
    try:
        if args.action == "context":
            result, status = context(root, args.profile)
        else:
            result, status = verify_saved(root, os.environ.get("BRAKET_INPUT", "{}")), 0
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return status
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        print("No se pudo preparar la publicación: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
