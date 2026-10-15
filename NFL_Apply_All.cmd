@echo off
REM One-click: prove + verify + refresh + commit the NFL witness.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\_RUN_nfl_apply_all_v1.ps1" -RepoRoot "%~dp0."
echo.
echo Exit code: %ERRORLEVEL%
pause
