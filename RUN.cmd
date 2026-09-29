@echo off
setlocal EnableExtensions
title StarNet - OpenCode Go Station
set "HERE=%~dp0"

rem --- find the launcher next to this script (project layout, then repo layout, then one level up) ---
set "LAUNCH="
if exist "%HERE%scripts\launch-opencodego.ps1" set "LAUNCH=%HERE%scripts\launch-opencodego.ps1"
if not defined LAUNCH if exist "%HERE%launch-opencodego.ps1" set "LAUNCH=%HERE%launch-opencodego.ps1"
if not defined LAUNCH if exist "%HERE%..\scripts\launch-opencodego.ps1" set "LAUNCH=%HERE%..\scripts\launch-opencodego.ps1"

if not defined LAUNCH (
  echo.
  echo   Could not find launch-opencodego.ps1 next to this script.
  echo   Expected:  %HERE%scripts\launch-opencodego.ps1
  echo.
  pause
  exit /b 1
)

echo.
echo   Starting the StarNet x OpenCode Go station...
echo   %LAUNCH%
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%LAUNCH%"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" echo   The launcher exited with code %RC% - read the messages above.
echo   The station keeps running in the background. You can close this window.
echo   Run this file again any time to restart it cleanly.
echo.
pause
exit /b %RC%
