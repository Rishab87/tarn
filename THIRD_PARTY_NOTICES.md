# Third-party software

Tarn ships with, or downloads, the following software. Each keeps its own license.

## Bundled in the app

| Component | Used for | License |
|---|---|---|
| [llama.cpp](https://github.com/ggml-org/llama.cpp) (`llama-server` and its libraries, build b11960) | Runs the AI model | MIT, © The ggml authors. The full text ships in the app as `llama.cpp-LICENSE.txt`. |
| [Sparkle](https://github.com/sparkle-project/Sparkle) 2.10.1 | App updates | MIT-style, © Andy Matuschak and contributors. See its [LICENSE](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE), which also covers its bundled components. |
| [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) 2.4.1 | Rendering answers | MIT, © 2020 Guillermo Gonzalez |
| [NetworkImage](https://github.com/gonzalezreal/NetworkImage) | Dependency of MarkdownUI | MIT, © 2020 Guille Gonzalez |
| [swift-cmark](https://github.com/swiftlang/swift-cmark) | Markdown parsing (cmark-gfm) | BSD-2-Clause and others, © 2014 John MacFarlane. See its [COPYING](https://github.com/swiftlang/swift-cmark/blob/gfm/COPYING). |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) 0.9.20 | Backups and skill imports | MIT, © 2017-2025 Thomas Zoechling |

## Downloaded by the app at your request

Tarn downloads one AI model from Hugging Face, picked to fit your Mac. The models aren't part of this repository.

| Model | Published as | License |
|---|---|---|
| Qwen3.5 2B, 4B and 9B | [unsloth/Qwen3.5-*-GGUF](https://huggingface.co/unsloth) | Apache 2.0 (Qwen team, Alibaba) |
| Qwen3.6 35B-A3B | [unsloth/Qwen3.6-35B-A3B-GGUF](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF) | Apache 2.0 |
| Qwen3.8 27B | [unsloth/Qwen3.8-27B-GGUF](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF) | Apache 2.0 |

Web search uses DuckDuckGo's public HTML results page.
