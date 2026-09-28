#requires -Version 5.1
<#
  kickoff-mission.ps1
  Fires the standing mission routine and HOLDS the connection until the run finishes, so the
  coordination run is never cancelled by a dropped client. Spawned detached by the launcher.
  Usage: powershell -ExecutionPolicy Bypass -File kickoff-mission.ps1 [-Port 8787]
#>
param(
  [int]$Port = 8787,
  [string]$JobName = 'MISSION: Time Management App',
  [int]$MaxMinutes = 240
)
$ErrorActionPreference = 'Stop'
$Base = "http://127.0.0.1:$Port"
$deadline = (Get-Date).AddMinutes($MaxMinutes)

function Get-Token {
  $html = (Invoke-WebRequest -UseBasicParsing -Uri ($Base + '/') -TimeoutSec 20).Content
  return ([regex]::Match($html, '__STARNET_API_TOKEN__="((?:\\.|[^"])*)"')).Groups[1].Value
}

$tok = Get-Token
if (-not $tok) { throw 'could not read the sidecar API token' }
$H = @{ 'X-StarNet-Token' = $tok }

# Wait for the routine to exist (the launcher may create it moments after boot).
$job = $null
for ($i = 0; $i -lt 30 -and -not $job; $i++) {
  try {
    $cron = Invoke-RestMethod -Uri ($Base + '/api/cron') -Headers $H -TimeoutSec 20
    $job = @($cron.jobs | Where-Object { $_.name -eq $JobName })[0]
  } catch { }
  if (-not $job) { Start-Sleep -Seconds 2 }
}
if (-not $job) { throw "routine '$JobName' not found" }

# Fire it and hold the stream open to completion (a dropped client cancels the run).
# A 409 means the routine's one-run-in-flight lease is still held (an earlier interrupted run, or the
# scheduled tick firing at the same moment). Wait and retry rather than dying — the run WILL be free soon.
$body = @{ id = $job.id } | ConvertTo-Json -Compress
$resp = $null
for ($attempt = 1; $attempt -le 40; $attempt++) {
  $req = [Net.HttpWebRequest]::Create($Base + '/api/cron/run')
  $req.Method = 'POST'
  $req.Headers['X-StarNet-Token'] = $tok
  $req.ContentType = 'application/json'
  $req.Timeout = 30000
  $req.ReadWriteTimeout = [Threading.Timeout]::Infinite
  $bytes = [Text.Encoding]::UTF8.GetBytes($body)
  $req.ContentLength = $bytes.Length
  $st = $req.GetRequestStream(); $st.Write($bytes, 0, $bytes.Length); $st.Close()
  try { $resp = $req.GetResponse(); break }
  catch [Net.WebException] {
    $code = 0
    try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = 0 }
    if ($code -eq 409) { Start-Sleep -Seconds 15; continue }
    throw
  }
}
if (-not $resp) { throw 'could not start the mission run (routine stayed busy)' }
$rd = New-Object IO.StreamReader($resp.GetResponseStream())
while (-not $rd.EndOfStream -and (Get-Date) -lt $deadline) { [void]$rd.ReadLine() }
$rd.Close(); $resp.Close()
Write-Output 'kickoff complete'
