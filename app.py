import json
import os
import queue
import subprocess

# Ensure Homebrew binaries (ffmpeg, ffprobe) are available when the server
# is launched outside a normal shell (e.g. via Automator or launchd)
os.environ["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", "")
import shutil
import tempfile
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from threading import Thread
from typing import Optional

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from pipeline import start_pipeline, generate_pdf
from storyboard import get_video_metadata, generate_docx, SUPPORTED_FORMATS

app = FastAPI()
app.mount("/static", StaticFiles(directory=str(Path(__file__).parent / "static")), name="static")

WORKSPACE_ROOT = Path("./workspace")
shutil.rmtree(WORKSPACE_ROOT, ignore_errors=True)
WORKSPACE_ROOT.mkdir(exist_ok=True)

STATIC_DIR = Path(__file__).parent / "static"


# ---------------------------------------------------------------------------
# Session state
# ---------------------------------------------------------------------------

@dataclass
class Session:
    id: str
    video_path: str
    workspace: str
    metadata: dict = field(default_factory=dict)
    rows: list = field(default_factory=list)
    thread: Optional[Thread] = None
    progress_queue: Optional[queue.Queue] = None
    status: str = "idle"  # idle | processing | done | error
    auto_frames: list = field(default_factory=list)  # [{time, filename}]
    auto_frames_ready: bool = False


_session: Optional[Session] = None


def get_session(session_id: str) -> Session:
    if _session is None or _session.id != session_id:
        raise HTTPException(status_code=404, detail="Session not found")
    return _session


# ---------------------------------------------------------------------------
# Auto frame extraction
# ---------------------------------------------------------------------------

def _extract_auto_frames(session: Session):
    """Extract frames at scene changes using ffmpeg's scene filter."""
    try:
        auto_dir = Path(session.workspace) / "auto_frames"
        auto_dir.mkdir(exist_ok=True)

        threshold = 0.3  # lower = more sensitive (more frames detected)
        filter_str = f"select='eq(n\\,0)+gt(scene\\,{threshold})',showinfo"
        result = subprocess.run(
            ["ffmpeg", "-y", "-i", session.video_path,
             "-vf", filter_str, "-vsync", "vfr", "-q:v", "3",
             str(auto_dir / "auto_%04d.jpg")],
            capture_output=True, text=True,
        )

        # Parse exact timestamps from ffmpeg stderr showinfo output
        timestamps = []
        for line in result.stderr.splitlines():
            if "pts_time:" in line and "Parsed_showinfo" in line:
                try:
                    timestamps.append(float(line.split("pts_time:")[1].split()[0]))
                except (IndexError, ValueError):
                    continue

        frame_files = sorted(auto_dir.glob("auto_*.jpg"))
        frames = []
        for i, f in enumerate(frame_files):
            ts = timestamps[i] if i < len(timestamps) else float(i)
            frames.append({"time": round(ts, 3), "filename": f.name})

        session.auto_frames = frames
    except Exception as e:
        print(f"[auto-frames] error: {e}")
    finally:
        session.auto_frames_ready = True


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get("/", response_class=HTMLResponse)
async def index():
    html = (STATIC_DIR / "index.html").read_text()
    return HTMLResponse(content=html)


@app.post("/api/upload")
async def upload_video(file: UploadFile = File(...)):
    global _session

    ext = Path(file.filename).suffix.lower()
    if ext not in SUPPORTED_FORMATS:
        raise HTTPException(status_code=400, detail=f"Unsupported format: {ext}")

    session_id = str(uuid.uuid4())
    workspace = WORKSPACE_ROOT / session_id
    workspace.mkdir(parents=True, exist_ok=True)

    video_path = workspace / f"video{ext}"
    with open(video_path, "wb") as f:
        shutil.copyfileobj(file.file, f)

    try:
        metadata = get_video_metadata(str(video_path))
    except Exception as e:
        shutil.rmtree(workspace, ignore_errors=True)
        raise HTTPException(status_code=422, detail=str(e))

    # Clean up previous session workspace
    if _session is not None:
        old_ws = Path(_session.workspace)
        if old_ws.exists():
            shutil.rmtree(old_ws, ignore_errors=True)

    _session = Session(
        id=session_id,
        video_path=str(video_path),
        workspace=str(workspace),
        metadata=metadata,
    )

    Thread(target=_extract_auto_frames, args=(_session,), daemon=True).start()

    return {
        "session_id": session_id,
        "metadata": metadata,
        "video_url": f"/video/{session_id}",
        "filename": file.filename,
    }


@app.get("/video/{session_id}")
async def serve_video(session_id: str):
    s = get_session(session_id)
    return FileResponse(s.video_path, media_type="video/mp4")


@app.get("/api/auto-frames/{session_id}")
async def get_auto_frames(session_id: str):
    s = get_session(session_id)
    frames = [
        {"time": f["time"], "thumbnail_url": f"/auto-thumbs/{session_id}/{f['filename']}"}
        for f in s.auto_frames
    ]
    return {"ready": s.auto_frames_ready, "frames": frames}


@app.get("/auto-thumbs/{session_id}/{filename}")
async def serve_auto_thumb(session_id: str, filename: str):
    s = get_session(session_id)
    path = Path(s.workspace) / "auto_frames" / filename
    if not path.exists():
        raise HTTPException(status_code=404, detail="Thumbnail not found")
    return FileResponse(str(path), media_type="image/jpeg")


@app.get("/thumbs/{session_id}/{filename}")
async def serve_thumb(session_id: str, filename: str):
    s = get_session(session_id)
    path = Path(s.workspace) / "frames" / filename
    if not path.exists():
        raise HTTPException(status_code=404, detail="Thumbnail not found")
    return FileResponse(str(path), media_type="image/jpeg")


# ---------------------------------------------------------------------------
# Processing
# ---------------------------------------------------------------------------

class ProcessRequest(BaseModel):
    session_id: str
    timecodes: list[float]
    options: dict = {}


@app.post("/api/process")
async def process(req: ProcessRequest):
    global _session
    s = get_session(req.session_id)

    if not req.timecodes:
        raise HTTPException(status_code=400, detail="No timecodes provided")

    # Clean previous frames
    frames_dir = Path(s.workspace) / "frames"
    if frames_dir.exists():
        shutil.rmtree(frames_dir)

    s.status = "processing"
    s.rows = []
    q, t = start_pipeline(s.video_path, req.timecodes, req.options)
    s.progress_queue = q
    s.thread = t

    return {"status": "started"}


@app.get("/api/progress/{session_id}")
async def progress_stream(session_id: str):
    s = get_session(session_id)

    def event_generator():
        while True:
            try:
                msg = s.progress_queue.get(timeout=0.5)
                yield f"data: {json.dumps(msg)}\n\n"
                if msg.get("step") == "complete":
                    s.rows = msg["rows"]
                    s.status = "done"
                    # Rewrite thumbnail_path to URL in stored rows
                    for row in s.rows:
                        tp = row.get("thumbnail_path", "")
                        if tp:
                            row["thumbnail_url"] = f"/thumbs/{session_id}/{Path(tp).name}"
                    break
                if msg.get("step") == "error":
                    s.status = "error"
                    break
            except queue.Empty:
                yield "data: {\"ping\": true}\n\n"

    return StreamingResponse(event_generator(), media_type="text/event-stream")


# ---------------------------------------------------------------------------
# Rows
# ---------------------------------------------------------------------------

@app.get("/api/rows/{session_id}")
async def get_rows(session_id: str):
    s = get_session(session_id)
    return s.rows


class SaveRowsRequest(BaseModel):
    rows: list


@app.post("/api/rows/{session_id}")
async def save_rows(session_id: str, req: SaveRowsRequest):
    s = get_session(session_id)
    s.rows = req.rows
    return {"saved": True}


# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------

@app.get("/api/export/docx/{session_id}")
async def export_docx(session_id: str):
    s = get_session(session_id)
    if not s.rows:
        raise HTTPException(status_code=400, detail="No rows to export")

    output_path = str(Path(s.workspace) / "storyboard.docx")
    filename = Path(s.video_path).stem

    # Restore thumbnail_path from thumbnail_url if needed
    rows = _restore_thumbnail_paths(s.rows, s.workspace)

    try:
        generate_docx(rows, s.metadata, filename, output_path)
    except RuntimeError as e:
        raise HTTPException(status_code=500, detail=str(e))

    return FileResponse(
        output_path,
        media_type="application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        filename="storyboard.docx",
    )


@app.get("/api/export/pdf/{session_id}")
async def export_pdf(session_id: str):
    s = get_session(session_id)
    if not s.rows:
        raise HTTPException(status_code=400, detail="No rows to export")

    output_path = str(Path(s.workspace) / "storyboard.pdf")
    rows = _restore_thumbnail_paths(s.rows, s.workspace)

    try:
        generate_pdf(rows, output_path)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

    return FileResponse(output_path, media_type="application/pdf", filename="storyboard.pdf")


def _restore_thumbnail_paths(rows: list, workspace: str) -> list:
    """Ensure thumbnail_path points to the actual file on disk."""
    restored = []
    for row in rows:
        r = dict(row)
        if not r.get("thumbnail_path") or not os.path.exists(r["thumbnail_path"]):
            url = r.get("thumbnail_url", "")
            if url:
                filename = url.split("/")[-1]
                r["thumbnail_path"] = str(Path(workspace) / "frames" / filename)
        restored.append(r)
    return restored
