#requires -Version 5.1
[CmdletBinding()]
param(
  [int]$Port = 8787,
  [string]$Model = 'mimo-v2.5',
  [string]$Repo,
  [string]$ProxyDir,
  [int]$ReadyTimeoutSec = 90,
  [int]$CrewWaitSec = 60,
  [switch]$NoBrowser
)
$ErrorActionPreference = 'Stop'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Url = "http://127.0.0.1:$Port/"
function Step([string]$m) { Write-Host ("  [starnet] " + $m) }
function Warn([string]$m) { Write-Host ("  [starnet] " + $m) -ForegroundColor Yellow }
function Fail([string]$m) { Write-Host ("  [starnet] " + $m) -ForegroundColor Red; throw $m }
function HttpOk([string]$u, [int]$t = 4) {
  try { $r = Invoke-WebRequest -UseBasicParsing -Uri $u -TimeoutSec $t; return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400) } catch { return $false }
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
  $dl = (Get-Date).AddSeconds(5)
  while ((Get-Date) -lt $dl) {
    if (@(Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue).Count -eq 0) { break }
    Start-Sleep -Milliseconds 250
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
# 5. PROXY
if (-not (HttpOk ($proxyBase + '/health'))) {
  $starter = Join-Path $ProxyDir 'start_proxy.ps1'
  if ($starter -and (Test-Path -LiteralPath $starter)) { try { & $starter | Out-Null } catch { Warn "proxy starter error" } }
  for ($i = 0; $i -lt 40 -and -not (HttpOk ($proxyBase + '/health')); $i++) { Start-Sleep -Milliseconds 500 }
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
  try { Unregister-ScheduledTask -TaskName 'StarNet-OpenCodeGoProxy' -Confirm:$false -ErrorAction SilentlyContinue } catch {}
  Register-ScheduledTask -TaskName 'StarNet-OpenCodeGoProxy' -Action (New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c "' + $proxyCmd + '"') -WorkingDirectory $ProxyDir) -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(2)) -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 30) -MultipleInstances IgnoreNew) -Principal (New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType S4U -RunLevel Limited) -Force | Out-Null
  Start-ScheduledTask -TaskName 'StarNet-OpenCodeGoProxy'
  for ($i = 0; $i -lt 40 -and -not (HttpOk ($proxyBase + '/health')); $i++) { Start-Sleep -Milliseconds 500 }
  if (-not (HttpOk ($proxyBase + '/health'))) { Fail "proxy supervisor failed" }
  Step 'proxy supervised'
}
$mr = Invoke-RestMethod -Uri ($providerBase + '/models') -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 20
$models = @($mr.data | ForEach-Object { [string]$_.id })
if ($models.Count -gt 0 -and $Model -notin $models) { Warn "model '$Model' not in catalog" }
Step ("brain: OpenCode Go ($($models.Count) models)")
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
# 9. WAIT FOR FULL READINESS
$ready = $false; $tok = ''
$deadline = (Get-Date).AddSeconds($ReadyTimeoutSec)
while ((Get-Date) -lt $deadline) {
  if (Test-Listen $Port) {
    try {
      $html = (Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 5).Content
      $tok = ([regex]::Match($html, '__STARNET_API_TOKEN__="((?:\\.|[^"])*)"')).Groups[1].Value
      if ($tok) {
        $h = @{ 'X-StarNet-Token' = $tok }
        $hr = Invoke-WebRequest -UseBasicParsing -Uri ($Url + 'api/health') -Headers $h -TimeoutSec 5
        if ($hr.StatusCode -ge 200 -and $hr.StatusCode -lt 400) { $ready = $true; break }
      }
    } catch {}
  }
  Start-Sleep -Milliseconds 700
}
if (-not $ready) { Fail "station did not become fully ready on $Url" }
Start-Sleep -Seconds 3
Step "station ready: $Url"
# 10. MASTER BYPASS
$H = @{ 'X-StarNet-Token' = $tok }
try {
  $bp = Invoke-RestMethod -Uri ($Url + 'api/permissions/bypass') -Method Post -Headers $H -ContentType 'application/json' -Body (@{ on = $true } | ConvertTo-Json) -TimeoutSec 10
  Step ("bypass: " + $bp.masterBypass)
} catch { Warn "bypass failed" }
# 11. FORCE A BRAND-NEW CREW ON EVERY RUN: reset folder, wipe routines, mint unique routine, fire immediately
# The Commander runs this script whenever a task in F:\Downloads\a.* must be achieved from ZERO by the crew.
$novaLead = "You are NOVA, the team leader. A BRAND-NEW CREW STARTS THIS MISSION FROM ABSOLUTE ZERO - the project folder was wiped by the launcher; build EVERYTHING from scratch. YOUR FIRST ACTION in your FIRST response MUST be ONE team_dispatch call covering ALL 7 specialists (scout, researcher, analyst, engineer, writer, operator, foreman) with parallel:true, each with an acceptance criteria. TOOLCHAIN ON THIS MACHINE: cmake (MinGW variant) and g++ 64-bit are in PATH; there is NO MSVC (no cl, no msbuild); configure with cmake -G ""MinGW Makefiles"" and compile with g++. ACCEPTANCE CHECKLIST (foreman must map EVERY item to a file+proof before the mission is done): (1) project root F:\study\Windows\Applications\Desktop\Utilities\System\MonitorIsolator - at least 6 directory layers under F:\study. (2) C++20 WIN32 SOURCES under src\: monitor enumeration (EnumDisplayMonitors/GetMonitorInfo), strict per-monitor isolation of windows+focus+mouse+clipboard+notifications so nothing running on one monitor can ever affect any other monitor, low-level hooks (WH_MOUSE_LL, WH_KEYBOARD_LL, SetWinEventHook), Shift+S global toggle via RegisterHotKey sized to not conflict with other keybinds, Shell_NotifyIcon system-tray icon with a beautiful generated .ico and enable/disable state, single-instance mutex, settings persistence (JSON or INI), logging. (3) CMakeLists.txt that compiles the whole app with cmake -G ""MinGW Makefiles"" and g++ with NO external package manager. (4) build.cmd that recompiles from scratch on demand and copies the final binary into dist\. (5) dist\MonitorIsolator.exe - a freshly compiled NATIVE C++ binary (NOT Python, NOT PyInstaller) that launches and runs the tray loop. (6) README.md + USER_GUIDE.md + CHANGELOG.md + RUN.cmd. (7) Foreman acceptance table mapping every checklist number to its concrete file+proof. PLAN: SCOUT surveys briefly, ANALYST writes the acceptance spec, ENGINEER creates the tree + writes all C++ sources + CMakeLists + build.cmd + compiles + fixes until it links clean + copies exe to dist + launch-verifies, WRITER writes docs, OPERATOR writes RUN.cmd launch steps, FOREMAN tracks and delivers the acceptance table. HARD RULES: dispatch ONLY - never call shell_exec/fs_*/cmake/compiler yourself; do NOT pass resultSchema to workers; do NOT pass session to workers (their output lands in this chat); re-dispatch any failed/timeout/invalid worker with a simpler prompt; report every completion in chat as it lands. If any worker reports MSVC missing, redirect it to the MinGW g++/cmake toolchain in PATH. PROMPT-SIZE RULE: every dispatched worker prompt MUST stay under 3500 characters - prompts over 4000 characters are auto-declined and never start, so keep subtask text tight and put shared context in the worker's own workspace files instead. SEQUENTIAL-BOOTSTRAP RULE: if the full 7-worker wave would joint-stall (all long compiles at once), first send a SHORT scout wave (analyst + researcher + scout), then the build wave. SEQUENTIAL-RETRY RULE: re-dispatch any failed/timed-out worker ONE AT A TIME with a prompt under 3000 characters, never inside the full-crew parallel wave. Never stop until EVERY checklist item is done and proven."
Step "nova chat session: global"
# 11a. remove EVERY standing routine - this run mints a fresh crew each time
try {
  $list = Invoke-RestMethod -Uri ($Url + 'api/cron') -Headers $H -TimeoutSec 15
  foreach ($j in @($list.jobs)) {
    try { Invoke-RestMethod -Uri ($Url + 'api/cron/remove') -Method Post -Headers $H -ContentType 'application/json' -Body (@{ id = $j.id } | ConvertTo-Json) -TimeoutSec 15 | Out-Null } catch {}
  }
  Step 'standing routines wiped - new crew cycle starts from zero'
} catch { Warn "routine cleanup failed: $($_.Exception.Message)" }
# 11b. FRESH DELIVERABLE WIPE - crew builds from absolute zero
$ProjectRoot = 'F:\study\Windows\Applications\Desktop\Utilities\System\MonitorIsolator'
if (Test-Path -LiteralPath $ProjectRoot) {
  Step 'resetting deliverable folder for a true fresh build...'
  Get-ChildItem -LiteralPath $ProjectRoot -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | ForEach-Object { try { $_.Delete() } catch {} }
  Get-ChildItem 'F:\study\Windows\Applications\Desktop\Utilities\System' -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'MonitorIsolator' } | ForEach-Object { try { $_.Delete() } catch {} }
  Step 'deliverable folder removed'
}
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
  $cr = Invoke-RestMethod -Uri ($Url + 'api/cron') -Method Post -Headers $H -ContentType 'application/json' -Body ((@{ name = $novaName; schedule = 'every 3 minutes'; agentId = 'agent' } + $novaCommon) | ConvertTo-Json -Depth 8) -TimeoutSec 20
  if ($cr.declined -and -not $cr.job) { Warn "fresh routine declined: $runTag - falling back to MISSION: NOVA"; $novaName = 'MISSION: NOVA' }
} catch { Warn "routine create failed: $($_.Exception.Message)"; $novaName = 'MISSION: NOVA' }
$persisted = 0
try { $list = Invoke-RestMethod -Uri ($Url + 'api/cron') -Headers $H -TimeoutSec 15; $persisted = @($list.jobs | Where-Object { $_.name -eq $novaName }).Count } catch {}
if ($persisted -ge 1) { Step ("fresh crew routine ready: " + $novaName) } else { Warn "NEW crew routine not persisted" }
# 12. FIRE THE CREW IMMEDIATELY (Run Now; the 8s timeout only releases the stream - the run continues)
if ($persisted -ge 1) {
  $freshJob = $null
  try { $list = Invoke-RestMethod -Uri ($Url + 'api/cron') -Headers $H -TimeoutSec 10; $freshJob = @($list.jobs | Where-Object { $_.name -eq $novaName })[0] } catch {}
  if ($freshJob) {
    try { Invoke-WebRequest -UseBasicParsing -Uri ($Url + 'api/cron/run') -Method Post -Headers $H -ContentType 'application/json' -Body (@{ id = $freshJob.id } | ConvertTo-Json) -TimeoutSec 8 | Out-Null; Step ("crew fired immediately: " + $novaName) } catch { Step "crew fire stream held 8s - the run continues in background" }
  }
}


# 13. WAIT FOR PARALLEL CREW (need 5+ distinct agents to prove true parallelism)
Step "waiting for agents (up to ${CrewWaitSec}s)..."
$dl = (Get-Date).AddSeconds($CrewWaitSec); $lastLive = ''
while ((Get-Date) -lt $dl) {
  try {
    $snap = Invoke-RestMethod -Uri ($Url + 'api/state/snapshot') -Headers $H -TimeoutSec 5
    $ids = @($snap.runs | ForEach-Object { $_.agentId })
    if ($ids.Count -gt 0) { $lastLive = ($ids -join ', '); if ((@($ids | Sort-Object -Unique)).Count -ge 5) { break } }
  } catch {}; Start-Sleep -Seconds 5
}
if ($lastLive) { Step ("agents working: " + $lastLive) } else { Warn "no agents visible yet" }
# 14. VERIFY
try { $r = Get-Content -LiteralPath (Join-Path $Workspace 'agent.roster.json') -Raw | ConvertFrom-Json; Step ("roster: " + ($r.agents | ForEach-Object { $_.agentId }) -join ', ') } catch {}
# 15. OPEN BROWSER
$finalOk = $false; $dl = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $dl) { if (Test-Listen $Port) { try { $hr = Invoke-WebRequest -UseBasicParsing -Uri ($Url + 'api/health') -Headers $H -TimeoutSec 5; if ($hr.StatusCode -lt 400) { $finalOk = $true; break } } catch {} }; Start-Sleep -Milliseconds 700 }
if ($finalOk) { Step 'station healthy' } else { Warn 'station re-check failed' }
if (-not $NoBrowser) { Step 'opening Chrome...'; try { Start-Process $Url } catch { Warn ("browser error: " + $_.Exception.Message) } }
Write-Host ""
Write-Host "  StarNet is live at $Url" -ForegroundColor Green
Write-Host "  Brain: opencode-go / $Model" -ForegroundColor Green
Write-Host "  Leader: NOVA (7 parallel dispatches FIRST action) + 7 crew in parallel" -ForegroundColor Green
Write-Host "  Crew: RESEARCHER, ANALYST, ENGINEER, WRITER, SCOUT, OPERATOR, FOREMAN" -ForegroundColor Green
if ($taskText) { Write-Host "  Task: $TaskFile ($($taskText.Length) chars)" -ForegroundColor Green }
else { Write-Host "  Task: built-in default" -ForegroundColor Yellow }
Write-Host ""
