# Developing Caddy

## Building the app

The app is in `CaddyApp/`. Open `CaddyApp/Caddy.xcodeproj` in Xcode (Swift 6, macOS 26.2 or later) and run. There are no third-party dependencies.

To produce a signed, notarised build:

```bash
CaddyApp/release.sh <version>
```

This needs a Developer ID Application certificate and a notary profile saved in the keychain as `caddy-notary`.

`CLAUDE.md` (in the repo root) describes the app's architecture in detail, and `BRD.md` (also in the root) holds the requirements and open questions. `relay/` is the small Netlify function that files in-app issue reports as GitHub issues; see `relay/README.md`.

## Python web app (reference build)

The original prototype, a FastAPI web app that proved the pipeline, is still in the repo (`app.py`, `pipeline.py`, `storyboard.py`, `static/`). It isn't the product, but you can run it:

```bash
brew install ffmpeg   # 5.1 or newer, with ffprobe
pip install -r requirements.txt
./launch.sh           # then open http://localhost:8000
```

The first run downloads the Whisper base model (about 150 MB).
