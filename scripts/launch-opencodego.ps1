#requires -Version 5.1
<#
  launch-opencodego.ps1 - StarNet launcher. NOVA leads, crew follows.
  Run it. NOVA gets the task, understands it, dispatches to crew. Chrome opens when working.
  Task source: ANY file named a.* in F:\Downloads
  Usage: powershell -ExecutionPolicy Bypass -File launch-opencodego.ps1
#>
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
    'F:\study\repos\aiml\AI_and_Machine_Learning\Artificial_Intelligence\cli\opencode\OpencodeGoProxy',
    (Join-Path $ScriptDir 'OpencodeGoProxy'), (Join-Path $Repo 'OpencodeGoProxy'))
}
$ProxyConfig = if ($ProxyDir) { Join-Path $ProxyDir 'config.json' } else { $null }
$ProxyExe = if ($ProxyDir) { Join-Path $ProxyDir 'OpencodeGoProxy.exe' } else { $null }
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
  if ($m) {
    $TaskFile = $m.FullName
    $taskText = (Get-Content -LiteralPath $TaskFile -Raw -ErrorAction SilentlyContinue).Trim()
  }
} catch {}

# 4. TASK TEXT
$defaultTask = 'Create, test, and deploy the most useful time-organization and management application you can build, with every genuinely useful feature you can think of.'
if ($taskText) {
  Step ("task: " + $TaskFile + " (" + $taskText.Length + " chars)")
} else {
  if ($TaskFile) { Warn "task file empty ($TaskFile) - using built-in default" }
  else { Warn "no file named 'a.*' in F:\Downloads - using built-in default" }
  $taskText = $defaultTask
}

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
Stop-SidecarNodes
Stop-Port $Port
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

# 11. MISSION - NOVA LEADS, CREW FOLLOWS
# NOVA gets the FULL task. NOVA understands it deeply, then dispatches role-specific
# subtasks to each crew member via team_dispatch. Each crew member only gets their part.
$novaSession = ''
try {
  $sv = Get-Content -LiteralPath (Join-Path $Workspace 'agent.save.json') -Raw | ConvertFrom-Json
  $ws = @($sv.doc.workstreams) | Where-Object { $_ -and ($_.agentId -eq 'agent') } | Select-Object -First 1
  if (-not $ws) { $ws = @($sv.doc.workstreams) | Select-Object -First 1 }
  if ($ws) { $novaSession = [string]$ws.id }
} catch {}
if (-not $novaSession) { $novaSession = 'ws_nova_main' }
Step ("nova chat session: " + $novaSession)

# Clean up old stale routines
try {
  $list = Invoke-RestMethod -Uri ($Url + 'api/cron') -Headers $H -TimeoutSec 15
  foreach ($j in @($list.jobs)) {
    if ($j.name -eq 'TEST' -or ($j.name -like 'MISSION:*' -and $j.name -ne 'MISSION: NOVA')) {
      try { Invoke-RestMethod -Uri ($Url + 'api/cron/remove') -Method Post -Headers $H -ContentType 'application/json' -Body (@{ id = $j.id } | ConvertTo-Json) -TimeoutSec 15 | Out-Null } catch {}
    }
  }
} catch { Warn "routine cleanup failed" }

# NOVA's mission prompt - the LEADER prompt
$novaPrompt = @"
You are NOVA, the team leader. You have 7 specialist crew members you can dispatch work to.

YOUR TASK:
$taskText

YOUR JOB - DO THIS FIRST, THEN DISPATCH:
1. READ the task above carefully. Understand EVERY detail, every requirement, every constraint.
2. BREAK the task into subtasks, one per crew member, based on their specialty.
3. For EACH subtask, write clear acceptance criteria so the specialist knows exactly what "done" looks like.
4. Use team_dispatch to assign each subtask to the RIGHT specialist:
   - RESEARCHER: research, web_search, gather facts, find existing solutions
   - ANALYST: specs, acceptance criteria, prioritization, risk analysis
   - ENGINEER: build code, create files, run tests, fix bugs
   - WRITER: documentation, README, usage guides
   - SCOUT: survey existing solutions, compare approaches
   - OPERATOR: launch scripts, deployment, automation
   - FOREMAN: track progress, report status, identify blockers
5. After ALL crew members finish, VERIFY every deliverable meets the original task criteria.
6. Report progress in the chat as you go.

RULES:
- NEVER do the specialist work yourself. DISPATCH it.
- Each dispatched subtask MUST include: what to do, acceptance criteria, where to save output.
- If a crew member's work doesn't meet criteria, re-dispatch with corrections.
- You can talk to the Commander at any time for steering.
- Never stop until the ENTIRE task is complete and verified.
"@

# Create NOVA's routine
$novaName = 'MISSION: NOVA'
$novaExisting = $null
try { $list = Invoke-RestMethod -Uri ($Url + 'api/cron') -Headers $H -TimeoutSec 15; $novaExisting = @($list.jobs | Where-Object { $_.name -eq $novaName })[0] } catch {}
$novaCommon = @{
  prompt = $novaPrompt; enabled = $true; state = 'scheduled'; deliver = 'local'; attachToSession = $true;
  origin = @{ sessionId = $novaSession; streamId = $novaSession; sessionTitle = 'General' }
}
try {
  if ($novaExisting) {
    $patch = @{ id = $novaExisting.id; patch = $novaCommon } | ConvertTo-Json -Depth 8
    Invoke-RestMethod -Uri ($Url + 'api/cron/update') -Method Post -Headers $H -ContentType 'application/json' -Body $patch -TimeoutSec 20 | Out-Null
  } else {
    $body = (@{ name = $novaName; schedule = 'every 3 minutes'; agentId = 'agent' } + $novaCommon) | ConvertTo-Json -Depth 8
    $cr = Invoke-RestMethod -Uri ($Url + 'api/cron') -Method Post -Headers $H -ContentType 'application/json' -Body $body -TimeoutSec 20
    if ($cr.declined -and -not $cr.job) { Warn "NOVA routine declined by mint gate" }
  }
} catch { Warn "NOVA routine failed: $($_.Exception.Message)" }

# Verify NOVA routine persisted
$persisted = 0
try { $list = Invoke-RestMethod -Uri ($Url + 'api/cron') -Headers $H -TimeoutSec 15; $persisted = @($list.jobs | Where-Object { $_.name -eq $novaName }).Count } catch {}
if ($persisted -ge 1) { Step "mission: NOVA routine ready + persisted" }
else { Warn "NOVA routine not persisted" }

# 12. FIRE NOVA
if ($Kickoff -and (Test-Path -LiteralPath $Kickoff)) {
  try {
    $cmdline = ('powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Kickoff + '" -JobName "MISSION: NOVA"')
    $spawn = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmdline; CurrentDirectory = $Repo }
    if ($spawn.ReturnValue -ne 0) { Warn "NOVA kickoff failed" }
  } catch { Warn "NOVA kickoff failed: $($_.Exception.Message)" }
  Step 'NOVA fired - will dispatch to crew'
}

# 13. WAIT FOR AGENTS TO BE WORKING
Step "waiting for agents to start working (up to ${CrewWaitSec}s)..."
$dl = (Get-Date).AddSeconds($CrewWaitSec)
$lastLive = ''
while ((Get-Date) -lt $dl) {
  try {
    $snap = Invoke-RestMethod -Uri ($Url + 'api/state/snapshot') -Headers $H -TimeoutSec 5
    $ids = @($snap.runs | ForEach-Object { $_.agentId })
    if ($ids.Count -gt 0) {
      $lastLive = ($ids -join ', ')
      if ($ids.Count -ge 1) { break }
    }
  } catch {}
  Start-Sleep -Seconds 5
}
if ($lastLive) { Step ("agents working: " + $lastLive) } else { Warn "no agents visible yet - opening browser anyway (mission continues in background)" }

# 14. VERIFY
try {
  $r = Get-Content -LiteralPath (Join-Path $Workspace 'agent.roster.json') -Raw | ConvertFrom-Json
  Step ("roster: " + ($r.agents | ForEach-Object { $_.agentId }) -join ', ')
} catch {}

# 15. FINAL HEALTH RE-CHECK
$finalOk = $false
$dl = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $dl) {
  if (Test-Listen $Port) {
    try { $hr = Invoke-WebRequest -UseBasicParsing -Uri ($Url + 'api/health') -Headers $H -TimeoutSec 5; if ($hr.StatusCode -lt 400) { $finalOk = $true; break } } catch {}
  }
  Start-Sleep -Milliseconds 700
}
if ($finalOk) { Step 'station healthy - opening browser' } else { Warn 'station re-check failed - opening browser anyway' }

if (-not $NoBrowser) {
  Step 'opening Chrome...'
  try { Start-Process $Url } catch { Warn "could not open browser: $($_.Exception.Message)" }
}

Write-Host ""
Write-Host "  StarNet is live at $Url" -ForegroundColor Green
Write-Host "  Brain: opencode-go / $Model" -ForegroundColor Green
Write-Host "  Leader: NOVA (dispatches to crew via team_dispatch)" -ForegroundColor Green
Write-Host "  Crew: RESEARCHER, ANALYST, ENGINEER, WRITER, SCOUT, OPERATOR, FOREMAN" -ForegroundColor Green
Write-Host "  Permissions: full access ON, no-questions ON, crew-aware dispatch ON" -ForegroundColor Green
if ($taskText) { Write-Host "  Task: $TaskFile ($($taskText.Length) chars)" -ForegroundColor Green }
else { Write-Host "  Task: using built-in default (no a.* task file found)" -ForegroundColor Yellow }
Write-Host ""
