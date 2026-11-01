# Tarn

A private AI for the Mac. It detects the hardware, downloads the right open model, and runs it locally with llama.cpp. No account, no cloud.

- **App:** native SwiftUI for macOS 26+ with Liquid Glass, Apple silicon only.
- **Engine:** llama.cpp `llama-server` b11960, bundled in `Contents/MacOS` (fetched by `scripts/fetch_llama.py`).
- **Map:** `docs/MODELS.md` (how models are picked), `docs/WATER.md` (the counter), `docs/DISTRIBUTION.md` (hosting, updates, payments).

## Build

```sh
python3 scripts/fetch_llama.py        # engine binaries, SHA-256 checked
xcodegen generate                     # Tarn.xcodeproj from project.yml
xcodebuild -scheme Tarn -configuration Release -derivedDataPath build/DerivedData build
xcodebuild -scheme Tarn -derivedDataPath build/DerivedData test   # 30 unit tests
```

## Develop without touching your real profile

- `TARN_DATA_DIR` points the app at a scratch profile (normally `~/Library/Application Support/Tarn`).
- `TARN_MODELS_DIR` shares downloaded models between profiles.
- `TARN_LLAMA_SERVER` swaps in another engine binary.
- `scripts/dev/autosend.sh` runs one real chat headlessly against a scratch profile (Debug builds only), then checks that the engine stops with the app.

## Layout

- `Tarn/Model`: data types, the model catalog and fit rule, prompt building, the water maths.
- `Tarn/Services`: storage, hardware detection, downloader, engine, agent tools, MCP client, skills, backup, updater.
- `Tarn/App/AppModel.swift`: app state and the agent loop.
- `Tarn/Views`: onboarding, chat, sidebar, settings.
- `scripts`: engine fetch, catalog build, model measurement, icon.
