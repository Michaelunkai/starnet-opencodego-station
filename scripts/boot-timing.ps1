#requires -Version 5.1
<#
  boot-timing.ps1 - StarNet boot-timing instrument and under-60-second proof harness.

  Times a REAL launcher run end-to-end and proves the launch guarantee:
    * station_ready : the HTTP station answers AND /api/health returns ok   (budget <= 45s)
    * crew_working  : at least 3 distinct agentIds appear in /api/state/snapshot runs (budget <= 60s)

  Exits non-zero if either budget is exceeded, so it is usable as a CI gate.

  Owned by the Boot Timing slot. Read-only against the rest of the starnet tree.
#>
[CmdletBinding()]
param(
  [int]$Port = 8787,
  [string]$Repo = 'F:\study\Windows\Applications\PowerShell\Automation\OpenCode\Scripts\starnet',
  [string]$Launcher,
  [double]$StationBudgetSec = 45,
  [double]$CrewBudgetSec = 60,
  [int]$StationTimeoutSec = 120,
  [int]$CrewTimeoutSec = 180,
  [int]$PollMs = 200,
  [int]$WaitLauncherForSec = 0,
  [switch]$OpenBrowser
)

$ErrorActionPreference = 'Stop'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Url = "http://127.0.0.1:$Port/"
$HealthUrl = $Url + 'api/health'
$SnapshotUrl = $Url + 'api/state/snapshot'
$TokenRegex = '__STARNET_API_TOKEN__="((?:\\.|[^"])*)"'
$LogDir = 'C:\Temp\opencode\starnet-boot-timing'

function Info([string]$m) { Write-Host ("  [boot-timing] " + $m) }
function Get-Text([object]$r) {
  if ($null -eq $r) { return '' }
  $c = $r.Content
  if ($c -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($c) }
  return [string]$c
}
function HttpGet([string]$u, [hashtable]$h, [int]$t = 5) {
  try { return Invoke-WebRequest -UseBasicParsing -Uri $u -Headers $h -TimeoutSec $t } catch { return $null }
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
function Stop-ExistingSidecar([int]$p) {
  # Stop the self-healing scheduled task FIRST so its loop cannot resurrect the sidecar we are about to kill.
  try { Stop-ScheduledTask -TaskName 'StarNet-OpenCodeGo' -ErrorAction SilentlyContinue } catch {}
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
  Stop-Port $p
}

# ---- resolve the launcher -------------------------------------------------
if (-not $Launcher) {
  $Launcher = Join-Path $Repo 'launch-opencodego.ps1'
}
if (-not (Test-Path -LiteralPath $Launcher)) { throw "launcher not found: $Launcher" }
$Launcher = (Resolve-Path -LiteralPath $Launcher).Path

try { if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null } } catch {}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outLog = Join-Path $LogDir ("launcher-$stamp.out.log")
$errLog = Join-Path $LogDir ("launcher-$stamp.err.log")

Write-Host ""
Write-Host "  StarNet boot-timing proof" -ForegroundColor Cyan
Info ("launcher: " + $Launcher)
Info ("station : " + $Url)

# ---- 1. kill any existing sidecar + cmd batch holders ---------------------
Info 'killing existing sidecar and batch holders...'
Stop-ExistingSidecar $Port
Info 'port clear'

# ---- 2. start the launcher as a child process and start the stopwatch ------
$childArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$Launcher`" -Port $Port"
if (-not $OpenBrowser) { $childArgs += " -NoBrowser" }
Info 'starting launcher...'
$proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $childArgs -WorkingDirectory $Repo `
  -WindowStyle Hidden -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
$sw = [Diagnostics.Stopwatch]::StartNew()

# ---- 3. poll for station ready (page answers AND /api/health ok) ----------
$token = ''
$stationReady = $false
$stationDeadline = (Get-Date).AddSeconds($StationTimeoutSec)
while ((Get-Date) -lt $stationDeadline) {
  if (-not $token) {
    $r = HttpGet $Url @{} 3
    if ($r -and $r.StatusCode -ge 200 -and $r.StatusCode -lt 400) {
      $m = [regex]::Match((Get-Text $r), $TokenRegex)
      if ($m.Success -and $m.Groups[1].Value) { $token = $m.Groups[1].Value }
    }
  }
  if ($token) {
    $h = @{ 'X-StarNet-Token' = $token }
    $hr = HttpGet $HealthUrl $h 3
    if ($hr -and $hr.StatusCode -ge 200 -and $hr.StatusCode -lt 400 -and (Get-Text $hr).Trim().ToLower() -eq 'ok') {
      $stationReady = $true
      break
    }
  }
  # If the launcher died before bringing the station up, stop waiting.
  if ($proc -and $proc.HasExited -and -not $token) { break }
  Start-Sleep -Milliseconds $PollMs
}
$tStation = [Math]::Round($sw.Elapsed.TotalSeconds, 2)

# ---- 4. poll for the crew working (>= 3 distinct agentIds) ----------------
$tCrew = $null
$crewAgents = @()
$peakAgents = 0
$peakIds = @()
if ($stationReady) {
  $h = @{ 'X-StarNet-Token' = $token }
  $crewDeadline = (Get-Date).AddSeconds($CrewTimeoutSec)
  while ((Get-Date) -lt $crewDeadline) {
    $snap = $null
    try { $snap = Invoke-RestMethod -Uri $SnapshotUrl -Headers $h -TimeoutSec 4 } catch { $snap = $null }
    if ($snap) {
      $ids = @($snap.runs | ForEach-Object { $_.agentId } | Where-Object { $_ } | Sort-Object -Unique)
      if ($ids.Count -gt $peakAgents) { $peakAgents = $ids.Count; $peakIds = $ids }
      if ($ids.Count -ge 3) { $crewAgents = $ids; break }
    }
    Start-Sleep -Milliseconds $PollMs
  }
  $tCrew = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
}

# ---- 5. report ------------------------------------------------------------
# IMPORTANT: the launcher holds the crew's /api/cron/run NDJSON stream open for the life of the run;
# killing it cancels the run ("run ended without completion: cancelled"). We therefore NEVER force-kill
# the launcher. It is left running so the crew keeps working, and its exit code is read only if it
# happens to have finished on its own (or after an opt-in bounded wait).
if ($WaitLauncherForSec -gt 0 -and $proc -and -not $proc.HasExited) {
  try { Wait-Process -Id $proc.Id -Timeout $WaitLauncherForSec -ErrorAction SilentlyContinue } catch {}
}
$sw.Stop()

$stationPass = ($stationReady -and $tStation -le $StationBudgetSec)
$crewPass = ($null -ne $tCrew -and $tCrew -le $CrewBudgetSec)
$tStationText = if ($stationReady) { $tStation.ToString('0.00') } else { "> $StationTimeoutSec (timeout)" }
$tCrewText = if ($null -ne $tCrew) { $tCrew.ToString('0.00') } elseif ($stationReady) { "> $CrewTimeoutSec (timeout)" } else { 'n/a' }
$crewResult = if (-not $stationReady) { 'FAIL' } elseif ($crewPass) { 'PASS' } else { 'FAIL' }

Write-Host ""
Write-Host ("  {0,-16} {1,-12} {2,-8} {3}" -f 'metric', 'seconds', 'budget', 'result')
Write-Host ("  {0,-16} {1,-12} {2,-8} {3}" -f '----------------', '-----------', '------', '------')
Write-Host ("  {0,-16} {1,-12} {2,-8} {3}" -f 'station_ready', $tStationText, ("<= $StationBudgetSec"), $(if ($stationPass) { 'PASS' } else { 'FAIL' })) -ForegroundColor $(if ($stationPass) { 'Green' } else { 'Red' })
Write-Host ("  {0,-16} {1,-12} {2,-8} {3}" -f 'crew_working', $tCrewText, ("<= $CrewBudgetSec"), $crewResult) -ForegroundColor $(if ($crewPass) { 'Green' } else { 'Red' })
Write-Host ""
Info ("peak distinct agents seen in runs: " + $peakAgents + $(if ($peakIds.Count -gt 0) { " (" + ($peakIds -join ', ') + ")" } else { '' }))
if ($crewAgents.Count -gt 0) { Info ("crew agentIds at threshold: " + ($crewAgents -join ', ')) }
Info ("launcher log: " + $outLog)
if (Test-Path -LiteralPath $errLog) {
  $errTail = (Get-Content -LiteralPath $errLog -Tail 8 -ErrorAction SilentlyContinue) -join "`n"
  if ($errTail) { Info ("launcher stderr tail: " + $errTail) }
}

if ($stationPass -and $crewPass) {
  Write-Host "  BOOT PROOF: PASS (station_ready $tStationText s, crew_working $tCrewText s)" -ForegroundColor Green
  exit 0
}
Write-Host "  BOOT PROOF: FAIL (station_ready $tStationText s, crew_working $tCrewText s)" -ForegroundColor Red
exit 1
