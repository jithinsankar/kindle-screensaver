#Requires -Version 5.1
<#
.SYNOPSIS
    Check that an animation folder matches the Kindle dashboard animation format.

.DESCRIPTION
    Run this before sharing an animation with anyone, or after receiving one.
    It reports in plain language whether the set is valid, and what to fix if not.

    See artwork/FORMAT.md for the format itself.

.EXAMPLE
    powershell -File tools\check-artwork.ps1 artwork\bird
    powershell -File tools\check-artwork.ps1 . -All
#>
[CmdletBinding()]
param(
    # One animation folder, or a parent folder containing several.
    [Parameter(Position = 0)]
    [string] $Path = 'artwork',

    # Check every subfolder of $Path rather than just $Path itself.
    [switch] $All
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Drawing

$script:Errors   = 0
$script:Warnings = 0

function Bad  { param([string]$m) Write-Host "  ERROR  $m" -ForegroundColor Red;    $script:Errors++ }
function Warn { param([string]$m) Write-Host "  warn   $m" -ForegroundColor Yellow; $script:Warnings++ }
function Good { param([string]$m) Write-Host "  ok     $m" -ForegroundColor Green }

function Get-PngInfo {
    param([string]$File)
    $bytes = [IO.File]::ReadAllBytes($File)
    if ($bytes.Length -lt 24) { return $null }
    $sig = ($bytes[0..7] | ForEach-Object { $_.ToString('x2') }) -join ''
    if ($sig -ne '89504e470d0a1a0a') { return $null }
    # IHDR: width at bytes 16-19, height at 20-23, big endian.
    $w = ($bytes[16] * 16777216) + ($bytes[17] * 65536) + ($bytes[18] * 256) + $bytes[19]
    $h = ($bytes[20] * 16777216) + ($bytes[21] * 65536) + ($bytes[22] * 256) + $bytes[23]
    return [pscustomobject]@{ Width = $w; Height = $h }
}

function Get-DistinctGreys {
    param([string]$File)
    $bmp = [System.Drawing.Bitmap]::FromFile($File)
    try {
        $seen = New-Object 'System.Collections.Generic.HashSet[int]'
        # Sample every pixel; frames are small (a few hundred thousand at most).
        for ($y = 0; $y -lt $bmp.Height; $y++) {
            for ($x = 0; $x -lt $bmp.Width; $x++) {
                [void]$seen.Add($bmp.GetPixel($x, $y).R)
            }
        }
        return $seen.Count
    } finally { $bmp.Dispose() }
}

function Test-AnimSet {
    param([string]$Dir)

    # Baseline: the error counter is global, so comparing against a snapshot is
    # what makes "did THIS set have problems" correct. Using -gt 0 directly meant
    # that once any set failed, every later set bailed out early.
    $errorsBefore = $script:Errors

    Write-Host ''
    Write-Host "=== $(Split-Path $Dir -Leaf) ===" -ForegroundColor Cyan
    Write-Host "  $Dir"

    $manifestPath = Join-Path $Dir 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        Bad 'no manifest.json. Every set needs one -- see artwork/FORMAT.md.'
        return
    }

    try {
        $m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    } catch {
        Bad "manifest.json is not valid JSON: $($_.Exception.Message)"
        return
    }
    Good 'manifest.json is valid JSON'

    # --- required fields ---------------------------------------------------
    foreach ($f in 'format', 'version', 'screen', 'frame', 'count', 'delay_ms', 'loop', 'palette') {
        if ($null -eq $m.$f) { Bad "manifest is missing the '$f' field" }
    }
    if ($script:Errors -gt $errorsBefore) { return }

    if ($m.format -ne 'kindle-dashboard-animation') {
        Bad "format is '$($m.format)', expected 'kindle-dashboard-animation'"
    } else {
        Good "format id is correct (version $($m.version))"
    }

    # --- frames present ----------------------------------------------------
    $pattern = 'frame_*.png'
    $frames = @(Get-ChildItem -LiteralPath $Dir -Filter $pattern -File | Sort-Object Name)
    if ($frames.Count -eq 0) {
        Bad "no frames found. They must be named $pattern (zero-padded, starting at frame_000.png)."
        return
    }
    Good "$($frames.Count) frame(s) found matching $pattern"

    if ($m.count -ne $frames.Count) {
        Bad "manifest says count=$($m.count) but there are $($frames.Count) frames"
    } else {
        Good "frame count matches the manifest"
    }

    # Contiguous numbering, because the player relies on name order.
    for ($i = 0; $i -lt $frames.Count; $i++) {
        $expected = 'frame_{0:d3}.png' -f $i
        if ($frames[$i].Name -ne $expected) {
            Warn "frame $i is named '$($frames[$i].Name)', expected '$expected'"
        }
    }

    # --- frame geometry ----------------------------------------------------
    $fw = [int]$m.frame.width
    $fh = [int]$m.frame.height
    $fx = [int]$m.frame.x
    $fy = [int]$m.frame.y
    $sw = [int]$m.screen.width
    $sh = [int]$m.screen.height

    $badSize = 0
    $first = $null
    foreach ($f in $frames) {
        $info = Get-PngInfo -File $f.FullName
        if (-not $info) { Bad "$($f.Name) is not a PNG"; continue }
        if ($null -eq $first) { $first = $info }
        if ($info.Width -ne $fw -or $info.Height -ne $fh) {
            if ($badSize -lt 3) {
                Bad "$($f.Name) is $($info.Width)x$($info.Height) but the manifest says ${fw}x${fh}"
            }
            $badSize++
        }
    }
    if ($badSize -eq 0) { Good "all frames are ${fw}x${fh}, matching the manifest" }
    elseif ($badSize -gt 3) { Bad "...and $($badSize - 3) more frames with the wrong size" }

    # Placement sanity: the frame must fit on the panel.
    if (($fx + $fw) -gt $sw -or ($fy + $fh) -gt $sh) {
        Bad "the frame does not fit: it is placed at ($fx,$fy) with size ${fw}x${fh} on a ${sw}x${sh} screen"
    } elseif ($fx -eq 0 -and $fy -eq 0 -and $fw -eq $sw -and $fh -eq $sh) {
        Good 'full-screen frames (600x800 at 0,0)'
        Warn 'full-screen frames repaint the whole panel each frame, so this is the SLOWEST option'
    } else {
        $pct = [math]::Round(100 * ($fw * $fh) / ($sw * $sh))
        Good "frame occupies $pct% of the panel at ($fx,$fy) -- smaller means faster"
    }

    # --- palette -----------------------------------------------------------
    $greys = Get-DistinctGreys -File $frames[0].FullName
    if ($m.palette -eq '1-bit') {
        if ($greys -gt 2) {
            Warn "palette is '1-bit' but $($frames[0].Name) contains $greys grey levels."
            Warn 'Grey pixels dither on the panel and ghost. Pure black/white animates best.'
        } else {
            Good 'pure black and white, as 1-bit art should be'
        }
    } else {
        Good "palette '$($m.palette)' ($greys grey levels in the first frame)"
    }

    # --- timing ------------------------------------------------------------
    $fps = if ($m.delay_ms -gt 0) { [math]::Round(1000 / $m.delay_ms, 1) } else { 0 }
    Write-Host "  info   asks for $($m.delay_ms)ms per frame (~${fps} fps), $($frames.Count) frames"
    if ($fps -gt 15) {
        Warn 'e-ink manages roughly 5-10 fps; anything above that is wasted. The real rate is in the log.'
    }
    if ($frames.Count -gt 16) {
        Warn "$($frames.Count) frames is a lot. 6-12 per cycle is the useful range at this speed."
    }

    if (Test-Path -LiteralPath (Join-Path $Dir 'preview.png')) {
        Good 'preview.png present (all frames side by side)'
    }
}

# --- run -------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host "No such path: $Path" -ForegroundColor Red
    exit 1
}

if ($All -or -not (Test-Path -LiteralPath (Join-Path $Path 'manifest.json'))) {
    # Only directories that actually look like an animation set. The repo also
    # contains tools/, and a set is defined by having a manifest.json or frames --
    # anything else is not a set and must not be reported as a broken one.
    $candidates = @()
    foreach ($s in @(Get-ChildItem -LiteralPath $Path -Directory)) {
        $hasManifest = Test-Path -LiteralPath (Join-Path $s.FullName 'manifest.json')
        $hasFrames = @(Get-ChildItem -LiteralPath $s.FullName -Filter 'frame_*.png' -File `
                           -ErrorAction SilentlyContinue).Count -gt 0
        if ($hasManifest -or $hasFrames) { $candidates += $s }
        else { Write-Host "  (skipping $($s.Name): no manifest.json and no frames, so not an animation set)" -ForegroundColor DarkGray }
    }
    if ($candidates.Count -eq 0) {
        Write-Host "No animation sets under $Path" -ForegroundColor Red
        exit 1
    }
    foreach ($s in $candidates) { Test-AnimSet -Dir $s.FullName }
} else {
    Test-AnimSet -Dir (Resolve-Path -LiteralPath $Path).Path
}

Write-Host ''
if ($script:Errors -gt 0) {
    Write-Host "$($script:Errors) error(s), $($script:Warnings) warning(s) -- not valid yet." -ForegroundColor Red
    exit 1
}
if ($script:Warnings -gt 0) {
    Write-Host "Valid, with $($script:Warnings) warning(s)." -ForegroundColor Yellow
    exit 0
}
Write-Host 'Valid. This animation will play.' -ForegroundColor Green
exit 0
