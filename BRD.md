# Caddy

> A native macOS app that turns a finished ad into an editable CAD script, for the brand and creative team.

**Status:** Rebuilding as a native macOS app (the Python web app is the reference build)
**Last updated:** 2026-11-25

## How to use this document

This BRD is the source of truth for what is being built. Where it conflicts with
general conventions, house style, or a CLAUDE.md in this repo, this document wins.

- Locked Choices are non-negotiable. Do not substitute, upgrade, or suggest
  alternatives unless explicitly asked.
- Rules apply across the whole codebase, without exception.
- Not Doing means not doing. Do not implement it, do not scaffold for it.
- If a decision is not covered here and would be expensive to reverse, stop and
  ask. Add it to Open Questions rather than assuming.
- Build one item from Scope at a time unless told otherwise.
- When a decision changes, update this document before writing code against it.

---

## 1. Overview

**The problem**
Before an ad goes to air, the brand and creative team must produce a CAD script:
the audio and vision script, voiceovers, jingles, graphics, supers and
disclaimers, plus supporting paperwork such as substantiation documents. Today
this is done by hand: get the finished asset, screenshot every frame change, note
the supers and other elements per frame, and assemble it all in a Word document.
It takes around 20 minutes for a roughly 1 minute video, and repeats for every ad.

**Who it's for**
The brand and creative team at frog, who prepare ads for air. Roles using it
day to day (producer, editor, etc.) are not yet confirmed.

**What it does**
The user drops a finished video into Caddy. It proposes frames at scene changes,
transcribes the audio on the device, and fills an editable script sheet while it
works. The user accepts or removes frames, adds frames from the timeline, edits
voiceover, supers, jingles, graphics and notes, then exports a Word or PDF
document. Every script is kept in a local library, grouped into projects, so
the team's CAD scripts live in one place.

**Why not the existing option**
The existing option is the manual process above. A local app keeps unreleased ad
assets on the team's own machines. The Python web app proved the pipeline, but it
can't be handed around the office: it needs Python, Homebrew ffmpeg and a
terminal script, and runs as a browser tab on port 8000.

**Done means**
A colleague installs Caddy from a zip with no other setup, drops in a finished
video, gets suggested frames and a transcript, edits the rows, and exports a Word
document the team can send as-is, in noticeably less time than the current manual
process. The exact time target and export template are open (see section 6).

**Scope**
- Signed, notarized app distributed as a zip, updating itself with Sparkle (its only dependency)
- Local library in one window: a sidebar of projects holding scripts, plus scripts not in a project; scripts save as they're edited
- Drop or open a video, with a metadata check
- Auto-suggested frames at scene changes, shown as suggestions to accept or reject
- Add a frame at the playhead, delete frames
- On-device transcription aligned to frames
- On-screen text read on the device and suggested as supers
- Editable rows: voiceover, supers, jingle, graphics, notes
- Inspector: full-size frame, segment playback, mark as checked
- Word (DOCX) export
- PDF export
- Report an issue from the Help menu: a short form filed as a GitHub issue through a small relay, so reporters need no GitHub account

---

## 2. Flow

One library window: a sidebar of projects and scripts, and the selected script
beside it. There are no separate upload, select and processing screens; work
appears in the window as it completes.

1. **Start.** The sidebar lists projects (expandable, with script counts) and
   scripts not in a project. Dropping a video on the window, or New Script from Video… (⌘N),
   creates a script in the selected project, or outside any project.
2. **Analyse.** The new script opens straight away with the video loaded.
   Analysis runs in the background with progress in the toolbar: scene markers
   appear on the timeline and suggested rows fill the sheet as they're found,
   then voiceover fills in as transcription finishes. The user can start editing
   before analysis ends.
3. **Review.** The window has three areas:
   - **Script sheet** (centre): one row per frame with thumbnail, timecode, VO,
     super, jingle, graphics and notes. Suggested rows are visibly marked until
     accepted (Return) or removed (Delete).
   - **Inspector** (right): the selected row's full-size frame, a player for
     that row's segment, status (Pending, Checked) and the row's fields.
   - **Timeline** (bottom): filmstrip of the whole ad with playhead and a marker
     per row. "Add frame" (⌘F or the toolbar) inserts a row at the playhead.
4. **Export.** A sheet chooses DOCX or PDF and what to include, with a preview,
   then saves the file in the team's one CAD Script template.

Generated text (transcript, suggested frames) stays marked as a draft until the
user edits or accepts it.

---

## 3. Locked Choices

| Layer | Choice | Notes |
|---|---|---|
| Language | Swift 6 | Default actor isolation `MainActor`, as in Stems |
| UI | SwiftUI | AppKit only where SwiftUI falls short (e.g. the timeline) |
| App model | One `Window` with a `NavigationSplitView` sidebar over a local library | Library in `~/Library/Application Support/Caddy` (not `~/Documents`, which iCloud may sync): `library.json` for projects and names, one `.caddy` package per script (`script.json`). Existing `.caddy` files are imported |
| Media | AVFoundation | Metadata, frame grabs (`AVAssetImageGenerator`), audio, playback |
| Scene detection | `AVAssetReader` frames scored with vImage | Block-based sudden-change score, catches supers as well as cuts. ffmpeg's scene score missed every event in the test ad at the Python app's 0.3 threshold |
| Transcription | Speech framework `SpeechAnalyzer` / `SpeechTranscriber` | On device. Language assets come from Apple, no ad data leaves the Mac |
| Supers | Vision `RecognizeTextRequest` | On device. Draft text; in-scene signage is read too |
| Export | DOCX: OOXML written from a template and zipped. PDF: Core Graphics / PDFKit | |
| Platform | macOS 26.2+, Apple silicon | Pending office hardware check (section 6) |
| Distribution | Developer ID signed, hardened runtime, notarized, zipped | Team `TZSHUKU49X`, not sandboxed, not the Mac App Store. `CaddyApp/release.sh <version>` archives, exports with `ExportOptions.plist`, notarises with the `caddy-notary` keychain profile (an app-specific password) and staples; output in `CaddyApp/build/release/<version>/`. It then writes a Sparkle appcast (signed with the EdDSA key in the login Keychain, account `caddy`) and, after asking, publishes the zip and `appcast.xml` as GitHub release `v<version>`, which the app checks daily (`SUFeedURL`: the latest release's `appcast.xml`) |
| Project | Xcode project, Swift Package Manager | |
| Issue reports | Netlify function (`relay/`) that files GitHub issues | On a work Netlify account. The GitHub token (fine-grained, Issues on this repo only) lives only in Netlify. The app posts to `CaddyReportURL` in Info.plist; reports carry what the user types plus app version, macOS and Mac model |

**Reference build**
The Python app (`app.py`, `pipeline.py`, `storyboard.py`, `static/`) stays in the
repo, unchanged, as the reference for pipeline behaviour and for comparing scene
detection, transcription and exports.

---

## 4. Rules

**Always**
- Process video, audio and transcripts locally on the user's machine.
- Keep every exported field editable by the user before export.
- Keep `CLAUDE.md` and `AGENTS.md` in step with this document when architecture changes.
- Run analysis off the main thread and show results as they arrive.
- Use light and dark colour tokens; never hardcode colours in views.

**Never**
- Call a cloud or third-party API with ad assets, audio, frames or transcripts.
- Add a Swift package or other dependency without asking.
- Bundle a command-line tool (ffmpeg, Python) or require Homebrew.
- Commit test videos, `workspace/`, `output/` or exported documents.
- Ship a GitHub token or other credential in the app, or send scripts, frames or videos with an issue report.
- Present machine-generated text as final; it is a draft until the user edits or accepts it.

**Patterns**
- Long jobs are Swift concurrency tasks that can be cancelled, owned by the document.
- The document is the single source of truth; edits go through it so undo and autosave work.
- Video files are referenced from the script, not copied into the library: by path plus a macOS bookmark, so renaming or moving a video on the same disk doesn't break its script. A video that can't be found can be located again without losing edits.

---

## 5. Not Doing

**Non-goals**: product direction this deliberately excludes
- Not an automatic frame-describing bot. v1 is an editor with suggested frames, not a tool that writes about what changed between frames.
- Not a hosted or multi-user product. The library is local to each Mac.
- Not cross-platform. No Windows or web build.

**Out of scope**: not in this build, may come later
- Local vision-model descriptions of frames.
- Command-line use.
- New features in the Python web app; it is reference only.
- A shared or synced team library (conflicts between editors).
- Screenshots or logs attached to issue reports (GitHub's API can't attach files; they'd need storing elsewhere).

---

## 6. Open Questions

Flag and pause on these. Do not assume an answer.

- [ ] Are all office Macs Apple silicon on macOS 26? If not, the platform floor and the transcription choice (WhisperKit instead of SpeechTranscriber) change.
- [ ] Is SpeechTranscriber accurate enough on ad voiceover compared with faster-whisper? Spike on 3 or 4 real ads before building on it.
- [x] Should a script reference the video or copy it in? Reference (decided 2026-10-26, with the local library).
- [ ] Should the library later be shared across the team, and how would edits from two people be reconciled?
- [ ] AVFoundation can't read MKV or AVI, which the Python app accepted. Are those formats used, or is MP4/MOV enough?
- [ ] What is the time target? The manual process takes about 20 minutes per 1 minute video; what counts as good enough?
- [ ] Can a script be uploaded alongside the video and used for alignment instead of transcription? The original brief says yes; the app does not do this yet.
- [ ] Should in-scene text (signage, packaging) be filtered out of suggested supers, or is removing it by hand acceptable?
- [ ] Is there a team Word template the export must match?
- [ ] Are substantiation documents in scope for v1 (attached, referenced, or generated)?
- [ ] How is accuracy measured? Suggest comparing output against one real ad with a hand-made CAD script.
- [ ] Which roles use it, and has anyone used it on a real ad yet?
- [ ] What may be shared outside the company? This is a work project.
- [ ] `README.md` still describes the old CLI and OCR; rewrite it or drop it?
- [ ] Change the bundle ID to reverse DNS (`com.andreasthoma.Caddy`, now `andreasthoma.Caddy`) before the first public release? Changing it later moves the app's preferences.
- [ ] Who owns the work Netlify account and GitHub token for the issue relay, and who triages reported issues?
