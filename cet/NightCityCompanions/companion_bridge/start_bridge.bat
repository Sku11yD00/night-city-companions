@echo off
rem Starts the Night City Companions bridge. Add --voice to hear replies, --listen to talk with your microphone.
cd /d "%~dp0"
if not exist .venv (
  py -3 -m venv .venv
  .venv\Scripts\python -m pip install -r requirements.txt
)
.venv\Scripts\python bridge.py %*
pause
