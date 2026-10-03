#Requires -Version 5.1
<#
.SYNOPSIS
    Convert a GIF or a folder of images into Kindle-optimised animation frames.

.DESCRIPTION
    fbink has no animation player: it draws one static image per invocation. An
    e-ink animation is therefore a numbered sequence of frames replayed by a
    shell loop, and this script produces exactly that.

    Frames are written as 8-bit greyscale PNG (values restricted to the levels we
    choose, so the file is tiny) because PNG is certain to be supported by fbink
    on every build. Content is thresholded to pure black and white by default,
    because the fast e-ink waveforms (A2/DU) are effectively 1-bit: grey pixels
    get dithered by the panel and ghost badly. Design for a linocut, not a photo.

    Antialiasing is handled by rendering/upscaling first and thresholding after,
    which keeps edges smooth instead of ragged.

.EXAMPLE
    # Procedural demo, so the pipeline can be exercised without any assets
    powershell -File tools\make-animation.ps1 -Demo night -Width 420 -Height 320 -OutDir artwork\night

.EXAMPLE
    # The other built-in scene: a bird flapping on a branch
    powershell -File tools\make-animation.ps1 -Demo bird -Width 420 -Height 320 -OutDir artwork\bird

.EXAMPLE
    # From an animated GIF, cropped out of a 600x800 frame
    powershell -File tools\make-animation.ps1 -Source bird.gif -Crop 180,420,200,150 -OutDir artwork\bird

.EXAMPLE
    # From a folder of hand-drawn frames, 16 grey levels with ordered dithering
    powershell -File tools\make-animation.ps1 -Source frames\ -Mode grey16 -OutDir artwork\bird
#>
[CmdletBinding()]
param(
    # An animated .gif, or a folder of images. Not used with -Demo.
    [string] $Source,

    # Built-in procedural source, so the pipeline works with no assets at all.
    #   bird  = a bird on a branch, flapping
    #   night = a moonlit scene: crescent moon, drifting clouds, layered hills,
    #           a torii gate and falling blossom
    [string] $Demo,
    [switch] $DemoBird,
    [int] $DemoFrames = 8,

    # Where to write the frames. A manifest.json and optional preview.png are
    # written alongside them. The repo folder is artwork/; it installs as
    # animations/ on the device. The folder name becomes the animation's name.
    [string] $OutDir = 'artwork\bird',

    # Target size. 0 means "keep whatever the crop/source gives".
    [int] $Width = 0,
    [int] $Height = 0,

    # Crop the source before scaling, as "x,y,w,h".
    [string] $Crop,

    # bw     = pure black/white, best for the fast A2/DU waveforms
    # grey16 = 16 levels with ordered dithering, nicer gradients, slower + ghostier
    [ValidateSet('bw', 'grey16')]
    [string] $Mode = 'bw',

    # Luminance cut for -Mode bw, 0-255. Raise to keep more white, lower to keep more black.
    [int] $Threshold = 128,

    # Swap black and white, for art designed light-on-dark.
    [switch] $Invert,

    # Take every Nth source frame. Use this to slow a GIF down to e-ink speeds.
    [int] $EveryNth = 1,

    # Cap the number of output frames. 0 = no cap.
    [int] $MaxFrames = 0,

    # Where the frame sits on the 600x800 panel. These are written into
    # manifest.json. Defaults match a 420x320 frame centred-ish on the panel.
    # For true full-screen frames, pass -Width 600 -Height 800 -DrawX 0 -DrawY 0.
    [int] $DrawX = 90,
    [int] $DrawY = 240,

    # Frame filename prefix. Keep the default so the player can find them.
    [string] $Prefix = 'frame_',

    # Also write preview.png: every frame side by side, so you can check the cycle
    # at a glance without opening them one at a time.
    [switch] $Preview
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
function Get-Luma {
    # Perceptual luminance, matching what GDI+ would use for a grey conversion.
    param([int]$R, [int]$G, [int]$B)
    return (0.299 * $R) + (0.587 * $G) + (0.114 * $B)
}

# 8x8 ordered (Bayer) matrix, scaled to 0..63
$Bayer8 = @(
    @( 0, 32,  8, 40,  2, 34, 10, 42),
    @(48, 16, 56, 24, 50, 18, 58, 26),
    @(12, 44,  4, 36, 14, 46,  6, 38),
    @(60, 28, 52, 20, 62, 30, 54, 22),
    @( 3, 35, 11, 43,  1, 33,  9, 41),
    @(51, 19, 59, 27, 49, 17, 57, 25),
    @(15, 47,  7, 39, 13, 45,  5, 37),
    @(63, 31, 55, 23, 61, 29, 53, 21)
)

function New-GreyIndexedBitmap {
    # 8bpp indexed with a 256-entry grey palette. Writing an indexed bitmap is
    # more predictable than asking GDI+ to emit 1bpp, whose row stride and
    # palette ordering are easy to get subtly wrong.
    param([int]$W, [int]$H)
    $bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
    $pal = $bmp.Palette
    for ($i = 0; $i -lt 256; $i++) {
        $pal.Entries[$i] = [System.Drawing.Color]::FromArgb(255, $i, $i, $i)
    }
    $bmp.Palette = $pal
    return $bmp
}

function Convert-ToGreyIndexed {
    # Threshold or ordered-dither a 32bpp ARGB bitmap into an 8bpp grey bitmap.
    param(
        [System.Drawing.Bitmap] $Src,
        [string] $ModeName,
        [int] $Cut,
        [bool] $Flip
    )
    $w = $Src.Width
    $h = $Src.Height
    $dst = New-GreyIndexedBitmap -W $w -H $h

    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $srcData = $Src.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                             [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $dstData = $dst.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
                             [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
    try {
        $srcStride = $srcData.Stride
        $dstStride = $dstData.Stride
        $srcBytes = New-Object byte[] ($srcStride * $h)
        [System.Runtime.InteropServices.Marshal]::Copy($srcData.Scan0, $srcBytes, 0, $srcBytes.Length)
        $dstBytes = New-Object byte[] ($dstStride * $h)

        for ($y = 0; $y -lt $h; $y++) {
            $srow = $y * $srcStride
            $drow = $y * $dstStride
            for ($x = 0; $x -lt $w; $x++) {
                $o = $srow + ($x * 4)
                # BGRA byte order in memory
                $luma = Get-Luma -R $srcBytes[$o + 2] -G $srcBytes[$o + 1] -B $srcBytes[$o]
                if ($Flip) { $luma = 255 - $luma }

                if ($ModeName -eq 'bw') {
                    $v = if ($luma -ge $Cut) { 255 } else { 0 }
                } else {
                    # 16 levels with an 8x8 ordered dither so flat areas do not band
                    $levels = 15
                    $scaled = ($luma / 255.0) * $levels
                    $thresh = $Bayer8[$y % 8][$x % 8] / 64.0
                    $q = [math]::Floor($scaled)
                    if (($scaled - $q) -gt $thresh) { $q = $q + 1 }
                    if ($q -lt 0) { $q = 0 }
                    if ($q -gt $levels) { $q = $levels }
                    $v = [int][math]::Round(($q / $levels) * 255)
                }
                $dstBytes[$drow + $x] = [byte]$v
            }
            # 8bpp rows are padded to a 4-byte boundary; GDI+ already zeroed the
            # buffer, so the padding needs nothing further.
        }
        [System.Runtime.InteropServices.Marshal]::Copy($dstBytes, 0, $dstData.Scan0, $dstBytes.Length)
    }
    finally {
        $Src.UnlockBits($srcData)
        $dst.UnlockBits($dstData)
    }
    return $dst
}

function Resize-Bitmap {
    param([System.Drawing.Bitmap]$Src, [int]$W, [int]$H)
    $dst = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    try {
        # HighQualityBicubic here is what gives a smooth edge after thresholding.
        # NearestNeighbor would produce ragged, aliased outlines.
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.Clear([System.Drawing.Color]::White)
        $g.DrawImage($Src, 0, 0, $W, $H)
    }
    finally { $g.Dispose() }
    return $dst
}

# ---------------------------------------------------------------------------
# procedural demo source: a bird on a branch, flapping
# ---------------------------------------------------------------------------
function Draw-BirdFrame {
    param([int]$Frame, [int]$Total, [int]$W, [int]$H)

    # Supersample, then let the main pipeline downscale and threshold. Drawing
    # antialiased shapes straight into the target size gives ragged 1-bit edges.
    $ss = 4
    $big = New-Object System.Drawing.Bitmap(($W * $ss), ($H * $ss), [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($big)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::White)
        $black = [System.Drawing.Brushes]::Black
        $white = [System.Drawing.Brushes]::White

        $sw = $W * $ss
        $sh = $H * $ss

        # The bird's proportions are authored against a 200px-wide canvas, so
        # scale them to whatever was asked for. Without this a large fullscreen
        # canvas would contain a tiny bird. $ss handles supersampling only.
        $u = $W / 200.0
        $k = $ss * $u

        # --- branch -------------------------------------------------------
        $branchY = [int]($sh * 0.78)
        $branchPen = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, (3.2 * $k))
        $g.DrawLine($branchPen, (-5 * $k), $branchY, ($sw * 1.02), ($branchY - 6 * $k))
        # a couple of twigs so it reads as a tree
        $g.DrawLine($branchPen, ($sw * 0.70), $branchY, ($sw * 0.82), ($branchY + 16 * $k))
        $g.DrawLine($branchPen, ($sw * 0.86), ($branchY - 3 * $k), ($sw * 0.96), ($branchY + 13 * $k))

        # --- bird geometry -----------------------------------------------
        $bodyX = $sw * 0.42
        $bodyY = $branchY - (17 * $k)
        $bodyW = 40 * $k
        $bodyH = 27 * $k

        # --- wings --------------------------------------------------------
        # Near wing sweeps through a wide arc; the far wing lags so the flap does
        # not read as one rigid plate. Wings are long and thin and the shoulder
        # sits above the body, otherwise the wing merges into the body silhouette
        # and the motion is invisible at 1-bit.
        # Wing arc is biased upward: a symmetric arc sweeps the tip below the
        # branch, which reads as the bird falling off rather than flapping.
        # This sweeps roughly -48 degrees (up) to +12 (down).
        $phase = (2 * [math]::PI * $Frame) / $Total
        $nearAngle = -18 - (30 * [math]::Sin($phase))
        $farAngle = -18 - (30 * [math]::Sin($phase - 0.55))

        $shoulderX = $bodyX + 4 * $k
        $shoulderY = $bodyY - 9 * $k

        # far wing first, so the body overlaps it
        $st = $g.Save()
        $g.TranslateTransform($shoulderX, $shoulderY)
        $g.RotateTransform([float]$farAngle)
        $g.FillEllipse($black, (-8 * $k), (-9 * $k), (54 * $k), (11 * $k))
        $g.Restore($st)

        # --- tail and body ------------------------------------------------
        $tail = @(
            (New-Object System.Drawing.PointF(($bodyX - $bodyW * 0.44), $bodyY)),
            (New-Object System.Drawing.PointF(($bodyX - $bodyW * 1.05), ($bodyY + 12 * $k))),
            (New-Object System.Drawing.PointF(($bodyX - $bodyW * 0.40), ($bodyY + 12 * $k)))
        )
        $g.FillPolygon($black, $tail)

        $g.FillEllipse($black, ($bodyX - $bodyW / 2), ($bodyY - $bodyH / 2), $bodyW, $bodyH)

        # --- head and beak ------------------------------------------------
        $headR = 11 * $k
        $headX = $bodyX - ($bodyW * 0.40)
        $headY = $bodyY - ($bodyH * 0.30) - $headR
        $g.FillEllipse($black, ($headX - $headR), ($headY - $headR), ($headR * 2), ($headR * 2))

        $beak = @(
            (New-Object System.Drawing.PointF(($headX - $headR * 0.75), ($headY - $headR * 0.10))),
            (New-Object System.Drawing.PointF(($headX - $headR * 2.10), ($headY + $headR * 0.16))),
            (New-Object System.Drawing.PointF(($headX - $headR * 0.75), ($headY + $headR * 0.52)))
        )
        $g.FillPolygon($black, $beak)

        # eye as a hole, so it reads at 1-bit
        $g.FillEllipse($white, ($headX - $headR * 0.42), ($headY - $headR * 0.34), (2.6 * $k), (2.6 * $k))

        # --- near wing on top --------------------------------------------
        $st = $g.Save()
        $g.TranslateTransform($shoulderX, $shoulderY)
        $g.RotateTransform([float]$nearAngle)
        $g.FillEllipse($black, (-6 * $k), (-6 * $k), (58 * $k), (12 * $k))
        $g.Restore($st)

        # --- legs ---------------------------------------------------------
        $legPen = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, (2.0 * $k))
        $g.DrawLine($legPen, ($bodyX - 4 * $k), ($bodyY + $bodyH * 0.40), ($bodyX - 5 * $k), $branchY)
        $g.DrawLine($legPen, ($bodyX + 6 * $k), ($bodyY + $bodyH * 0.38), ($bodyX + 5 * $k), $branchY)
    }
    finally { $g.Dispose() }
    return $big
}

# ---------------------------------------------------------------------------
# gather source frames
# ---------------------------------------------------------------------------
$frameImages = New-Object System.Collections.Generic.List[object]
$sourceKind = ''
$delayMs = 120
# ---------------------------------------------------------------------------
# procedural demo source: a moonlit night scene
#
# Black ink on white paper, which is literally what 1-bit e-ink is, so everything
# is a silhouette or a bold outline -- the only thing the fast A2/DU waveforms can
# render without dithering and ghosting. The composition follows the conventions
# that make this kind of image read well:
#   * bold, flat shapes rather than shading
#   * an asymmetrical layout, with elements cropped by the frame edge
#   * the tripartite depth trick: a large form in the foreground, a smaller one
#     behind it, and a smaller one behind that
#
# Two things move, and both loop seamlessly. The clouds drift sideways and the
# blossom falls, each on a tile period of HALF the canvas, so the pattern repeats
# twice across the frame and after the last frame it is exactly back where it
# started -- no jump at the loop point.
#
# The composition is original. The motifs -- crescent moon, stylised cloud bands,
# layered hills, a torii gate, falling blossom -- are traditional and belong to
# nobody; no existing artwork is copied.
# ---------------------------------------------------------------------------

function Draw-Blossom {
    param($G, $Brush, [double]$X, [double]$Y, [double]$R)
    # Five petals around a centre, which reads as a blossom even at ~10px.
    foreach ($a in @(0, 72, 144, 216, 288)) {
        $rad = $a * [math]::PI / 180.0
        $px = $X + ([math]::Cos($rad) * $R * 0.60)
        $py = $Y + ([math]::Sin($rad) * $R * 0.60)
        $G.FillEllipse($Brush, ($px - $R * 0.42), ($py - $R * 0.42), ($R * 0.84), ($R * 0.84))
    }
    $G.FillEllipse($Brush, ($X - $R * 0.20), ($Y - $R * 0.20), ($R * 0.40), ($R * 0.40))
}

function Draw-NightFrame {
    param([int]$Frame, [int]$Total, [int]$W, [int]$H)

    $ss = 4
    $big = New-Object System.Drawing.Bitmap(($W * $ss), ($H * $ss), [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($big)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::White)
        $black = [System.Drawing.Brushes]::Black
        $white = [System.Drawing.Brushes]::White

        $sw = $W * $ss
        $sh = $H * $ss
        $k  = $ss * ($W / 420.0)      # proportions are authored against a 420px canvas
        $ph = (2 * [math]::PI * $Frame) / $Total

        # --- stars: fixed positions, so they do not crawl between frames ------
        $stars = @(
            @(0.06,0.07),@(0.13,0.17),@(0.22,0.05),@(0.31,0.14),@(0.39,0.04),
            @(0.48,0.11),@(0.57,0.06),@(0.66,0.16),@(0.75,0.05),@(0.84,0.13),
            @(0.92,0.08),@(0.97,0.20),@(0.10,0.28),@(0.27,0.24),@(0.63,0.26),
            @(0.89,0.29),@(0.18,0.36),@(0.72,0.34),@(0.45,0.20),@(0.54,0.29)
        )
        $si = 0
        foreach ($s in $stars) {
            $si++
            # A 4-point sparkle, not a dot: dots are indistinguishable from the
            # falling blossom and the sky just reads as speckled noise.
            $sx = $s[0] * $sw
            $sy = $s[1] * $sh
            # Every third star twinkles. Two cycles per loop, so it closes exactly.
            if (($si % 3) -eq 0) {
                if ([math]::Sin(2 * $ph + $si * 1.7) -lt 0.15) { continue }
            }
            $r  = 2.6 * $k
            $w  = 0.9 * $k
            $g.FillRectangle($black, [float]($sx - $w / 2), [float]($sy - $r), [float]$w, [float](2 * $r))
            $g.FillRectangle($black, [float]($sx - $r), [float]($sy - $w / 2), [float](2 * $r), [float]$w)
        }

        # --- distant birds: the classic three-stroke motif ---------------------
        # Each is two arcs meeting at a shallow angle, which is all a bird needs
        # to be at this size. Static, and small, so they read as far away.
        $birdPen = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, (1.1 * $k))
        $birdPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $birdPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
        foreach ($bd in @(@(0.455, 0.175, 0.030), @(0.512, 0.135, 0.024), @(0.560, 0.200, 0.019))) {
            $bx = $bd[0] * $sw
            $by = $bd[1] * $sh
            $bw = $bd[2] * $sw
            $bh = $bw * 0.42
            $g.DrawBezier($birdPen,
                [System.Drawing.PointF]::new([float]($bx - $bw), [float]($by + $bh)),
                [System.Drawing.PointF]::new([float]($bx - $bw * 0.5), [float]($by - $bh)),
                [System.Drawing.PointF]::new([float]($bx - $bw * 0.1), [float]($by - $bh)),
                [System.Drawing.PointF]::new([float]$bx, [float]$by))
            $g.DrawBezier($birdPen,
                [System.Drawing.PointF]::new([float]$bx, [float]$by),
                [System.Drawing.PointF]::new([float]($bx + $bw * 0.1), [float]($by - $bh)),
                [System.Drawing.PointF]::new([float]($bx + $bw * 0.5), [float]($by - $bh)),
                [System.Drawing.PointF]::new([float]($bx + $bw), [float]($by + $bh)))
        }

        # --- moon: a crescent, which is unmistakable where a disc would read as
        # a sun. Carved by overlapping a white disc on a black one.
        $mr = 0.090 * $sw
        $mx = 0.775 * $sw
        $my = 0.195 * $sh
        $g.FillEllipse($black, ($mx - $mr), ($my - $mr), (2 * $mr), (2 * $mr))
        $g.FillEllipse($white, ($mx - $mr + 0.52 * $mr), ($my - $mr - 0.36 * $mr), (2 * $mr), (2 * $mr))
        # NO halo ring here. An earlier version drew one and it crossed the clouds
        # and the crescent like a stray circle, which looked like a mistake.

        # --- clouds drifting sideways -----------------------------------------
        # (No clouds. Three attempts -- solid capsules, layered capsules and
        # outlined scalloped bands -- all read as the wrong thing: black tablets,
        # then stacked pancakes, then caterpillar segments. Cloud shapes are hard
        # to get right procedurally at this size, and a wrong cloud is much worse
        # than no cloud. A human artist can add them with the same pipeline.)

        # --- distant ridge: drawn BEFORE the near hill, so the near hill covers
        # its base and only the ridge line shows above. That is what makes it read
        # as further away rather than as a stray line floating in the sky.
        $ridge = New-Object System.Drawing.Drawing2D.GraphicsPath
        $r0 = 0.700 * $sh
        $ridge.AddBezier(0, ($r0 + 0.02 * $sh), (0.22 * $sw), ($r0 - 0.13 * $sh), (0.38 * $sw), ($r0 - 0.13 * $sh), (0.53 * $sw), ($r0 + 0.01 * $sh))
        $ridge.AddBezier((0.53 * $sw), ($r0 + 0.01 * $sh), (0.68 * $sw), ($r0 + 0.15 * $sh), (0.84 * $sw), ($r0 - 0.11 * $sh), $sw, ($r0 + 0.02 * $sh))
        $ridgePen = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, (1.5 * $k))
        $g.DrawPath($ridgePen, $ridge)
        $ridge.Dispose()

        # --- near hill, sampled from a function rather than a hand-drawn path.
        # A hard-coded torii position against a bezier put the gate either floating
        # in the sky or buried in the hill; with a function the gate can be planted
        # EXACTLY on the surface.
        $hillY = {
            param([double]$t)
            0.815 - 0.075 * [math]::Sin([math]::PI * $t) - 0.020 * [math]::Sin(2 * [math]::PI * $t + 0.6)
        }
        $hp = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
        for ($i = 0; $i -le 60; $i++) {
            $t = $i / 60.0
            $hp.Add([System.Drawing.PointF]::new([float]($t * $sw), [float]((& $hillY $t) * $sh)))
        }
        $hp.Add([System.Drawing.PointF]::new([float]$sw, [float]$sh))
        $hp.Add([System.Drawing.PointF]::new([float]0, [float]$sh))
        $g.FillPolygon($black, $hp.ToArray())

        # --- torii gate. Planted on the hill surface via the same function, and
        # rising clear of the ridge behind it so the whole gate reads against the
        # sky. The first attempt drew it on the solid hill, where black-on-black
        # made it invisible.
        $tx = 0.295
        $baseY = (& $hillY $tx) * $sh
        $topY  = 0.500 * $sh
        $pw    = 0.019 * $sw
        $off   = 0.072 * $sw
        $lean  = 0.011 * $sw
        $tcx   = $tx * $sw
        foreach ($side in @(-1, 1)) {
            $bx = $tcx + ($side * $off)
            $g.FillPolygon($black, @(
                [System.Drawing.PointF]::new([float]($bx - $pw / 2 + $side * $lean), [float]$topY),
                [System.Drawing.PointF]::new([float]($bx + $pw / 2 + $side * $lean), [float]$topY),
                [System.Drawing.PointF]::new([float]($bx + $pw / 2), [float]$baseY),
                [System.Drawing.PointF]::new([float]($bx - $pw / 2), [float]$baseY)
            ))
        }
        # kasagi: the top lintel, swept up at the ends
        $kw = 0.145 * $sw
        $kt = 0.014 * $sh
        $kx1 = $tcx - $kw
        $kx2 = $tcx + $kw
        $kEnd = $topY - 0.018 * $sh
        $kMid = $topY + 0.006 * $sh
        $g.FillPolygon($black, @(
            [System.Drawing.PointF]::new([float]$kx1,                 [float]$kEnd),
            [System.Drawing.PointF]::new([float]($kx1 + 0.09 * $sw), [float]$kMid),
            [System.Drawing.PointF]::new([float]($kx2 - 0.09 * $sw), [float]$kMid),
            [System.Drawing.PointF]::new([float]$kx2,                 [float]$kEnd),
            [System.Drawing.PointF]::new([float]$kx2,                 [float]($kEnd + $kt)),
            [System.Drawing.PointF]::new([float]($kx2 - 0.09 * $sw), [float]($kMid + $kt)),
            [System.Drawing.PointF]::new([float]($kx1 + 0.09 * $sw), [float]($kMid + $kt)),
            [System.Drawing.PointF]::new([float]$kx1,                 [float]($kEnd + $kt))
        ))
        # nuki: the lower beam, and the short strut between the two
        $nw = 0.098 * $sw
        $nh = 0.010 * $sh
        $ny = $topY + 0.070 * $sh
        $g.FillRectangle($black, ($tcx - $nw), $ny, (2 * $nw), $nh)
        $g.FillRectangle($black, ($tcx - 0.007 * $sw), ($kEnd + $kt), (0.014 * $sw), ($ny - ($kEnd + $kt)))

        # --- falling blossom --------------------------------------------------
        $pPeriod = 0.5
        $pFall   = $pPeriod / $Total
        $petals = @(
            @(0.10, 0.00), @(0.24, 0.34), @(0.37, 0.68), @(0.52, 0.16),
            @(0.65, 0.52), @(0.79, 0.82), @(0.92, 0.44)
        )
        foreach ($p in $petals) {
            $px = $p[0] * $sw + ([math]::Sin($ph + $p[1] * 6.283) * 0.016 * $sw)
            $py = (($p[1] + $Frame * $pFall) % $pPeriod) * $sh
            foreach ($off in @(-1.0, 0.0, 1.0)) {
                $yy = $py + ($off * $pPeriod * $sh)
                if ($yy -lt (-0.05 * $sh) -or $yy -gt (1.05 * $sh)) { continue }
                $st = $g.Save()
                $g.TranslateTransform([float]$px, [float]$yy)
                $g.RotateTransform([float](28 * [math]::Sin($ph + $p[1] * 3.0)))
                # A single small ellipse. The two-lobe version read as a peanut or
                # a blob at this size, and made the sky look like debris.
                $pr = 0.012 * $sw
                $g.FillEllipse($black, [float](-$pr), [float](-$pr * 0.55), [float](2 * $pr), [float]($pr * 1.10))
                $g.Restore($st)
            }
        }

        # (No foreground branch: an earlier version had one entering the top-left,
        # and it collided with the clouds and read as a squiggle with blobs on it.
        # The petals and the solid hill already supply the near plane.)
    }
    finally { $g.Dispose() }
    return $big
}

$tempSourceDir = $null
$scratch = New-Object System.Collections.Generic.List[System.IDisposable]

if ($DemoBird) { $Demo = 'bird' }
if ($Demo) {
    switch ($Demo) {
        'bird'  { $dw = 200; $dh = 150 }
        'night' { $dw = 420; $dh = 320 }
        default { throw "unknown -Demo '$Demo' -- use 'bird' or 'night'" }
    }
    if ($Width  -gt 0) { $dw = $Width }
    if ($Height -gt 0) { $dh = $Height }
    $sourceKind = "procedural demo '$Demo' ($DemoFrames frames)"
    $Width = $dw
    $Height = $dh
    for ($i = 0; $i -lt $DemoFrames; $i++) {
        switch ($Demo) {
            'bird'  { $bmp = Draw-BirdFrame  -Frame $i -Total $DemoFrames -W $dw -H $dh }
            'night' { $bmp = Draw-NightFrame -Frame $i -Total $DemoFrames -W $dw -H $dh }
        }
        $frameImages.Add($bmp)
    }
}
elseif (-not $Source) {
    throw "Give -Source <gif|folder> or -Demo <bird|night>."
}
elseif (Test-Path -LiteralPath $Source -PathType Container) {
    $files = @(Get-ChildItem -LiteralPath $Source -File |
        Where-Object { $_.Extension -in @('.png', '.gif', '.jpg', '.jpeg', '.bmp', '.tga') } |
        Sort-Object Name)
    if (-not $files) { throw "No images found in $Source" }
    $sourceKind = "folder ($($files.Count) files)"
    foreach ($f in $files) { $frameImages.Add([System.Drawing.Bitmap]::FromFile($f.FullName)) }
}
else {
    if (-not (Test-Path -LiteralPath $Source)) { throw "Source not found: $Source" }
    $img = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $Source).Path)
    $dim = New-Object System.Drawing.Imaging.FrameDimension($img.FrameDimensionsList[0])
    $count = $img.GetFrameCount($dim)
    $sourceKind = "image ($count frame(s))"

    # GIF frame delays, in hundredths of a second
    $perFrame = @()
    try {
        $prop = $img.GetPropertyItem(0x5100)
        for ($i = 0; $i -lt $count; $i++) {
            $perFrame += [BitConverter]::ToInt32($prop.Value, $i * 4) * 10
        }
        if ($perFrame.Count -gt 0) { $delayMs = $perFrame[0] }
    } catch { }

    for ($i = 0; $i -lt $count; $i++) {
        $img.SelectActiveFrame($dim, $i) | Out-Null
        $frameImages.Add((New-Object System.Drawing.Bitmap($img)))
    }
    $img.Dispose()
}

# ---------------------------------------------------------------------------
# crop / scale / quantise
# ---------------------------------------------------------------------------
$cropRect = $null
if ($Crop) {
    $parts = $Crop -split ','
    if ($parts.Count -ne 4) { throw "-Crop must be x,y,w,h" }
    $cropRect = New-Object System.Drawing.Rectangle(
        [int]$parts[0], [int]$parts[1], [int]$parts[2], [int]$parts[3])
}

if ($Width -le 0) { $Width = if ($cropRect) { $cropRect.Width } else { $frameImages[0].Width } }
if ($Height -le 0) { $Height = if ($cropRect) { $cropRect.Height } else { $frameImages[0].Height } }

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}

Write-Host "source      : $sourceKind"
Write-Host "target      : ${Width}x${Height}, mode=$Mode$(if ($Invert) { ', inverted' })"
if ($cropRect) { Write-Host "crop        : $Crop" }
Write-Host "out dir     : $OutDir"

$written = New-Object System.Collections.Generic.List[string]
$index = 0
$kept = 0

for ($i = 0; $i -lt $frameImages.Count; $i++) {
    if ($EveryNth -gt 1 -and ($i % $EveryNth) -ne 0) { continue }
    if ($MaxFrames -gt 0 -and $kept -ge $MaxFrames) { break }

    $srcBmp = $frameImages[$i]

    # crop first if asked, so we only scale the region of interest
    $region = $srcBmp
    if ($cropRect) {
        $region = New-Object System.Drawing.Bitmap($cropRect.Width, $cropRect.Height,
                                                   [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $rg = [System.Drawing.Graphics]::FromImage($region)
        $rg.DrawImage($srcBmp, (New-Object System.Drawing.Rectangle(0, 0, $cropRect.Width, $cropRect.Height)),
                      $cropRect, [System.Drawing.GraphicsUnit]::Pixel)
        $rg.Dispose()
    }

    $resized = Resize-Bitmap -Src $region -W $Width -H $Height
    $out = Convert-ToGreyIndexed -Src $resized -ModeName $Mode -Cut $Threshold -Flip ([bool]$Invert)

    $name = "{0}{1:d3}.png" -f $Prefix, $index
    $path = Join-Path $OutDir $name
    $out.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)

    $written.Add($name)
    $out.Dispose(); $resized.Dispose()
    if ($cropRect) { $region.Dispose() }

    $index++
    $kept++
}

# ---------------------------------------------------------------------------
# manifest + optional contact sheet
# ---------------------------------------------------------------------------
# A real, self-describing manifest. This is what makes a folder portable: anyone
# receiving it can see the frame size, where it is placed, how fast it runs and
# what palette it uses, without reading config.sh. See artwork/FORMAT.md.
$setName = Split-Path $OutDir -Leaf
$manifest = [ordered]@{
    format   = 'kindle-dashboard-animation'
    version  = 1
    name     = $setName
    screen   = [ordered]@{ width = 600; height = 800 }
    frame    = [ordered]@{ width = $Width; height = $Height; x = $DrawX; y = $DrawY }
    count    = $written.Count
    delay_ms = $delayMs
    loop     = 'continuous'
    palette  = $(if ($Mode -eq 'grey16') { 'grey16' } else { '1-bit' })
}
if ($Preview) { $manifest['preview'] = 'preview.png' }
$manifestPath = Join-Path $OutDir 'manifest.json'
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding ASCII

if ($Preview) {
    $gap = 6
    $total = $written.Count
    $sheetW = ($Width * $total) + ($gap * ($total + 1))
    $sheetH = $Height + ($gap * 2)
    $sheet = New-Object System.Drawing.Bitmap($sheetW, $sheetH, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $sg = [System.Drawing.Graphics]::FromImage($sheet)
    try {
        $sg.Clear([System.Drawing.Color]::FromArgb(255, 120, 120, 130))
        for ($n = 0; $n -lt $total; $n++) {
            $f = [System.Drawing.Image]::FromFile((Join-Path $OutDir $written[$n]))
            $sg.DrawImage($f, ($gap + ($n * ($Width + $gap))), $gap, $Width, $Height)
            $f.Dispose()
        }
    }
    finally { $sg.Dispose() }
    $sheetPath = Join-Path $OutDir 'preview.png'
    $sheet.Save($sheetPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $sheet.Dispose()
    Write-Host "preview     : $sheetPath (every frame side by side, to check the cycle)"
}

foreach ($d in $scratch) { $d.Dispose() }
foreach ($f in $frameImages) { if ($f -is [System.IDisposable]) { $f.Dispose() } }

Write-Host ""
Write-Host "wrote $($written.Count) frame(s) of ${Width}x${Height} to $OutDir" -ForegroundColor Green
$first = Join-Path $OutDir $written[0]
Write-Host "first frame: $first ($((Get-Item -LiteralPath $first).Length) bytes)"
Write-Host "manifest   : $manifestPath"
