# Developing Caddy

## Building the app

The app is in `CaddyApp/`. Open `CaddyApp/Caddy.xcodeproj` in Xcode (Swift 6, macOS 26.2 or later) and run. There are no third-party dependencies.

To produce a signed, notarised build:

```bash
CaddyApp/release.sh <version>
```

This needs a Developer ID Application certificate and a notary profile saved in the keychain as `caddy-notary`.

`CLAUDE.md` (in the repo root) describes the app's architecture in detail, and `BRD.md` (also in the root) holds the requirements and open questions. `relay/` is the small Netlify function that files in-app issue reports as GitHub issues; see `relay/README.md`.

The original Python web app prototype was removed. It's in git history if you need it.
