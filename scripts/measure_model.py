#!/usr/bin/env python3
"""Measure what a model really costs on this Mac with Tarn's exact llama-server flags:
KV-cache bytes per token, fixed runtime buffers, and generation speed.

  LLAMA_SERVER=/opt/homebrew/bin/llama-server python3 scripts/measure_model.py model.gguf [ctx]

Results feed scripts/catalog.source.json (kvBytesPerToken, overheadBytes) and docs/MODELS.md.
"""
from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
model = sys.argv[1]
ctx = int(sys.argv[2]) if len(sys.argv) > 2 else 16384
binary = os.environ.get("LLAMA_SERVER", str(ROOT / "Engine" / "llama" / "llama-server"))

with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]

args = [binary, "-m", model, "--host", "127.0.0.1", "--port", str(port), "-c", str(ctx), "-np", "1", "-ngl", "all",
        "--fit", "off", "-fa", "auto", "-ctk", "q8_0", "-ctv", "q8_0", "--jinja", "--reasoning-format", "deepseek",
        "--no-webui", "--cache-ram", "256", "-lv", "4"]
log_path = Path(os.environ.get("TMPDIR", "/tmp")) / f"tarn-measure-{port}.log"
with log_path.open("w") as log:
    proc = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT)
try:
    t0 = time.time()
    while True:
        if proc.poll() is not None:
            raise SystemExit(log_path.read_text()[-3000:])
        try:
            if urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2).status == 200:
                break
        except Exception:
            pass
        if time.time() - t0 > 300:
            raise SystemExit("timeout")
        time.sleep(0.25)
    load_ms = int((time.time() - t0) * 1000)
    text = log_path.read_text()

    def mib(pattern: str) -> float:
        return sum(float(m) for m in re.findall(pattern, text)) * 1024 * 1024

    kv = mib(r"llama_kv_cache: size =\s*([\d.]+) MiB")
    recurrent = mib(r"llama_memory_recurrent: size =\s*([\d.]+) MiB")
    compute = mib(r"compute buffer size =\s*([\d.]+) MiB")
    output = mib(r"output buffer size =\s*([\d.]+) MiB")

    def chat(prompt: str, max_tokens: int, thinking: bool) -> dict:
        body = json.dumps({"messages": [{"role": "user", "content": prompt}], "max_tokens": max_tokens, "temperature": 0.7,
                           "cache_prompt": False, "chat_template_kwargs": {"enable_thinking": thinking}}).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions", data=body, headers={"Content-Type": "application/json"})
        return json.load(urllib.request.urlopen(req, timeout=600))

    chat("Say hi.", 8, False)
    r = chat("Write a detailed, friendly guide to planning a week-long trip to Japan for a first-time visitor.", 400, False)
    t = chat("What is 17 * 23? Answer briefly.", 600, True)
    print(json.dumps({
        "model": Path(model).name, "fileBytes": Path(model).stat().st_size, "ctx": ctx, "loadMs": load_ms,
        "kvBytesPerToken": round(kv / ctx), "recurrentBytes": int(recurrent), "computeBytes": int(compute),
        "outputBytes": int(output), "overheadBytes": int(recurrent + compute + output),
        "tokensPerSec": round(r["timings"]["predicted_per_second"], 1), "promptTokensPerSec": round(r["timings"]["prompt_per_second"]),
        "thinkingWhenEnabled": bool(t["choices"][0]["message"].get("reasoning_content")),
    }, indent=2))
finally:
    proc.kill()
    log_path.unlink(missing_ok=True)
