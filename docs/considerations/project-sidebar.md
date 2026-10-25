# Project sidebar instead of the welcome window

Status: under consideration, not planned.

Idea: replace the launch window with a left-hand sidebar listing the open project and recently opened projects, so you can switch between them quickly.

## Current setup

- `CaddyApp.swift` has a welcome `Window` scene followed by a `DocumentGroup`: one window per document.
- The BRD says "One document window per ad" (`BRD.md:74`) and describes a launch window with "Open video…", a drop target and recents.
- `Playback`, `Thumbnails` and `Analyzer` are `@State` on `DocumentView`, so they live exactly as long as the window.
- A new empty document already shows `EmptyDocumentView` with its own drop target.

## Option A: sidebar inside each document window (small)

- Wrap `DocumentView` in a `NavigationSplitView`. The sidebar lists open documents and `NSDocumentController.shared.recentDocumentURLs`, reusing the list from `WelcomeView`.
- Clicking an open project brings its window to the front. Clicking a recent one calls `openDocument(at:)`, which opens a new window.
- Remove the welcome `Window` scene and let a new document open straight to `EmptyDocumentView`.
- Roughly 100 to 150 lines. No model changes.

Downside: switching jumps between windows rather than swapping content, and every window shows its own copy of the same list. Pair it with native window tabs (tabbing mode `.preferred`) so switching feels like one window.

## Option B: one window, sidebar swaps the project (large)

This is a library model, like Final Cut or Logic. It means dropping `DocumentGroup` and handling documents yourself. You'd lose or have to rebuild:

- Autosave, Versions, Revert, unsaved-changes tracking, Save As, File ▸ Open Recent and Finder double-click opening a `.caddy` file.
- The per-document `UndoManager`, which the undoable `merge`, `add` and `change` helpers on `Binding<[ScriptRow]>` rely on.
- Per-project state: switching away would either kill an analysis halfway or need a store that keeps each project's player and analyzer alive in the background.

This rewrites the app shell, `CaddyDocument` loading and saving, and state ownership in `DocumentView`. The playback, sheet and analysis code would mostly survive. The BRD would need updating.

## Recommendation

Option A plus window tabs, with the welcome window removed. It gives quick switching and a visible recents list while keeping everything `DocumentGroup` provides. Only choose B if Caddy becomes a project library, for example browsing many ads by client.
