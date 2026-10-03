#Requires -Version 5.1
<#
.SYNOPSIS
    Report what a given fbink binary can actually do.

.DESCRIPTION
    fbink is compiled with optional feature flags and ships as a stripped static
    binary, so there is no --version output describing its build. Its printf
    format strings and help text are still in the binary though, so extracting
    printable strings is a reliable way to answer:

      * which waveform modes are compiled in (matters for animation speed)
      * which image decoders are present
      * whether raw pixel input is supported (skips PNG decode at runtime)
      * whether OpenType, image, dithering and input features are enabled

    Use this before trusting any documented capability.

.EXAMPLE
    powershell -File tools\fbink-capabilities.ps1
    powershell -File tools\fbink-capabilities.ps1 -Path F:\libkh\bin\fbink
#>
[CmdletBinding()]
param(
    [string] $Path
)

$ErrorActionPreference = 'Continue'

function Find-Kindle {
    foreach ($vol in (Get-Volume -ErrorAction SilentlyContinue)) {
        if (-not $vol.DriveLetter) { continue }
        $root = "$($vol.DriveLetter):"
        if (Test-Path -LiteralPath (Join-Path $root 'system\version.txt')) { return $root }
    }
    return $null
}

function Get-Strings {
    param([string]$File, [int]$MinLength = 2)
    # NOTE: MinLength must stay low. Waveform names are as short as two
    # characters (A2, DU) and a length filter of 4 silently drops exactly the
    # fast modes that matter most for animation.
    $bytes = [IO.File]::ReadAllBytes($File)
    $sb = New-Object System.Text.StringBuilder
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($b in $bytes) {
        if ($b -ge 32 -and $b -lt 127) { [void]$sb.Append([char]$b) }
        else {
            if ($sb.Length -ge $MinLength) { $out.Add($sb.ToString()) }
            [void]$sb.Clear()
        }
    }
    if ($sb.Length -ge $MinLength) { $out.Add($sb.ToString()) }
    return $out | Select-Object -Unique
}

# Candidates in the order a caller would want them.
$candidates = @()
if ($Path) {
    $candidates += $Path
} else {
    $kindle = Find-Kindle
    if ($kindle) {
        Write-Host "Kindle mounted at $kindle" -ForegroundColor Cyan
        $candidates += (Join-Path $kindle 'libkh\bin\fbink')
        $candidates += (Join-Path $kindle 'koreader\fbink')
        $candidates += (Join-Path $kindle 'extensions\MRInstaller\bin\KHF\fbink')
    } else {
        Write-Host 'Kindle not mounted and no -Path given.' -ForegroundColor Yellow
        exit 1
    }
}

$target = $null
foreach ($c in $candidates) {
    if (Test-Path -LiteralPath $c) { $target = (Resolve-Path -LiteralPath $c).Path; break }
}
if (-not $target) {
    Write-Host "No fbink binary found. Tried:" -ForegroundColor Red
    $candidates | ForEach-Object { Write-Host "  $_" }
    exit 1
}

Write-Host "Inspecting $target ($((Get-Item -LiteralPath $target).Length) bytes)" -ForegroundColor Cyan
$s = Get-Strings -File $target
$set = [System.Collections.Generic.HashSet[string]]::new([string[]]$s)
$text = ($s -join "`n")
Write-Host "extracted $($s.Count) unique strings`n"

# A name is "present" if it is its own NUL-terminated string (a table entry) or
# appears somewhere inside a longer help string. Both count as supported.
function Has-Exact { param([string]$n) return $set.Contains($n) }
function Has-Sub   { param([string]$n) return ($text.IndexOf($n, [StringComparison]::Ordinal) -ge 0) }

function Section { param([string]$t) Write-Host "=== $t ===" -ForegroundColor Green }

Section 'Waveform modes (fast ones matter for animation)'
# Base set is A2/DU/GL16/GC16/AUTO; families add the rest depending on model+FW.
$waves = 'A2', 'DU', 'DU4', 'DUNM', 'GC16', 'GC16HQ', 'GC16_FAST', 'GL16', 'GL16_FAST',
         'GL16_INV', 'GC4', 'GL4', 'AUTO', 'REAGL', 'REAGLD', 'GCK16', 'GLKW16',
         'GCC16', 'GLRC16', 'GCCK16', 'GLRCK16', 'GS16'
$foundWave = @($waves | Where-Object { (Has-Exact $_) -or (Has-Sub $_) })
if ($foundWave) { $foundWave | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  (none matched)' }

Section 'Image decoders'
# These names appear only inside a longer "Supported image formats: ..." help
# string, so substring matching is required here.
$fmts = 'PNG', 'JPEG', 'TGA', 'BMP', 'GIF', 'PNM', 'PBM', 'PGM', 'PPM'
$foundFmt = @($fmts | Where-Object { Has-Sub $_ })
if ($foundFmt) { $foundFmt | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  (none matched)' }

Section 'Raw pixel / bit-depth support (fastest path for animation)'
foreach ($k in 'raw', 'Gray8', 'Gray16', 'RGB32', 'RGB24', 'MONO', 'dither',
                'PASSTHROUGH', 'ORDERED', 'FLOYD', 'ATKINSON', 'flatten', 'alpha') {
    $mark = if ((Has-Exact $k) -or (Has-Sub $k)) { 'yes' } else { 'no ' }
    Write-Host "  $mark  $k"
}

Section 'Feature flags referenced in help text'
foreach ($k in 'truetype', 'OpenType', '-g, --image', '-k, --cls', '-s, --refresh',
                '--norefresh', '--daemon', '-K, --animate', 'halign', 'valign',
                'notrunc', 'compute', 'UNIFONT', '-E, --coordinates', '-b, --norefresh') {
    $mark = if ((Has-Exact $k) -or (Has-Sub $k)) { 'yes' } else { 'no ' }
    Write-Host "  $mark  $k"
}

Section 'Animate option details (MTK screen transition, not frame animation)'
$s | Where-Object { $_ -match 'direction=|steps=|-K, --animate' } |
    Select-Object -First 6 | ForEach-Object { Write-Host "  $_" }

Section 'Eval output keys (screen state)'
$hits = @($s | Where-Object { $_ -match 'screenWidth=.*screenHeight=' } | Select-Object -First 1)
if ($hits) { $hits[0].Split(';') | Where-Object { $_ -match 'screenWidth|screenHeight|viewWidth|viewHeight|DPI|BPP|device' } | ForEach-Object { Write-Host "  $_" } }

Section 'Coordinates output format (-E)'
$s | Where-Object { $_ -match 'next_top=|lastRect_Top=' } | ForEach-Object { Write-Host "  $_" }
