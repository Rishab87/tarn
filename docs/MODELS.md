# How Tarn picks a model for each Mac

Users never see model names, only **Recommended (9B)** and **Lighter (4B)**. The names appear under Settings → AI Model → Details.

## The rule: a memory budget, not RAM bands

`ModelFit.picks` in `Tarn/Model/Catalog.swift`:

1. **Budget** = RAM minus a reserve for macOS, a browser and everyday apps.
   - The reserve is half of RAM, clamped to between 4.5 and 12 GiB.
   - The budget is also capped by Metal's live `recommendedMaxWorkingSetSize` minus 0.5 GiB.
   - On a 16 GB Mac that leaves 8 GiB for the AI.
2. **Footprint** of a model at a given context length:
   - weights + (KV bytes per token × context) + fixed buffers + the prompt cache (`--cache-ram 256`)
   - Contexts tried are 32K, 16K, then 8K. The largest one that fits wins.
3. **Speed gate:** a model is only recommended if its estimated speed is at least 12 tokens/s.
   - Estimated speed = bandwidth × 0.62 ÷ bytes read per token.
   - Bytes read per token are the weights, scaled by active/total parameters for mixture-of-experts models.
4. **Recommended** is the highest-quality model that fits and passes the gate.
5. **Lighter** is the best model using at most 60% of Recommended's memory.

New models arrive only through app updates: edit `scripts/catalog.source.json`, then run `python3 scripts/build_catalog.py`.

What each Mac gets (these are enforced by `TarnTests`):

| Mac | Recommended | Lighter |
|---|---|---|
| 8 GB (M1–M3, MacBook Neo) | Qwen3.5 4B at 16K context | Qwen3.5 2B |
| 16 GB | Qwen3.5 9B at 32K | Qwen3.5 4B |
| 24 GB | Qwen3.5 9B | Qwen3.5 4B |
| 32 GB and up | Qwen3.6 35B-A3B (mixture of experts, 3B active) | Qwen3.5 9B |

llama.app (by the llama.cpp team) budgets min(GPU working set − 1 GB, RAM − 4 GB). On a 16 GB Mac that is about 10.8 GB. Tarn deliberately stays at 50% there, because the brief is "don't slow the Mac while browsing".

## Why these models (as of 2026-11-01)

- **Qwen3.5 2B / 4B / 9B** (Apache 2.0) lead their sizes on independent tool-use tests: Artificial Analysis τ²-Bench 82 / 92 / 87 in non-reasoning mode, against Gemma 4 E2B at 21 and Gemma 4 12B at 36. Tool use is what makes web search, files and connectors work.
- **Qwen3.6 35B-A3B** (Apache 2.0) scores τ² 95. It's fast because only 3B parameters are active per token.
- **Left out:**
  - Gemma 4: weak at tool calls, plus an open llama.cpp tool-parsing bug (#29655).
  - gpt-oss-20b: its reasoning can't be turned off, and it returns HTTP 500 on MCP schemas (#30781).
  - LFM3: its license limits commercial use.
- **Qwen3.8 27B:** the best quality (Artificial Analysis index 34), but it's a dense model, so it only reaches 12 tokens/s on chips with roughly 320 GB/s or more. It also needs `reasoning_effort` handling and hasn't been tested on a 32 GB+ Mac. It's the next candidate.

## Measured on an Apple M5 (16 GB, 153 GB/s) with llama.cpp b11960

| Model | File | KV bytes/token (q8_0) | Fixed buffers | Speed |
|---|---|---|---|---|
| Qwen3.5 2B Q4_K_M | 1.28 GB | 6,528 | 148 MB | 65–73 tok/s |
| Qwen3.5 4B Q4_K_M | 2.74 GB | 17,408 | 256 MB | 35 tok/s |
| Qwen3.5 9B Q4_K_M | 5.68 GB | 17,408 | 273 MB | 21 tok/s |

**KV cache:** Qwen3.5/3.6 are hybrids. Only every 4th layer uses full attention, so KV = attention layers × KV heads × 512 × 1.0625 bytes. This formula matches all three measurements exactly. For Qwen3.6 35B-A3B (10 attention layers, 2 KV heads) it gives 10,880 bytes/token. That model's fixed buffers are estimated at 500 MB, which is deliberately on the high side.

**Bandwidth efficiency** measured: 0.58 (2B), 0.63 (4B), 0.78 (9B). Tarn uses 0.62.

## Apple Silicon bandwidth (GB/s)

| Chip | Base | Pro | Max | Ultra |
|---|---|---|---|---|
| M1 | 68 | 200 | 400 | 800 |
| M2 | 100 | 200 | 400 | 800 |
| M3 | 100 | 150 | 300 or 400 | 819 |
| M4 | 120 | 273 | 410 or 546 | – |
| M5 | 153 | 307 | 460 or 614 | 1,200 |
| M6 | 153 or more | – | – | – |
| A18 Pro (MacBook Neo) | – | 60 | – | – |

- The two Max figures are bins, told apart by GPU core count. For M5 Max, the 32-core split is assumed from M4 Max.
- Sources: support.apple.com tech specs; M1 from AnandTech.
- Chips newer than the table fall back to the newest known chip of the same tier.

## llama-server flags Tarn uses

- `-c <fit>` and `-np 1`.
- `-ctk q8_0 -ctv q8_0`: halves the KV cache.
- `--cache-ram 256`: the default is 8 GiB of RAM for old prompts.
- `--sleep-idle-seconds`: unloads the model when idle.
- `--reasoning-format deepseek`.
- `chat_template_kwargs.enable_thinking` is sent on every request, because the default varies between GGUF uploads.
- Sampling follows Qwen's guidance:
  - non-thinking: temperature 0.7, top_p 0.8
  - thinking: temperature 1.0, top_p 0.95
  - both: top_k 20, presence penalty 1.5
