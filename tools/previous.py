#!/usr/bin/env python3
"""Retain the previous public immutable payload during a Pages deployment."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.request

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def main() -> None:
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    if not re.fullmatch(r"[A-Za-z0-9-]+/[A-Za-z0-9_.-]+", repo):
        raise SystemExit("Expected GITHUB_REPOSITORY")
    owner, name = repo.split("/")
    base = f"https://{owner.lower()}.github.io/{name}/"
    opener = urllib.request.build_opener(NoRedirect())
    def read(path: str, limit: int) -> bytes:
        with opener.open(urllib.request.Request(base + path, headers={"Cache-Control": "no-cache"}), timeout=20) as response:
            raw = response.read(limit + 1)
            if len(raw) > limit:
                raise ValueError("Previous publication exceeds its bound")
            return raw
    try:
        manifest_bytes = read("manifest.json", 128 * 1024)
        value = json.loads(manifest_bytes)
        entry = value["snapshot"]
        if value.get("format") != "coc-clan-publication" or not re.fullmatch(r"data/[a-f0-9]{64}\.json", entry["path"]):
            raise ValueError("Unsupported previous publication")
        raw = read(entry["path"], 16 * 1024 * 1024)
        if len(raw) != entry["bytes"] or hashlib.sha256(raw).hexdigest() != entry["sha256"]:
            raise ValueError("Previous payload did not match its manifest")
        directory = Path(".private/previous")
        (directory / "data").mkdir(parents=True, exist_ok=True)
        (directory / "manifest.json").write_bytes(manifest_bytes)
        (directory / entry["path"]).write_bytes(raw)
        print("Previous immutable snapshot retained")
    except (urllib.error.URLError, ValueError, KeyError):
        print("No valid previous public snapshot; continuing with a fresh publication")

if __name__ == "__main__":
    main()
