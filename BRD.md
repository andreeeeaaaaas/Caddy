# Caddy

> A local tool that turns a finished ad into an editable CAD script, for the brand and creative team.

**Status:** Building
**Last updated:** 2026-10-21

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
Takes a finished video, proposes frames at scene changes, transcribes the audio
locally, and presents everything in an editable table. The user adds or removes
frames, edits voiceover, supers, jingles and notes, then exports a Word or PDF
document.

**Why not the existing option**
The existing option is the manual process above. Replacing it with a local tool
keeps unreleased ad assets on the team's own machines.

**Done means**
A user uploads a finished video, gets suggested frames and a transcript, edits the
rows, and exports a Word document the team can send as-is, in noticeably less
time than the current manual process. The exact time target and export template
are open (see section 5).

**Scope**
- Video upload and metadata check
- Auto-suggested frames at scene changes
- Manual frame selection by timecode
- Add and delete frames
- Local audio transcription aligned to frames
- Editable rows: voiceover, supers, notes
- Jingle and graphics fields per row
- Word (DOCX) export
- PDF export

---

## 2. Locked Choices

| Layer | Choice | Notes |
|---|---|---|
| Language | Python 3.10+ | |
| Framework | FastAPI + uvicorn | Local web server, `http://localhost:8000` |
| Styling | Plain HTML/CSS in `static/` | No front-end framework |
| Data / DB | Filesystem, `workspace/{session_id}/` | In-memory session state, no database |
| Media | ffmpeg and ffprobe | Frame extraction, audio, scene detection |
| Transcription | faster-whisper | Local only, base model by default |
| Export | python-docx (DOCX), ReportLab (PDF) | |
| Hosting | Local macOS, `launch.sh` | |
| Package manager | pip, `requirements.txt` | |

**Pinned versions**
Python 3.10 minimum. `launch.sh` currently hardcodes the Python 3.13 framework path.

---

## 3. Rules

**Always**
- Process video, audio and transcripts locally on the user's machine.
- Keep every exported field editable by the user before export.
- Keep `CLAUDE.md` and `AGENTS.md` in step with this document when architecture changes.

**Never**
- Call a cloud or third-party API with ad assets, audio, frames or transcripts.
- Install a dependency without asking.
- Commit `workspace/` or `output/` (uploaded videos and generated exports).
- Present machine-generated text as final; it is a draft until the user edits or accepts it.

**Patterns**
- Long jobs run in a background thread and report progress to the UI through SSE.
- Edited rows are saved back through `POST /api/rows/{session_id}`.

---

## 4. Not Doing

**Non-goals** — product direction this deliberately excludes
- Not an automatic frame-describing bot. v1 is an editor with suggested frames, not a tool that writes about what changed between frames.
- Not a hosted or multi-user product.

**Out of scope** — not in this build, may come later
- Local vision-model descriptions of frames.
- Command-line use. `storyboard.py` keeps a legacy CLI, but the web app is the product.

---

## 5. Open Questions

Flag and pause on these. Do not assume an answer.

- [ ] What is the time target? The manual process takes about 20 minutes per 1 minute video; what counts as good enough?
- [ ] Can a script be uploaded alongside the video and used for alignment instead of transcription? The original brief says yes; the app does not do this yet.
- [ ] Should on-screen supers and disclaimers be detected with OCR? The original CLI did this; the web app dropped it.
- [ ] Is there a team Word template the export must match?
- [ ] Are substantiation documents in scope for v1 (attached, referenced, or generated)?
- [ ] How is accuracy measured? Suggest comparing output against one real ad with a hand-made CAD script.
- [ ] Which roles use it, and has anyone used it on a real ad yet?
- [ ] What may be shared outside the company? This is a work project.
- [ ] `README.md` still describes the old CLI and OCR; rewrite it or drop it?
