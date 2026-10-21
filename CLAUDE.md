# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Setup

```bash
pip install -r requirements.txt
# First run downloads Whisper base model (~150MB)
```

Requires `ffmpeg` and `ffprobe` on PATH (`brew install ffmpeg`), version 5.1 or newer (scene detection uses `-fps_mode`, which replaced `-vsync`).

## Running

```bash
./launch.sh
# or
uvicorn app:app --reload
```

The app runs as a FastAPI web server. Open `http://localhost:8000` in a browser.

## Architecture

Three files:

- `app.py` — FastAPI server, session state, HTTP routes
- `pipeline.py` — background pipeline logic, PDF export via ReportLab
- `storyboard.py` — core functions (metadata, audio, transcription, alignment, DOCX generation) plus a legacy CLI entrypoint

### User flow

1. User uploads a video via the UI (`/api/upload`)
2. Server reads metadata (`get_video_metadata`) and kicks off auto scene-detect frame extraction in a background thread (`_extract_auto_frames`)
3. UI shows the video player and auto-detected frame thumbnails; user selects which timecodes to include
4. User submits selected timecodes (`/api/process`), which starts `run_pipeline` in a background thread
5. UI polls `/api/progress/{session_id}` via SSE for progress updates

### Pipeline steps (run_pipeline in pipeline.py)

1. **extract_frames_at_timecodes** — ffmpeg extracts one JPEG per selected timecode to `workspace/{session_id}/frames/`
2. **extract_audio** — ffmpeg extracts mono 16kHz WAV (skipped if no audio track or `no_transcribe` option set)
3. **transcribe_audio** — faster-whisper transcribes the WAV; result cached to `workspace/{session_id}/transcript.json`
4. **align_transcript** — transcript segments assigned to frame windows by `start_seconds`
5. **build_rows** — assembles final row dicts (timecode, thumbnail path, transcript, supers, notes, status)

### Post-processing

- UI displays rows in an editable script sheet; user can edit VO, supers, jingle, graphics, and notes
- Clicking a row opens an inspect drawer: full-size frame, segment player, mark as checked (`status` PENDING/CHECKED), delete frame, and add frame at the playhead
- Edited rows are saved back via `POST /api/rows/{session_id}`
- `POST /api/frame/{session_id}` extracts one frame at a time and returns a new empty row (used by "Add frame")
- "Re-select frames" re-runs the pipeline and discards all edits
- Export: `GET /api/export/docx/{session_id}` (python-docx) or `GET /api/export/pdf/{session_id}` (ReportLab)

## Native app (`CaddyApp/`)

The SwiftUI rebuild (see BRD). Open `CaddyApp/Caddy.xcodeproj`. Swift 6, default actor isolation `MainActor`, macOS 26.2+, folder-synced group, so every file in `CaddyApp/Caddy/` is compiled. `Info.plist` sits outside that folder and declares the `.caddy` package type (`andreasthoma.caddy.document`).

- `CaddyApp.swift`: scenes (welcome `Window`, then `DocumentGroup`) and `VideoFile` (mp4/mov/m4v; AVFoundation can't read MKV or AVI)
- `Model/CaddyDocument.swift`: `FileDocument` writing `script.json` into the package; `Script`, `ScriptRow`, `Timecode`, `Script.sample`
- `Model/Playback.swift`: per-window `AVPlayer`, current time, segment playback
- `Model/Thumbnails.swift`: `AVAssetImageGenerator` frame grabs, cached in memory
- `Model/Analyzer.swift`: runs scene detection, on-screen text reading, then transcription, writing suggested rows, supers and VO into the script as results arrive; re-applies sensitivity to saved scores
- `Model/SceneDetector.swift`: per-frame score = share of 5×5 px blocks (160 px wide frame) whose change jumps more than 10 grey levels above their 12-frame median. Cut ≈ 0.7, full-screen graphic ≈ 0.25, super ≈ 0.03. Sensitivity 0 to 1 maps to threshold 0.3 to 0.005 (default 0.73 ≈ 0.015). Scores are saved in the document
- `Model/ScreenTextReader.swift`: Vision text recognition for supers, sampled every 0.5 s plus just after each candidate scene change. Each frame is read at full and quarter size (text taller than 8% of the frame from the quarter pass, which reads large display type that full size drops). Stacked pieces under 5× apart in height join into one block. Per row, reads are de-duplicated on letters and digits, merged reads (containing two other reads) and partial reads are dropped. In-scene text such as signage is read too. Samples are saved in the document
- `Model/VoiceoverTranscriber.swift`: SpeechTranscriber with per-word times; VO is aligned a sentence at a time to the row it overlaps most. Accepted rows keep their VO
- `Views/`: `WelcomeView`, `DocumentView` (toolbar, status, layout), `ScriptSheet`, `InspectorView` (uses `AVPlayerView`; SwiftUI `VideoPlayer` crashes with the Xcode 27.1 SDK), `FilmstripView`, `ExportSheet` (options only, no writers yet)

Model types are `nonisolated` so `FileDocument` can read and write them off the main actor. Detection and transcription are `@concurrent` and take a URL, since `AVAsset` isn't `Sendable`. Frame times get `Playback.frameNudge` (1 ms) before conversion to `CMTime`, or grabs can land on the previous frame.

Test ad: `~/Documents/Work/frog/HRB-MaxYourTax_Hero_16x9_15_OP59-v09.mp4` (15 s). Expected frames at the default sensitivity: 0, 7.08, 9.24, 10.92, 13.12, 14.08. Expected supers: "Don't tax yourself" (10.92), "MAX YOUR TAX" (13.12), "H&R BLOCK® / IN-OFFICE | ONLINE" (14.08); "H&R BLOCK®" at 9.24 and 10.92 is the wall sign.

## Key Constants

| Constant | Default | Purpose |
|---|---|---|
| `DEFAULT_SCENE_THRESHOLD` | 0.4 | ffmpeg scene filter sensitivity (auto-frame extraction) |
| `DEFAULT_INTERVAL` | 2 | Seconds between frames in legacy CLI interval mode |
| `SUPPORTED_FORMATS` | mp4/mov/mkv/avi | Validated at upload |
