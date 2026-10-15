@echo off
REM Runs the NFL local HTTP API (nfl.api.v1) in this window on http://127.0.0.1:8086/ . Ctrl+C stops it.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\nfl_api_v1.ps1" -RepoRoot "%~dp0." -Prefix "http://127.0.0.1:8086/"
