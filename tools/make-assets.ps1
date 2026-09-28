#requires -Version 5.1
<#
  make-assets.ps1 - generate every image in assets/ PROGRAMMATICALLY (no screenshots, no external tools).
  Windows PowerShell 5.1 + System.Drawing only. Deterministic: same output every run.

  Usage:  powershell -ExecutionPolicy Bypass -File tools\make-assets.ps1
#>
[CmdletBinding()]
param(
  [string]$OutDir
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $scriptDir) 'assets' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# ---- palette (matches the StarNet phosphor-terminal look) ----
$BG      = [System.Drawing.Color]::FromArgb(11, 15, 16)
$PANEL   = [System.Drawing.Color]::FromArgb(18, 24, 26)
$FRAME   = [System.Drawing.Color]::FromArgb(60, 78, 80)
$GREEN   = [System.Drawing.Color]::FromArgb(98, 255, 158)
$AMBER   = [System.Drawing.Color]::FromArgb(255, 201, 120)
$CYAN    = [System.Drawing.Color]::FromArgb(90, 208, 255)
$TEXT    = [System.Drawing.Color]::FromArgb(238, 232, 219)
$DIM     = [System.Drawing.Color]::FromArgb(150, 168, 165)

function New-Canvas([int]$w, [int]$h) {
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
  $g.Clear($BG)
  return @{ Bmp = $bmp; G = $g }
}

function New-Font([string]$family, [single]$size, [string]$style = 'Regular') {
  $s = [System.Drawing.FontStyle]::$style
  return New-Object System.Drawing.Font($family, $size, $s, [System.Drawing.GraphicsUnit]::Pixel)
}

function Draw-Text($g, [string]$text, $font, $color, [int]$x, [int]$y) {
  $brush = New-Object System.Drawing.SolidBrush($color)
  $g.DrawString($text, $font, $brush, [single]$x, [single]$y)
  $brush.Dispose()
}

function Draw-Box($g, [int]$x, [int]$y, [int]$w, [int]$h, $fill, $frame, [int]$radius = 10) {
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $radius * 2
  $path.AddArc($x, $y, $d, $d, 180, 90)
  $path.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $path.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $path.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $path.CloseFigure()
  $fb = New-Object System.Drawing.SolidBrush($fill)
  $g.FillPath($fb, $path)
  $pen = New-Object System.Drawing.Pen($frame, 1.4)
  $g.DrawPath($pen, $path)
  $fb.Dispose(); $pen.Dispose(); $path.Dispose()
}

function Draw-Arrow($g, [int]$x1, [int]$y1, [int]$x2, [int]$y2, $color) {
  $pen = New-Object System.Drawing.Pen($color, 2.0)
  $pen.CustomEndCap = New-Object System.Drawing.Drawing2D.AdjustableArrowCap(5, 6, $true)
  $g.DrawLine($pen, $x1, $y1, $x2, $y2)
  $pen.Dispose()
}

function Save-Canvas($c, [string]$path) {
  $c.G.Dispose()
  $c.Bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $c.Bmp.Dispose()
  Write-Host ("wrote " + $path)
}

$mono = 'Consolas'
$sans = 'Segoe UI'

# ============================================================ 1. HERO BANNER
$c = New-Canvas 1280 640
$g = $c.G
# subtle grid
$gridPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(22, 34, 34), 1)
for ($x = 0; $x -lt 1280; $x += 32) { $g.DrawLine($gridPen, $x, 0, $x, 640) }
for ($y = 0; $y -lt 640; $y += 32) { $g.DrawLine($gridPen, 0, $y, 1280, $y) }
$gridPen.Dispose()

Draw-Box $g 48 48 1184 544 $PANEL $FRAME 16
Draw-Text $g 'LOCAL AGENT STATION' (New-Font $mono 16 'Bold') $GREEN 84 92
Draw-Text $g 'STARNET' (New-Font $sans 78 'Bold') $TEXT 80 120
Draw-Text $g 'x' (New-Font $sans 44 'Bold') $AMBER 400 150
Draw-Text $g 'OPENCODE GO' (New-Font $sans 58 'Bold') $CYAN 470 138
Draw-Text $g 'Wire the StarNet harness to the OpenCode Go API through a self-healing local failover proxy,' (New-Font $sans 20) $DIM 84 268
Draw-Text $g 'seed a full 8-agent crew, and run a standing mission unattended - in Chrome.' (New-Font $sans 20) $DIM 84 300

$chips = @(
  @{ t = 'launch-opencodego.ps1'; c = $GREEN },
  @{ t = '8-agent crew';          c = $CYAN  },
  @{ t = 'mimo-v2.5';             c = $AMBER },
  @{ t = 'chat/completions';      c = $GREEN },
  @{ t = 'proxy failover';        c = $CYAN  },
  @{ t = 'crew-aware routines';   c = $AMBER }
)
$cx = 84
foreach ($ch in $chips) {
  $font = New-Font $mono 15 'Bold'
  $sz = $g.MeasureString($ch.t, $font)
  $w = [int]$sz.Width + 26
  Draw-Box $g $cx 356 $w 40 $BG $ch.c 8
  Draw-Text $g $ch.t $font $ch.c ($cx + 13) 366
  $cx += $w + 12
  $font.Dispose()
}

Draw-Text $g 'NOVA + FOREMAN + RESEARCHER + ENGINEER + ANALYST + WRITER + SCOUT + OPERATOR' (New-Font $mono 17 'Bold') $TEXT 84 452
Draw-Text $g 'https://127.0.0.1:8787   |   MIT-licensed upstream: github.com/androoAGI/starnet' (New-Font $mono 15) $DIM 84 500
Draw-Text $g '> station online' (New-Font $mono 18 'Bold') $GREEN 84 540
Save-Canvas $c (Join-Path $OutDir 'hero.png')

# ============================================================ 2. ARCHITECTURE
$c = New-Canvas 1280 720
$g = $c.G
Draw-Text $g 'ARCHITECTURE' (New-Font $sans 30 'Bold') $TEXT 56 40
Draw-Text $g 'one machine, four hops, zero external services' (New-Font $sans 16) $DIM 56 80

$bw = 250; $bh = 120; $by = 220
$xs = @(60, 370, 680, 990)
$boxes = @(
  @{ t = 'CHROME'; s = @('http://127.0.0.1:8787', 'StarNet world + COMMS'); c = $CYAN },
  @{ t = 'SIDECAR'; s = @('sidecar/index.js', 'agents - tools - cron'); c = $GREEN },
  @{ t = 'PROXY'; s = @('OpencodeGoProxy.exe', ':4000/v1 failover'); c = $AMBER },
  @{ t = 'OPENCODE GO'; s = @('opencode.ai/zen/go/v1', 'mimo-v2.5'); c = $CYAN }
)
for ($i = 0; $i -lt 4; $i++) {
  $b = $boxes[$i]
  Draw-Box $g $xs[$i] $by $bw $bh $PANEL $b.c 12
  Draw-Text $g $b.t (New-Font $mono 22 'Bold') $b.c ($xs[$i] + 18) ($by + 18)
  Draw-Text $g $b.s[0] (New-Font $mono 13) $TEXT ($xs[$i] + 18) ($by + 58)
  Draw-Text $g $b.s[1] (New-Font $mono 13) $DIM ($xs[$i] + 18) ($by + 80)
  if ($i -lt 3) { Draw-Arrow $g ($xs[$i] + $bw + 6) ($by + $bh / 2) ($xs[$i + 1] - 8) ($by + $bh / 2) $DIM }
}
Draw-Arrow $g ($xs[2] + $bw / 2) ($by + $bh + 6) ($xs[2] + $bw / 2) ($by + $bh + 60) $AMBER
Draw-Text $g 'key failover: retries 402 / 429 / 5xx across the credential pool' (New-Font $mono 14) $AMBER 600 420

Draw-Box $g 60 480 1180 190 $PANEL $FRAME 14
Draw-Text $g 'THE CREW' (New-Font $mono 18 'Bold') $GREEN 84 502
$crew = @('NOVA', 'FOREMAN', 'RESEARCHER', 'ENGINEER', 'ANALYST', 'WRITER', 'SCOUT', 'OPERATOR')
$ccx = 84; $ccy = 542
foreach ($a in $crew) {
  $f = New-Font $mono 15 'Bold'
  $sz = $g.MeasureString($a, $f)
  $w = [int]$sz.Width + 24
  if ($ccx + $w -gt 1216) { $ccx = 84; $ccy += 46 }
  Draw-Box $g $ccx $ccy $w 34 $BG $(if ($a -eq 'NOVA') { $GREEN } else { $CYAN }) 8
  Draw-Text $g $a $f $TEXT ($ccx + 12) ($ccy + 8)
  $f.Dispose()
  $ccx += $w + 10
}
Draw-Text $g 'NOVA leads; the seven specialists each run their own real agent loop and report back.' (New-Font $sans 14) $DIM 84 640
Save-Canvas $c (Join-Path $OutDir 'architecture.png')

# ============================================================ 3. FEATURE CARDS
$c = New-Canvas 1280 620
$g = $c.G
Draw-Text $g 'WHAT THE LAUNCHER SETS UP' (New-Font $sans 28 'Bold') $TEXT 56 40
$cards = @(
  @{ t = 'ONE COMMAND BOOT';   d = @('proxy health + supervisor', 'sidecar under an S4U task', 'station seeded, browser opened'); c = $GREEN },
  @{ t = 'FULL CREW';          d = @('8 agents, approvalMode=full', 'roster pushed to disk', 'mimo-v2.5 everywhere');        c = $CYAN  },
  @{ t = 'STANDING MISSION';   d = @('routine every 15 minutes', 'kicked off immediately', 'crew-aware (team.dispatch)');    c = $AMBER },
  @{ t = 'NO PROMPTS';         d = @('master bypass ON', 'no-questions mode', 'autonomous until done');                       c = $GREEN }
)
$cx = 56; $cy = 110; $cw = 285; $ch = 300
for ($i = 0; $i -lt 4; $i++) {
  $card = $cards[$i]
  Draw-Box $g $cx $cy $cw $ch $PANEL $card.c 14
  Draw-Text $g $card.t (New-Font $mono 18 'Bold') $card.c ($cx + 20) ($cy + 22)
  $yy = $cy + 74
  foreach ($line in $card.d) {
    Draw-Text $g ('- ' + $line) (New-Font $mono 13) $TEXT ($cx + 20) $yy
    $yy += 34
  }
  $cx += $cw + 22
}
Draw-Text $g 'Windows PowerShell 5.1  |  Node.js  |  Chrome  |  a running OpencodeGoProxy' (New-Font $mono 15) $DIM 56 470
Draw-Text $g 'Everything is local. The only outbound call is to the OpenCode Go API.' (New-Font $mono 15) $GREEN 56 510
Save-Canvas $c (Join-Path $OutDir 'features.png')

# ============================================================ 4. LIVE STATUS BUBBLES
$c = New-Canvas 1280 560
$g = $c.G
Draw-Text $g 'LIVE WORK BUBBLES' (New-Font $sans 28 'Bold') $TEXT 56 40
Draw-Text $g 'every working agent shows what it is doing, in real time, over its head' (New-Font $sans 16) $DIM 56 80
$bubbles = @(
  @{ a = 'RESEARCHER'; s = 'working: WEB.SEARCH'; c = $CYAN },
  @{ a = 'ENGINEER';   s = 'working: FS.WRITE';   c = $GREEN },
  @{ a = 'ANALYST';    s = 'working: SHELL.EXEC'; c = $AMBER },
  @{ a = 'WRITER';     s = 'working: FS.APPEND';  c = $CYAN }
)
$bx = 90; $byy = 170
foreach ($b in $bubbles) {
  Draw-Box $g $bx $byy 250 90 $PANEL $b.c 12
  Draw-Text $g $b.s (New-Font $mono 14 'Bold') $TEXT ($bx + 16) ($byy + 20)
  $g.FillPolygon((New-Object System.Drawing.SolidBrush($PANEL)), @(
      (New-Object System.Drawing.Point(($bx + 40), ($byy + 90))),
      (New-Object System.Drawing.Point(($bx + 56), ($byy + 90))),
      (New-Object System.Drawing.Point(($bx + 48), ($byy + 104)))
    ))
  Draw-Text $g $b.a (New-Font $mono 13 'Bold') $b.c ($bx + 16) ($byy + 118)
  $bx += 290
  if ($bx -gt 1000) { $bx = 90; $byy += 170 }
}
Draw-Text $g 'Fed only by real harness events (agent.run.start / agent.tool_call / agent.run.end).' (New-Font $sans 15) $DIM 56 460
Draw-Text $g 'Truthful telemetry: a bubble can never say more than the harness actually reported.' (New-Font $sans 15) $GREEN 56 492
Save-Canvas $c (Join-Path $OutDir 'bubbles.png')

Write-Host 'all assets written'
