"""
Importable pipeline used by the FastAPI web app.
Wraps storyboard.py functions and adds web-specific helpers.
"""

import os
import queue
import subprocess
import threading
from pathlib import Path

from storyboard import (
    get_video_metadata,
    extract_audio,
    transcribe_audio,
    align_transcript,
    build_rows,
    generate_docx,
    check_ffmpeg,
    format_timecode,
)


def extract_frames_at_timecodes(video_path: str, timecodes: list, workspace: str) -> list:
    frames_dir = os.path.join(workspace, "frames")
    os.makedirs(frames_dir, exist_ok=True)

    frames = []
    for i, t in enumerate(sorted(timecodes)):
        out_path = os.path.join(frames_dir, f"frame_{i:04d}.jpg")
        # -i before -ss uses output seeking — slower but frame-accurate
        cmd = [
            "ffmpeg", "-y", "-i", video_path,
            "-ss", str(t), "-frames:v", "1", "-q:v", "2", out_path,
        ]
        subprocess.run(cmd, capture_output=True)
        frames.append({
            "index": i,
            "timecode_seconds": float(t),
            "filepath": out_path,
        })

    return frames


def run_pipeline(video_path: str, timecodes: list, options: dict, progress_queue: queue.Queue):
    """
    Run the full pipeline in a background thread, pushing progress dicts onto
    progress_queue after each step. options keys: model, no_transcribe, no_ocr.
    Puts {"step": "complete", "rows": [...]} on success or {"step": "error", "error": "..."} on failure.
    """
    try:
        check_ffmpeg()

        model = options.get("model", "base")
        no_transcribe = options.get("no_transcribe", False)

        workspace = os.path.dirname(video_path)

        progress_queue.put({"step": "frames", "label": "Extracting frames", "progress": 15})
        frames = extract_frames_at_timecodes(video_path, timecodes, workspace)
        if not frames:
            raise RuntimeError("No frames were extracted.")
        progress_queue.put({"step": "frames", "label": "Frames extracted", "progress": 20, "count": len(frames)})

        metadata = get_video_metadata(video_path)
        transcript = []

        if not metadata["has_audio"]:
            no_transcribe = True

        if not no_transcribe:
            progress_queue.put({"step": "audio", "label": "Extracting audio", "progress": 30})
            audio_path = extract_audio(video_path, workspace)
            progress_queue.put({"step": "transcribe", "label": "Transcribing audio (this may take a while)", "progress": 50})
            transcript = transcribe_audio(audio_path, model, workspace, metadata["duration"])
            progress_queue.put({"step": "transcribe", "label": "Transcription complete", "progress": 80})
        else:
            progress_queue.put({"step": "transcribe", "label": "Skipping transcription", "progress": 80})

        progress_queue.put({"step": "align", "label": "Aligning transcript", "progress": 92})
        if not no_transcribe:
            aligned = align_transcript(frames, transcript)
        else:
            aligned = [""] * len(frames)

        rows = build_rows(frames, aligned, [[] for _ in frames])
        progress_queue.put({"step": "complete", "label": "Done", "progress": 100, "rows": rows})

    except Exception as e:
        progress_queue.put({"step": "error", "error": str(e)})


def start_pipeline(video_path: str, timecodes: list, options: dict) -> queue.Queue:
    q = queue.Queue()
    t = threading.Thread(target=run_pipeline, args=(video_path, timecodes, options, q), daemon=True)
    t.start()
    return q, t


def generate_pdf(rows: list, output_path: str):
    from reportlab.lib.pagesizes import letter
    from reportlab.lib import colors
    from reportlab.lib.units import inch
    from reportlab.platypus import SimpleDocTemplate, Table, TableStyle, Paragraph, Spacer, Image as RLImage
    from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle

    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)

    doc = SimpleDocTemplate(
        output_path,
        pagesize=letter,
        leftMargin=0.5 * inch,
        rightMargin=0.5 * inch,
        topMargin=0.5 * inch,
        bottomMargin=0.5 * inch,
    )

    styles = getSampleStyleSheet()
    normal = ParagraphStyle("normal", fontName="Helvetica", fontSize=9, leading=13)
    bold = ParagraphStyle("bold", fontName="Helvetica-Bold", fontSize=9, leading=13)

    col_frame = 2.8 * inch
    col_script = 4.7 * inch

    table_data = [
        [
            Paragraph("<b>FRAME</b>", bold),
            Paragraph("<b>SCRIPT</b>", bold),
        ]
    ]

    for row in rows:
        thumb_path = row.get("thumbnail_path", "")
        if os.path.exists(thumb_path):
            img = RLImage(thumb_path, width=2.6 * inch, height=None)
            img.hAlign = "CENTER"
            frame_cell = img
        else:
            frame_cell = Paragraph("[No image]", normal)

        vo_text = row.get("transcript") or "(none)"
        supers = row.get("supers", [])
        super_text = "  |  ".join(supers) if supers else "(none)"
        timecode = row.get("timecode_display", "")

        script_content = (
            f"<font size=7 color='#888888'>{timecode}</font><br/>"
            f"<b>VO:</b> {vo_text}<br/><br/>"
            f"<b>SUPER:</b> {super_text}"
        )
        script_cell = Paragraph(script_content, normal)

        table_data.append([frame_cell, script_cell])

    table = Table(table_data, colWidths=[col_frame, col_script])
    table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), colors.black),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("ALIGN", (0, 0), (-1, 0), "CENTER"),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("GRID", (0, 0), (-1, -1), 0.5, colors.grey),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#f7f7f7")]),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
        ("RIGHTPADDING", (0, 0), (-1, -1), 6),
        ("TOPPADDING", (0, 0), (-1, -1), 6),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
    ]))

    doc.build([table])
