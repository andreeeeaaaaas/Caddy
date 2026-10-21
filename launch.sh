#!/bin/bash
cd "$(dirname "$0")"

# Ensure Homebrew and system binaries are on PATH
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Kill any existing instance on port 8000
lsof -ti :8000 | xargs kill -9 2>/dev/null

# Activate virtualenv if one exists alongside this script
if [ -f ".venv/bin/activate" ]; then
  source .venv/bin/activate
fi

# Start server in background, log to /tmp/caddy.log
/Library/Frameworks/Python.framework/Versions/3.13/bin/uvicorn app:app --port 8000 --reload > /tmp/caddy.log 2>&1 &

# Wait until the server responds (up to 10s)
for i in $(seq 1 20); do
  sleep 0.5
  curl -s http://localhost:8000 > /dev/null && break
done

open http://localhost:8000
