#Requires -Version 5.1
<#
.SYNOPSIS
    Copy the Kindle Lockscreen Dashboard onto a USB-connected Kindle.

.DESCRIPTION
    Finds the Kindle's mass-storage volume, copies device/ to <kindle>\dashboard
    and device/kual to <kindle>\extensions\dashboard.

    An existing config.sh on the Kindle is preserved by default so your
    locations/units survive a re-deploy. Pass -Force to overwrite it.

.EXAMPLE
    .\deploy.ps1
    .\deploy.ps1 -DriveLetter F
    .\deploy.ps1 -Force
#>
[CmdletBinding()]
param(
    [string] $DriveLetter,
    [switch] $Force,
    [switch] $SkipKual
)

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$srcDevice = Join-Path $repoRoot 'device'

if (-not (Test-Path -LiteralPath $srcDevice)) {
    throw "Cannot find '$srcDevice'. Run this script from tools\ inside the project."
}

function Resolve-KindleVolume {
    param([string] $Requested)

    if ($Requested) {
        $candidate = $Requested.TrimEnd(':', '\') + ':'
        if (-not (Test-Path -LiteralPath (Join-Path $candidate 'system\version.txt'))) {
            throw "'$candidate' does not look like a Kindle (no system\version.txt)."
        }
        return $candidate
    }

    foreach ($vol in (Get-Volume -ErrorAction SilentlyContinue)) {
        if (-not $vol.DriveLetter) { continue }
        $root   = "$($vol.DriveLetter):"
        $marker = Join-Path $root 'system\version.txt'
        if (Test-Path -LiteralPath $marker) {
            $version = (Get-Content -LiteralPath $marker -ErrorAction SilentlyContinue |
                        Select-Object -First 1)
            Write-Host "Found Kindle on $root  ($version)"
            return $root
        }
    }
    throw "No USB-connected Kindle found. Plug it in and wait for it to mount as a drive."
}

$kindle = Resolve-KindleVolume -Requested $DriveLetter

# --- payload ---------------------------------------------------------------
$dst = Join-Path $kindle 'dashboard'
New-Item -ItemType Directory -Force -Path $dst | Out-Null

Get-ChildItem -LiteralPath $srcDevice -Force |
    Where-Object { $_.Name -ne 'config.sh' } |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $dst -Recurse -Force }

$cfgDest = Join-Path $dst 'config.sh'
if ($Force -or -not (Test-Path -LiteralPath $cfgDest)) {
    Copy-Item -LiteralPath (Join-Path $srcDevice 'config.sh') -Destination $cfgDest -Force
    Write-Host "wrote   $cfgDest"
} else {
    Write-Host "kept    $cfgDest (existing file, use -Force to overwrite)"
}

# --- KUAL extension -------------------------------------------------------
if (-not $SkipKual) {
    $extDst = Join-Path $kindle 'extensions\dashboard'
    New-Item -ItemType Directory -Force -Path $extDst | Out-Null

    # NOTE: copy item-by-item. Copy-Item -LiteralPath does NOT expand
    # wildcards, so "-LiteralPath ...\kual\*" silently copies nothing.
    $kualSrc = Join-Path $srcDevice 'kual'
    Get-ChildItem -LiteralPath $kualSrc -Force |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $extDst -Recurse -Force }

    $copied = @(Get-ChildItem -LiteralPath $extDst -Recurse -File -ErrorAction SilentlyContinue).Count
    if ($copied -eq 0) {
        throw "KUAL extension copy produced no files in $extDst -- the menu entry would not appear."
    }
    Write-Host "wrote   $extDst ($copied files)"
}

# --- artwork ----------------------------------------------------------------
# The repo folder is artwork/ but it installs as animations/ on the device, which
# is where ANIM_DIR in config.sh points.
$artSrc = Join-Path $repoRoot 'artwork'
if (Test-Path -LiteralPath $artSrc) {
    $animDst = Join-Path $dst 'animations'
    New-Item -ItemType Directory -Force -Path $animDst | Out-Null
    $sets = @(Get-ChildItem -LiteralPath $artSrc -Directory)
    foreach ($set in $sets) {
        $srcFrames = @(Get-ChildItem -LiteralPath $set.FullName -Filter 'frame_*.png' -File `
                           -ErrorAction SilentlyContinue).Count
        $hasManifest = Test-Path -LiteralPath (Join-Path $set.FullName 'manifest.json')
        $setDst = Join-Path $animDst $set.Name

        # A set is defined by having a manifest or frames. The artwork folder also
        # contains tools/ (the authoring scripts), which is not a set.
        if (-not $hasManifest -and $srcFrames -eq 0) {
            Write-Host "skipped $($set.Name): not an animation set (no manifest.json, no frames)"
            continue
        }
        # Mirror rather than merge. Without this, files from an older format linger
        # in the folder forever -- a renamed frame prefix, an old manifest.txt, a
        # contact-sheet.png -- and it becomes impossible to tell what is in use.
        # Guarded so a bad source can never wipe good art.
        if ($srcFrames -ge 2) {
            if (Test-Path -LiteralPath $setDst) { Remove-Item -LiteralPath $setDst -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $setDst | Out-Null

            # Copy item by item. Copy-Item -LiteralPath does NOT expand wildcards,
            # so "-LiteralPath ...\*" silently copies nothing -- which, combined
            # with the delete above, leaves the device with an EMPTY folder.
            Get-ChildItem -LiteralPath $set.FullName -Force |
                ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $setDst -Recurse -Force }

            # Verify, because the failure mode above is silent and destructive.
            $dstFrames = @(Get-ChildItem -LiteralPath $setDst -Filter 'frame_*.png' -File `
                               -ErrorAction SilentlyContinue).Count
            if ($dstFrames -ne $srcFrames) {
                throw "Copy of '$($set.Name)' produced $dstFrames of $srcFrames frames in $setDst. The device copy may now be incomplete -- re-run after fixing the source."
            }
            Write-Host "wrote   $setDst ($dstFrames frames, mirrored)"
        } else {
            Write-Host "SKIPPED $($set.Name): only $srcFrames frame(s) in the repo, leaving the device copy alone"
        }
    }
} else {
    Write-Host "note    no artwork/ folder, skipping frames"
}

Write-Host ""
Write-Host "Copied to $kindle" -ForegroundColor Green
Write-Host ""
Write-Host "Next, on the Kindle:"
Write-Host "  1. Safely eject / unmount the Kindle from Windows."
Write-Host "  2. Open KUAL from your library."
Write-Host "  3. Dashboard -> 'Install / refresh files', then 'Start (show clock + weather)'."
Write-Host ""
Write-Host "To revert:  Dashboard -> 'Uninstall (restore wallpaper)'."
