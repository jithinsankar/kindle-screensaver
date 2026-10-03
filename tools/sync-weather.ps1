#Requires -Version 5.1
<#
.SYNOPSIS
    Refresh the vendored copy of the weather module.

.DESCRIPTION
    weather/ is its OWN git repository, published separately
    (kindle-weather-dashboard), because it has nothing to do with e-ink, clocks
    or layout -- it is HTTP in, one line of text out.

    This repo still has to ship a copy of it at device/lib/weather.sh, because
    that file is part of the device payload: the Kindle updater copies device/
    verbatim and does not fetch a second repository at runtime. So the module is
    VENDORED, and this script is what keeps the copy honest.

    Run it after changing the module, then commit the result. verify.ps1 fails
    when the two drift apart, which is the failure that actually hurts: the
    published library and the code running on the device quietly stop matching.

.EXAMPLE
    .\sync-weather.ps1
    .\sync-weather.ps1 -Check
#>
[CmdletBinding()]
param(
    # Compare instead of copying. Exits 1 when the vendored copy is stale.
    [switch] $Check
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$src = Join-Path $repoRoot 'weather\weather.sh'
$dst = Join-Path $repoRoot 'device\lib\weather.sh'
$rel = 'device\lib\weather.sh'

if (-not (Test-Path -LiteralPath $src)) {
    throw "Cannot find '$src'. It is the source of truth, so there is nothing to vendor. Clone kindle-weather-dashboard into weather\ first."
}

# Normalise to LF on the way in. A CRLF shell script is fatal on the device: the
# kernel looks for an interpreter literally named "/bin/sh`r" and every script
# then fails with a confusing "not found" while looking fine in an editor.
$newText = ([System.IO.File]::ReadAllText($src)) -replace "`r`n", "`n"

if ($Check) {
    if (-not (Test-Path -LiteralPath $dst)) {
        Write-Host "MISSING  $rel (run tools\sync-weather.ps1)"
        exit 1
    }
    $curText = ([System.IO.File]::ReadAllText($dst)) -replace "`r`n", "`n"
    if ($curText -ne $newText) {
        Write-Host "DRIFTED  $rel differs from weather\weather.sh (run tools\sync-weather.ps1)"
        exit 1
    }
    Write-Host "in sync  $rel"
    exit 0
}

[System.IO.File]::WriteAllText($dst, $newText, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "wrote   $dst"
Write-Host "        (vendored from weather\weather.sh -- now run tools\verify.ps1)"
