#!/usr/bin/env python3
"""Read-only bounded D1 export for CI. The API token is accepted only from the environment."""
from __future__ import annotations
import argparse
import collections
import json
import os
from pathlib import Path
import re
import time
import urllib.error
import urllib.request

MAX_BYTES = 32 * 1024 * 1024
META = """SELECT
  (SELECT value FROM clan_meta WHERE key='clanTag') AS clan_tag,
  (SELECT value FROM clan_meta WHERE key='lastSuccess') AS last_success,
  (SELECT COALESCE(MAX(row_id),0) FROM clan_observations) AS high_water,
  (SELECT COUNT(*) FROM clan_capture_jobs WHERE enabled=1 AND last_error<>'') AS failed"""
PAGE = "SELECT row_id,data,confirmed_at FROM clan_observations WHERE row_id>? AND row_id<=? ORDER BY row_id LIMIT 100"

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

class D1Reader:
    def __init__(self, account: str, database: str, token: str):
        if not re.fullmatch(r"[a-f0-9]{32}", account) or not re.fullmatch(r"[a-f0-9-]{36}", database) or not token:
            raise ValueError("Configure CF_ACCOUNT_ID, CF_DATABASE_ID and CF_D1_API_TOKEN")
        self.url = f"https://api.cloudflare.com/client/v4/accounts/{account}/d1/database/{database}/query"
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect())

    def query(self, sql: str, params: list[str] | None = None) -> list[dict]:
        if sql not in (META, PAGE):
            raise ValueError("Only the two fixed read-only queries are supported")
        request = urllib.request.Request(self.url, data=json.dumps({"sql": sql, "params": params or []}).encode(),
            method="POST", headers={"Authorization": "Bearer " + self.token, "Content-Type": "application/json", "User-Agent": "clan-insight-export/1"})
        for attempt in range(3):
            try:
                with self.opener.open(request, timeout=30) as response:
                    raw = response.read(4 * 1024 * 1024 + 1)
                    if len(raw) > 4 * 1024 * 1024:
                        raise RuntimeError("D1 page exceeded 4 MB")
                    result = json.loads(raw)
                if not result.get("success") or len(result.get("result", [])) != 1:
                    raise RuntimeError("D1 did not return one successful query")
                query = result["result"][0]
                if not query.get("success") or query.get("meta", {}).get("rows_written", 0) or query.get("meta", {}).get("changed_db", False):
                    raise RuntimeError("Read-only D1 export failed its invariant")
                return query["results"]
            except urllib.error.HTTPError as error:
                if error.code in (429, 502, 503, 504) and attempt < 2:
                    time.sleep(min(10, max(1, int(error.headers.get("Retry-After", "2")))))
                    continue
                raise RuntimeError(f"D1 export HTTP {error.code}") from None
            except urllib.error.URLError:
                if attempt < 2:
                    time.sleep(1); continue
                raise RuntimeError("D1 export network failure") from None
        raise RuntimeError("D1 export retry bound exceeded")

def export(reader: D1Reader, expected_tag: str) -> tuple[dict, dict]:
    for attempt in range(3):
        before = reader.query(META)[0]
        if before["clan_tag"] != expected_tag:
            raise ValueError("D1 contains another clan")
        cursor = 0; observations = []; total = 0; by_kind: dict[str, str] = {}
        for _ in range(1001):
            rows = reader.query(PAGE, [str(cursor), str(before["high_water"])])
            if not rows:
                break
            for row in rows:
                if type(row["row_id"]) is not int or row["row_id"] <= cursor:
                    raise ValueError("D1 cursor did not advance")
                cursor = row["row_id"]
                total += len(row["data"].encode())
                if total > MAX_BYTES or len(observations) >= 100_000:
                    raise ValueError("D1 archive exceeds the supported export bound")
                observation = json.loads(row["data"])
                observation["confirmedAt"] = row["confirmed_at"]
                observations.append(observation)
                kind = observation["kind"]
                by_kind[kind] = max(by_kind.get(kind, ""), row["confirmed_at"])
            if len(rows) < 100:
                break
        else:
            raise ValueError("D1 export page bound exceeded")
        after = reader.query(META)[0]
        if before["last_success"] != after["last_success"] or before["high_water"] != after["high_water"]:
            if attempt < 2:
                time.sleep(1); continue
            raise RuntimeError("Source changed during all export attempts; previous publication is retained")
        if not observations:
            raise ValueError("Empty source archive; previous publication is retained")
        return ({"format": "coc-clan-archive", "schemaVersion": 1, "clanTag": expected_tag, "observations": observations},
                {"lastSuccess": after["last_success"], "issues": ["partial_failure"] if after["failed"] else [], "byKind": by_kind})
    raise RuntimeError("Source stability retry bound exceeded")

def write_private(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as stream:
        json.dump(value, stream, separators=(",", ":"), ensure_ascii=False)

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    tag = os.environ.get("CLAN_TAG", "").strip().upper()
    if not re.fullmatch(r"#[A-Z0-9]{3,15}", tag):
        raise SystemExit("Configure CLAN_TAG")
    reader = D1Reader(os.environ.get("CF_ACCOUNT_ID", ""), os.environ.get("CF_DATABASE_ID", ""), os.environ.get("CF_D1_API_TOKEN", ""))
    archive, status = export(reader, tag)
    write_private(args.output / "archive.json", archive)
    write_private(args.output / "status.json", status)
    print(json.dumps({"observations": len(archive["observations"]), "kinds": dict(collections.Counter(x["kind"] for x in archive["observations"])), "issues": status["issues"]}))

if __name__ == "__main__":
    main()
