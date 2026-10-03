#!/bin/sh
# ============================================================================
#  Kindle Lockscreen Dashboard -- user configuration
#
#  Edit this file, then run:  KUAL -> Dashboard -> Restart
#  (or from a shell:          sh /mnt/us/dashboard/dashboard.sh restart )
# ============================================================================

# ---------------------------------------------------------------------------
# WEATHER LOCATIONS
# ---------------------------------------------------------------------------
# One location per line, format:   Label|latitude|longitude|IANA timezone
# One or two locations fit nicely at 600x800. More than two will overflow.
LOCATIONS="
Bengaluru|12.9716|77.5946|Asia/Kolkata
Thalassery|11.7500|75.4900|Asia/Kolkata
"

UNITS="celsius"              # celsius | fahrenheit

# ---------------------------------------------------------------------------
# REFRESH CADENCE
# ---------------------------------------------------------------------------
WEATHER_INTERVAL=900         # seconds between weather downloads  (900 = 15 min)
CLOCK_INTERVAL=60            # seconds between clock redraws      (60 = 1 min)

# ---------------------------------------------------------------------------
# STANDBY BEHAVIOUR
# ---------------------------------------------------------------------------
# How the dashboard holds the screen so the Kindle UI cannot repaint over it.
#   wm        = SIGSTOP the window manager + hide the status bar.
#               Non-destructive and fully reversible. Same trick KOReader uses.
#   framework = stop the whole Amazon framework. Bullet-proof, but heavier and
#               the Kindle UI is unavailable until you stop the dashboard.
#   none      = just draw and hope nothing repaints (for debugging only).
SCREEN_HOLD="wm"

# Ask powerd not to blank/show a screensaver, and to keep the idle timer alive
# so the clock can tick. If the firmware refuses we log it and carry on.
KEEP_AWAKE=1

# Stop volumd so that plugging in a USB cable does NOT switch the Kindle into
# USB-drive mode (which would tear the dashboard down). While this is on you
# cannot see the Kindle's files from a PC until you stop the dashboard.
INHIBIT_USBMS=0

# Frontlight brightness 0-24, or -1 to leave whatever the user set.
#
# 0 by default, and that default matters: this is a standby display meant to sit
# showing one page for days, and a lit frontlight is by far the biggest drain on a
# device we are deliberately keeping awake. Note 0 is NOT the same as -1 -- -1
# leaves the light at whatever the user last chose, which is how it can end up
# burning all night. Set a number (1-24) if you actually want the light on.
#
# The original value is restored when you stop the dashboard.
FRONTLIGHT=0

# Tap the screen three times within TAP_WINDOW seconds to stop the dashboard and
# hand the Kindle UI back. Once the window manager is frozen this is the ONLY way
# out, so if the touchscreen cannot be found (or TAP_TO_EXIT is 0) the daemon
# refuses to freeze the window manager at all and falls back to SCREEN_HOLD=none.
TAP_TO_EXIT=1
TAP_COUNT=3
TAP_WINDOW=3

# Re-sync the clock from the HTTP "Date:" header on every weather refresh.
# Keeps the clock exact even if the Kindle has been offline. Needs root (we have it).
SYNC_TIME=1

# ---------------------------------------------------------------------------
# LOOK  (iOS lockscreen style)
# ---------------------------------------------------------------------------
SHOW_DATE=1
SHOW_ICONS=1                 # weather glyph in the condition line
SHOW_FOOTER=1                # subtle "Updated HH:MM" line
FLASH_EVERY=10               # full black flash every N full refreshes (deghosts)

# Vertical layout is CHAINED, not absolute.
#
# fbink's OpenType renderer reports `next_top` -- the value to pass as `top` for
# the following line -- via -E, --coordinates. render.sh feeds that forward, so
# each block is positioned from the previous block's real measured height rather
# than from a guess about where ink lands inside a line box. That is what stops
# the clock from colliding with the date above it.
#
# The *_TOP values below are therefore only the STARTING position of the first,
# second, etc. block, not the ink position of each. The card tops are anchored
# from the bottom so the footer always fits.
DATE_PX=24
DATE_TOP=20
CLOCK_PX=200
CLOCK_GAP=6                  # extra space between the date and the clock
FOOTER_PX=22
FOOTER_TOP=750

# Fallback geometry, used only when fbink cannot report next_top (older builds,
# or if -E is rejected). Not used in normal operation.
FALLBACK_LINE_FACTOR=1.45     # line height as a multiple of px
CLOCK_BAND_TOP=60
CLOCK_BAND_HEIGHT=280

# Position every block from fbink's own reported line advance (-E) instead of
# from hard-coded offsets. Leave on. `dashboard.sh geo` shows the raw numbers.
MEASURE_LAYOUT=1

# Weather cards.
#
# IMPORTANT: CARD_LEFT and CARD_WIDTH are *screen coordinates* for the panel,
# but fbink's left=/right= text options are MARGINS measured from the screen
# edges. render.sh converts between the two. Getting this wrong collapses the
# text area to zero width and every line silently falls back to the bitmap font.
#
# Card tops are anchored from the BOTTOM of the screen (footer, then card 2,
# then card 1) so the footer can never be pushed off the display.
#    card 1   370..546
#    card 2   562..738
#    footer   ink ~758..775
# The three text lines inside a card are also chained, so the condition line
# cannot drift off the bottom edge of its panel.
CARD_LEFT=40
CARD_WIDTH=520
CARD_HEIGHT=176
CARD1_TOP=370
CARD2_TOP=562
CARD_PAD_TOP=12              # first line offset inside the card
CARD_GAP1=6                  # label -> temperature
CARD_GAP2=4                  # temperature -> condition
CARD_LABEL_PX=22
CARD_TEMP_PX=52
CARD_COND_PX=22

# Draw everything into the framebuffer first, then flush the eInk panel in one
# update (no flicker between elements). Set to 0 if a firmware ever refuses to
# show the batched result.
BATCH_DRAWS=1

# Greyscale palette. Any #RRGGBB value works; 16 shades get dithered.
C_PANEL="#EDEDED"
C_PRIMARY="#141414"
C_MUTED="#5F5F5F"
C_FAINT="#9A9A9A"
C_CLOCK="#141414"
C_BG="WHITE"

# Merely a starting point: the probe list in dashboard.sh tries KOReader's Noto
# Sans, then the stock Kindle faces. The card font must contain the weather
# dingbats (U+2600/2601/2602), which is why it is the CJK face; if fbink cannot
# render it the daemon falls back and disables icons automatically.
FONT_TEXT="/mnt/us/koreader/fonts/noto/NotoSans-Regular.ttf"
FONT_CARD="/mnt/us/koreader/fonts/noto/NotoSansCJKsc-Regular.otf"

# ---------------------------------------------------------------------------
# ANIMATION (a numbered frame sequence, replayed by a loop)
# ---------------------------------------------------------------------------
# fbink has no animation player, so an animation is a directory of frames. See
# tools/make-animation.ps1 to produce them.
#
# FULLSCREEN ONLY. The frames own the whole panel: no clock, no weather, and
# therefore nothing else drawing to the framebuffer, so there is no possibility
# of a second writer. Started from KUAL -> Dashboard -> Start animation and
# exited by tapping the screen three times.
#
# (An "overlay" mode used to flap the bird in a band of the clock/weather screen.
# It is gone: it needed a second frame set at a different size, and it shared the
# panel with the clock.)

# Frames. ANIM_SET names which installed artwork to play. Every artwork is its own
# folder under ANIM_DIR_BASE, so adding a new one NEVER replaces an existing one --
# only reusing the same folder name replaces it, which is how you update an
# artwork you already have.
#
# Switch at runtime from KUAL -> Dashboard -> "Next animation", which writes
# state/active-set and overrides ANIM_SET without editing this file or plugging
# the Kindle in. Delete that file to fall back to ANIM_SET.
ANIM_SET="bird"
ANIM_DIR_BASE="/mnt/us/dashboard/animations"

# Per-frame placement, used only for a set that has no manifest.json. A set that
# ships a manifest carries its own position and delay (see artwork/FORMAT.md),
# which is what makes a set portable. Set this to 0 to ignore manifests.
ANIM_USE_MANIFEST=1
ANIM_X=90
ANIM_Y=240

# A2 is the fast no-flash waveform. It is effectively 1-bit, which is exactly
# what the frames are, and it is why they must be pure black and white.
ANIM_DELAY_MS=120             # target gap between frames
ANIM_WAVEFORM=A2
ANIM_BURST_SECONDS=8          # how long to flap each time (ignored if continuous)

# Gap between bursts. 0 = CONTINUOUS, which is the default because a dedicated
# animation mode should look animated. Set it to e.g. 60 to flap for
# ANIM_BURST_SECONDS and then hold a single still frame in between, which uses
# less power and accumulates less ghosting -- but note that a held e-ink frame is
# visually identical to a crash, so burst mode is easy to mistake for a freeze.
ANIM_EVERY_SECONDS=0

# Ghosting accumulates with the fast waveform, so flash occasionally. Measured
# in SECONDS of elapsed animation, not loop count: the real frame rate varies a
# lot between devices, so a loop count gives no control over how often the flash
# is actually seen. 0 disables it.
ANIM_DEGHOST_SECONDS=120
ANIM_DEGHOST_WAVEFORM=GC16

# Stop the animation after this many consecutive frame-draw failures, rather
# than looping forever over a blank panel. The most likely cause is an fbink
# build without image support; dashboard.sh checks for that before it starts.
ANIM_MAX_FAILURES=3

# ---------------------------------------------------------------------------
# SELF-UPDATE FROM GITHUB
# ---------------------------------------------------------------------------
# Pull the latest code and artwork from your repository, so you can change things
# on your PC and have the Kindle pick them up without being plugged in. Needs
# Wi-Fi at start time.
#
# This fetches ONCE per start, not continuously. Nothing is written until the
# download has been verified as a real archive containing every expected file
# with every script passing `sh -n`, so a failed download can never replace
# working code. Your config.sh, state/ and log/ are never overwritten.
UPDATE_ON_START=0             # 1 = check for an update when the dashboard starts
UPDATE_REPO="owner/repo"       # GitHub owner/repo, or leave empty and set UPDATE_URL
UPDATE_REF="main"             # a branch name, or a full refs/tags/v1.0.0
UPDATE_URL=""                 # overrides UPDATE_REPO entirely (GitLab, a release asset, anything)
UPDATE_TOKEN=""               # only needed for a private repo; stored in plain text here
UPDATE_MIN_INTERVAL=0         # 0 = check on every start; e.g. 21600 = at most every 6h

# ---------------------------------------------------------------------------
# ARTWORK FROM A URL
# ---------------------------------------------------------------------------
# Pull the animation frames at start from a URL you control, so you can change
# the art by uploading to GitHub -- no cable, and no code update needed.
#
# Frames are installed into /mnt/us/dashboard/animations/, which is where the
# ANIM_DIR_* paths above point. A failed fetch leaves the frames already on the
# device untouched, so a bad URL can never leave you with no animation.
#
# Upload the artwork/ folder, then set one of these. See artwork/README.md.
# This is the published art repo, verified working end to end:
ART_URL="https://codeload.github.com/jithinsankar/kindle-screensaver/tar.gz/refs/heads/main"
#   e.g. https://codeload.github.com/you/your-repo/tar.gz/refs/heads/main
#   or   https://github.com/you/your-repo/releases/download/art-v1/artwork.tar.gz
#
# Or serve the PNGs individually at a base URL (one request per frame):
ART_RAW_BASE=""
#   e.g. https://raw.githubusercontent.com/you/your-repo/main/artwork

ART_ON_START=1                # 1 = fetch artwork at start
ART_MIN_INTERVAL=0            # 0 = every start; e.g. 3600 = at most hourly
ART_MAX_FRAMES=24             # cap when using ART_RAW_BASE

# ---------------------------------------------------------------------------
# MISCELLANEOUS
# ---------------------------------------------------------------------------
STATE_DIR="/mnt/us/dashboard/state"
LOG_FILE="/mnt/us/dashboard/log/dashboard.log"
LOG_MAX_BYTES=262144         # log is truncated to this size on start
