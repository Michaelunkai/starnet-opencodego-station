#requires -Version 5.1
<#
  verify-no-overlap.ps1

  NO-OVERLAP CREW CONTRACT verifier (read-only on every existing file).

  It extracts the NOVA lead prompt ($novaLead) from launch-opencodego.ps1 and
  proves, PASS/FAIL with a printed reason, that the dispatched crew works on
  seven disjoint slices with nothing skipped and nothing duplicated.

  Checks
    1. dispatch-all-seven      - the lead dispatches scout, researcher, analyst,
                                 engineer, writer, operator, foreman by name.
    2. exclusive-slices        - seven rows, each a distinct deliverable, no
                                 deliverable/token shared by two specialists.
    3. prompt-size-ceiling     - the <3500 char worker rule is present and
                                 consistent with the 4000 char auto-decline.
    4. no-schema-no-session    - workers are forbidden resultSchema + session.
    5. lead-tool-lockdown      - the lead is forbidden shell_exec / fs_* / web_*.
    6. numbered-acceptance     - every checklist item is numbered and mapped to
                                 a named deliverable.

  Exit code: 0 when every check PASSes, 1 when any FAILs, 2 on load failure.
  This script only reads; it writes nothing.
#>
[CmdletBinding()]
param(
  [string]$LaunchScript,
  [string]$RosterPath,
  [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $RepoRoot)     { $RepoRoot     = Split-Path -Parent $ScriptDir }
if (-not $LaunchScript) { $LaunchScript = Join-Path $RepoRoot 'launch-opencodego.ps1' }
if (-not $RosterPath)   { $RosterPath   = 'F:\study\Windows\Applications\PowerShell\Automation\OpenCode\State\StarNet\opencodego\workspace\agent.roster.json' }

$script:Pass = 0
$script:Fail = 0
function Result([bool]$ok, [string]$name, [string]$reason) {
  if ($ok) { $script:Pass++; Write-Host ('[PASS] ' + $name + ' - ' + $reason) }
  else     { $script:Fail++; Write-Host ('[FAIL] ' + $name + ' - ' + $reason) }
}
function ContainsCI([string]$hay, [string]$needle) {
  if ([string]::IsNullOrEmpty($hay) -or [string]::IsNullOrEmpty($needle)) { return $false }
  return ($hay.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

Write-Host ''
Write-Host '=== verify-no-overlap.ps1 : NO-OVERLAP CREW CONTRACT ==='
Write-Host ('launch : ' + $LaunchScript)
Write-Host ('roster : ' + $RosterPath)
Write-Host ''

# ---------------------------------------------------------------- load inputs
if (-not (Test-Path -LiteralPath $LaunchScript)) {
  Result $false 'load-launch' ('missing launch script: ' + $LaunchScript)
  Write-Host ''
  Write-Host ('RESULT: 0 passed, 1 failed (load error)')
  exit 2
}
$raw = Get-Content -LiteralPath $LaunchScript -Raw

$m = [regex]::Match($raw, '(?s)\$novaLead\s*=\s*"(.*?)"\r?\n')
if (-not $m.Success) {
  Result $false 'load-novalead' 'could not extract the $novaLead string from launch-opencodego.ps1'
  Write-Host ''
  Write-Host ('RESULT: 0 passed, 1 failed (load error)')
  exit 2
}
# unescape PowerShell doubled quotes ("") -> (")
$lead = $m.Groups[1].Value.Replace('""', '"')
Result $true 'load-novalead' ('extracted $novaLead (' + $lead.Length + ' chars)')

$rosterIds = @()
if (Test-Path -LiteralPath $RosterPath) {
  try {
    $roster = Get-Content -LiteralPath $RosterPath -Raw | ConvertFrom-Json
    $rosterIds = @($roster.agents | ForEach-Object { [string]$_.agentId })
    Result $true 'load-roster' ('parsed roster with ' + $rosterIds.Count + ' agents')
  } catch {
    Result $false 'load-roster' ('roster parse failed: ' + $_.Exception.Message)
  }
} else {
  Result $false 'load-roster' ('missing roster: ' + $RosterPath)
}

$roles = @('scout', 'researcher', 'analyst', 'engineer', 'writer', 'operator', 'foreman')

# ------------------------------------------------- 1. dispatch-all-seven
$missingInLead   = @($roles | Where-Object { -not (ContainsCI $lead $_) })
$missingInRoster = @($roles | Where-Object { $_ -notin $rosterIds })
$hasDispatch = ContainsCI $lead 'team_dispatch'
$hasAll7     = ContainsCI $lead 'ALL 7 specialists'
$hasParallel = ContainsCI $lead 'parallel:true'
$c1 = ($missingInLead.Count -eq 0) -and ($missingInRoster.Count -eq 0) -and $hasDispatch -and $hasAll7 -and $hasParallel
$c1reason = 'lead names all 7 (' + ($roles -join ', ') + '); team_dispatch=' + $hasDispatch + ', "ALL 7 specialists"=' + $hasAll7 + ', parallel:true=' + $hasParallel + '; roster has all 7=' + ($missingInRoster.Count -eq 0)
if ($missingInLead.Count -gt 0)   { $c1reason += '; MISSING from lead: ' + ($missingInLead -join ', ') }
if ($missingInRoster.Count -gt 0) { $c1reason += '; MISSING from roster: ' + ($missingInRoster -join ', ') }
Result $c1 'dispatch-all-seven' $c1reason

# ------------------------------------------------- 2. exclusive-slices
# Canonical seven-slice contract. Each specialist owns exactly one deliverable;
# Tokens are the exclusive artifacts that must not be claimed by any other role.
$slices = @(
  [pscustomobject]@{ Role = 'scout';      Deliverable = 'Reconnaissance survey of the project and defect surface'; Tokens = @('surveys briefly') },
  [pscustomobject]@{ Role = 'researcher'; Deliverable = 'Environment/toolchain facts (MinGW cmake, g++ 64-bit, no MSVC)'; Tokens = @('MinGW', 'g++ 64-bit', 'NO MSVC') },
  [pscustomobject]@{ Role = 'analyst';    Deliverable = 'Acceptance spec'; Tokens = @('acceptance spec') },
  [pscustomobject]@{ Role = 'engineer';   Deliverable = 'C++20 sources + CMakeLists.txt + build.cmd + dist\MonitorIsolator.exe'; Tokens = @('CMakeLists', 'build.cmd', 'MonitorIsolator.exe') },
  [pscustomobject]@{ Role = 'writer';     Deliverable = 'Docs: README.md, USER_GUIDE.md, CHANGELOG.md'; Tokens = @('writes docs') },
  [pscustomobject]@{ Role = 'operator';   Deliverable = 'RUN.cmd launch steps'; Tokens = @('RUN.cmd') },
  [pscustomobject]@{ Role = 'foreman';    Deliverable = 'Foreman acceptance table'; Tokens = @('acceptance table') }
)

$c2ok = $true
$c2notes = @()

# exactly one row per specialist
$rowRoles = @($slices | ForEach-Object { $_.Role })
$dupRoles = @($rowRoles | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
if ($slices.Count -ne 7) { $c2ok = $false; $c2notes += ('expected 7 slice rows, found ' + $slices.Count) }
if ($dupRoles.Count -gt 0) { $c2ok = $false; $c2notes += ('duplicate role rows: ' + ($dupRoles -join ', ')) }

# distinct, non-empty deliverable per role
$emptyDeliv = @($slices | Where-Object { [string]::IsNullOrWhiteSpace($_.Deliverable) } | ForEach-Object { $_.Role })
$dupDeliv = @($slices | Group-Object Deliverable | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
if ($emptyDeliv.Count -gt 0) { $c2ok = $false; $c2notes += ('empty deliverable for: ' + ($emptyDeliv -join ', ')) }
if ($dupDeliv.Count -gt 0)   { $c2ok = $false; $c2notes += ('duplicated deliverable: ' + ($dupDeliv -join ' | ')) }

# every slice is actually assigned in the lead prompt
$unassigned = @($slices | Where-Object {
    $hit = $false
    foreach ($t in $_.Tokens) { if (ContainsCI $lead $t) { $hit = $true; break } }
    -not $hit
} | ForEach-Object { $_.Role })
if ($unassigned.Count -gt 0) { $c2ok = $false; $c2notes += ('no slice text found in lead for: ' + ($unassigned -join ', ')) }

# no deliverable token is shared between two specialists (no overlap)
$tokenOwner = @{}
$tokenClash = @()
foreach ($s in $slices) {
  foreach ($t in $s.Tokens) {
    $key = $t.ToLowerInvariant()
    if ($tokenOwner.ContainsKey($key)) { $tokenClash += ($t + ' owned by ' + $tokenOwner[$key] + ' and ' + $s.Role) }
    else { $tokenOwner[$key] = $s.Role }
  }
}
if ($tokenClash.Count -gt 0) { $c2ok = $false; $c2notes += ('shared deliverable tokens: ' + ($tokenClash -join '; ')) }

$c2reason = '7 roles, 7 distinct deliverables, 0 shared tokens, all slices present in the lead prompt'
if ($c2notes.Count -gt 0) { $c2reason = ($c2notes -join '; ') }
Result $c2ok 'exclusive-slices' $c2reason

# ------------------------------------------------- 3. prompt-size-ceiling
$has3500  = ContainsCI $lead '3500'
$has4000  = ContainsCI $lead '4000'
$hasAuto  = (ContainsCI $lead 'auto-declined') -or (ContainsCI $lead 'auto declined')
$hasUnder = ContainsCI $lead 'MUST stay under 3500 characters'
$hasTight = ContainsCI $lead 'keep subtask text tight'
$c3 = $has3500 -and $has4000 -and $hasAuto -and $hasUnder -and $hasTight -and (3500 -lt 4000)
$c3reason = 'worker rule "<3500 chars"=' + $hasUnder + ', auto-decline mention=' + $hasAuto + ', enforced 3500 < decline threshold 4000 = True, "keep subtask text tight"=' + $hasTight
Result $c3 'prompt-size-ceiling' $c3reason

# ------------------------------------------------- 4. no-schema-no-session
$noSchema   = ContainsCI $lead 'do NOT pass resultSchema to workers'
$noSession  = ContainsCI $lead 'do NOT pass session to workers'
$schemaMentions  = @([regex]::Matches($lead, 'resultSchema')).Count
$schemaNegations = @([regex]::Matches($lead, 'NOT pass resultSchema to workers')).Count
$positiveSchema  = ($schemaMentions -gt $schemaNegations)
$c4 = $noSchema -and $noSession -and (-not $positiveSchema)
$c4reason = 'resultSchema ban=' + $noSchema + ', session-targeting ban=' + $noSession + ', resultSchema mentions=' + $schemaMentions + ' (negated=' + $schemaNegations + '), positive pass-through=' + $positiveSchema
Result $c4 'no-schema-no-session' $c4reason

# ------------------------------------------------- 5. lead-tool-lockdown
$hasForbiddenHeader = ContainsCI $lead 'FORBIDDEN TOOLS FOR NOVA'
$hasViolation       = ContainsCI $lead 'instant mission violation'
$hasShell           = ContainsCI $lead 'shell_exec'
$fsTools            = @('fs_write', 'fs_read', 'fs_edit', 'fs_list', 'fs_append')
$missingFs          = @($fsTools | Where-Object { -not (ContainsCI $lead $_) })
$hasWeb             = (ContainsCI $lead 'web_fetch') -and (ContainsCI $lead 'web_search') -and (ContainsCI $lead 'browser_navigate')
$hasOnly            = ContainsCI $lead 'Your ONLY permitted tools'
$hasTeamDispatchPerm = ContainsCI $lead 'team_dispatch'
$c5 = $hasForbiddenHeader -and $hasViolation -and $hasShell -and ($missingFs.Count -eq 0) -and $hasWeb -and $hasOnly -and $hasTeamDispatchPerm
$c5reason = 'header=' + $hasForbiddenHeader + ', shell_exec=' + $hasShell + ', fs_* all present=' + ($missingFs.Count -eq 0) + ', web_*/browser_navigate=' + $hasWeb + ', "ONLY permitted tools"=' + $hasOnly
if ($missingFs.Count -gt 0) { $c5reason += '; missing fs tools: ' + ($missingFs -join ', ') }
Result $c5 'lead-tool-lockdown' $c5reason

# ------------------------------------------------- 6. numbered-acceptance
$start = $lead.IndexOf('ACCEPTANCE CHECKLIST')
$end   = $lead.IndexOf('PLAN:')
$section = ''
if ($start -ge 0 -and $end -gt $start) { $section = $lead.Substring($start, $end - $start) }
$items = if ($section) { [regex]::Matches($section, '\((\d+)\)') } else { @() }
$nums  = @($items | ForEach-Object { [int]$_.Groups[1].Value })
$expected = @(1, 2, 3, 4, 5, 6, 7)
$missingNums = @($expected | Where-Object { $_ -notin $nums })

$deliverableRe = 'MonitorIsolator|CMakeLists\.txt|build\.cmd|README\.md|USER_GUIDE\.md|CHANGELOG\.md|RUN\.cmd|VERIFY_LAUNCH\.md|TROUBLESHOOTING_RUN|acceptance table|src\\|dist\\'
$unmapped = @()
if ($section) {
  $chunks = [regex]::Split($section, '\(\d+\)')
  for ($i = 1; $i -lt $chunks.Count; $i++) {
    if (-not ($chunks[$i] -match $deliverableRe)) { $unmapped += $i }
  }
}
$c6 = ($nums.Count -ge 7) -and ($missingNums.Count -eq 0) -and ($unmapped.Count -eq 0)
$c6reason = 'numbered items found=' + $nums.Count + ' [' + ($nums -join ',') + '], every item maps to a named deliverable=' + ($unmapped.Count -eq 0)
if ($missingNums.Count -gt 0) { $c6reason += '; missing numbers: ' + ($missingNums -join ', ') }
if ($unmapped.Count -gt 0)    { $c6reason += '; items without a deliverable: ' + ($unmapped -join ', ') }
Result $c6 'numbered-acceptance' $c6reason

# ---------------------------------------------------------------- summary
Write-Host ''
Write-Host ('RESULT: ' + $script:Pass + ' passed, ' + $script:Fail + ' failed')
if ($script:Fail -eq 0) { Write-Host 'NO-OVERLAP CREW CONTRACT: VERIFIED'; exit 0 }
Write-Host 'NO-OVERLAP CREW CONTRACT: NOT VERIFIED'
exit 1
