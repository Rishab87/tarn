#!/usr/bin/env python3
"""Download the pinned llama.cpp release for Apple Silicon, verify its SHA-256, and copy
llama-server plus the dylibs it links into Engine/llama/ (bundled into Tarn.app/Contents/MacOS).

The pinned build matches the one used in development (Homebrew llama.cpp 0.8.0 = build 11960).
Run: python3 scripts/fetch_llama.py
"""
from __future__ import annotations

import hashlib
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from pathlib import Path

BUILD = "b11960"
SHA256 = "58e5a5e1d7c2bf66cedd9c29e0323f3e570660a70a1e2156d32eed08f4cc1e3c"
ASSET = f"llama-{BUILD}-bin-macos-arm64.tar.gz"
URL = f"https://github.com/ggml-org/llama.cpp/releases/download/{BUILD}/{ASSET}"

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "vendor"
OUT = ROOT / "Engine" / "llama"
MARKER = OUT / ".build"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> None:
    if MARKER.exists() and MARKER.read_text().strip() == BUILD and (OUT / "llama-server").exists():
        print(f"llama.cpp {BUILD} already in Engine/llama")
        return
    VENDOR.mkdir(exist_ok=True)
    archive = VENDOR / ASSET
    if not archive.exists() or sha256(archive) != SHA256:
        print(f"Downloading {URL}")
        urllib.request.urlretrieve(URL, archive)
    got = sha256(archive)
    if got != SHA256:
        archive.unlink()
        raise SystemExit(f"Checksum mismatch for {ASSET}: expected {SHA256}, got {got}")

    with tempfile.TemporaryDirectory() as tmp:
        with tarfile.open(archive) as t:
            t.extractall(tmp, filter="data")
        src = Path(tmp) / f"llama-{BUILD}"
        # Walk @rpath dependencies from llama-server so only what it needs ships.
        needed = {"llama-server"}
        queue = ["llama-server"]
        while queue:
            out = subprocess.run(["otool", "-L", str(src / queue.pop())], capture_output=True, text=True, check=True).stdout
            for m in re.finditer(r"^\s*@rpath/(\S+)", out, re.M):
                if m.group(1) not in needed:
                    needed.add(m.group(1))
                    queue.append(m.group(1))
        if OUT.exists():
            shutil.rmtree(OUT)
        OUT.mkdir(parents=True)
        for name in sorted(needed):
            shutil.copyfile(src / name, OUT / name)  # follows symlinks
        (OUT / "llama-server").chmod(0o755)
        shutil.copyfile(src / "LICENSE", ROOT / "Tarn" / "Resources" / "llama.cpp-LICENSE.txt")
    MARKER.write_text(BUILD + "\n")
    print(f"llama.cpp {BUILD}: {len(needed)} files in Engine/llama")


if __name__ == "__main__":
    main()
