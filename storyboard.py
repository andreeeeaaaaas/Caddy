#!/usr/bin/env python3
"""
Storyboard CAD Tool — CLI POC
Takes a video file and produces a storyboard DOCX document.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SUPPORTED_FORMATS = {".mp4", ".mov", ".mkv", ".avi"}
DEFAULT_INTERVAL = 2
DEFAULT_SCENE_THRESHOLD = 0.4  # 0.0–1.0; higher = less sensitive (fewer frames)
DEFAULT_MODEL = "base"
DEFAULT_OUTPUT = "./output/storyboard.docx"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def format_timecode(seconds: float) -> str:
    td = timedelta(seconds=int(seconds))
    total_seconds = int(td.total_seconds())
    h = total_seconds // 3600
    m = (total_seconds % 3600) // 60
    s = total_seconds % 60
    return f"{h:02d}:{m:02d}:{s:02d}"


def check_ffmpeg():
    if shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None:
        raise RuntimeError(
            "ffmpeg is not installed or not on PATH. "
            "Install via: brew install ffmpeg (Mac) or https://ffmpeg.org/download.html (Windows)"
        )


def resolve_abs(path: str) -> str:
    return str(Path(path).resolve())


# ---------------------------------------------------------------------------
# Step 1 — Video Metadata
# ---------------------------------------------------------------------------

def get_video_metadata(video_path: str) -> dict:
    print("[1/7] Reading video metadata...")
    cmd = [
        "ffprobe", "-v", "quiet", "-print_format", "json",
        "-show_streams", "-show_format", video_path
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"ffprobe failed on '{video_path}': {result.stderr.strip()}")

    data = json.loads(result.stdout)
    duration = float(data["format"].get("duration", 0))
    fps = None
    width = height = None
    has_audio = False

    for stream in data.get("streams", []):
        if stream.get("codec_type") == "video" and fps is None:
            r_frame_rate = stream.get("r_frame_rate", "25/1")
            num, den = r_frame_rate.split("/")
            fps = float(num) / float(den) if float(den) else 25.0
            width = stream.get("width")
            height = stream.get("height")
        if stream.get("codec_type") == "audio":
            has_audio = True

    return {
        "duration": duration,
        "fps": fps or 25.0,
        "width": width,
        "height": height,
        "has_audio": has_audio,
    }


# ---------------------------------------------------------------------------
# Step 2 — Contact Sheet Frame Extraction
# ---------------------------------------------------------------------------

def extract_frames(video_path: str, interval: int, workspace: str) -> list:
    print("[2/7] Extracting contact sheet frames...")
    frames_dir = os.path.join(workspace, "frames")
    os.makedirs(frames_dir, exist_ok=True)

    cmd = [
        "ffmpeg", "-y", "-i", video_path,
        "-vf", f"fps=1/{interval}",
        os.path.join(frames_dir, "frame_%04d.jpg")
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg frame extraction failed: {result.stderr.strip()}")

    frame_files = sorted(Path(frames_dir).glob("frame_*.jpg"))
    frames = []
    for i, f in enumerate(frame_files):
        timecode = i * interval
        frames.append({
            "index": i,
            "timecode_seconds": float(timecode),
            "filepath": str(f),
        })

    return frames


# ---------------------------------------------------------------------------
# Step 2b — Scene Change Frame Extraction
# ---------------------------------------------------------------------------

def extract_frames_scene_detect(video_path: str, threshold: float, workspace: str) -> list:
    """
    Extract one frame per detected scene change using ffmpeg's scene filter.
    Uses showinfo to capture the actual pts_time of each selected frame.
    threshold: 0.0–1.0 (higher = less sensitive, fewer frames extracted)
    """
    print(f"[2/7] Extracting frames via scene change detection (threshold={threshold})...")
    frames_dir = os.path.join(workspace, "frames")
    os.makedirs(frames_dir, exist_ok=True)

    # select filter picks frames where scene score exceeds threshold, plus
    # the very first frame (scene filter has no previous frame to compare against).
    # showinfo writes pts_time to stderr so we can recover actual timestamps.
    filter_str = f"select='eq(n\\,0)+gt(scene\\,{threshold})',showinfo"
    cmd = [
        "ffmpeg", "-y", "-i", video_path,
        "-vf", filter_str,
        "-vsync", "vfr",
        os.path.join(frames_dir, "frame_%04d.jpg")
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)

    # ffmpeg writes showinfo to stderr regardless of return code
    timestamps = []
    for line in result.stderr.splitlines():
        if "pts_time:" in line and "Parsed_showinfo" in line:
            try:
                pts_str = line.split("pts_time:")[1].split()[0]
                timestamps.append(float(pts_str))
            except (IndexError, ValueError):
                continue

    frame_files = sorted(Path(frames_dir).glob("frame_*.jpg"))

    if not frame_files:
        print(f"    ffmpeg stderr:\n{result.stderr[-2000:]}")
        return []

    # Pair files with timestamps; fall back to index*1s if parse failed
    frames = []
    for i, f in enumerate(frame_files):
        ts = timestamps[i] if i < len(timestamps) else float(i)
        frames.append({
            "index": i,
            "timecode_seconds": ts,
            "filepath": str(f),
        })

    print(f"    → {len(frames)} scene change frames detected")
    return frames


# ---------------------------------------------------------------------------
# Step 3 — Audio Extraction
# ---------------------------------------------------------------------------

def extract_audio(video_path: str, workspace: str) -> str:
    print("[3/7] Extracting audio...")
    audio_path = os.path.join(workspace, "audio.wav")
    cmd = [
        "ffmpeg", "-y", "-i", video_path,
        "-ac", "1", "-ar", "16000", "-vn", audio_path
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg audio extraction failed: {result.stderr.strip()}")
    return audio_path


# ---------------------------------------------------------------------------
# Step 4 — Transcription
# ---------------------------------------------------------------------------

def transcribe_audio(audio_path: str, model_size: str, workspace: str, duration_seconds: float) -> list:
    cache_path = os.path.join(workspace, "transcript.json")
    if os.path.exists(audio_path) and os.path.exists(cache_path):
        print("[4/7] Loading cached transcript...")
        with open(cache_path) as f:
            return json.load(f)

    duration_minutes = duration_seconds / 60
    estimate = max(1, int(duration_minutes * 0.5))
    print(
        f"[4/7] Transcribing {duration_minutes:.1f} minutes of audio. "
        f"Estimated time: {estimate} minutes on CPU."
    )

    try:
        from faster_whisper import WhisperModel
    except ImportError:
        raise RuntimeError("faster-whisper is not installed. Run: pip install faster-whisper")

    try:
        model = WhisperModel(model_size, compute_type="int8")
        segments, _ = model.transcribe(audio_path)
    except Exception as e:
        raise RuntimeError(f"Could not load Whisper model. Check internet connection for first-time setup. Detail: {e}")

    transcript = [
        {"start_seconds": s.start, "end_seconds": s.end, "text": s.text.strip()}
        for s in segments
    ]

    with open(cache_path, "w") as f:
        json.dump(transcript, f, indent=2)

    return transcript


# ---------------------------------------------------------------------------
# Step 5 — Transcript Alignment
# ---------------------------------------------------------------------------

def align_transcript(frames: list, transcript: list) -> list:
    print("[5/6] Aligning transcripts to frames...")
    aligned = []

    for i, frame in enumerate(frames):
        win_start = frames[i - 1]["timecode_seconds"] if i > 0 else 0.0
        win_end = frame["timecode_seconds"]

        # Assign each segment to exactly one window based on its start time.
        # Overlap logic causes long Whisper segments to repeat across many rows.
        matching = [
            seg["text"] for seg in transcript
            if win_start <= seg["start_seconds"] < win_end
        ]
        aligned.append(" ".join(matching).strip())

    return aligned


# ---------------------------------------------------------------------------
# Step 7 — Build Storyboard Rows
# ---------------------------------------------------------------------------

def build_rows(frames: list, transcripts: list, ocr_windows: list = None) -> list:
    rows = []
    for i, frame in enumerate(frames):
        rows.append({
            "row_number": i + 1,
            "timecode_seconds": frame["timecode_seconds"],
            "timecode_display": format_timecode(frame["timecode_seconds"]),
            "thumbnail_path": frame["filepath"],
            "transcript": transcripts[i] if i < len(transcripts) else "",
            "supers": [],
            "notes": "",
            "status": "PENDING",
        })
    return rows


# ---------------------------------------------------------------------------
# DOCX Generation
# ---------------------------------------------------------------------------

def _set_cell_shading(cell, fill_hex: str):
    """Apply a background fill colour to a table cell."""
    from docx.oxml.ns import qn
    from docx.oxml import OxmlElement
    tc = cell._tc
    tcPr = tc.get_or_add_tcPr()
    # Remove any existing shd element before adding a new one
    for existing in tcPr.findall(qn("w:shd")):
        tcPr.remove(existing)
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), fill_hex)
    tcPr.append(shd)


def _add_run(paragraph, text: str, bold: bool = False, italic: bool = False,
             font_name: str = "Calibri", font_size_pt: float = None):
    """Add a run to a paragraph with consistent Calibri styling."""
    from docx.shared import Pt
    run = paragraph.add_run(text)
    run.bold = bold
    run.italic = italic
    run.font.name = font_name
    if font_size_pt:
        run.font.size = Pt(font_size_pt)
    return run


def generate_docx(rows: list, metadata: dict, video_filename: str, output_path: str):
    print("[6/6] Generating DOCX...")

    try:
        from docx import Document
        from docx.shared import Inches, Pt, RGBColor
        from docx.enum.text import WD_ALIGN_PARAGRAPH
        from docx.oxml.ns import qn
        from docx.oxml import OxmlElement
        from PIL import Image
    except ImportError:
        raise RuntimeError("python-docx or Pillow not installed. Run: pip install python-docx Pillow")

    doc = Document()

    # --- Page setup: portrait, 0.5" margins (matches CAD script template) ---
    for section in doc.sections:
        section.page_width = Inches(8.5)
        section.page_height = Inches(11)
        section.left_margin = Inches(0.5)
        section.right_margin = Inches(0.5)
        section.top_margin = Inches(0.5)
        section.bottom_margin = Inches(0.5)

    # --- Storyboard table: 2 columns — FRAME | SCRIPT ---
    # Usable width: 8.5" - 1" margins = 7.5"
    col_widths = [Inches(2.8), Inches(4.7)]

    table = doc.add_table(rows=1, cols=2)
    table.style = "Table Grid"

    # Header row — black background, white bold Calibri, centred
    hdr_cells = table.rows[0].cells
    for cell, label in zip(hdr_cells, ["FRAME", "SCRIPT"]):
        _set_cell_shading(cell, "000000")
        p = cell.paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        run = _add_run(p, label, bold=True, font_size_pt=11)
        run.font.color.rgb = RGBColor(0xFF, 0xFF, 0xFF)

    for idx, row in enumerate(rows):
        row_cells = table.add_row().cells

        # --- FRAME column: thumbnail only ---
        frame_cell = row_cells[0]
        frame_cell.width = col_widths[0]

        if os.path.exists(row["thumbnail_path"]):
            try:
                import io
                img = Image.open(row["thumbnail_path"]).convert("RGB")
                buf = io.BytesIO()
                img.save(buf, format="JPEG")
                buf.seek(0)
                p = frame_cell.paragraphs[0]
                p.alignment = WD_ALIGN_PARAGRAPH.CENTER
                p.add_run().add_picture(buf, width=Inches(2.6))
            except Exception as e:
                _add_run(frame_cell.paragraphs[0], f"[Image error: {e}]", italic=True)
        else:
            _add_run(frame_cell.paragraphs[0], "[No image]", italic=True)

        # --- SCRIPT column: VO and SUPER only ---
        script_cell = row_cells[1]
        script_cell.width = col_widths[1]

        script_cell.paragraphs[0].clear()

        # VOICEOVER
        p = script_cell.paragraphs[0]
        _add_run(p, "VO: ", bold=True)
        _add_run(p, row["transcript"] if row["transcript"] else "(none)")

        # ON-SCREEN TEXT / SUPERS
        script_cell.add_paragraph("")
        sup_p = script_cell.add_paragraph()
        _add_run(sup_p, "SUPER: ", bold=True)
        if row["supers"]:
            _add_run(sup_p, "  |  ".join(row["supers"]))
        else:
            _add_run(sup_p, "(none)")

    # --- Save ---
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    doc.save(output_path)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def _run(args):
    # --- Validate input ---
    video_path = resolve_abs(args.video)
    if not os.path.exists(video_path):
        raise RuntimeError(f"File not found: {video_path}")

    ext = Path(video_path).suffix.lower()
    if ext not in SUPPORTED_FORMATS:
        raise RuntimeError(f"Unsupported format '{ext}'. Supported: mp4, mov, mkv, avi")

    video_filename = Path(video_path).name
    output_path = resolve_abs(args.output)
    output_dir = os.path.dirname(output_path)

    try:
        os.makedirs(output_dir, exist_ok=True)
        test_file = os.path.join(output_dir, ".write_test")
        with open(test_file, "w") as f:
            f.write("test")
        os.remove(test_file)
    except OSError:
        raise RuntimeError(f"Cannot write to output directory: {output_dir}")

    check_ffmpeg()

    # Workspace
    workspace = resolve_abs("./workspace")
    os.makedirs(workspace, exist_ok=True)

    # --- Run pipeline ---
    metadata = get_video_metadata(video_path)
    duration_minutes = metadata["duration"] / 60

    if duration_minutes > 10:
        frame_count_estimate = int(metadata["duration"] / args.interval)
        print(
            f"Warning: Video is {duration_minutes:.1f} minutes. "
            f"Contact sheet will contain ~{frame_count_estimate} frames. "
            f"Consider using --interval 5 to reduce processing time."
        )

    if args.scene_detect:
        frames = extract_frames_scene_detect(video_path, args.scene_threshold, workspace)
    else:
        frames = extract_frames(video_path, args.interval, workspace)

    if not frames:
        raise RuntimeError("No frames were extracted. Check the video file.")

    transcript = []

    if not metadata["has_audio"]:
        print("Warning: No audio track found. Skipping transcription.")
        args.no_transcribe = True
    else:
        if not args.no_transcribe:
            audio_path = extract_audio(video_path, workspace)
            transcript = transcribe_audio(audio_path, args.model, workspace, metadata["duration"])
        else:
            print("[3/7] Skipping audio extraction (--no-transcribe)")
            print("[4/7] Skipping transcription (--no-transcribe)")

    if not args.no_transcribe:
        aligned_transcripts = align_transcript(frames, transcript)
    else:
        print("[5/7] Skipping transcript alignment")
        aligned_transcripts = [""] * len(frames)

    rows = build_rows(frames, aligned_transcripts)
    generate_docx(rows, metadata, video_filename, output_path)

    # --- Cleanup ---
    if not args.keep_workspace:
        shutil.rmtree(workspace, ignore_errors=True)

    print(f"\nDone. Output saved to: {output_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Generate a storyboard DOCX from a video file."
    )
    parser.add_argument("video", help="Path to input video file")
    parser.add_argument("--output", default=DEFAULT_OUTPUT, help="Output DOCX path")
    parser.add_argument("--interval", type=int, default=DEFAULT_INTERVAL,
                        help="Seconds between contact sheet frames (default: 2)")
    parser.add_argument("--scene-detect", action="store_true",
                        help="Use scene change detection instead of fixed interval")
    parser.add_argument("--scene-threshold", type=float, default=DEFAULT_SCENE_THRESHOLD,
                        help="Scene change sensitivity 0.0–1.0 (default: 0.4; higher = fewer frames)")
    parser.add_argument("--model", default=DEFAULT_MODEL,
                        choices=["tiny", "base", "small"],
                        help="Whisper model size (default: base)")
    parser.add_argument("--no-transcribe", action="store_true",
                        help="Skip transcription")
    parser.add_argument("--keep-workspace", action="store_true",
                        help="Keep temporary workspace files after export")
    args = parser.parse_args()
    try:
        _run(args)
    except RuntimeError as e:
        print(f"Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
