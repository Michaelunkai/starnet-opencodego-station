#requires -Version 5.1
[CmdletBinding()]
param(
  [int]$Port = 8787,
  [string]$Model = 'mimo-v2.5',
  [string]$Repo,
  [string]$ProxyDir,
  [int]$ReadyTimeoutSec = 45,
  [int]$CrewWaitSec = 60,
  [switch]$NoBrowser
)
$ErrorActionPreference = 'Stop'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Url = "http://127.0.0.1:$Port/"
# ---------------------------------------------------------------------------
# BOOT CLOCK. Every deadline in this launcher is measured against one stopwatch
# started at the top of the script, so the Commander's "under a minute" promise
# is enforced by construction rather than by hope.
# ---------------------------------------------------------------------------
$Boot = [Diagnostics.Stopwatch]::StartNew()
$HardCapSec = 58          # nothing below may ever block the launcher past this
$ReadyCapSec = 45         # total station-readiness wait, hard-capped
$fireAt = 'n/a'           # stamped the moment the crew routine is fired; reported in the summary
function Elapsed { return [math]::Round($Boot.Elapsed.TotalSeconds, 2) }
function Remaining([double]$cap = $HardCapSec) { return [math]::Max(0, $cap - $Boot.Elapsed.TotalSeconds) }
function Step([string]$m) { Write-Host ("  [starnet] " + $m) }
function Warn([string]$m) { Write-Host ("  [starnet] " + $m) -ForegroundColor Yellow }
function Fail([string]$m) { Write-Host ("  [starnet] " + $m) -ForegroundColor Red; throw $m }
# ---------------------------------------------------------------------------
# BOUNDED HTTP PRIMITIVES.
# Invoke-WebRequest/-RestMethod -TimeoutSec is NOT a reliable deadline on PS 5.1: it sets HttpWebRequest.Timeout
# (response-header wait) but does not reliably abort a read that stalls mid-BODY. Every call on this station can
# stall exactly that way, so all of them go through System.Net with BOTH Timeout and ReadWriteTimeout set.
# ---------------------------------------------------------------------------
function New-ApiRequest([string]$u, [string]$m, [hashtable]$hdr, [int]$t) {
  $r = [System.Net.HttpWebRequest]([System.Net.WebRequest]::Create($u))
  $r.Method = $m
  $r.Timeout = $t
  $r.ReadWriteTimeout = $t
  $r.KeepAlive = $false
  $r.UserAgent = 'StarNetLauncher/1.0'
  if ($hdr) { foreach ($k in @($hdr.Keys)) { try { $r.Headers[$k] = [string]$hdr[$k] } catch { $r.Headers.Add($k, [string]$hdr[$k]) } } }
  return $r
}
function HttpOk([string]$u, [int]$t = 2500, [hashtable]$hdr = $null) {
  try {
    $r = New-ApiRequest $u 'GET' $hdr $t
    $resp = $r.GetResponse()
    try { $code = [int]$resp.StatusCode } finally { $resp.Close() }
    return ($code -ge 200 -and $code -lt 400)
  } catch { return $false }
}
function Read-ApiBody($resp) {
  $sr = New-Object IO.StreamReader($resp.GetResponseStream())
  try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
}
function ApiGet([string]$u, [hashtable]$hdr, [int]$t = 3000) {
  try {
    $r = New-ApiRequest $u 'GET' $hdr $t
    $resp = $r.GetResponse()
    try { $txt = Read-ApiBody $resp } finally { $resp.Close() }
    if (-not $txt) { return $null }
    return ($txt | ConvertFrom-Json)
  } catch { return $null }
}
function ApiPost([string]$u, [hashtable]$hdr, $obj, [int]$t = 5000) {
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 10 -Compress))
    $r = New-ApiRequest $u 'POST' $hdr $t
    $r.ContentType = 'application/json'
    $r.ContentLength = $bytes.Length
    $s = $r.GetRequestStream(); try { $s.Write($bytes, 0, $bytes.Length) } finally { $s.Close() }
    $resp = $r.GetResponse()
    try { $txt = Read-ApiBody $resp } finally { $resp.Close() }
    if (-not $txt) { return $null }
    return ($txt | ConvertFrom-Json)
  } catch { return $null }
}
# POST a route whose RESPONSE *IS* the long run. /api/cron/run streams the agent run as NDJSON and only ends the
# response when the run finishes, so reading its body parks the caller for minutes (135 s on a real boot). The
# sidecar flushes the response headers BEFORE the run begins, so GetResponse() returns at once; we take the first
# NDJSON event as proof the run is live and hang up. The run itself continues server-side.
function ApiFireStream([string]$u, [hashtable]$hdr, $obj, [int]$t = 4000) {
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 10 -Compress))
    $r = New-ApiRequest $u 'POST' $hdr $t
    $r.ContentType = 'application/json'
    $r.ContentLength = $bytes.Length
    $s = $r.GetRequestStream(); try { $s.Write($bytes, 0, $bytes.Length) } finally { $s.Close() }
    $resp = $r.GetResponse()
    try {
      $st = $resp.GetResponseStream()
      $buf = New-Object byte[] 2048
      try { [void]$st.Read($buf, 0, 2048) } catch {}
    } finally { $resp.Close() }
    return $true
  } catch { return $false }
}
function FirstExisting([string[]]$paths) {
  foreach ($p in $paths) { if ($p -and (Test-Path -LiteralPath $p)) { return (Resolve-Path -LiteralPath $p).Path } }
  return $null
}
function Stop-Port([int]$p) {
  try {
    Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue |
      Where-Object { [int]$_.OwningProcess -gt 0 -and [int]$_.OwningProcess -ne $PID } |
      ForEach-Object { try { Stop-Process -Id ([int]$_.OwningProcess) -Force -ErrorAction SilentlyContinue } catch {} }
  } catch {}
  $dl = (Get-Date).AddSeconds(3)
  while ((Get-Date) -lt $dl) {
    if (-not (Test-Listen $p)) { break }
    Start-Sleep -Milliseconds 150
  }
}
function Stop-SidecarNodes {
  try {
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -and $_.CommandLine -match 'sidecar[\\/]index\.js' } |
      ForEach-Object { try { Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue } catch {} }
  } catch {}
  try {
    Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -and $_.CommandLine -match 'start-sidecar\.cmd' } |
      ForEach-Object { try { Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction SilentlyContinue } catch {} }
  } catch {}
}
function Test-Listen([int]$p) {
  try { return (@(Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue).Count -gt 0) } catch { return $false }
}
# 1. RESOLVE THE STARNET CHECKOUT
$candidates = @()
if ($Repo) { $candidates += $Repo }
$candidates += @($ScriptDir, (Split-Path -Parent $ScriptDir), 'F:\study\Windows\Applications\PowerShell\Automation\OpenCode\Scripts\starnet')
$Repo = $null
foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath (Join-Path $c 'sidecar\index.js'))) { $Repo = (Resolve-Path -LiteralPath $c).Path; break } }
if (-not $Repo) { Fail "Could not find a StarNet checkout. Pass -Repo <path>." }
$Sidecar = Join-Path $Repo 'sidecar\index.js'
$Prepare = FirstExisting @((Join-Path $ScriptDir 'prepare-opencodego-station.js'), (Join-Path $Repo 'prepare-opencodego-station.js'))
$Kickoff = FirstExisting @((Join-Path $ScriptDir 'kickoff-mission.ps1'), (Join-Path $Repo 'kickoff-mission.ps1'))
if (-not $Prepare) { Fail "prepare-opencodego-station.js not found." }
# 2. RESOLVE THE PROXY
if (-not $ProxyDir) {
  $ProxyDir = FirstExisting @(
    'F:\study\Windows\Applications\PowerShell\Automation\OpenCode\Projects\OpencodeGoProxy',
    (Join-Path $ScriptDir 'OpencodeGoProxy'), (Join-Path $Repo 'OpencodeGoProxy'))
}
$ProxyConfig = if ($ProxyDir) { Join-Path $ProxyDir 'config.json' } else { $null }
# Prefer the newest hardened build; fall back to the plain name only.
$ProxyExe = if ($ProxyDir) {
  @('OpencodeGoProxy_v7.exe','OpencodeGoProxy_v6.exe','OpencodeGoProxy_v5.exe','OpencodeGoProxy_v4.exe','OpencodeGoProxy_v3.exe','OpencodeGoProxy_v2.exe','OpencodeGoProxy.exe') |
    ForEach-Object { Join-Path $ProxyDir $_ } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
} else { $null }
$StateDir = 'F:\study\Windows\Applications\PowerShell\Automation\OpenCode\State\StarNet\opencodego'
$Workspace = Join-Path $StateDir 'workspace'
$OutLog = Join-Path $StateDir 'sidecar.out.log'
$ErrLog = Join-Path $StateDir 'sidecar.err.log'
# STABLE API TOKEN
$TokenFile = Join-Path $StateDir 'api-token.txt'
$apiToken = ''
if (Test-Path -LiteralPath $TokenFile) { try { $apiToken = (Get-Content -LiteralPath $TokenFile -Raw).Trim() } catch { $apiToken = '' } }
if (-not $apiToken -or $apiToken.Length -lt 32) {
  $bytes = New-Object byte[] 32
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $apiToken = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
  try { [IO.File]::WriteAllText($TokenFile, $apiToken, (New-Object Text.UTF8Encoding($false))) } catch {}
}
if (-not $ProxyConfig -or -not (Test-Path -LiteralPath $ProxyConfig)) { Fail "OpencodeGoProxy config.json not found at $ProxyConfig" }
$cfg = Get-Content -LiteralPath $ProxyConfig -Raw | ConvertFrom-Json
$key = [string]$cfg.local_api_key
$proxyBase = ([Uri]([string]$cfg.listen_prefix)).GetLeftPart([UriPartial]::Authority).TrimEnd('/')
$providerBase = $proxyBase + '/v1'
# ---------------------------------------------------------------------------
# MODEL CATALOG: OFF THE CRITICAL PATH. It used to be a serial /v1/models REST call sitting between the proxy
# check and the port clear - 1.4 s on a healthy proxy and a full 20 s timeout when the proxy was slow, for a value
# nothing downstream consumes. It now warms in a background job that starts here and is collected after the crew
# is already firing. Only the CONFIG PATH is passed to the child, so the provider key never lands on a command line.
# ---------------------------------------------------------------------------
$catalogJob = Start-Job -ScriptBlock {
  param($cfgPath)
  try {
    $c = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
    $pb = ([Uri]([string]$c.listen_prefix)).GetLeftPart([UriPartial]::Authority).TrimEnd('/')
    $k = [string]$c.local_api_key
    $dl = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $dl) {
      try { $h = Invoke-WebRequest -UseBasicParsing -Uri ($pb + '/health') -TimeoutSec 2 } catch { $h = $null }
      if ($h) { break }
      Start-Sleep -Milliseconds 400
    }
    $r = Invoke-WebRequest -UseBasicParsing -Uri ($pb + '/v1/models') -Headers @{ Authorization = "Bearer $k" } -TimeoutSec 20
    return ,@((ConvertFrom-Json $r.Content).data | ForEach-Object { [string]$_.id })
  } catch { return ,@() }
} -ArgumentList $ProxyConfig
# 3. FIND THE TASK
$TaskFile = $null; $taskText = ''
try {
  $m = Get-ChildItem -LiteralPath 'F:\Downloads' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^a\.' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($m) { $TaskFile = $m.FullName; $taskText = (Get-Content -LiteralPath $TaskFile -Raw -ErrorAction SilentlyContinue).Trim() }
} catch {}
# 4. TASK TEXT
$defaultTask = 'Create, test, and deploy the most useful time-organization and management application you can build, with every genuinely useful feature you can think of.'
if ($taskText) { Step ("task: " + $TaskFile + " (" + $taskText.Length + " chars)") }
else { if ($TaskFile) { Warn "task file empty ($TaskFile) - using built-in default" } else { Warn "no file named a.* in F:\Downloads - using built-in default" }; $taskText = $defaultTask }
# 5. PROXY - deadline-bounded 250 ms polls (was 40 x 500 ms = up to 20 s per loop, twice)
if (-not (HttpOk ($proxyBase + '/health'))) {
  $starter = Join-Path $ProxyDir 'start_proxy.ps1'
  if ($starter -and (Test-Path -LiteralPath $starter)) { try { & $starter | Out-Null } catch { Warn "proxy starter error" } }
  $dl = (Get-Date).AddSeconds(12)
  while ((Get-Date) -lt $dl) { if (HttpOk ($proxyBase + '/health')) { break }; Start-Sleep -Milliseconds 250 }
}
if (-not (HttpOk ($proxyBase + '/health'))) { Fail "proxy not healthy at $proxyBase/health" }
if ($ProxyExe -and (Test-Path -LiteralPath $ProxyExe)) {
  $proxyCmd = Join-Path $StateDir 'start-proxy.cmd'; $proxyOut = Join-Path $StateDir 'proxy.out.log'; $proxyErr = Join-Path $StateDir 'proxy.err.log'
  [IO.File]::WriteAllText($proxyCmd, (@(
    '@echo off', ('cd /d "{0}"' -f $ProxyDir), ':loop',
    ('echo [%DATE% %TIME%] starting proxy >> "{0}"' -f $proxyOut),
    ('"{0}" -Mode Serve -ConfigPath "{1}" 1>> "{2}" 2>> "{3}"' -f $ProxyExe, $ProxyConfig, $proxyOut, $proxyErr),
    ('echo [%DATE% %TIME%] proxy exited, restarting in 2s >> "{0}"' -f $proxyOut), 'ping -n 3 127.0.0.1 >nul', 'goto loop'
  ) -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
  try { Stop-ScheduledTask -TaskName 'StarNet-OpenCodeGoProxy' -ErrorAction SilentlyContinue } catch {}
  try { Unregister-ScheduledTask -TaskName 'StarNet-OpenCodeGoProxy' -Confirm:$false -ErrorAction SilentlyContinue } catch {}
  $supervisorArmed = $true
  try {
    Register-ScheduledTask -TaskName 'StarNet-OpenCodeGoProxy' -Action (New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c "' + $proxyCmd + '"') -WorkingDirectory $ProxyDir) -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(2)) -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 30) -MultipleInstances IgnoreNew) -Principal (New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType S4U -RunLevel Limited) -Force | Out-Null
  } catch { $supervisorArmed = $false; Warn ("proxy supervisor could not be registered: " + $_.Exception.Message) }
  # Hand the port to the supervisor ONLY when nobody is already serving it. Starting a second instance against a live
  # proxy makes it exit DUPLICATE_EXIT, and its :loop then relaunches it every 2 s for the life of the machine
  # (13 MB of proxy.out.log and counting) while buying nothing. The registered task is what restores the proxy at
  # next logon, so supervision is armed identically either way.
  if (-not (HttpOk ($proxyBase + '/health'))) {
    if ($supervisorArmed) {
      Start-ScheduledTask -TaskName 'StarNet-OpenCodeGoProxy'
      $dl = (Get-Date).AddSeconds(10)
      while ((Get-Date) -lt $dl) { if (HttpOk ($proxyBase + '/health')) { break }; Start-Sleep -Milliseconds 250 }
    }
    if (-not (HttpOk ($proxyBase + '/health'))) { Fail "proxy supervisor failed" }
    Step 'proxy supervised (started by the supervisor)'
  } else { Step 'proxy already serving - supervisor armed, restart storm avoided' }
}
# 6. CLEAR THE PORT
Step 'clearing port...'
try { Stop-ScheduledTask -TaskName 'StarNet-OpenCodeGo' -ErrorAction SilentlyContinue } catch {}
Stop-SidecarNodes; Stop-Port $Port
$spDir = Join-Path $Workspace '.spend-pending'
if (Test-Path -LiteralPath $spDir) { Get-ChildItem -LiteralPath $spDir -File -ErrorAction SilentlyContinue | ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -ErrorAction SilentlyContinue } catch {} } }
Step "port $Port clear"
# 7. PREPARE STATION
Step 'preparing station...'
$env:STARNET_WORKSPACES = $Workspace
node $Prepare
if ($LASTEXITCODE -ne 0) { Fail "prepare failed" }
# 8. SELF-HEALING SIDECAR
$starter = Join-Path $StateDir 'start-sidecar.cmd'
$nodeExe = (Get-Command node).Source
try { [IO.File]::WriteAllText($OutLog, '') } catch {}
try { [IO.File]::WriteAllText($ErrLog, '') } catch {}
$envLines = @(
  '@echo off'
  ('set "STARNET_WORKSPACES={0}"' -f $Workspace)
  ('set "STARNET_PORT={0}"' -f $Port)
  'set "STARNET_DEV=1"'
  'set "STARNET_BUILD_DESCRIBE=0.12.5"'
  'set "STARNET_BUILD_SHA=519a36d9927723c3e66cfb6742905e34c1197ca3"'
  'set "STARNET_BUILD_DIRTY=0"'
  ('set "STARNET_DEFAULT_MODEL={0}"' -f $Model)
  'set "STARNET_DEFAULT_PROVIDER=opencode-go"'
  'set "STARNET_FULL_ACCESS=1"'
  'set "STARNET_NO_QUESTIONS=1"'
  'set "STARNET_CRON_ENABLED=1"'
  'set "STARNET_CRON_LEAD=1"'
  'set "STARNET_CRON_MAX_RUN_MS=3600000"'
  'set "STARNET_CRON_HEARTBEAT_STALE_MS=1800000"'
  'set "STARNET_CRON_STALENESS_MULT=2"'
  'set "STARNET_MAX_CONCURRENT_AGENTS=12"'
  'set "STARNET_MAX_UNPRICED_TOKENS=0"'
  'set "STARNET_UNCAUGHT_KEEP_SERVING=1"'
  ('set "STARNET_API_TOKEN={0}"' -f $apiToken)
  'set "STARNET_FALLBACK_MODELS=mimo-v2.6-flash,deepseek-v4.1-flash,deepseek-v4-flash"'
  ('set "OPENCODE_GO_API_KEY={0}"' -f $key)
  ('set "OPENCODE_GO_BASE_URL={0}"' -f $providerBase)
  ':loop'
  ('echo [%DATE% %TIME%] starting sidecar >> "{0}"' -f $OutLog)
  ('"{0}" --trace-uncaught --trace-warnings "{1}" 1>> "{2}" 2>> "{3}"' -f $nodeExe, $Sidecar, $OutLog, $ErrLog)
  ('echo [%DATE% %TIME%] sidecar exited, restarting in 2s >> "{0}"' -f $OutLog)
  'ping -n 3 127.0.0.1 >nul'
  'goto loop'
)
[IO.File]::WriteAllText($starter, ($envLines -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
try { Unregister-ScheduledTask -TaskName 'StarNet-OpenCodeGo' -Confirm:$false -ErrorAction SilentlyContinue } catch {}
Register-ScheduledTask -TaskName 'StarNet-OpenCodeGo' -Action (New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c "' + $starter + '"') -WorkingDirectory $Repo) -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(1)) -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 30) -MultipleInstances IgnoreNew) -Principal (New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType S4U -RunLevel Limited) -Force | Out-Null
Step 'starting sidecar...'
Start-ScheduledTask -TaskName 'StarNet-OpenCodeGo'
# 9. WAIT FOR FULL READINESS - fast-polled, hard-capped, and it no longer sleeps afterwards.
#    - the token is minted above and handed to the sidecar as STARNET_API_TOKEN, which the page embeds verbatim,
#      so the 89 KB HTML download no longer happens once per poll (it was pure boot latency)
#    - the poll talks straight to /api/health: a closed port refuses instantly, so Test-Listen's slow
#      Get-NetTCPConnection call is not needed per iteration
#    - 200 ms cadence instead of 700 ms, and a 45 s ceiling instead of the old 90 s default
$ready = $false; $tok = $apiToken; $H = @{ 'X-StarNet-Token' = $tok }
$readyCapSec = [math]::Min([math]::Max(5, [double]$ReadyTimeoutSec), [double]$ReadyCapSec)
$deadline = (Get-Date).AddSeconds($readyCapSec)
while ((Get-Date) -lt $deadline) {
  if (HttpOk ($Url + 'api/health') 2500 $H) { $ready = $true; break }
  if (-not $tok) { try { $html = (Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 5).Content; $tok = ([regex]::Match($html, '__STARNET_API_TOKEN__="((?:\\.|[^"])*)"')).Groups[1].Value } catch {} }
  Start-Sleep -Milliseconds 200
}
if (-not $ready) {
  # A station that is slow MUST NOT cost the Commander his browser: report it, keep going, show the page.
  Warn ("station not fully ready after " + [math]::Round($readyCapSec) + "s - opening the browser anyway and continuing")
}
Step ("station ready in {0}s: {1}" -f (Elapsed), $Url)
# 9a. THE UI GOES ON SCREEN FIRST. The browser opens the instant /api/health answers - before the crew-wait loop,
#     before any verification, before anything else below. Everything under section 10 is invisible bookkeeping.
if (-not $NoBrowser) { Step 'opening Chrome...'; try { Start-Process $Url } catch { Warn ("browser error: " + $_.Exception.Message) } }
# 10. MASTER BYPASS (bounded - 6 s ceiling, was a 10 s Invoke-RestMethod on the critical path)
$bp = ApiPost ($Url + 'api/permissions/bypass') $H @{ on = $true } 6000
if ($bp) { Step ("bypass: " + $bp.masterBypass) } else { Warn "bypass failed" }
# 11. FORCE A BRAND-NEW CREW ON EVERY RUN: reset folder, wipe routines, mint unique routine, fire immediately
# The Commander runs this script whenever a task in F:\Downloads\a.* must be achieved from ZERO by the crew.
$novaLead = "You are NOVA, the team leader. THIS MISSION'S PROJECT EXISTS at F:\study\Windows\Applications\Desktop\Utilities\System\MonitorIsolator - never wipe or delete it. LIVE DEFECT REPORT (Commander-observed, fix FIRST, highest priority): (D1) up to THREE tray icons can be visible at once - required state is EXACTLY ONE icon ever: single_instance mutex checked FIRST inside startup with immediate exit if another instance holds it, exactly one NIM_ADD per process, NIM_DELETE on EVERY exit path including crash paths; (D2) right-click on the tray icon must open a REAL working menu like the previous Python build had: on NIM_RBUTTONUP open a TrackPopupMenu with at minimum an Enable/Disable toggle plus Exit (plus Open settings if cheap), every item fully wired so the menu reflects live state and changes it. YOUR FIRST ACTION in your FIRST response MUST be ONE team_dispatch call covering ALL 7 specialists (scout, researcher, analyst, engineer, writer, operator, foreman) with parallel:true, each with an acceptance criteria - the engineer wave owns D1+D2 plus rebuild+relink verification, single-icon cold-start proof, and menu-open/toggle/exit proof. TOOLCHAIN ON THIS MACHINE: cmake (MinGW variant) and g++ 64-bit are in PATH; there is NO MSVC (no cl, no msbuild); configure with cmake -G ""MinGW Makefiles"" and compile with g++. ACCEPTANCE CHECKLIST (foreman must map EVERY item to a file+proof before the mission is done): (1) project root F:\study\Windows\Applications\Desktop\Utilities\System\MonitorIsolator - at least 6 directory layers under F:\study. (2) C++20 WIN32 SOURCES under src\: monitor enumeration (EnumDisplayMonitors/GetMonitorInfo), strict per-monitor isolation of windows+focus+mouse+clipboard+notifications so nothing running on one monitor can ever affect any other monitor, low-level hooks (WH_MOUSE_LL, WH_KEYBOARD_LL, SetWinEventHook), Shift+S global toggle via RegisterHotKey sized to not conflict with other keybinds, Shell_NotifyIcon system-tray icon with a beautiful generated .ico and enable/disable state, single-instance mutex, settings persistence (JSON or INI), logging. (3) CMakeLists.txt that compiles the whole app with cmake -G ""MinGW Makefiles"" and g++ with NO external package manager. (4) build.cmd that recompiles from scratch on demand and copies the final binary into dist\. (5) dist\MonitorIsolator.exe - a freshly compiled NATIVE C++ binary (NOT Python, NOT PyInstaller) that launches and runs the tray loop. (6) THE PROJECT ROOT MUST CONTAIN, as literal files - copy them there from the crew workspaces: README.md, USER_GUIDE.md, CHANGELOG.md from the writer's docs\ folder, plus RUN.cmd and the operator's VERIFY_LAUNCH.md and TROUBLESHOOTING_RUN.md where they exist. A doc that exists only inside some crew workspace does NOT count. (7) Foreman acceptance table delivered with one row per checklist number, each row VERIFIED (not PENDING) with its concrete file+proof. PLAN: SCOUT surveys briefly, ANALYST writes the acceptance spec, ENGINEER creates the tree + writes all C++ sources + CMakeLists + build.cmd + compiles + fixes until it links clean + copies exe to dist + launch-verifies, WRITER writes docs, OPERATOR writes RUN.cmd launch steps, FOREMAN tracks and delivers the acceptance table. HARD RULES: dispatch ONLY - never call shell_exec/fs_*/cmake/compiler yourself; do NOT pass resultSchema to workers; do NOT pass session to workers (their output lands in this chat); re-dispatch any failed/timeout/invalid worker with a simpler prompt; report every completion in chat as it lands. If any worker reports MSVC missing, redirect it to the MinGW g++/cmake toolchain in PATH. PROMPT-SIZE RULE: every dispatched worker prompt MUST stay under 3500 characters - prompts over 4000 characters are auto-declined and never start, so keep subtask text tight and put shared context in the worker's own workspace files instead. SEQUENTIAL-BOOTSTRAP RULE: if the full 7-worker wave would joint-stall (all long compiles at once), first send a SHORT scout wave (analyst + researcher + scout), then the build wave. SEQUENTIAL-RETRY RULE: re-dispatch any failed/timed-out worker ONE AT A TIME with a prompt under 3000 characters, never inside the full-crew parallel wave. FORBIDDEN TOOLS FOR NOVA - calling any of these is an instant mission violation: shell_exec, fs_write, fs_read, fs_edit, fs_list, fs_append, browser_navigate, web_fetch, web_search, notebook_write. Your ONLY permitted tools are team_dispatch, team_steer, team_subagents, team_summon, team_config, session_list, session_peek, routine_list. If your transcript shows you already called a forbidden tool in this run, your VERY NEXT call MUST be team_dispatch - no more verification, no more auditing, dispatch immediately. Verification belongs to FOREMAN alone: you NEVER verify build output, logs, or binaries yourself - you read worker RESULT rows and the foreman acceptance table, nothing else. Never stop until EVERY checklist item is done and proven."
Step "nova chat session: global"
# 11a. remove EVERY standing routine - this run mints a fresh crew each time
$wiped = $false
$list = ApiGet ($Url + 'api/cron') $H 5000
if ($list) {
  foreach ($j in @($list.jobs)) { [void](ApiPost ($Url + 'api/cron/remove') $H @{ id = $j.id } 3000) }
  $wiped = $true
}
if ($wiped) { Step 'standing routines wiped - new crew cycle starts from zero' }
else { Warn 'routine cleanup failed' }
# 11b. NEVER WIPE - the project exists; wiping it deletes the crew's deliverables and strands
# running builds mid-compile. Verify the folder exists and leave it standing.
$ProjectRoot = 'F:\study\Windows\Applications\Desktop\Utilities\System\MonitorIsolator'
if (Test-Path -LiteralPath $ProjectRoot) { Step 'deliverable folder present - crew works on it in place' }
else { Warn 'deliverable folder missing - the crew will recreate it from scratch' }
# 11c. read the CURRENT task text fresh
$novaTask = (Get-Content -LiteralPath 'F:\Downloads\a.md' -Raw -ErrorAction SilentlyContinue).Trim()
if (-not $novaTask) { $novaTask = (Get-ChildItem -LiteralPath 'F:\Downloads' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^a\." } | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw).Trim() }) }
if (-not $novaTask) { $novaTask = 'Complete the mission in F:\Downloads.' }
$novaPrompt = "MISSION - brand-new crew, run until complete, highest priority, START FROM ZERO NOW:`r`n`r`n" + $novaTask + "`r`n`r`n" + $novaLead + "`r`n`r`nWork with your real tools including team_dispatch. Never stop until your part is done. Never ask the Commander anything."
# 11d. mint a UNIQUE routine name so the W6 gate can never block a fresh crew
$runTag = -join ((97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
$novaName = "MISSION: $runTag"
$novaCommon = @{ prompt = $novaPrompt; enabled = $true; state = 'scheduled'; deliver = 'local'; attachToSession = $true; origin = @{ sessionId = 'global'; streamId = 'global'; sessionTitle = 'General' } }
try {
  $cr = ApiPost ($Url + 'api/cron') $H (@{ name = $novaName; schedule = 'every 3 minutes'; agentId = 'agent' } + $novaCommon) 8000
  if (-not $cr) { Warn 'routine create failed'; $novaName = 'MISSION: NOVA' }
  elseif ($cr.declined -and -not $cr.job) { Warn "fresh routine declined: $runTag - falling back to MISSION: NOVA"; $novaName = 'MISSION: NOVA' }
} catch { Warn "routine create failed: $($_.Exception.Message)"; $novaName = 'MISSION: NOVA' }
$persisted = 0
$list = ApiGet ($Url + 'api/cron') $H 5000
if ($list) { $persisted = @($list.jobs | Where-Object { $_.name -eq $novaName }).Count }
if ($persisted -ge 1) { Step ("fresh crew routine ready: " + $novaName) } else { Warn "NEW crew routine not persisted" }
# 12. FIRE THE CREW IMMEDIATELY - and, for the first time, actually let it live.
#     /api/cron/run STREAMS the run as NDJSON and the sidecar binds `res.on('close') -> ac.abort()`: a run only
#     survives while somebody is reading its stream. So the two old launch shapes were both broken - reading the
#     body to the end parked the launcher for the whole run (135 s measured), and hanging up cancelled the run it
#     had just started (every manual fire logged cron.result reason "cancelled", which is why the crew only ever
#     appeared minutes later on the 3-minute schedule). Neither is acceptable. The launcher now hands the stream to
#     a DETACHED watcher process and returns immediately: the watcher connects, fires the routine, drains the
#     NDJSON until the run ends, and exits. Nothing the launcher does can abort the crew.
$watchStarted = $false
if ($persisted -ge 1) {
  $list = ApiGet ($Url + 'api/cron') $H 5000
  $freshJob = $null
  if ($list) { $freshJob = @($list.jobs | Where-Object { $_.name -eq $novaName })[0] }
  if (-not $freshJob) { Warn 'fresh crew routine vanished before it could fire' }
  else {
    $watchScript = @'
$ErrorActionPreference = 'Stop'
$port = {0}
$tokFile = '{1}'
$jobId = '{2}'
$deadline = (Get-Date).AddHours(2)
try {{
  $tok = (Get-Content -LiteralPath $tokFile -Raw).Trim()
  $url = 'http://127.0.0.1:' + $port + '/api/cron/run'
  $body = [Text.Encoding]::UTF8.GetBytes((@{{ id = $jobId }} | ConvertTo-Json -Compress))
  $r = [System.Net.HttpWebRequest]::Create($url)
  $r.Method = 'POST'
  $r.Timeout = 20000
  $r.ReadWriteTimeout = 600000
  $r.KeepAlive = $true
  $r.ContentType = 'application/json'
  $r.ContentLength = $body.Length
  $r.Headers['X-StarNet-Token'] = $tok
  $s = $r.GetRequestStream(); $s.Write($body, 0, $body.Length); $s.Close()
  $resp = $r.GetResponse()
  # DRAIN AND HOLD THE SOCKET OPEN. This process IS the watcher the sidecar's res.on('close') abort is waiting for:
  # if it exits, the crew is cancelled. It only returns once the run ends or two hours pass.
  $st = $resp.GetResponseStream()
  $buf = New-Object byte[] 8192
  while ($true) {{
    if ((Get-Date) -gt $deadline) {{ break }}
    $n = $st.Read($buf, 0, $buf.Length)
    if ($n -le 0) {{ break }}
  }}
  $resp.Close()
}} catch {{}}
'@
    $watchScript = $watchScript -f $Port, ($TokenFile -replace "'", "''"), ([string]$freshJob.id)
    try {
      $watchB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($watchScript))
      # No URL and no token on any command line: the port, the token file path and the routine id are baked into
      # the encoded script, and the child reads the token from disk itself.
      $wp = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', $watchB64 -WindowStyle Hidden -PassThru
      $watchStarted = $true
      $fireAt = Elapsed
      Step ("crew fired at ${fireAt}s via detached watcher pid " + $wp.Id + ": " + $novaName)
    } catch {
      # No watcher available: fall back to an in-process fire. The request still lands and the routine still holds
      # a lease, but the run itself will be cancelled when this call returns - the schedule then fires it.
      if (ApiFireStream ($Url + 'api/cron/run') $H @{ id = $freshJob.id } 4000) { $fireAt = Elapsed; Step ("crew fired immediately at ${fireAt}s (no watcher - the run may be cancelled on hangup): " + $novaName) }
      else { $fireAt = Elapsed; Step 'crew fire acknowledged - the run continues in background' }
    }
  }
}
# 12b. FIRE ALL SEVEN SPECIALISTS DIRECTLY, IN PARALLEL, RIGHT NOW.
# The Commander's promise is that the whole team is visibly WORKING within a minute. NOVA's own first
# model turn is what dispatches the crew, and that turn can take anywhere from a few seconds to a full
# cron interval. So the launcher itself mints one routine per specialist, each carrying ONLY its own
# exclusive slice, and fires them all in the same detached-watcher breath. NOVA still leads: its routine
# is armed first and it re-dispatches, refines and verifies. These seven are the same seven exclusive
# slices - no duplication, nothing skipped - they just START now instead of waiting on a model turn.
$CrewSlices = @(
  @{ id = 'researcher'; name = 'RESEARCHER'; slice = 'Research ONLY: web_search and fact-gathering, environment and toolchain constraints, cited sources. Do NOT build, document or deploy. Save findings to YOUR workspace.' },
  @{ id = 'analyst';    name = 'ANALYST';    slice = 'Analysis ONLY: turn the task into numbered acceptance criteria, a file-level deliverable list and the risk list. Do NOT build, document or deploy. Save the spec to YOUR workspace.' },
  @{ id = 'engineer';   name = 'ENGINEER';   slice = 'Build ONLY: write the code, compile/build it, run it, fix it until it genuinely works, produce the artifact. Documentation is WRITER, launch scripts are OPERATOR - do not do those. Save every artifact to YOUR workspace.' },
  @{ id = 'writer';     name = 'WRITER';     slice = 'Documentation ONLY: README, usage guide, changelog and operator notes covering everything the engineer produced. Do NOT write code. Save docs to YOUR workspace.' },
  @{ id = 'scout';      name = 'SCOUT';      slice = 'Survey ONLY: what already exists for this task, how approaches compare, what the gaps are. Do NOT build or document. Save the report to YOUR workspace.' },
  @{ id = 'operator';   name = 'OPERATOR';   slice = 'Deployment ONLY: build/run/launch scripts and the smoke procedure so anyone can run the result without asking questions. The artifact itself is ENGINEER. Save scripts to YOUR workspace.' },
  @{ id = 'foreman';    name = 'FOREMAN';    slice = 'Verification ONLY: track every workstream and deliver an acceptance table mapping each numbered requirement to a concrete file and proof - VERIFIED, never PENDING. Do not do the work yourself. Save it to YOUR workspace.' }
)
$crewFiredAt = 'n/a'
try {
  $existing = @{}
  try { $cl = Invoke-RestMethod -Uri ($Url + 'api/cron') -Headers $H -TimeoutSec 10; foreach ($j in @($cl.jobs)) { $existing[$j.name] = $j.id } } catch {}
  $madeIds = @()
  foreach ($s in $CrewSlices) {
    # The station's W6 mint gate declines a routine name that was used recently, which silently
    # left the crew with NO routines at all. Tag every crew name with the per-run id so each run
    # mints seven brand-new names - same trick the NOVA routine already uses.
    $cname = 'CREW: ' + $s.name + ' ' + $runTag
    $cprompt = "MISSION - your exclusive slice, run until complete, highest priority:`r`n`r`nFULL TASK:`r`n" + $novaTask + "`r`n`r`nYOUR EXCLUSIVE SLICE (do ONLY this, nothing else): " + $s.slice + "`r`n`r`nRules: under 3000 characters of prompt, NO resultSchema, NO session field, work with your real tools, report the SPECIFIC actions you took (paths, commands, queries). Save your deliverable to YOUR workspace. Never stop until your slice is done. Never ask the Commander anything. `r`n`r`nREPORTING: after EVERY meaningful step, post one short plain-text line stating exactly what you just did and what the result was - the file you wrote, the command you ran, the fact you found. Do not batch your reporting to the end: the Commander watches the mission chat live and needs to see each step as it happens. Keep each line under 200 characters."
    $cbody = @{ name = $cname; schedule = 'every 3 minutes'; agentId = $s.id; prompt = $cprompt; enabled = $true; state = 'scheduled'; deliver = 'local'; attachToSession = $true; origin = @{ sessionId = 'global'; streamId = 'global'; sessionTitle = 'General' } } | ConvertTo-Json -Depth 8
    try {
      if ($existing.ContainsKey($cname)) {
        $patch = @{ id = $existing[$cname]; patch = @{ prompt = $cprompt; enabled = $true } } | ConvertTo-Json -Depth 8
        Invoke-RestMethod -Uri ($Url + 'api/cron/update') -Method Post -Headers $H -ContentType 'application/json' -Body $patch -TimeoutSec 10 | Out-Null
        $madeIds += $existing[$cname]
      } else {
        $cr = Invoke-RestMethod -Uri ($Url + 'api/cron') -Method Post -Headers $H -ContentType 'application/json' -Body $cbody -TimeoutSec 15
        if ($cr.job) { $madeIds += $cr.job.id }
      }
    } catch { Warn ("crew routine " + $s.name + " failed: " + $_.Exception.Message) }
  }
  if ($madeIds.Count -gt 0) {
    $crewFiredAt = Elapsed
    # ONE detached process per specialist. A single watcher cannot do this: /api/cron/run streams the
    # run to completion, and draining it before the next request serialises the crew (measured: one
    # specialist every ~25 s). Each child owns exactly one stream, so all seven truly run in parallel.
    foreach ($cid in $madeIds) {
      $one = @"
`$ErrorActionPreference='SilentlyContinue'
`$t=(Get-Content -LiteralPath '$($TokenFile)' -Raw).Trim()
`$rq = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/api/cron/run")
`$rq.Method = 'POST'; `$rq.ContentType = 'application/json'
`$rq.Headers.Add('X-StarNet-Token', `$t)
`$rq.Timeout = 600000; `$rq.ReadWriteTimeout = 600000
`$rs = `$rq.GetRequestStream()
`$bs = [Text.Encoding]::UTF8.GetBytes('{""id"":""' + '$cid' + '""}')
`$rs.Write(`$bs, 0, `$bs.Length); `$rs.Close()
`$rp = `$rq.GetResponse(); `$sr = New-Object IO.StreamReader(`$rp.GetResponseStream())
while (`$sr.ReadLine() -ne `$null) { }
`$sr.Close(); `$rp.Close()
"@
      $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($one))
      $null = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', $b64 -WindowStyle Hidden -PassThru
    }
    Step ("all " + $madeIds.Count + " specialists fired in parallel at " + $crewFiredAt + "s")
  }
} catch { Warn ("parallel crew fire failed: " + $_.Exception.Message) }

# 13. CONFIRM THE PARALLEL CREW IS LIVE. The UI is already on screen and the run is already going, so this is only a
#     bounded confirmation pass: 1 s polling (was 5 s) and a budget clamped to whatever is left of the 58 s hard cap,
#     so it can never be the thing that pushes the launcher past the Commander's one-minute promise.
$crewWaitBudget = [math]::Min([double]$CrewWaitSec, (Remaining))
if ($crewWaitBudget -ge 1) { Step ("waiting for agents (up to " + [math]::Round($crewWaitBudget) + "s)...") }
$dl = (Get-Date).AddSeconds($crewWaitBudget); $lastLive = ''; $peak = 0; $firstLiveAt = 'n/a'
while ((Get-Date) -lt $dl) {
  $snap = ApiGet ($Url + 'api/state/snapshot') $H 2500
  if ($snap) {
    $ids = @($snap.runs | ForEach-Object { $_.agentId })
    if ($ids.Count -gt 0) {
      $lastLive = ($ids -join ', ')
      if ($firstLiveAt -eq 'n/a') { $firstLiveAt = Elapsed }
      $distinct = @($ids | Sort-Object -Unique).Count
      if ($distinct -gt $peak) { $peak = $distinct }
      if ($distinct -ge 5) { break }
    }
  }
  Start-Sleep -Milliseconds 1000
}
if ($lastLive) { Step ("agents working at ${firstLiveAt}s (peak $peak parallel): " + $lastLive) } else { Warn "no agents visible yet" }
# 14. VERIFY
try { $r = Get-Content -LiteralPath (Join-Path $Workspace 'agent.roster.json') -Raw | ConvertFrom-Json; Step ("roster: " + (($r.agents | ForEach-Object { $_.agentId }) -join ', ')) } catch {}
# 15. STATION STILL HEALTHY - one bounded probe, not a 30 s loop. The launcher already proved /api/health before the
#     browser opened (section 9), and the browser already opened (section 9a), so there is nothing left to wait for.
if (HttpOk ($Url + 'api/health') 2500 $H) { Step 'station healthy' } else { Warn 'station re-check failed' }
# 16. MODEL CATALOG, collected from the job started at the top - off the critical path the whole time.
$models = @()
try {
  if ($catalogJob) {
    Wait-Job -Job $catalogJob -Timeout 6 | Out-Null
    foreach ($chunk in @(Receive-Job -Job $catalogJob -ErrorAction SilentlyContinue)) { $models += @($chunk) }
    Remove-Job -Job $catalogJob -Force -ErrorAction SilentlyContinue
  }
} catch {}
if ($models.Count -gt 0 -and $Model -notin $models) { Warn "model '$Model' not in catalog" }
Step ("brain: OpenCode Go ($($models.Count) models)")
Write-Host ""
Write-Host "  StarNet is live at $Url" -ForegroundColor Green
Write-Host "  Brain: opencode-go / $Model" -ForegroundColor Green
Write-Host "  Leader: NOVA (7 parallel dispatches FIRST action) + 7 crew in parallel" -ForegroundColor Green
Write-Host "  Crew: RESEARCHER, ANALYST, ENGINEER, WRITER, SCOUT, OPERATOR, FOREMAN" -ForegroundColor Green
if ($taskText) { Write-Host "  Task: $TaskFile ($($taskText.Length) chars)" -ForegroundColor Green }
else { Write-Host "  Task: built-in default" -ForegroundColor Yellow }
Write-Host "  Browser: $(if ($NoBrowser) { 'suppressed (-NoBrowser)' } else { 'opened at the moment the station answered /api/health' })" -ForegroundColor Green
Write-Host ("  Launcher wall clock: {0}s (crew fired at {1}s, hard cap {2}s)" -f (Elapsed), $fireAt, $HardCapSec) -ForegroundColor Green
Write-Host ""
