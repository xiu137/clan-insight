#!/usr/bin/env python3
"""Build a whitelist-only Pages directory from validated facts and static assets."""
from __future__ import annotations
import argparse
import gzip
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--status", type=Path)
    parser.add_argument("--previous", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    private = ROOT / ".private"
    private.mkdir(mode=0o700, exist_ok=True)
    binary = private / "publish"
    subprocess.run(["swiftc", "-O", "-module-cache-path", str(private / "module-cache"),
                    *map(str, sorted((ROOT / "shared").glob("*.swift"))), str(ROOT / "tools/publish.swift"), "-o", str(binary)], check=True)
    staging = private / "publication-staging"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir()
    command = [str(binary), "--input", str(args.input.resolve()), "--output", str(staging), "--checks", str(private / "parity.json")]
    seed = ROOT / "seeds/initial-archive.json.gz"
    if seed.exists():
        seed_json = private / "initial-archive.json"
        with gzip.open(seed, "rb") as stream:
            raw = stream.read(32 * 1024 * 1024 + 1)
        if len(raw) > 32 * 1024 * 1024:
            raise ValueError("Seed exceeds 32 MB")
        seed_json.write_bytes(raw); seed_json.chmod(0o600)
        command.extend(["--seed", str(seed_json)])
    if args.status:
        command.extend(["--status", str(args.status.resolve())])
    if args.previous:
        command.extend(["--previous", str(args.previous.resolve())])
    subprocess.run(command, check=True)
    for name in ("index.html", "style.css", "app.mjs", "stats.mjs"):
        shutil.copyfile(ROOT / "public" / name, staging / name)
    (staging / ".nojekyll").touch()
    manifest = json.loads((staging / "manifest.json").read_text())
    # Only public connection metadata is shipped; credentials never enter dist.
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    if re.fullmatch(r"[A-Za-z0-9-]+/[A-Za-z0-9_.-]+", repository):
        owner, project = repository.split("/")
        connection = {"format": "coc-clan-connection", "connection": {
            "mode": "snapshot", "baseURL": f"https://{owner.lower()}.github.io/{project}", "clanTag": manifest["clanTag"]}}
        (staging / "connection.json").write_text(json.dumps(connection, indent=2) + "\n")
        index = staging / "index.html"
        index.write_text(index.read_text().replace('id="ios-connection" hidden', 'id="ios-connection"'))
    if not (staging / manifest["snapshot"]["path"]).is_file():
        raise ValueError("Publication snapshot is missing")
    if args.output.exists() and not (args.output / ".nojekyll").exists():
        raise ValueError("Output already exists and is not a generated publication directory")
    if args.output.resolve() in (ROOT, ROOT.parent, args.input.resolve().parent):
        raise ValueError("Refusing to replace a source directory")
    if args.output.exists():
        shutil.rmtree(args.output)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(staging, args.output)
    print("Pages build verified; only static assets, manifest and snapshot data are included")

if __name__ == "__main__":
    main()
