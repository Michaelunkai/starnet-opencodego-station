#requires -Version 5.1
<#  launch-opencodego.ps1  â€” THE script. Bulletproof edition.

    Run it. The station comes up, the ENTIRE crew starts working on your task,
    and Chrome opens ONLY when everything is already running â€” so the browser
    shows working agents from the first frame. Never a "STATION DATA UNREACHABLE".

    Task source: ANY file named  a.*  in F:\Downloads (a.md, a.txt, a.md.txt, â€¦).

    Usage:  powershell -ExecutionPolicy Bypass -File launch-opencodego.ps1
#>
[CmdletBinding()]
param(
  [int]$Port = 8787,
  [string]$Model = 'mimo-v2.5',
  [string]$Repo,
  [string]$ProxyDir,
  [int]$ReadyTimeoutSec = 90,
  [int]$CrewWaitSec = 60,     # wait this long for NOVA+crew to be live before opening Chrome
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

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# 1. RESOLVE THE STARNET CHECKOUT
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
$candidates = @()
if ($Repo) { $candidates += $Repo }
$candidates += @($ScriptDir, (Split-Path -Parent $ScriptDir), 'F:\study\Windows\Applications\PowerShell\Automation\OpenCode\Scripts\starnet', 'F:\study\Windows\Applications\PowerShell\Automation\OpenCode\Scripts\starnet', (Join-Path $env:USERPROFILE 'StarNet'))
$Repo = $null
foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath (Join-Path $c 'sidecar\index.js'))) { $Repo = (Resolve-Path -LiteralPath $c).Path; break } }
if (-not $Repo) { Fail "Could not find a StarNet checkout. Pass -Repo <path>." }
$Sidecar = Join-Path $Repo 'sidecar\index.js'
$Prepare = FirstExisting @((Join-Path $ScriptDir 'prepare-opencodego-station.js'), (Join-Path $Repo 'prepare-opencodego-station.js'))
$Kickoff = FirstExisting @((Join-Path $ScriptDir 'kickoff-mission.ps1'), (Join-Path $Repo 'kickoff-mission.ps1'))
if (-not $Prepare) { Fail "prepare-opencodego-station.js not found." }

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# 2. RESOLVE THE PROXY
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
if (-not $ProxyDir) {
  $ProxyDir = FirstExisting @(
    'F:\study\repos\aiml\AI_and_Machine_Learning\Artificial_Intelligence\cli\opencode\OpencodeGoProxy',
    (Join-Path $ScriptDir 'OpencodeGoProxy'), (Join-Path $Repo 'OpencodeGoProxy'))
}
$ProxyConfig = if ($ProxyDir) { Join-Path $ProxyDir 'config.json' } else { $null }
$ProxyExe = if ($ProxyDir) { Join-Path $ProxyDir 'OpencodeGoProxy.exe' } else { $null }
$StateDir = Join-Path $env:LOCALAPPDATA 'StarNet\opencodego'
$Workspace = Join-Path $StateDir 'workspace'
$OutLog = Join-Path $StateDir 'sidecar.out.log'
$ErrLog = Join-Path $StateDir 'sidecar.err.log'

# STABLE API TOKEN â€” THE fix for "STATION DATA UNREACHABLE / SAVE-NET". The sidecar mints a RANDOM token per
# launch unless STARNET_API_TOKEN is set, so a browser page loaded before a sidecar restart holds a token the
# NEW sidecar rejects â€” the page can never reconnect (its retry re-uses the dead token). Persist one token and
# reuse it on every launch so any open page survives any restart.
$TokenFile = Join-Path $StateDir 'api-token.txt'
$apiToken = ''
if (Test-Path -LiteralPath $TokenFile) { try { $apiToken = (Get-Content -LiteralPath $TokenFile -Raw).Trim() } catch { $apiToken = '' } }
if (-not $apiToken -or $apiToken.Length -lt 32) {
  $bytes = New-Object byte[] 32
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $apiToken = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
  try { [IO.File]::WriteAllText($TokenFile, $apiToken, (New-Object Text.UTF8Encoding($false))) } catch {}
}

if (-not $ProxyConfig -or -not (Test-Path -LiteralPath $ProxyConfig)) { Fail "OpencodeGoProxy config.json not found. Pass -ProxyDir." }
$cfg = Get-Content -LiteralPath $ProxyConfig -Raw | ConvertFrom-Json
$key = [string]$cfg.local_api_key
$proxyBase = ([Uri]([string]$cfg.listen_prefix)).GetLeftPart([UriPartial]::Authority).TrimEnd('/')
$providerBase = $proxyBase + '/v1'

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# 3. FIND THE TASK â€” ANY file named "a.*" in F:\Downloads
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
$TaskFile = $null; $taskText = ''
try {
  $m = Get-ChildItem -LiteralPath 'F:\Downloads' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^a\.' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($m) {
    $TaskFile = $m.FullName
    $taskText = (Get-Content -LiteralPath $TaskFile -Raw -ErrorAction SilentlyContinue).Trim()
  }
} catch {}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# 4. TASK TEXT (always populated â€” fall back to a built-in default mission)
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
$defaultTask = 'Create, test, and deploy the most useful time-organization and management application you can build, with every genuinely useful feature you can think of.'
if ($taskText) {
  Step ("task: " + $TaskFile + " (" + $taskText.Length + " chars)")
} else {
  if ($TaskFile) { Warn "task file empty ($TaskFile) - using built-in default" }
  else { Warn "no file named 'a.*' in F:\Downloads - using built-in default" }
  $taskText = $defaultTask
}

# THE ROLES â€” one routine per agent, fired IN PARALLEL. Deterministic: every specialist works
# on the task at the same time, no model discretion, no reliance on NOVA remembering to delegate.
$Roles = @(
  @{ id = 'agent';      name = 'NOVA';       job = 'Coordinate the whole mission. Research the task domain with web_search and produce a prioritized plan/spec with acceptance criteria. Save your spec to your workspace.' },
  @{ id = 'researcher'; name = 'RESEARCHER'; job = 'Research this task domain deeply with web_search. Return a thorough sourced feature/fact summary. Save it to your workspace.' },
  @{ id = 'analyst';    name = 'ANALYST';    job = 'Turn the task into a prioritized spec with concrete acceptance criteria. Save it to your workspace.' },
  @{ id = 'engineer';   name = 'ENGINEER';   job = 'Build the working artifact for this task in your workspace. Run it, test it, fix it until it genuinely works. Save every file you produce.' },
  @{ id = 'writer';     name = 'WRITER';     job = 'Write the README, usage documentation, and launch notes for this task artifact. Save them to your workspace.' },
  @{ id = 'scout';      name = 'SCOUT';      job = 'Survey what already exists for this task. Name what makes our approach different. Save a report to your workspace.' },
  @{ id = 'operator';   name = 'OPERATOR';   job = 'Make this task result runnable on demand: create the launch steps/script. Save them to your workspace.' },
  @{ id = 'foreman';    name = 'FOREMAN';    job = 'Track this mission as parallel workstreams. Report live status and what is left. Save a plan to your workspace.' }
)

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# 5. PROXY â€” healthy + supervised
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
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

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# 6. CLEAR THE PORT â€” clean boot, never hang
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
Step 'clearing port...'
try { Stop-ScheduledTask -TaskName 'StarNet-OpenCodeGo' -ErrorAction SilentlyContinue } catch {}
Stop-SidecarNodes
Stop-Port $Port
$spDir = Join-Path $Workspace '.spend-pending'
if (Test-Path -LiteralPath $spDir) { Get-ChildItem -LiteralPath $spDir -File -ErrorAction SilentlyContinue | ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -ErrorAction SilentlyContinue } catch {} } }
Step "port $Port clear"

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# 7. PREPARE STATION â€” team on disk
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
Step 'preparing station...'
node $Prepare
if ($LASTEXITCODE -ne 0) { Fail "prepare failed" }

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# 8. SELF-HEALING SIDECAR â€” never dies
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
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

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# 9. WAIT FOR FULL READINESS â€” station answers AND serves the API
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
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
Start-Sleep -Seconds 3   # settle: let the sidecar finish any background boot work
Step "station ready: $Url"

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# 10. MASTER BYPASS
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
$H = @{ 'X-StarNet-Token' = $tok }
try {
  $bp = Invoke-RestMethod -Uri ($Url + 'api/permissions/bypass') -Method Post -Headers $H -ContentType 'application/json' -Body (@{ on = $true } | ConvertTo-Json) -TimeoutSec 10
  Step ("bypass: " + $bp.masterBypass)
} catch { Warn "bypass failed" }

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# 11. MISSION ROUTINES â€” ONE PER AGENT (deterministic full-crew parallelism)
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# Never delete-and-recreate a canonical routine (the W6 mint gate declines a name used moments ago).
# Instead: remove only STALE routines (not one of the 8 canonical names), then PATCH-or-CREATE each role.
$canonical = $Roles | ForEach-Object { 'MISSION: ' + $_.name }
try {
  $list = Invoke-RestMethod -Uri ($Url + 'api/cron') -Headers $H -TimeoutSec 15
  foreach ($j in @($list.jobs)) {
    $isStale = ($j.name -eq 'TEST') -or (($j.name -like 'MISSION:*') -and ($canonical -notcontains $j.name))
    if ($isStale) {
      try { Invoke-RestMethod -Uri ($Url + 'api/cron/remove') -Method Post -Headers $H -ContentType 'application/json' -Body (@{ id = $j.id } | ConvertTo-Json) -TimeoutSec 15 | Out-Null } catch {}
    }
  }
} catch { Warn "routine cleanup failed: $($_.Exception.Message)" }

# NOVA's main chat session (the General stream in the save) â€” every agent's output is delivered HERE so the
# Commander watches the whole mission in NOVA's chat.
$novaSession = ''
try {
  $sv = Get-Content -LiteralPath (Join-Path $Workspace 'agent.save.json') -Raw | ConvertFrom-Json
  $ws = @($sv.doc.workstreams) | Where-Object { $_ -and ($_.agentId -eq 'agent') } | Select-Object -First 1
  if (-not $ws) { $ws = @($sv.doc.workstreams) | Select-Object -First 1 }
  if ($ws) { $novaSession = [string]$ws.id }
} catch {}
if (-not $novaSession) { $novaSession = 'ws_nova_main' }
Step ("nova chat session: " + $novaSession)

foreach ($r in $Roles) {
  $name = 'MISSION: ' + $r.name
  $prompt = "MISSION - run until complete, highest priority:`r`n`r`n" + $taskText + "`r`n`r`nYOUR ROLE ON THIS MISSION: " + $r.job + "`r`n`r`nWork with your real tools. Save your deliverable to YOUR workspace. Never stop until your part is done. Never ask the Commander anything."
  $existing = $null
  try { $list = Invoke-RestMethod -Uri ($Url + 'api/cron') -Headers $H -TimeoutSec 15; $existing = @($list.jobs | Where-Object { $_.name -eq $name })[0] } catch {}
  $common = @{
    prompt = $prompt; enabled = $true; state = 'scheduled'; deliver = 'local'; attachToSession = $true;
    origin = @{ sessionId = $novaSession; streamId = $novaSession; sessionTitle = 'General' }
  }
  try {
    if ($existing) {
      $patch = @{ id = $existing.id; patch = $common } | ConvertTo-Json -Depth 8
      Invoke-RestMethod -Uri ($Url + 'api/cron/update') -Method Post -Headers $H -ContentType 'application/json' -Body $patch -TimeoutSec 20 | Out-Null
    } else {
      $body = (@{ name = $name; schedule = 'every 3 minutes'; agentId = $r.id } + $common) | ConvertTo-Json -Depth 8
      $cr = Invoke-RestMethod -Uri ($Url + 'api/cron') -Method Post -Headers $H -ContentType 'application/json' -Body $body -TimeoutSec 20
      if ($cr.declined -and -not $cr.job) { Warn ("routine " + $r.name + " declined by mint gate; will retry on next run") }
    }
  } catch { Warn ("routine " + $r.name + " failed: " + $_.Exception.Message) }
}
$persisted = 0
try { $list = Invoke-RestMethod -Uri ($Url + 'api/cron') -Headers $H -TimeoutSec 15; $persisted = @($list.jobs | Where-Object { $_.name -in $canonical }).Count } catch {}
if ($persisted -ge $Roles.Count) { Step ("mission: " + $persisted + " agent routines ready + persisted") }
else { Warn ("mission routines: expected " + $Roles.Count + ", found " + $persisted) }

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# 12. FIRE ALL AGENTS IN PARALLEL â€” detached, each holds its own stream
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
if ($Kickoff -and (Test-Path -LiteralPath $Kickoff)) {
  foreach ($r in $Roles) {
    try {
      $cmdline = ('powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $Kickoff + '" -JobName "MISSION: ' + $r.name + '"')
      $spawn = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmdline; CurrentDirectory = $Repo }
      if ($spawn.ReturnValue -ne 0) { Warn ("kickoff " + $r.name + " failed") }
    } catch { Warn ("kickoff " + $r.name + " failed") }
  }
  Step 'all 8 agents fired in parallel'
}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# 13. WAIT FOR AGENTS TO BE WORKING â€” BEFORE opening the browser
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
Step "waiting for agents to start working (up to ${CrewWaitSec}s)..."
$dl = (Get-Date).AddSeconds($CrewWaitSec)
$lastLive = ''
while ((Get-Date) -lt $dl) {
  try {
    $snap = Invoke-RestMethod -Uri ($Url + 'api/state/snapshot') -Headers $H -TimeoutSec 5
    $ids = @($snap.runs | ForEach-Object { $_.agentId })
    if ($ids.Count -gt 0) {
      $lastLive = ($ids -join ', ')
      if ($ids.Count -ge 2) { break }   # NOVA + at least one crew member = the mission is visibly working
    }
  } catch {}
  Start-Sleep -Seconds 5
}
if ($lastLive) { Step ("agents working: " + $lastLive) } else { Warn "no agents visible yet - opening browser anyway (mission continues in background)" }

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# 14. VERIFY
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
try {
  $r = Get-Content -LiteralPath (Join-Path $Workspace 'agent.roster.json') -Raw | ConvertFrom-Json
  Step ("roster: " + ($r.agents | ForEach-Object { $_.agentId }) -join ', ')
} catch {}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# 15. FINAL HEALTH RE-CHECK â€” then open Chrome, when the station is provably healthy
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
$finalOk = $false
$dl = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $dl) {
  if (Test-Listen $Port) {
    try { $hr = Invoke-WebRequest -UseBasicParsing -Uri ($Url + 'api/health') -Headers $H -TimeoutSec 5; if ($hr.StatusCode -lt 400) { $finalOk = $true; break } } catch {}
  }
  Start-Sleep -Milliseconds 700
}
if ($finalOk) { Step 'station healthy - opening browser' } else { Warn 'station re-check failed - opening browser anyway (supervisor + persisted routines will recover)' }

if (-not $NoBrowser) {
  Step 'opening Chrome...'
  try { Start-Process $Url } catch { Warn "could not open browser: $($_.Exception.Message)" }
}

Write-Host ""
Write-Host "  StarNet is live at $Url" -ForegroundColor Green
Write-Host "  Brain: opencode-go / $Model" -ForegroundColor Green
Write-Host "  Team: NOVA + FOREMAN + RESEARCHER + ENGINEER + ANALYST + WRITER + SCOUT + OPERATOR" -ForegroundColor Green
Write-Host "  Permissions: full access ON, no-questions ON, crew-aware dispatch ON" -ForegroundColor Green
if ($taskText) { Write-Host "  Task: $TaskFile ($($taskText.Length) chars)" -ForegroundColor Green }
else { Write-Host "  Task: using built-in default (no a.* task file found)" -ForegroundColor Yellow }
Write-Host ""