#requires -Version 5.1
<#  launch-opencodego.ps1
    Boots StarNet wired to OpenCode Go (mimo-v2.5, chat/completions),
    with a full coordinator + 7-agent crew, master-bypass permissions, in Chrome.

    Pipeline:
      credentials  -> OpencodeGoProxy.exe (http://127.0.0.1:4000/v1)
                     -> StarNet sidecar    (opencode-go provider)
                     -> http://127.0.0.1:8787 (Chrome)
#>
[CmdletBinding()]
param(
  [int]$Port = 8787,
  [string]$Model = 'mimo-v2.5',
  [string]$ProxyDir = 'F:\study\repos\aiml\AI_and_Machine_Learning\Artificial_Intelligence\cli\opencode\OpencodeGoProxy',
  [switch]$Fresh,
  [switch]$NoBrowser,
  # By default the launcher performs a CLEAN RESTART of the sidecar so the code on disk is always what runs
  # (a stale in-memory sidecar silently ignores sidecar fixes). -KeepRunning adopts an already-serving station.
  [switch]$KeepRunning
)
$ErrorActionPreference = 'Stop'

$Repo        = Split-Path -Parent $MyInvocation.MyCommand.Path
$Sidecar     = Join-Path $Repo 'sidecar\index.js'
$ProxyConfig = Join-Path $ProxyDir 'config.json'
$ProxyStarter= Join-Path $ProxyDir 'start_proxy.ps1'
$StateDir    = Join-Path $env:LOCALAPPDATA 'StarNet\opencodego'
$Workspace   = Join-Path $StateDir 'workspace'
$OutLog      = Join-Path $StateDir 'sidecar.out.log'
$ErrLog      = Join-Path $StateDir 'sidecar.err.log'
$Prepare     = Join-Path $Repo 'prepare-opencodego-station.js'
$Url         = "http://127.0.0.1:$Port/"

function Step([string]$m) { Write-Host ("  [starnet] " + $m) }
function HttpOk([string]$u, [int]$t = 4) {
  try { $r = Invoke-WebRequest -UseBasicParsing -Uri $u -TimeoutSec $t; return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400) } catch { return $false }
}

# ---- 1. Proxy health ----
$cfg = Get-Content -LiteralPath $ProxyConfig -Raw | ConvertFrom-Json
$key = [string]$cfg.local_api_key
$listenUri = [Uri]([string]$cfg.listen_prefix)
$proxyBase = $listenUri.GetLeftPart([UriPartial]::Authority).TrimEnd('/')
$providerBase = $proxyBase + '/v1'

if (-not (HttpOk ($proxyBase + '/health'))) {
  if (-not (Test-Path -LiteralPath $ProxyStarter)) { throw "proxy not running and starter missing: $ProxyStarter" }
  Step "starting proxy..."
  & $ProxyStarter | Out-Null
  for ($i=0; $i -lt 30; $i++) { Start-Sleep -Milliseconds 500; if (HttpOk ($proxyBase + '/health')) { break } }
}
if (-not (HttpOk ($proxyBase + '/health'))) { throw "proxy did not become healthy" }

# ---- 1b. Supervise the proxy too ----
# The proxy is the brain's single point of failure: if it stops, every run dies with ECONNREFUSED and the
# mission fails. Keep it under its own self-healing scheduled task (same S4U, no-console recipe as the sidecar).
$proxyExe  = Join-Path $ProxyDir 'OpencodeGoProxy.exe'
$proxyCfg  = Join-Path $ProxyDir 'config.json'
$proxyOut  = Join-Path $StateDir 'proxy.out.log'
$proxyErr  = Join-Path $StateDir 'proxy.err.log'
$proxyStarterCmd = Join-Path $StateDir 'start-proxy.cmd'
if (Test-Path -LiteralPath $proxyExe) {
  $plines = @(
    '@echo off'
    ('cd /d "{0}"' -f $ProxyDir)
    ':proxy_supervise'
    ('echo [supervisor] starting proxy %DATE% %TIME% >> "{0}"' -f $proxyOut)
    ('"{0}" -Mode Serve -ConfigPath "{1}" 1>> "{2}" 2>> "{3}"' -f $proxyExe, $proxyCfg, $proxyOut, $proxyErr)
    ('echo [supervisor] proxy exited (code %ERRORLEVEL%) - restarting in 5s >> "{0}"' -f $proxyOut)
    'ping -n 6 127.0.0.1 >nul'
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
  for ($i=0; $i -lt 40 -and -not (HttpOk ($proxyBase + '/health')); $i++) { Start-Sleep -Milliseconds 500 }
  if (-not (HttpOk ($proxyBase + '/health'))) { throw "proxy supervisor did not bring the proxy up" }
  Step "proxy supervised (self-healing)"
}

# Validate model in catalog
$mr = Invoke-RestMethod -Uri ($providerBase + '/models') -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 20
$models = @($mr.data | ForEach-Object { [string]$_.id })
if ($models.Count -gt 0 -and $Model -notin $models) { throw "model '$Model' not in live proxy catalog ($($models.Count) models)" }
Step "brain: OpenCode Go ($($models.Count) models, key failover)"

# ---- 1c. Stop any existing sidecar for a CLEAN boot (so the current code on disk is what runs) ----
function Stop-StarNetSidecar {
  try { Stop-ScheduledTask -TaskName 'StarNet-OpenCodeGo' -ErrorAction SilentlyContinue } catch {}
  Start-Sleep -Milliseconds 400
  # the S4U task owns cmd.exe (the supervisor); node is its child and would be re-spawned by the loop, so kill
  # every node process whose command line names THIS sidecar. Matched narrowly, never a blanket node kill.
  try {
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -and $_.CommandLine -like '*sidecar\index.js*' } |
      ForEach-Object { try { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue } catch {} }
  } catch {}
  for ($i=0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 250; if (-not (HttpOk $Url 2)) { break } }
}
# STALE SPEND RECEIPTS: an interrupted run leaves a dispatch-only receipt in .spend-pending that the ledger
# refuses to settle (never guesses $0), which marks spend history UNKNOWN on the next boot. At a CLEAN start no
# run is live, so every leftover receipt is provably stale — clear them so the day rail reads true again.
function Clear-StaleSpendPending {
  $dir = Join-Path $Workspace '.spend-pending'
  if (-not (Test-Path -LiteralPath $dir)) { return 0 }
  $n = 0
  Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | ForEach-Object {
    try { Remove-Item -LiteralPath $_.FullName -ErrorAction Stop; $n++ } catch {}
  }
  return $n
}

# ---- 2. If already serving, skip to bypass + browser ----
if ((HttpOk $Url) -and -not $KeepRunning) {
  Step "restarting existing sidecar for a clean boot..."
  Stop-StarNetSidecar
}
if ((HttpOk $Url) -and $KeepRunning) {
  Step "already serving on port $Port (kept running)"
} else {
  # ---- 3. Prepare workspace (full team on disk) ----
  if ($Fresh -and (Test-Path -LiteralPath $Workspace)) {
    Remove-Item -LiteralPath $Workspace -Recurse -Force -ErrorAction SilentlyContinue
  }
  $cleared = Clear-StaleSpendPending
  if ($cleared -gt 0) { Step "cleared $cleared stale spend receipt(s)" }
  Step "preparing station (team + brain config)..."
  node $Prepare
  if ($LASTEXITCODE -ne 0) { throw "prepare-opencodego-station.js failed (exit $LASTEXITCODE)" }

  # ---- 4. Start sidecar ----
  $env:STARNET_WORKSPACES        = $Workspace
  $env:STARNET_PORT              = [string]$Port
  $env:STARNET_DEV               = '1'
  $env:STARNET_DEFAULT_MODEL     = $Model
  $env:STARNET_DEFAULT_PROVIDER  = 'opencode-go'
  $env:STARNET_FULL_ACCESS       = '1'
  $env:OPENCODE_GO_API_KEY       = $key
  $env:OPENCODE_GO_BASE_URL      = $providerBase

  Step "starting sidecar on port $Port..."
  # Write a SELF-CONTAINED starter .cmd (env vars + node command), then spawn it FULLY DETACHED.
  # Win32_Process.Create does not inherit this shell's environment, so the env must live in the .cmd;
  # detaching means the station keeps running after this window closes and a launcher exit can never
  # take the sidecar down with it. The .cmd holds only the loopback proxy's local bearer (already
  # plaintext in the proxy config) — never an upstream OpenCode Go key.
  $starter = Join-Path $StateDir 'start-sidecar.cmd'
  $nodeExe = (Get-Command node).Source
  # Truncate the logs so this launch starts with a clean, readable record (the supervisor APPENDS).
  try { [IO.File]::WriteAllText($OutLog, '') } catch {}
  try { [IO.File]::WriteAllText($ErrLog, '') } catch {}
  # SELF-HEALING SUPERVISOR: the .cmd re-runs node whenever it exits, so the station is always reachable
  # even if the sidecar is killed (terminal close, task manager, an unhandled crash). 5s between restarts.
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
    # routine can run a full-crew operation instead of the routine agent doing everything solo. Delegated
    # workers still never get the orchestrator object, so a worker can never re-delegate.
    'set "STARNET_CRON_LEAD=1"'
    # UNPRICED SEATBELT: OpenCode Go serves these models with no published price, so every turn reconciles at $0
    # and the default 2,000,000-token per-run ceiling stopped a real mission mid-build. This station is a flat-rate
    # subscription (nothing is billed per token), so the $ caps cannot govern — raise the token seatbelt to a
    # generous but still finite ceiling (50M) that a whole crew mission fits under, while a pathological loop is
    # still bounded. Set 0 to disable entirely.
    'set "STARNET_MAX_UNPRICED_TOKENS=50000000"'
    # Never let one uncaught fault take the station down: degrade and keep serving instead of exiting.
    'set "STARNET_UNCAUGHT_KEEP_SERVING=1"'
    # The upstream occasionally answers "Model is unavailable" for a single model; this chain makes a run
    # fall over to the next working model instead of failing the mission.
    'set "STARNET_FALLBACK_MODELS=mimo-v2.6-flash,deepseek-v4.1-flash,deepseek-v4-flash"'
    ('set "OPENCODE_GO_API_KEY={0}"'   -f $key)
    ('set "OPENCODE_GO_BASE_URL={0}"'  -f $providerBase)
    ':starnet_supervise'
    ('echo [supervisor] starting sidecar %DATE% %TIME% >> "{0}"' -f $OutLog)
    ('"{0}" --trace-uncaught --trace-warnings "{1}" 1>> "{2}" 2>> "{3}"' -f $nodeExe, $Sidecar, $OutLog, $ErrLog)
    ('echo [supervisor] sidecar exited (code %ERRORLEVEL%) - restarting in 5s >> "{0}"' -f $OutLog)
    'ping -n 6 127.0.0.1 >nul'
    'goto starnet_supervise'
  )
  $starterBody = $lines -join "`r`n"
  [IO.File]::WriteAllText($starter, $starterBody, (New-Object Text.UTF8Encoding($false)))
  # Start it via a WINDOWS SCHEDULED TASK running as S4U (session 0, NO console): a task's process tree is
  # owned by the Task Scheduler service, so it survives this shell exiting or the user closing the window,
  # AND running without an interactive console means nothing can deliver it a Ctrl+C from a terminal — the
  # exact signal that was killing the sidecar every ~1 minute in the background (verified: foreground and
  # S4U both stay up; a console-attached background task did not). The task re-runs the supervisor .cmd; the
  # .cmd loops node, so the station self-heals at BOTH levels.
  $taskName = 'StarNet-OpenCodeGo'
  try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
  $taskAction = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c "' + $starter + '"') -WorkingDirectory $Repo
  $taskTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(3)
  $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 30) -MultipleInstances IgnoreNew
  $taskPrincipal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType S4U -RunLevel Limited
  Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $taskTrigger -Settings $taskSettings -Principal $taskPrincipal -Force | Out-Null
  Start-ScheduledTask -TaskName $taskName

  $ready = $false
  for ($i=0; $i -lt 120; $i++) {
    Start-Sleep -Milliseconds 500
    if (HttpOk $Url 3) { $ready = $true; break }
  }
  if (-not $ready) {
    Write-Host "`n  Sidecar stderr:" -ForegroundColor Red
    if (Test-Path -LiteralPath $ErrLog) { Get-Content -LiteralPath $ErrLog -Tail 20 | Write-Host }
    throw "sidecar did not come up on $Url"
  }
}

# ---- 5. Set master-bypass via API (idempotent) ----
$html = (Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 10).Content
$tok = ([regex]::Match($html, '__STARNET_API_TOKEN__="((?:\\.|[^"])*)"')).Groups[1].Value
$H = @{ 'X-StarNet-Token' = $tok }
try {
  $bp = Invoke-RestMethod -Uri ($Url + 'api/permissions/bypass') -Method Post -Headers $H -ContentType 'application/json' -Body (@{ on = $true } | ConvertTo-Json) -TimeoutSec 10
  Step ("bypass: masterBypass=" + $bp.masterBypass + " envFullAccess=" + $bp.envFullAccess)
} catch { Step "bypass set failed (non-fatal): $($_.Exception.Message)" }

# ---- 6. Standing mission: create the routine (idempotent) and kick it off NOW ----
$missionPrompt = @'
MISSION - STANDING CREW OBJECTIVE (highest priority, run until complete):

Create, test, and deploy the most useful time-organization and management application you can build, with every genuinely useful feature you can think of.

You are NOVA, the coordinator. This is a FULL-CREW operation and you MUST delegate - you are not allowed to do the whole build yourself. The Commander is watching the floor and every working agent shows what it is doing live, so keep the crew busy.

1. In one line, brief the mission.
2. In your FIRST tool call, dispatch your whole crew IN PARALLEL with team.dispatch (parallel:true, one worker per specialist below, each with a concrete prompt):
   - researcher: research best-in-class time/task managers and the features people actually need; return a sourced feature list.
   - analyst: turn that into a prioritized spec with acceptance criteria.
   - engineer: build the working app in the station workspace, run it, fix what breaks.
   - writer: write README + usage docs + a short launch blurb.
   - scout: check existing tools and name what makes this one different.
   - operator: create a routine so the app can be launched/served on demand.
   - foreman: split the build into parallel workstreams, track each worker, report status.
   Pass those exact agentIds to team.dispatch (the names in parentheses above are the agentIds). Do NOT use team.spawn for this mission: the named crew must do the work so the Commander can watch each of them. If team.dispatch reports a worker as NOT RUN, re-dispatch it in a follow-up call. Do not silently drop a specialist.
3. Monitor every worker with team.subagents; steer or re-dispatch anything stalled.
4. Keep going until the app is built, tested, and runnable. Finish with the exact path and the launch command.

Never ask the Commander anything. Decide, act, finish.
'@
try {
  $routineBody = @{ name = 'MISSION: Time Management App'; prompt = $missionPrompt; schedule = 'every 15 minutes'; agentId = 'agent' } | ConvertTo-Json -Depth 6
  $cr = Invoke-RestMethod -Uri ($Url + 'api/cron') -Method Post -Headers $H -ContentType 'application/json' -Body $routineBody -TimeoutSec 30
  if ($cr.duplicate) {
    # The routine already exists; refresh its prompt so edits to the mission text here always take effect (a
    # standing routine would otherwise keep running its first-ever prompt forever).
    $list = Invoke-RestMethod -Uri ($Url + 'api/cron') -Headers $H -TimeoutSec 15
    $job = @($list.jobs | Where-Object { $_.name -eq 'MISSION: Time Management App' })[0]
    if ($job) {
      $patchBody = @{ id = $job.id; patch = @{ prompt = $missionPrompt; enabled = $true } } | ConvertTo-Json -Depth 6
      Invoke-RestMethod -Uri ($Url + 'api/cron/update') -Method Post -Headers $H -ContentType 'application/json' -Body $patchBody -TimeoutSec 30 | Out-Null
      Step 'mission routine: present (every 15m) — prompt refreshed'
    } else { Step 'mission routine: present (every 15m)' }
  } else { Step 'mission routine: created (every 15m)' }
} catch { Step "mission routine failed (non-fatal): $($_.Exception.Message)" }

# Kick the mission off immediately. Detached (Win32_Process.Create) so it outlives this shell, and it HOLDS
# the run stream open to completion — the manual cron route aborts its run the instant the client disconnects.
$kickoff = Join-Path $Repo 'kickoff-mission.ps1'
if (Test-Path -LiteralPath $kickoff) {
  try {
    $spawn = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = ('powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $kickoff + '"'); CurrentDirectory = $Repo }
    if ($spawn.ReturnValue -eq 0) { Step 'mission kicked off (crew dispatching)' } else { Step "mission kickoff failed (code $($spawn.ReturnValue))" }
  } catch { Step "mission kickoff failed (non-fatal): $($_.Exception.Message)" }
}

# ---- 6. Verify provider + model ----
$pr = Invoke-RestMethod -Uri ($Url + 'api/providers') -Headers $H -TimeoutSec 15
$go = @($pr.providers | Where-Object { $_.id -eq 'opencode-go' })[0]
Step ("provider: opencode-go configured=" + $go.configured + " base=" + $go.currentBaseUrl)

$r = Get-Content -LiteralPath (Join-Path $Workspace 'agent.roster.json') -Raw | ConvertFrom-Json
Step ("roster: " + $r.agents.Count + " agents (" + (($r.agents | ForEach-Object { $_.agentId }) -join ', ') + ")")
$s = Get-Content -LiteralPath (Join-Path $Workspace 'agent.save.json') -Raw | ConvertFrom-Json
Step ("save hero model: " + $s.doc.agent.model + " prov: " + $s.doc.prov)
Step ("save crew count: " + $s.doc.agents.Count)

# ---- 7. Open Chrome ----
if (-not $NoBrowser) {
  Step "opening Chrome..."
  Start-Process $Url
}

Write-Host ""
Write-Host "  StarNet is live at $Url" -ForegroundColor Green
Write-Host "  Brain: opencode-go / $Model / chat/completions" -ForegroundColor Green
Write-Host "  Team: NOVA + FOREMAN + RESEARCHER + ENGINEER + ANALYST + WRITER + SCOUT + OPERATOR" -ForegroundColor Green
Write-Host "  Permissions: master bypass ON, full access ON" -ForegroundColor Green
Write-Host ""