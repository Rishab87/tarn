#!/usr/bin/env python3
"""Generate Tarn/Resources/catalog.json from scripts/catalog.source.json.

catalog.source.json holds hand-picked facts (which file, quality rank, measured memory use,
sampling). This adds what must be exact, read from the Hugging Face API: the pinned commit,
file size and SHA-256. Run after editing the source: python3 scripts/build_catalog.py
"""
from __future__ import annotations

import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def get(url: str) -> object:
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)


def main() -> None:
    entries = json.loads((ROOT / "scripts" / "catalog.source.json").read_text())
    out = []
    for e in entries:
        info = get(f"https://huggingface.co/api/models/{e['repo']}")
        if info.get("gated"):
            raise SystemExit(f"{e['repo']} is gated; Tarn can only use models anyone can download.")
        revision = e.get("revision") or info["sha"]
        folder = e["path"].rsplit("/", 1)[0] if "/" in e["path"] else ""
        tree = get(f"https://huggingface.co/api/models/{e['repo']}/tree/{revision}" + (f"/{folder}" if folder else ""))
        f = next((x for x in tree if x["path"] == e["path"]), None)
        if not f or not f.get("lfs"):
            raise SystemExit(f"{e['repo']}/{e['path']} not found at {revision}")
        entry = {k: v for k, v in e.items() if k not in ("repo", "path", "revision")}
        entry["file"] = {"repo": e["repo"], "path": e["path"], "revision": revision, "size": f["lfs"]["size"], "sha256": f["lfs"]["oid"]}
        out.append(entry)
        print(f"{e['id']:<22} {f['lfs']['size'] / 1e9:6.2f} GB  {revision[:8]}  {f['lfs']['oid'][:12]}")
    dest = ROOT / "Tarn" / "Resources" / "catalog.json"
    dest.write_text(json.dumps(out, indent=2) + "\n")
    print(f"Wrote {len(out)} models to {dest.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
