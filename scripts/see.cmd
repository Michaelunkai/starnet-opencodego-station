@echo off
REM ============================================================================
REM  see - GLOBAL VISION BRIDGE  (installed permanently; source of truth on F:)
REM
REM  Most models on this host are TEXT-ONLY. A screenshot tool hands them bytes
REM  they cannot read, which is how an agent ends up claiming visual verification
REM  it never performed. This command converts pixels into TEXT via a
REM  vision-capable model on the OpenCodeGo proxy, so it works for EVERY model
REM  and EVERY session - sighted or blind.
REM
REM  USAGE
REM    see --url http://127.0.0.1:8787/ "what is on screen?"
REM    see --url http://127.0.0.1:8787/ --check C:\Users\Admin\bin\see-checks.json
REM    see --monitor                 all displays (this box: 7680x2160 across 2 panels)
REM    see --monitor 0               first display only
REM    see --file shot.png "describe this"
REM    see --probe                   which models can actually see, right now
REM
REM  EXIT CODES   0 ok (and, with --check, zero FAIL)  1 a check failed
REM               3 capture failed   5 no sighted model available
REM ============================================================================
setlocal
set "SEE_HOME=F:\study\Windows\Applications\PowerShell\Automation\OpenCode\vision-bridge"
if not exist "%SEE_HOME%\see.py" (
  echo see: bridge missing at %SEE_HOME%\see.py 1>&2
  exit /b 9
)
where python >nul 2>&1
if errorlevel 1 (
  echo see: python is not on PATH 1>&2
  exit /b 9
)
python "%SEE_HOME%\see.py" %*
exit /b %ERRORLEVEL%
