# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

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

## Key Constants

| Constant | Default | Purpose |
|---|---|---|
| `DEFAULT_SCENE_THRESHOLD` | 0.4 | ffmpeg scene filter sensitivity (auto-frame extraction) |
| `DEFAULT_INTERVAL` | 2 | Seconds between frames in legacy CLI interval mode |
| `SUPPORTED_FORMATS` | mp4/mov/mkv/avi | Validated at upload |

## Imported Claude Cowork project instructions
