#Requires -Version 5.1
<#
.SYNOPSIS
    Static verification for the Kindle dashboard project.

.DESCRIPTION
    Checks everything that can be checked without the device:

      * every shell script parses (bash -n, via Git Bash)
      * no CRLF line endings (they break /bin/sh on the Kindle)
      * menu.json is valid JSON and config.xml is valid XML
      * KUAL menu priorities are unique
      * no stray diff markers or malformed escapes from editing
      * both test suites pass
      * every config value referenced by the code actually exists

    Run:  powershell -File tools\verify.ps1
#>
[CmdletBinding()]
param(
    [string] $BashPath = 'C:\Program Files\Git\bin\bash.exe',
    [switch] $SkipTests
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$dev  = Join-Path $root 'device'

$script:Problems = 0
function Fail { param([string]$m) Write-Host "  FAIL $m" -ForegroundColor Red; $script:Problems++ }
function Pass { param([string]$m) Write-Host "  ok   $m" -ForegroundColor Green }
function Head { param([string]$m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }

$shells = @(
    'config.sh', 'dashboard.sh', 'install.sh', 'uninstall.sh',
    'lib\util.sh', 'lib\weather.sh', 'lib\render.sh', 'lib\anim.sh',
    'lib\update.sh', 'kual\bin\ctl.sh'
)

function To-BashPath {
    param([string]$Win)
    $full = (Resolve-Path -LiteralPath $Win).Path
    '/' + ($full.Substring(0,1).ToLower()) + ($full.Substring(2) -replace '\\','/')
}

Head 'shell syntax (bash -n)'
if (-not (Test-Path -LiteralPath $BashPath)) {
    Fail "Git Bash not found at $BashPath"
} else {
    foreach ($f in $shells) {
        $p = Join-Path $dev $f
        if (-not (Test-Path -LiteralPath $p)) { Fail "$f MISSING"; continue }
        $out = & $BashPath -n (To-BashPath $p) 2>&1
        if ($LASTEXITCODE -eq 0) { Pass $f } else { Fail "$f : $out" }
    }
}

Head 'line endings (CRLF breaks /bin/sh on the Kindle)'
foreach ($f in $shells) {
    $p = Join-Path $dev $f
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $bytes = [IO.File]::ReadAllBytes($p)
    $crlf = 0
    for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
        if ($bytes[$i] -eq 13 -and $bytes[$i+1] -eq 10) { $crlf++ }
    }
    if ($crlf -gt 0) { Fail "$f has $crlf CRLF pairs" } else { Pass "$f is LF-only" }
}

Head 'manifests'
$menuPath = Join-Path $dev 'kual\menu.json'
try {
    $menu = Get-Content -LiteralPath $menuPath -Raw | ConvertFrom-Json
    Pass 'menu.json is valid JSON'

    $tops = @($menu.items[0].items)
    $prios = $tops | ForEach-Object { $_.priority }
    if (($prios | Select-Object -Unique).Count -ne $prios.Count) {
        Fail "duplicate top-level priorities: $($prios -join ',')"
    } else { Pass "top-level priorities unique ($($prios.Count))" }

    $tools = @($tops | Where-Object { $_.name -eq 'Tools' })[0]
    if ($tools) {
        $tp = $tools.items | ForEach-Object { $_.priority }
        if (($tp | Select-Object -Unique).Count -ne $tp.Count) {
            Fail "duplicate Tools priorities: $($tp -join ',')"
        } else { Pass "Tools priorities unique ($($tp.Count))" }

        foreach ($it in $tools.items) {
            if (-not $it.params) { Fail "Tools entry '$($it.name)' has no params" }
        }
    }

    # A menu label must never name a specific animation set. The set is whatever
    # config.json says, so "(bird)" is wrong the moment it changes to anything
    # else -- and it was, which is how this got noticed.
    $labels = @($tops | ForEach-Object { $_.name })
    if ($tools) { $labels += @($tools.items | ForEach-Object { $_.name }) }
    $named = @($labels | Where-Object { $_ -match '\((bird|night|fish)\)' })
    if ($named.Count -gt 0) {
        Fail "menu label hardcodes an animation set: $($named -join ', ')"
    } else { Pass 'no menu label names a specific animation set' }

    # The same action listed twice at different levels is how this menu became
    # confusing: 'Update from GitHub' and 'Fetch artwork' were in both the top
    # level and Tools.
    $dupes = @($labels | Group-Object | Where-Object { $_.Count -gt 1 })
    if ($dupes.Count -gt 0) {
        Fail "menu has duplicate entries: $(($dupes | ForEach-Object { $_.Name }) -join ', ')"
    } else { Pass 'no duplicate menu entries' }

    # What the user actually sees first is the top level, so that is what "bloated"
    # means. Counting both levels together made a 6-item menu look like a 17-item
    # one, which is a false alarm.
    if ($tops.Count -gt 7) {
        Write-Host "  WARN the KUAL top level has $($tops.Count) entries; consider consolidating into Tools" -ForegroundColor Yellow
    } else {
        Pass "KUAL top level is concise ($($tops.Count) entries, plus Tools)"
    }
} catch {
    Fail "menu.json: $($_.Exception.Message)"
}

try {
    $null = [xml](Get-Content -LiteralPath (Join-Path $dev 'kual\config.xml') -Raw)
    Pass 'config.xml is valid XML'
} catch {
    Fail "config.xml: $($_.Exception.Message)"
}

Head 'edit artefacts'
# Scan text files only (a PNG will always match a byte pattern), and skip full-line
# comments so that notes *about* `$10` or a literal "+" are not reported.
$textFiles = @()
foreach ($dir in @($dev, (Join-Path $dev 'lib'), (Join-Path $dev 'kual'),
                   (Join-Path $dev 'kual\bin'), (Join-Path $root 'tools'),
                   (Join-Path $root 'preview'))) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $textFiles += @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -ne 'verify.ps1' -and
            $_.Extension -in @('.sh', '.json', '.xml', '.html', '.ps1', '.md')
        })
}

$badPatterns = @(
    @{ n = 'diff marker at line start'; re = '^\+[a-zA-Z]' }
    @{ n = 'merged echo lines';          re = 'echo\+echo' }
    @{ n = 'unquoted JSON key';          re = '^\s*exitmenu":' }
    @{ n = 'unbraced $1N positional';    re = '\$1[0-9]' }
)

$hits = 0
foreach ($file in $textFiles) {
    $lines = Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue
    # Tracks whether we are inside a single-quoted span that spans lines. awk
    # programs are written that way, and the shell does not expand positional
    # parameters inside single quotes -- so `w = $17 * 256` is an awk field, not
    # a bug. Reporting it as one made this check untrustworthy.
    $inQuote = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        if ($inQuote) {
            if ($line.IndexOf("'") -ge 0) { $inQuote = $false }
            continue
        }
        if ($line -match '^\s*#') { continue }        # comment line

        # Remove complete quoted spans, then truncate at any unmatched quote: the
        # rest of the line is inside a span continuing below.
        $test = [regex]::Replace($line, "'[^']*'", "''")
        $q = $test.IndexOf("'")
        if ($q -ge 0) {
            $test = $test.Substring(0, $q)
            $inQuote = $true
        }

        foreach ($bp in $badPatterns) {
            if ($test -match $bp.re) {
                Fail "$($file.Name):$($i+1) $($bp.n): $($line.Trim())"
                $hits++
            }
        }
    }
}
if ($hits -eq 0) { Pass 'no stray diff markers, bad quotes, or unbraced $1N' }

Head 'config keys referenced by code exist in config.sh'
$cfg = Get-Content -LiteralPath (Join-Path $dev 'config.sh') -Raw
$cfgKeys = [regex]::Matches($cfg, '(?m)^\s*([A-Z][A-Z0-9_]*)=') |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

# Code only -- config.sh must NOT be included here, or every key trivially "exists".
$code = ''
foreach ($f in $shells) {
    if ($f -eq 'config.sh') { continue }
    $code += (Get-Content -LiteralPath (Join-Path $dev $f) -Raw) + "`n"
}

# Resolved at runtime or overridable for tests, so not expected in config.sh.
$internalOk = @(
    'CLOCK_TOP_ACTUAL', 'FONT_CARD_RESOLVED', 'FONT_TEXT_RESOLVED',
    'INPUT_DEVICES_FILE', 'DRAW_NEXT_TOP', 'DRAW_BBOX_H', 'TOUCH_DEV_CACHE',
    'CURL_BIN', 'WGET_BIN', 'FBINK', 'POWER_PROP',
    'ANIM_DIR', 'ANIM_REST_FRAME', 'ANIM_READY',
    'ANIM_FRAME_GLOB', 'ANIM_MANIFEST', 'ANIM_MF_X', 'ANIM_MF_Y', 'ANIM_MF_DELAY',
    'FBINK_IMG', 'FBINK_IMG_UNUSABLE', 'FBINK_IMAGE_CANDIDATES', 'SLEEP_MS_CMD',
    'UPDATE_TMPDIR', 'ART_DEST', 'ART_DEST_DEFAULT',
    # Standard environment variables, not project settings.
    'TMPDIR', 'HOME', 'PATH'
)

$used = [regex]::Matches($code, '\$\{([A-Z][A-Z0-9_]*):-') |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$undeclared = $used | Where-Object { ($cfgKeys -notcontains $_) -and ($internalOk -notcontains $_) }
if ($undeclared) {
    foreach ($u in $undeclared) { Fail "used but not in config.sh: $u" }
} else {
    Pass "all $($used.Count) tunables resolve"
}

# Options documented in config.sh but never read by any code: honest-but-dead knobs.
$dead = @()
foreach ($k in $cfgKeys) {
    if ($code -notmatch [regex]::Escape($k)) { $dead += $k }
}
if ($dead) {
    Write-Host "  WARN declared in config.sh but never read: $($dead -join ', ')" -ForegroundColor Yellow
} else {
    Pass 'every config.sh option is read by the code'
}

# The frontlight default is a battery decision, not a cosmetic one: a lit light on
# a device we deliberately keep awake is the single biggest drain, and it defeats
# the whole point of an always-on e-ink display. Shipping -1 ("leave it as the user
# set it") means the light simply stays on for as long as the dashboard runs.
$flMatch = [regex]::Match($cfg, '(?m)^\s*FRONTLIGHT\s*=\s*(-?\d+)')
if (-not $flMatch.Success) {
    Fail 'FRONTLIGHT has no numeric default in config.sh'
} else {
    $fl = [int]$flMatch.Groups[1].Value
    if ($fl -eq 0) {
        Pass 'FRONTLIGHT defaults to 0 (frontlight off while showing a page)'
    } elseif ($fl -lt 0) {
        Fail "FRONTLIGHT defaults to $fl, so the frontlight stays lit while the dashboard runs"
    } else {
        Pass "FRONTLIGHT defaults to $fl (light deliberately on)"
    }
}

if (-not $SkipTests) {
    Head 'test suites'
    if (Test-Path -LiteralPath $BashPath) {
        foreach ($t in @('test-parse.sh', 'test-helpers.sh')) {
            $tp = Join-Path $root "tools\$t"
            if (-not (Test-Path -LiteralPath $tp)) { Fail "$t missing"; continue }
            $out = & $BashPath (To-BashPath $tp) 2>&1
            $line = $out | Select-String 'passed:'
            if ($LASTEXITCODE -eq 0) { Pass "$t -> $line" }
            else { Fail "$t -> $line"; $out | Select-Object -Last 20 | ForEach-Object { Write-Host "       $_" } }
        }
    }
}

Head 'artwork (animation format validation)'
# Delegates to check-artwork.ps1 rather than duplicating the format rules, so the
# spec has exactly one implementation. Runs it as a child process because it calls
# `exit`, which must not terminate this script.
$artDir  = Join-Path $root 'artwork'
$checker = Join-Path $root 'tools\check-artwork.ps1'
if (-not (Test-Path -LiteralPath $artDir)) {
    Write-Host '  (no artwork folder)' -ForegroundColor Yellow
} elseif (-not (Test-Path -LiteralPath $checker)) {
    Fail 'tools\check-artwork.ps1 is missing'
} else {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $checker $artDir -All 2>&1
    $rc = $LASTEXITCODE
    if ($rc -eq 0) {
        $out | Where-Object { $_ -match '^\s+(ok|info)\s' } | ForEach-Object { Write-Host "  $_" -ForegroundColor Green }
        Pass 'every animation set is valid'
    } else {
        $out | Where-Object { $_ -match '^\s+(ERROR|warn)\s' } | ForEach-Object { Fail $_.ToString().Trim() }
        if (-not ($out | Where-Object { $_ -match '^\s+(ERROR|warn)\s' })) {
            Fail "check-artwork.ps1 exited $rc with no detail"
        }
    }
}

Head 'mirrored tools (the artwork repo ships copies)'
# artwork/tools/ is mirrored so the published artwork repo is usable on its own.
# Drift here is silent: the published copy just quietly stops matching the one
# being developed, and a designer then runs a stale tool.
$mirror = Join-Path $artDir 'tools'
if (-not (Test-Path -LiteralPath $mirror)) {
    Write-Host '  (no mirrored tools)' -ForegroundColor Yellow
} else {
    foreach ($name in 'make-animation.ps1', 'check-artwork.ps1') {
        $src = Join-Path $root "tools\$name"
        $dst = Join-Path $mirror $name
        if (-not (Test-Path -LiteralPath $dst)) {
            Fail "mirrored copy missing: artwork\tools\$name"
            continue
        }
        $a = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
        $b = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash
        if ($a -eq $b) { Pass "in sync: $name" }
        else { Fail "DRIFTED: artwork\tools\$name differs from tools\$name (re-copy it)" }
    }
}

Head 'deployed payload (if the Kindle is mounted)'
$kindle = $null
foreach ($vol in (Get-Volume -ErrorAction SilentlyContinue)) {
    if (-not $vol.DriveLetter) { continue }
    $marker = "$($vol.DriveLetter):\system\version.txt"
    if (Test-Path -LiteralPath $marker) { $kindle = "$($vol.DriveLetter):"; break }
}
if (-not $kindle) {
    Write-Host '  (Kindle not mounted - skipping)' -ForegroundColor Yellow
} else {
    Pass "Kindle at $kindle"
    foreach ($f in $shells) {
        $src = Join-Path $dev $f
        $dst = Join-Path $kindle ("dashboard\" + $f)
        if (-not (Test-Path -LiteralPath $dst)) { Fail "not deployed: $f"; continue }
        $a = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
        $b = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash
        if ($a -eq $b) { Pass "deployed: $f" } else { Fail "STALE on device: $f" }
    }
    $ext = Join-Path $kindle 'extensions\dashboard'
    if (Test-Path -LiteralPath $ext) {
        $n = @(Get-ChildItem -LiteralPath $ext -Recurse -File).Count
        if ($n -ge 3) { Pass "KUAL extension present ($n files)" } else { Fail "KUAL extension incomplete ($n files)" }
    } else { Fail 'KUAL extension missing' }
}

Write-Host ''
if ($script:Problems -gt 0) {
    Write-Host "$($script:Problems) problem(s) found" -ForegroundColor Red
    exit 1
}
Write-Host 'ALL CLEAN' -ForegroundColor Green
exit 0
