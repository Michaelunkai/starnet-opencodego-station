#requires -Version 5.1
<#  launch-opencodego.ps1  (Windows PowerShell 5.1)

    Boots StarNet wired to OpenCode Go (mimo-v2.5, chat/completions) with a full coordinator + 7-agent crew,
    master-bypass permissions, and a standing crew mission - then opens Chrome so you can watch the team work.

    HARDENED (2026-09-29):
      * LOCATION-INDEPENDENT: works from the StarNet repo root OR from <project>\scripts\ (auto-finds the
        checkout; override with -Repo).
      * PORT IS ALWAYS FREED FIRST: stops the task, kills the sidecar's node, and kills WHATEVER holds the
        port - so the station can never fail to bind behind a stale listener.
      * NEVER HANGS: every wait is bounded and prints progress; failures dump the logs and exit with a reason.
      * FULL-CREW PARALLELISM: crew-aware routines + a concurrency ceiling big enough for the whole crew.

    Pipeline:
      credentials -> OpencodeGoProxy.exe (http://127.0.0.1:4000/v1)
                  -> StarNet sidecar    (opencode-go provider)
                  -> http://127.0.0.1:8787 (Chrome)
#>
[CmdletBinding()]
param(
  [int]$Port = 8787,
  [string]$Model = 'mimo-v2.5',
  [string]$Repo,                                  # StarNet checkout; auto-detected when omitted
  [string]$ProxyDir,                              # OpencodeGoProxy folder; auto-detected when omitted
  [int]$ReadyTimeoutSec = 90,                     # bounded wait for the station to answer
  [int]$WatchSeconds = 0,                         # optional: print the live crew for this many seconds
  [switch]$Fresh,
  [switch]$NoBrowser,
  [switch]$KeepRunning
)
$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Url       = "http://127.0.0.1:$Port/"

function Step([string]$m) { Write-Host ("  [starnet] " + $m) }
function Warn([string]$m) { Write-Host ("  [starnet] " + $m) -ForegroundColor Yellow }
function Fail([string]$m) { Write-Host ("  [starnet] " + $m) -ForegroundColor Red }
function HttpOk([string]$u, [int]$t = 4) {
  try { $r = Invoke-WebRequest -UseBasicParsing -Uri $u -TimeoutSec $t; return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400) } catch { return $false }
}
function FirstExisting([string[]]$paths) {
  foreach ($p in $paths) { if ($p -and (Test-Path -LiteralPath $p)) { return (Resolve-Path -LiteralPath $p).Path } }
  return $null
}

# ----------------------------------------------------------------------------------------------------------
# 0. RESOLVE PATHS (so this script runs from the repo root OR from a project's scripts\ folder)
# ----------------------------------------------------------------------------------------------------------
$repoCandidates = @()
if ($Repo) { $repoCandidates += $Repo }
$repoCandidates += @(
  $ScriptDir,                       # repo layout:      <repo>\launch-opencodego.ps1
  (Split-Path -Parent $ScriptDir),  # project layout:   <project>\scripts\launch-opencodego.ps1
  'C:\Users\Admin\StarNet',
  'C:\StarNet',
  (Join-Path $env:USERPROFILE 'StarNet')
)
$Repo = $null
foreach ($c in $repoCandidates) {
  if ($c -and (Test-Path -LiteralPath (Join-Path $c 'sidecar\index.js'))) { $Repo = (Resolve-Path -LiteralPath $c).Path; break }
}
if (-not $Repo) {
  throw "Could not find a StarNet checkout (need <repo>\sidecar\index.js). Pass -Repo <path>."
}
$Sidecar = Join-Path $Repo 'sidecar\index.js'
$Prepare = FirstExisting @((Join-Path $ScriptDir 'prepare-opencodego-station.js'), (Join-Path $Repo 'prepare-opencodego-station.js'))
$Kickoff = FirstExisting @((Join-Path $ScriptDir 'kickoff-mission.ps1'), (Join-Path $Repo 'kickoff-mission.ps1'))
if (-not $Prepare) { throw "prepare-opencodego-station.js not found next to this script or in the repo." }

if (-not $ProxyDir) {
  $ProxyDir = FirstExisting @(
    'F:\study\repos\aiml\AI_and_Machine_Learning\Artificial_Intelligence\cli\opencode\OpencodeGoProxy',
    (Join-Path $ScriptDir 'OpencodeGoProxy'),
    (Join-Path $Repo 'OpencodeGoProxy')
  )
}
$ProxyConfig  = if ($ProxyDir) { Join-Path $ProxyDir 'config.json' } else { $null }
$ProxyStarter = if ($ProxyDir) { Join-Path $ProxyDir 'start_proxy.ps1' } else { $null }
$ProxyExe     = if ($ProxyDir) { Join-Path $ProxyDir 'OpencodeGoProxy.exe' } else { $null }

$StateDir  = Join-Path $env:LOCALAPPDATA 'StarNet\opencodego'
$Workspace = Join-Path $StateDir 'workspace'
$OutLog    = Join-Path $StateDir 'sidecar.out.log'
$ErrLog    = Join-Path $StateDir 'sidecar.err.log'

Write-Host ""
Step ("repo:   " + $Repo)
Step ("proxy:  " + ($(if ($ProxyDir) { $ProxyDir } else { '(none - pass -ProxyDir)' })))
Step ("port:   " + $Port)

# ----------------------------------------------------------------------------------------------------------
# 1. PORT CONTROL - free the port before anything else, so the station can never fail to bind
# ----------------------------------------------------------------------------------------------------------
function Stop-ListenerOnPort([int]$p) {
  $killed = @()
  try {
    $conns = Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue
    foreach ($c in $conns) {
      $procId = [int]$c.OwningProcess
      if ($procId -gt 0 -and $procId -ne $PID) {
        try { Stop-Process -Id $procId -Force -ErrorAction Stop; $killed += $procId } catch {}
      }
    }
  } catch {}
  return $killed
}
function Stop-SidecarNodes {
  $killed = @()
  try {
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -and $_.CommandLine -match 'sidecar[\\/]index\.js' } |
      ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $killed += $_.ProcessId } catch {} }
  } catch {}
  return $killed
}
function Test-PortListening([int]$p) {
  try { return (@(Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue).Count -gt 0) } catch { return $false }
}

# ----------------------------------------------------------------------------------------------------------
# 2. PROXY - ensure it is healthy, then keep it under a self-healing task
# ----------------------------------------------------------------------------------------------------------
if ($ProxyDir -and (Test-Path -LiteralPath $ProxyConfig)) {
  $cfg = Get-Content -LiteralPath $ProxyConfig -Raw | ConvertFrom-Json
  $key = [string]$cfg.local_api_key
  $listenUri = [Uri]([string]$cfg.listen_prefix)
  $proxyBase = $listenUri.GetLeftPart([UriPartial]::Authority).TrimEnd('/')
  $providerBase = $proxyBase + '/v1'

  if (-not (HttpOk ($proxyBase + '/health'))) {
    if ($ProxyStarter -and (Test-Path -LiteralPath $ProxyStarter)) {
      Step 'starting proxy...'
      try { & $ProxyStarter | Out-Null } catch { Warn ("proxy starter: " + $_.Exception.Message) }
    }
    for ($i = 0; $i -lt 40 -and -not (HttpOk ($proxyBase + '/health')); $i++) { Start-Sleep -Milliseconds 500 }
  }
  if (-not (HttpOk ($proxyBase + '/health'))) { Fail "proxy did not become healthy at $proxyBase/health"; }

  if ((Test-Path -LiteralPath $ProxyExe)) {
    $proxyStarterCmd = Join-Path $StateDir 'start-proxy.cmd'
    $proxyOut = Join-Path $StateDir 'proxy.out.log'
    $proxyErr = Join-Path $StateDir 'proxy.err.log'
    $plines = @(
      '@echo off'
      ('cd /d "{0}"' -f $ProxyDir)
      ':proxy_supervise'
      ('echo [supervisor] starting proxy %DATE% %TIME% >> "{0}"' -f $proxyOut)
      ('"{0}" -Mode Serve -ConfigPath "{1}" 1>> "{2}" 2>> "{3}"' -f $ProxyExe, $ProxyConfig, $proxyOut, $proxyErr)
      ('echo [supervisor] proxy exited (code %ERRORLEVEL%) - restarting in 2s >> "{0}"' -f $proxyOut)
      'ping -n 3 127.0.0.1 >nul'
      'goto proxy_supervise'
    )
    [IO.File]::WriteAllText($proxyStarterCmd, ($plines -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
    $proxyTask = 'StarNet-OpenCodeGoProxy'
    try { Unregister-ScheduledTask -TaskName $proxyTask -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    $pa = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c "' + $proxyStarterCmd + '"') -WorkingDirectory $ProxyDir
    $pt = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(2)
    $ps = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 30) -MultipleInstances IgnoreNew
    $pp = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType S4U -RunLevel Limited
    Register-ScheduledTask -TaskName $proxyTask -Action $pa -Trigger $pt -Settings $ps -Principal $pp -Force | Out-Null
    Start-ScheduledTask -TaskName $proxyTask
    for ($i = 0; $i -lt 40 -and -not (HttpOk ($proxyBase + '/health')); $i++) { Start-Sleep -Milliseconds 500 }
    if (-not (HttpOk ($proxyBase + '/health'))) { throw "proxy supervisor did not bring the proxy up at $proxyBase/health" }
    Step 'proxy supervised (self-healing)'
  }
} else {
  throw "OpencodeGoProxy config.json not found. Pass -ProxyDir <folder> (needs config.json)."
}

$mr = Invoke-RestMethod -Uri ($providerBase + '/models') -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 20
$models = @($mr.data | ForEach-Object { [string]$_.id })
if ($models.Count -gt 0 -and $Model -notin $models) { throw "model '$Model' not in live proxy catalog ($($models.Count) models)" }
Step "brain: OpenCode Go ($($models.Count) models, key failover)"

# ----------------------------------------------------------------------------------------------------------
# 3. STOP THE OLD STATION AND FREE THE PORT (always, unless -KeepRunning and it is already healthy)
# ----------------------------------------------------------------------------------------------------------
function Stop-StarNetStation {
  try { Stop-ScheduledTask -TaskName 'StarNet-OpenCodeGo' -ErrorAction SilentlyContinue } catch {}
  Start-Sleep -Milliseconds 300
  $n = Stop-SidecarNodes
  if ($n.Count) { Step ("stopped " + $n.Count + " sidecar node process(es)") }
  $k = Stop-ListenerOnPort $Port
  if ($k.Count) { Step ("freed port $Port (stopped pid " + ($k -join ',') + ")") }
  # bounded wait for the port to actually clear
  for ($i = 0; $i -lt 20 -and (Test-PortListening $Port); $i++) { Start-Sleep -Milliseconds 250 }
  if (Test-PortListening $Port) {
    $again = Stop-ListenerOnPort $Port
    if ($again.Count) { Step ("re-freed port $Port (pid " + ($again -join ',') + ")") }
    for ($i = 0; $i -lt 12 -and (Test-PortListening $Port); $i++) { Start-Sleep -Milliseconds 250 }
  }
  return -not (Test-PortListening $Port)
}
function Clear-StaleSpendPending {
  $dir = Join-Path $Workspace '.spend-pending'
  if (-not (Test-Path -LiteralPath $dir)) { return 0 }
  $n = 0
  Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | ForEach-Object {
    try { Remove-Item -LiteralPath $_.FullName -ErrorAction Stop; $n++ } catch {}
  }
  return $n
}

$alreadyServing = HttpOk $Url
if ($alreadyServing -and $KeepRunning) {
  Step "already serving on port $Port (kept running)"
} else {
  if ($alreadyServing) { Step 'restarting existing station for a clean boot...' }
  if (-not (Stop-StarNetStation)) { throw "port $Port is still in use and could not be freed." }
  Step "port $Port is free"

  # ---- prepare workspace (full team on disk) ----
  if ($Fresh -and (Test-Path -LiteralPath $Workspace)) {
    Remove-Item -LiteralPath $Workspace -Recurse -Force -ErrorAction SilentlyContinue
  }
  $cleared = Clear-StaleSpendPending
  if ($cleared -gt 0) { Step "cleared $cleared stale spend receipt(s)" }
  Step 'preparing station (team + brain config)...'
  node $Prepare
  if ($LASTEXITCODE -ne 0) { throw "prepare-opencodego-station.js failed (exit $LASTEXITCODE)" }

  # ---- self-contained, self-healing starter .cmd ----
  $starter = Join-Path $StateDir 'start-sidecar.cmd'
  $nodeExe = (Get-Command node).Source
  try { [IO.File]::WriteAllText($OutLog, '') } catch {}
  try { [IO.File]::WriteAllText($ErrLog, '') } catch {}
  $lines = @(
    '@echo off'
    ('set "STARNET_WORKSPACES={0}"'    -f $Workspace)
    ('set "STARNET_PORT={0}"'          -f $Port)
    'set "STARNET_DEV=1"'
    ('set "STARNET_DEFAULT_MODEL={0}"' -f $Model)
    'set "STARNET_DEFAULT_PROVIDER=opencode-go"'
    'set "STARNET_FULL_ACCESS=1"'
    'set "STARNET_NO_QUESTIONS=1"'
    'set "STARNET_CRON_ENABLED=1"'
    # CREW-AWARE ROUTINES: a scheduled/Run-Now fire is a LEAD (orchestrator object -> team.dispatch), so a
    # routine can run a full-crew operation instead of the routine agent doing everything solo.
    'set "STARNET_CRON_LEAD=1"'
    # FULL-CREW PARALLELISM: let the whole crew (hero + 7) run at once so a mission fans out to maximum width.
    'set "STARNET_MAX_CONCURRENT_AGENTS=12"'
    # UNPRICED SEATBELT: OpenCode Go serves these models with no published price, so every turn reconciles at $0
    # and the default 2,000,000-token ceiling stopped a real mission mid-build. Raise it generously but finitely.
    'set "STARNET_MAX_UNPRICED_TOKENS=50000000"'
    'set "STARNET_UNCAUGHT_KEEP_SERVING=1"'
    'set "STARNET_FALLBACK_MODELS=mimo-v2.6-flash,deepseek-v4.1-flash,deepseek-v4-flash"'
    ('set "OPENCODE_GO_API_KEY={0}"'   -f $key)
    ('set "OPENCODE_GO_BASE_URL={0}"'  -f $providerBase)
    ':starnet_supervise'
    ('echo [supervisor] starting sidecar %DATE% %TIME% >> "{0}"' -f $OutLog)
    ('"{0}" --trace-uncaught --trace-warnings "{1}" 1>> "{2}" 2>> "{3}"' -f $nodeExe, $Sidecar, $OutLog, $ErrLog)
    ('echo [supervisor] sidecar exited (code %ERRORLEVEL%) - restarting in 2s >> "{0}"' -f $OutLog)
    'ping -n 3 127.0.0.1 >nul'
    'goto starnet_supervise'
  )
  [IO.File]::WriteAllText($starter, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding($false)))

  $taskName = 'StarNet-OpenCodeGo'
  try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
  $taskAction = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c "' + $starter + '"') -WorkingDirectory $Repo
  $taskTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(1)
  $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 30) -MultipleInstances IgnoreNew
  $taskPrincipal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType S4U -RunLevel Limited
  Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $taskTrigger -Settings $taskSettings -Principal $taskPrincipal -Force | Out-Null
  Step "starting sidecar on port $Port..."
  Start-ScheduledTask -TaskName $taskName

  # ---- bounded readiness wait: LISTEN first, then HTTP ----
  $deadline = (Get-Date).AddSeconds($ReadyTimeoutSec)
  $ready = $false
  while ((Get-Date) -lt $deadline) {
    if ((Test-PortListening $Port) -and (HttpOk $Url 3)) { $ready = $true; break }
    Start-Sleep -Milliseconds 500
  }
  if (-not $ready) {
    Fail 'sidecar did not come up in time.'
    if (Test-Path -LiteralPath $ErrLog) { Write-Host '  --- sidecar.err.log ---'; Get-Content -LiteralPath $ErrLog -Tail 20 | Write-Host }
    if (Test-Path -LiteralPath $OutLog) { Write-Host '  --- sidecar.out.log ---'; Get-Content -LiteralPath $OutLog -Tail 20 | Write-Host }
    throw "sidecar did not come up on $Url"
  }
  $owner = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)[0].OwningProcess
  Step ("station up on $Url (pid " + $owner + ")")
}

# ----------------------------------------------------------------------------------------------------------
# 4. MASTER BYPASS
# ----------------------------------------------------------------------------------------------------------
$html = (Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 10).Content
$tok = ([regex]::Match($html, '__STARNET_API_TOKEN__="((?:\\.|[^"])*)"')).Groups[1].Value
$H = @{ 'X-StarNet-Token' = $tok }
try {
  $bp = Invoke-RestMethod -Uri ($Url + 'api/permissions/bypass') -Method Post -Headers $H -ContentType 'application/json' -Body (@{ on = $true } | ConvertTo-Json) -TimeoutSec 10
  Step ("bypass: masterBypass=" + $bp.masterBypass + " envFullAccess=" + $bp.envFullAccess)
} catch { Warn "bypass set failed (non-fatal): $($_.Exception.Message)" }

# ----------------------------------------------------------------------------------------------------------
# 5. STANDING MISSION - create/refresh the routine, then kick it off detached (holds its own stream)
# ----------------------------------------------------------------------------------------------------------
# MISSION SOURCE: whatever the Commander puts in the task file wins. The file is re-read on every launch, so
# editing it and re-running the launcher is the whole workflow. Missing/empty -> the built-in default mission.
$TaskFile = 'F:\downloads\a.md'
$CrewDirective = @'
=== HOW TO RUN THIS (you are NOVA, the coordinator) ===
You MUST delegate - you are not allowed to do the whole job yourself. The Commander is watching the floor and
every working agent shows what it is doing live, so keep the crew busy.

1. In one line, brief the job.
2. In your FIRST tool call, dispatch your WHOLE crew IN PARALLEL with team.dispatch (parallel:true, one worker per
   specialist below, each with a concrete prompt).
   IMPORTANT: do NOT pass a `session` on any worker. This mission runs HEADLESS (a scheduled/Run-Now lead has no
   station page attached), so a named session CANNOT be resolved and that worker would be REFUSED and never run.
   Dispatch with parallel:true and NO session so every worker actually runs and reports back to you.
   The specialists:
   - researcher: gather the facts and sources this job needs; return a sourced summary.
   - analyst: turn that into a prioritized spec with acceptance criteria.
   - engineer: build and fix the working artifact; run it and verify it actually works.
   - writer: write the README and usage docs.
   - scout: check what already exists and what makes this different.
   - operator: make it runnable on demand (routine / launch steps).
   - foreman: split the build into parallel workstreams and track every worker.
   Pass those exact agentIds (the names above ARE the agentIds). Do NOT use team.spawn. If team.dispatch reports a
   worker as NOT RUN, re-dispatch it in a follow-up call - never silently drop a specialist.
3. Monitor every worker with team.subagents; steer or re-dispatch anything stalled.
4. Keep going until the job is done to PERFECTION. Finish with the exact path and the launch command.

Never ask the Commander anything. Decide, act, finish.
'@

$taskText = ''
if (Test-Path -LiteralPath $TaskFile) {
  try { $taskText = (Get-Content -LiteralPath $TaskFile -Raw).Trim() } catch { $taskText = '' }
}
if ($taskText) {
  Step ("mission source: " + $TaskFile + " (" + $taskText.Length + " chars)")
  $missionPrompt = "MISSION - STANDING CREW OBJECTIVE (highest priority, run until complete):`r`n`r`n" + $taskText + "`r`n`r`n" + $CrewDirective
} else {
  if (Test-Path -LiteralPath $TaskFile) { Warn "task file is empty - using the built-in default mission" }
  else { Warn "task file not found ($TaskFile) - using the built-in default mission" }
  $missionPrompt = "MISSION - STANDING CREW OBJECTIVE (highest priority, run until complete):`r`n`r`nCreate, test, and deploy the most useful time-organization and management application you can build, with every genuinely useful feature you can think of.`r`n`r`n" + $CrewDirective
}
try {
  $routineBody = @{ name = 'MISSION: Time Management App'; prompt = $missionPrompt; schedule = 'every 15 minutes'; agentId = 'agent' } | ConvertTo-Json -Depth 6
  $cr = Invoke-RestMethod -Uri ($Url + 'api/cron') -Method Post -Headers $H -ContentType 'application/json' -Body $routineBody -TimeoutSec 30
  if ($cr.duplicate) {
    $list = Invoke-RestMethod -Uri ($Url + 'api/cron') -Headers $H -TimeoutSec 15
    $job = @($list.jobs | Where-Object { $_.name -eq 'MISSION: Time Management App' })[0]
    if ($job) {
      $patchBody = @{ id = $job.id; patch = @{ prompt = $missionPrompt; enabled = $true } } | ConvertTo-Json -Depth 6
      Invoke-RestMethod -Uri ($Url + 'api/cron/update') -Method Post -Headers $H -ContentType 'application/json' -Body $patchBody -TimeoutSec 30 | Out-Null
      Step 'mission routine: present (every 15m) - prompt refreshed'
    } else { Step 'mission routine: present (every 15m)' }
  } else { Step 'mission routine: created (every 15m)' }
} catch { Warn "mission routine failed (non-fatal): $($_.Exception.Message)" }

if ($Kickoff -and (Test-Path -LiteralPath $Kickoff)) {
  try {
    $spawn = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = ('powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Kickoff + '"'); CurrentDirectory = $Repo }
    if ($spawn.ReturnValue -eq 0) { Step 'mission kicked off (crew dispatching)' } else { Warn "mission kickoff failed (code $($spawn.ReturnValue))" }
  } catch { Warn "mission kickoff failed (non-fatal): $($_.Exception.Message)" }
}

# ----------------------------------------------------------------------------------------------------------
# 6. VERIFY PROVIDER + ROSTER
# ----------------------------------------------------------------------------------------------------------
try {
  $pr = Invoke-RestMethod -Uri ($Url + 'api/providers') -Headers $H -TimeoutSec 15
  $go = @($pr.providers | Where-Object { $_.id -eq 'opencode-go' })[0]
  Step ("provider: opencode-go configured=" + $go.configured + " base=" + $go.currentBaseUrl)
} catch { Warn "provider check failed: $($_.Exception.Message)" }
try {
  $r = Get-Content -LiteralPath (Join-Path $Workspace 'agent.roster.json') -Raw | ConvertFrom-Json
  Step ("roster: " + $r.agents.Count + " agents (" + (($r.agents | ForEach-Object { $_.agentId }) -join ', ') + ")")
} catch { Warn "roster check failed: $($_.Exception.Message)" }

# ----------------------------------------------------------------------------------------------------------
# 7. OPEN CHROME (while the station is running) + optional live crew watch
# ----------------------------------------------------------------------------------------------------------
if (-not $NoBrowser) {
  Step 'opening Chrome...'
  try { Start-Process $Url } catch { Warn "could not open the browser: $($_.Exception.Message)" }
}

if ($WatchSeconds -gt 0) {
  $end = (Get-Date).AddSeconds($WatchSeconds)
  Write-Host ''
  Step "live crew (watching ${WatchSeconds}s)..."
  while ((Get-Date) -lt $end) {
    try {
      $snap = Invoke-RestMethod -Uri ($Url + 'api/state/snapshot') -Headers $H -TimeoutSec 8
      $ids = @($snap.runs | ForEach-Object { $_.agentId })
      $line = if ($ids.Count) { ($ids -join ', ') } else { '(dispatching...)' }
      Write-Host ("    runs: " + $line)
    } catch { Write-Host "    (snapshot unavailable)" }
    Start-Sleep -Seconds 5
  }
}

Write-Host ''
Write-Host "  StarNet is live at $Url" -ForegroundColor Green
Write-Host "  Brain: opencode-go / $Model / chat/completions" -ForegroundColor Green
Write-Host "  Team: NOVA + FOREMAN + RESEARCHER + ENGINEER + ANALYST + WRITER + SCOUT + OPERATOR" -ForegroundColor Green
Write-Host "  Permissions: master bypass ON, full access ON, no-questions ON" -ForegroundColor Green
Write-Host "  Routines: crew-aware (team.dispatch) - every 15m, kicked off now" -ForegroundColor Green
Write-Host ''
