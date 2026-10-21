# Storyboard CAD Tool — CLI POC

## Prerequisites
- Python 3.10+
- ffmpeg

## Install ffmpeg
```
Mac:    brew install ffmpeg
Linux:  sudo apt install ffmpeg
Windows: https://ffmpeg.org/download.html (add to PATH)
```

## Install Python dependencies
```
pip install -r requirements.txt
```

Note: First run will download the Whisper base model (~150MB).
EasyOCR will also download model weights (~100MB) on first use.

## Usage
```
python storyboard.py path/to/video.mp4
```

## Options
```
--output FILE        Output DOCX path (default: ./output/storyboard.docx)
--interval N         Seconds between contact sheet frames (default: 2)
--model MODEL        Whisper model: tiny, base, small (default: base)
--no-transcribe      Skip transcription
--no-ocr             Skip OCR
--keep-workspace     Do not delete temporary files after export
```

## Known Limitations
- Transcription of a 10-minute video takes 5–15 minutes on CPU without a GPU
- OCR accuracy is variable on stylised fonts and animated text
- OCR only scans the bottom 30% of each frame by default
