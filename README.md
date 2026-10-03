# Kindle Lockscreen Dashboard

Turns a jailbroken Kindle into a wall/desk display that shows **the time and the
weather for two places**, styled after the iOS lock screen, and keeps showing it
while the Kindle is idle (standby).

```
        Thursday, 2 October
              10:42

     +---------------------------+
     |         Bengaluru         |
     |            27°            |
     |    ☀ Clear · 31°/22°      |
     +---------------------------+
     +---------------------------+
     |        Thalassery         |
     |            29°            |
     |  ☂ Heavy showers · 32°/25°|
     +---------------------------+

            Updated 10:41
```

Everything runs **on the Kindle**. Once installed it needs no PC — it joins your
Wi-Fi, fetches the forecast itself, and repaints the e-ink panel. E-ink retains
its last image with no power, so the dashboard is still readable even if the
device eventually suspends.

---

## Your device (as detected)

| | |
|---|---|
| Model | **Kindle Basic 3 (2019) Kids Edition** — device code `0VB`, id `0x3AB` |
| Serial | `G090VB06217602DL` |
| Screen | 600 × 800, 16-level greyscale, 167 dpi, touch |
| Firmware | 5.18.1 |
| Jailbreak | WinterBreak 1.7.0 (Mesquito) |
| Launcher | KUAL (booklet), MRPI installed |
| Also present | KOReader v2025.08 |
| Renderer | `fbink` — already on the device at `/mnt/us/libkh/bin/fbink` |

Nothing extra needs downloading. All the fonts and binaries used are already
on your Kindle.

---

## Install

**1. Copy the files across (on the PC).**

```powershell
cd tools
.\deploy.ps1
```

That writes `dashboard/` and `extensions/dashboard/` to the Kindle drive and
leaves an existing `config.sh` alone. If the drive isn't detected, pass it
explicitly: `.\deploy.ps1 -DriveLetter F`.

**2. Safely eject the Kindle** (Safely Remove Hardware / "Eject" in Explorer).
Do not just unplug it — the FAT32 volume must be flushed.

**3. On the Kindle: KUAL → Dashboard.**

- **Install / refresh files** → installs the KUAL entry points and records your
  current power settings so they can be restored later.
- **Start (show clock + weather)** → the panel switches to the dashboard.

The very first paint happens within a few seconds. If the Kindle has never been
on Wi-Fi it will show `—` for the weather until it can reach the internet.

> **No KUAL?** You can bootstrap from KOReader instead: KOReader → Tools →
> Terminal, then run `sh /mnt/us/dashboard/install.sh`.

### Requirements

- The Kindle must be **connected to Wi-Fi** for weather and for clock sync.
- Weather comes from `api.open-meteo.com`, falling back to `wttr.in`.
- **Power it from a wall charger, not from the PC.** A data connection to a PC
  puts the Kindle into USB-drive mode, which stops the framework and hides
  `/mnt/us` — the dashboard cannot run. On a charger it runs indefinitely.

---

## Daily use

| I want to… | Do this |
|---|---|
| **Stop and get the Kindle UI back** | **Tap the screen 3 times quickly** (or KUAL → Dashboard → Stop) |
| Redraw immediately | KUAL → Dashboard → **Redraw now** |
| Change cities, units, sizes | edit `dashboard/config.sh`, then **Restart** |
| Check it's healthy | KUAL → Dashboard → **Show status on screen** |
| Run it automatically after boot | KUAL → Dashboard → **Toggle boot autostart** |
| Push a change from your PC | KUAL → Dashboard → **Update from GitHub** (see below) |

Every Dashboard entry is at one level — there are no submenus to hunt through.
The two diagnostic modes (`probe`, `geo`) are deliberately not in the menu
because they are for tuning, not daily use; run them from a shell:
`sh /mnt/us/dashboard/dashboard.sh probe`

### The whole KUAL menu

One flat list, in this order, so nothing is hidden behind a submenu:

| # | Entry | What it does |
|---|---|---|
| 1 | Start (show clock + weather) | takes the screen and runs the dashboard |
| 2 | Stop (restore Kindle UI) | gives the screen back to the Kindle |
| 3 | Restart | stop, then start |
| 4 | Redraw now | draws one frame and exits |
| 5 | Start animation | plays the active animation until you tap 3× |
| 6 | Next animation | switches to the next installed set |
| 7 | Show animations | lists the installed sets, marking the active one |
| 8 | Show status on screen | is it running, which set, which font resolved |
| 9 | Update from GitHub | pulls the project's `code` branch and reinstalls |
| 10 | Fetch artwork from URL | pulls `ART_URL` and installs any animation sets |
| 11 | Install / refresh files | re-copies files and re-enables KUAL entries |
| 12 | Toggle boot autostart | flips autostart on/off and reports the new state |
| 13 | Uninstall (restore wallpaper) | stops it and removes every installed file |

Entries 9–12 are the ones you use after changing something on your PC.
They paint their output straight onto the eInk panel, because KUAL gives the
extension no console.


### Getting back to the Kindle UI

While the dashboard is showing, the normal Kindle interface is deliberately
frozen so that nothing repaints over the clock. There are three ways back, in
order of convenience:

1. **Tap the screen three times within three seconds.** The daemon watches the
touchscreen directly and will stop itself and hand the screen back. This is the
normal, intended way out.
2. **Plug the Kindle into a PC.** USB-drive mode terminates the dashboard, and
the framework restarts normally when you unplug.
3. **Hold the power button for ~40 seconds to reboot.** With boot autostart
left off (the default), the Kindle comes back to its normal UI.

Because freezing the window manager removes the only route back, the daemon
**refuses to take the screen at all** if it cannot find the touchscreen (or the
`od` tool needed to decode taps). In that case it logs a warning, leaves the
Kindle UI alone, and you can still stop it from KUAL.

### Getting out if the screen is frozen

While the dashboard holds the screen the normal Kindle UI is deliberately
frozen. If you cannot reach KUAL:

- **Plug the Kindle into a PC.** USB-drive mode terminates the dashboard and the
  normal UI comes back. This is the easiest escape.
- Or **hold the power button to reboot.** Without boot autostart enabled, the
  Kindle comes up normally.

---

## Revert to your normal wallpaper / screensaver

Nothing in this project modifies your screensaver wallpapers (`bg_ss*.png`,
`bg_kids_*.png`) or any other stock file, so reverting is simply:

**KUAL → Dashboard → Uninstall (restore wallpaper)**

That will:

1. stop the dashboard;
2. un-freeze the window manager and re-enable the status bar;
3. put the `com.lab126.powerd` properties back to the values recorded at install
   time (`dashboard/state/original-powerd.txt`);
4. remove the KUAL menu entry and any boot autostart job;
5. restart the framework so the home screen and the stock standby wallpaper
   return.

To also delete the payload: `sh /mnt/us/dashboard/uninstall.sh --purge`.

---

## Configuration

All in `dashboard/config.sh`. The interesting knobs:

```sh
# One per line:  Label|latitude|longitude|IANA timezone
LOCATIONS="
Bengaluru|12.9716|77.5946|Asia/Kolkata
Thalassery|11.7500|75.4900|Asia/Kolkata
"
UNITS="celsius"          # celsius | fahrenheit
WEATHER_INTERVAL=900     # refetch the forecast every 15 min
CLOCK_INTERVAL=60        # repaint the clock every minute
SCREEN_HOLD="wm"         # wm | framework | none
KEEP_AWAKE=1
CLOCK_PX=200             # the giant clock
```

- Two locations fill the 600×800 panel. A third will overflow.
- `CLOCK_PX` is safe up to about 215 (a 5-character `10:42` still fits inside
  600 px). The current value renders 511 px wide.
- `SCREEN_HOLD="wm"` is the gentlest way to own the screen. Use `"framework"`
  if the UI ever repaints over the dashboard.

### Vertical layout is chained, not absolute

This is the part worth understanding before you move anything. An earlier
version positioned every element at its own hand-tuned offset, which produced
overlapping text on real hardware because it relied on an assumption about where
ink lands inside a line box.

The current version asks fbink where the next line must start
(`-E, --coordinates` reports `next_top`) and feeds that forward:

```
date      top = DATE_TOP
date'     top = <what fbink reported>            <- chained
clock     top = date' + CLOCK_GAP                <- chained
clock'    top = <what fbink reported>            <- chained
cards     fixed, anchored from the bottom so the footer always fits
```

Because each block starts below the previous block's *measured* line advance,
the date and the clock cannot collide however the font's metrics work out. Set
`MEASURE_LAYOUT=0` to fall back to a plain `px × FALLBACK_LINE_FACTOR` estimate
if a firmware ever refuses `-E`.

If something is still mispositioned, run `sh /mnt/us/dashboard/dashboard.sh geo`
(`dashboard.sh probe` also exists; neither is in the KUAL menu).
It prints the raw `next_top` and `bbox_height` fbink reports at each font size,
which is the ground truth for adjusting `DATE_TOP`, `CLOCK_GAP` and the card
tops — rather than guessing.

### Power, USB and brightness options

```sh
KEEP_AWAKE=1        # ask powerd not to blank/suspend, and keep the idle timer alive
FRONTLIGHT=0        # 0-24, or -1 to leave the user's setting alone
INHIBIT_USBMS=1     # stop volumd so plugging in a cable does not take the screen
TAP_TO_EXIT=1       # 0 disables the tap-to-exit watcher (see the warning below)
```

- **`FRONTLIGHT=0` is the default, and that matters.** This is a standby display
  meant to sit showing one page for days, and the frontlight is by far the largest
  drain on a device we deliberately keep awake. `0` is *not* the same as `-1`: `-1`
  leaves the light at whatever the user last chose, so it simply stays lit — which
  is how it can end up burning all night. Set 1-24 if you want it on. The dashboard
  drives `flIntensity` *and* `flOn` (some firmware clamps `0` or gates the light
  behind the second), reads the result back, and logs a warning if it would not go
  off — a frontlight that silently stays on is otherwise invisible, because the
  frames render perfectly either way. The original value is restored when you stop.
- `INHIBIT_USBMS=1` lets the dashboard survive being tethered to a PC, at the
  cost of not being able to see the Kindle's files while it runs.
- `TAP_TO_EXIT=0` **disables your only way back to the Kindle UI.** The daemon
  treats that as having no escape route and therefore refuses to freeze the
  window manager, falling back to `SCREEN_HOLD="none"`. It is safe, but the UI
  will be able to repaint over the dashboard.

Use `preview/lockscreen.html` to try layout changes in a browser first — it
mirrors the numbers in `config.sh`.

---

## Updating from GitHub without plugging in

Put the project in a GitHub repo and the Kindle will pull it **once at start** — no
cable, no re-deploy. That covers the code *and* the `artwork/` frames, so you
can change the bird by pushing new frames.

### 1. Publish the project

```sh
git init
git add .
git commit -m "kindle dashboard"
git branch -M main
git remote add origin https://github.com/<you>/<repo>.git
git push -u origin main
```

`.gitignore` already excludes runtime state, logs and generated previews.

### 2. Check the repo will work BEFORE trusting it

The updater refuses anything that is not a valid archive containing every file it
expects, so most mistakes fail safely — but you want to know that up front:

```sh
sh tools/check-update-source.sh <you>/<repo> main
```

It downloads the archive exactly as the device will and verifies the URL resolves,
the response is really a gzip archive, it extracts, `device/config.sh` is present,
and every script passes `sh -n`. Do not validate with a `.zip` from PowerShell's
`Compress-Archive`: it writes backslash separators, which `unzip` rejects. Use a
real GitHub archive or build a `.tar.gz` with `tar`.

### 3. Point the Kindle at it

```sh
UPDATE_ON_START=1
UPDATE_REPO="you/repo"       # or leave empty and set UPDATE_URL instead
UPDATE_REF="main"           # a branch, or refs/tags/v1.0.0 to pin a release
UPDATE_URL=""              # overrides UPDATE_REPO; works with any host
UPDATE_MIN_INTERVAL=0       # 0 = check on every start; 21600 = at most every 6h
```

The repo must contain **`device/config.sh`** at its top level — that is how the
updater confirms it downloaded this project and not, say, an artwork archive.
Pointing `UPDATE_REPO` at an art-only repo gives a plain `HTTP 404` and nothing
else to go on, so a placeholder or a missing repo is now reported by name.

`UPDATE_MIN_INTERVAL` is the answer to "don't query it all the time": set it and
the Kindle will skip the check if it fetched recently. It never polls while
running — only at start.

A **private** repo needs `UPDATE_TOKEN`; it is read from the config file and sent
as a bearer header, never logged. Be aware it is stored in plain text on the device.

#### Code and artwork in one repo, on two branches

This is how this project is published, and it keeps the artwork repo artwork-only:

| Branch | Holds | Fetched by |
|---|---|---|
| `main` | the frames, `config.json`, `FORMAT.md` | `ART_URL` (the art fetch) |
| `code` | the whole project (`device/`, `tools/`, `README.md`) | `UPDATE_REPO` + `UPDATE_REF="code"` |

The two are independent: the art fetch never needs the code, and a code update
never rewrites your frames. `.gitignore` excludes `artwork/` from the code branch
because it is its own repository — committing it there would record a bare
gitlink, and the archive would contain an empty directory that the updater would
mistake for artwork it had received.

**Line endings are load-bearing.** The device runs these files with `/bin/sh`
straight from the archive, and a CRLF script fails with a confusing "not found"
while looking perfectly fine in an editor. `.gitattributes` pins `eol=lf` for
scripts, JSON and XML so no local `core.autocrlf` setting can break a release.

### What it does, and what it will not do

At start it fetches `codeload.github.com/<repo>/tar.gz/<ref>` — **one HTTP
request** — then:

1. rejects anything that is not a real archive (an error page can never be saved
   as the update), extracts it, and looks for `device/config.sh` to confirm it got
   this project
2. checks every expected file exists and every script passes `sh -n`, so a
   truncated download cannot reach the install
3. backs up the current version, copies the new files, and **rolls back if the
   copy fails**

Guaranteed:

- **`config.sh`, `state/` and `log/` are never overwritten** — your settings,
  weather cache and logs survive every update.
- **A failed update is never fatal.** It logs and carries on with the installed
  version.
- Files are replaced via a temporary plus rename, so a *running* daemon can never
  read a half-written script. (In-place overwriting is what corrupts a live shell,
  which is why the update runs before the daemon launches.)
- Files deleted upstream are **not** removed from the device — the updater only
  adds and replaces.

Wi-Fi must be up at start. If the update lands while the dashboard is running,
restart it to pick up the new code; the boot-time path does not need this because
it updates before launching.

---

## Animated wall display

A looping black-and-white animation (a bird on a branch, flapping) that you can
leave running on the panel.

### First, the honest limits

E-ink cannot play video. A full refresh costs 300-800ms **and flashes the whole
panel**; only the fast `A2`/`DU` waveforms are usable, and they manage roughly
**50-150ms per update — about 5-10 fps**. So eight frames is about one second per
flap cycle: a slow, deliberate flutter, not a video.

`A2` is effectively 1-bit and leaves ghosting, so a full `GC16` flash is needed
periodically. That flash is visible; `ANIM_DEGHOST_SECONDS` controls how often.

### One mode: fullscreen

**KUAL → Dashboard → Start animation.** The frames own the whole panel — no clock
and no weather — so nothing else draws to the framebuffer and there is no
possibility of a second writer. Exit by tapping the screen 3×.

It reuses the same escape hatch as the dashboard: it will not take the screen
unless a tap can be detected to give it back.

> An `overlay` mode used to flap the bird in a band of the clock/weather screen.
> It is gone: it needed a second frame set at a different size and shared the
> panel with the clock, for a fraction of the benefit.

### Frame format

The animation is a numbered sequence of images, one per frame, in a directory
containing a `manifest.json` that describes it. `fbink` has no animation player,
so this is the only way. **Not a GIF** — fbink *decodes* GIF but renders only the
first frame.

**The format is specified in [`artwork/FORMAT.md`](artwork/FORMAT.md)** — that is
the document to hand to anyone designing an animation, and it explains the design
rules and why frames are usually smaller than the screen.

```
artwork/bird/manifest.json      <- describes the animation (size, position, speed)
artwork/bird/frame_000.png
artwork/bird/frame_001.png
...
artwork/bird/preview.png        <- optional: all frames side by side
```

On the device these install as `/mnt/us/dashboard/animations/bird/`, which is what
`ANIM_DIR` points at.

| Property | Value | Why |
|---|---|---|
| Colour | **pure black & white, no antialiasing** | `A2` is 1-bit; grey dithers and ghosts |
| Format | 8-bit greyscale PNG | Certain to work; ~1.5KB per frame |
| Size | crop to the subject, not 600×800 | Smaller rectangle = faster update, less ghosting |
| Count | 6-12 per cycle | More is wasted below 10 fps |
| Naming | zero-padded `frame_NNN.png` | A shell glob sorts correctly |
| Manifest | `manifest.json` beside the frames | Makes the set self-describing and portable |

Design it like a linocut — bold solid shapes. That is what the panel renders well.

### Making frames

```powershell
# two built-in scenes, generated procedurally -- no assets needed
powershell -File tools\make-animation.ps1 -Demo night -Width 420 -Height 320 -DrawX 90 -DrawY 240 -OutDir artwork\night -Preview
powershell -File tools\make-animation.ps1 -Demo bird  -Width 420 -Height 320 -DrawX 90 -DrawY 240 -OutDir artwork\bird  -Preview

# from an animated GIF, cropping a region out of a 600x800 frame
powershell -File tools\make-animation.ps1 -Source bird.gif -Crop 180,420,420,320 -OutDir artwork\myscene

# from a folder of frames you drew
powershell -File tools\make-animation.ps1 -Source frames\ -Mode bw -OutDir artwork\myscene
```

`-Demo night` is a moonlit scene: a crescent moon, twinkling stars, three distant
birds, a torii gate on a hill, and falling blossom. `-Demo bird` is a bird flapping
on a branch. Both are drawn from code, so they double as worked examples of how to
compose for 1-bit.

Useful options: `-Mode grey16` (16 levels with ordered dithering, for gradients —
slower and ghostier), `-Threshold`, `-Invert`, `-EveryNth` to slow a GIF down,
`-MaxFrames`, `-DrawX`/`-DrawY` to say where the frame sits on the panel, and
`-Preview` to write `preview.png`, a single image with every frame side by side —
the quickest way to check a cycle. The tool writes `manifest.json` for you, so you
never hand-write it. `tools\deploy.ps1` copies `artwork/` to the Kindle
automatically (as `animations/` on the device).

Validate any set before sharing it:

```powershell
powershell -File tools\check-artwork.ps1 artwork\bird
```

It reports in plain language whether the manifest is valid, whether the frames
match what it claims, and whether they are the size and palette they should be.

The bundled `bird` and `night` sets are procedural placeholders, not artwork. Add
your own as new folders under `artwork/`; nothing else needs changing as long as
there is a `manifest.json` and the frames are named `frame_NNN.png`. See
[`artwork/FORMAT.md`](artwork/FORMAT.md).

### Tuning

```sh
ANIM_WAVEFORM=A2          # the fast one; GC16 is slow and flashes
ANIM_DELAY_MS=120         # target gap between frames
ANIM_BURST_SECONDS=8      # length of one playback run
ANIM_EVERY_SECONDS=0      # gap between runs; 0 = CONTINUOUS (the default)
ANIM_DEGHOST_SECONDS=120  # full de-ghost flash every N seconds; 0 disables
ANIM_SET="bird"           # which installed artwork plays (default)
ANIM_DIR_BASE="/mnt/us/dashboard/animations"
ANIM_X=90                 # where the frames are drawn (420x320 at 90,240)
ANIM_Y=240
```

### Several artworks, and switching between them

**Every artwork is its own folder, so a new one never replaces an existing one.**
The folder name is the artwork's identity:

- a **new folder name** is a **new artwork** — everything already
  installed stays exactly as it is. Only `bird/` ships in this project, so
  `fish/` below is a stand-in for whatever you add.
- the **same folder name** (`bird/`) **updates** that artwork, which is how you
  revise one you already have

The fetch installs *every* set it finds in the repo, so putting `bird/` and
`night/` in the same repository gives you both on the Kindle. Nothing is ever
deleted.

To choose which one plays, any of these:

| How | Notes |
|---|---|
| **edit `"active"` in the repo's `config.json`** | **the intended way** — one line on GitHub, no cable, no tapping. Scales to hundreds of animations |
| **KUAL → Dashboard → Next animation** | steps through the installed sets and shows the name |
| **KUAL → Dashboard → Show animations** | lists what is installed and which is active |
| `sh /mnt/us/dashboard/dashboard.sh use night` | set it explicitly |
| `ANIM_SET="night"` in `config.sh` | the device default, used when nothing overrides it |

The repo's `config.json` **wins** over the device's own choice, so editing it has a
visible effect. Remove `active` from it to hand control back to the device. A name
that does not exist is ignored with a warning rather than breaking the animation.

With many animations in one repo, set `"only_active": true` so the device keeps
only the one it plays. For thousands, use `ART_RAW_BASE` pointing at the repo root
and only the active set's frames are downloaded at all — see
[`artwork/FORMAT.md`](artwork/FORMAT.md).

The KUAL action and `use` write `state/active-set`, which is used when the repo
does not declare an active set. That file survives updates, so your choice sticks.

**Why a still bird may look like a crash.** E-ink holds one image with no power,
so a frame that is deliberately held is pixel-identical to a hung device. With
`ANIM_EVERY_SECONDS` set above 0 the bird flaps for `ANIM_BURST_SECONDS` and then
**holds a single still frame** until the next run — that is burst mode, not a bug,
and the log says so explicitly:

```
anim: holding a still frame for 60s
```

Burst mode uses less power and accumulates less ghosting, but it is easy to
misread. `ANIM_EVERY_SECONDS=0` animates continuously.

A **de-ghost flash** is also expected: every `ANIM_DEGHOST_SECONDS` the panel does
a full black flash to clear the residue the fast waveform leaves behind. That
brief blink is normal; raise the value or set it to 0 to stop it.

**Continuous or burst?** The default is continuous (`ANIM_EVERY_SECONDS=0`),
because a dedicated animation mode should look animated. Burst is the more
frugal choice — between bursts the panel holds one static frame and the CPU is
idle, whereas continuous animation keeps the panel controller busy, drains the
battery faster and ghosts sooner. The catch is that a deliberately held e-ink
frame is pixel-identical to a hung device, which makes burst mode easy to
misread as a crash. If you want it, set `ANIM_EVERY_SECONDS=60`; the log then
says `anim: holding a still frame for 60s` so the pause is self-explanatory.

---

## How it works

```
PC  ──deploy.ps1──►  /mnt/us/dashboard/          (scripts + state + log)
                     /mnt/us/extensions/dashboard/ (KUAL menu)

Kindle:
  dashboard.sh run ──┬── fetch_all      lib/weather.sh (vendored module):
                     │                     open-meteo JSON, sed-parsed (no jq)
                     │                     └── fallback: wttr.in text
                     ├── sync_time      HTTP Date header → date -u -s
                     ├── render_full    fbink OpenType → framebuffer
                     ├── render_clock   every 60 s, damaged-region refresh
                     └── hold_screen    disableEnablePillow + SIGSTOP awesome
```

A few decisions worth knowing about, because they are the non-obvious parts:

**Rendering is OpenType text via fbink, not images.** The Kindle has no Python
or ImageMagick, so there is nothing to compose a PNG with. `fbink` can draw
TrueType/OpenType text at exact pixel sizes and colours, which is everything an
iOS-style lock screen needs.

**The vertical metrics are deliberate.** fbink places the first baseline at
`top + ascent`, so the visible cap-height of a line begins about `0.355em` below
the `top` value. The `*_TOP` values in `config.sh` account for that; if you move
something, move it in ink-space and subtract `0.355 × px`.

**Two fonts, on purpose.** `NotoSans-Regular` has no weather dingbats at all —
only `°`, `·` and `–`. `NotoSansCJKsc-Regular.otf` does have `☀` (U+2600),
`☁` (U+2601) and `☂` (U+2602) *and* a full Latin set, so the card lines are
drawn in it and can carry an icon inline. Glyph coverage was verified against
the actual font files, so nothing renders as a blank box.

**Screen ownership uses KOReader's own technique.** Freezing the window manager
(`killall -STOP awesome`) plus `disableEnablePillow` is what KOReader does on
this firmware to stop the framework repainting over it. It is fully reversible
with `-CONT`, unlike stopping the framework.

**Colours are hex, not greyscale names.** `-B '#EDEDED'` is unambiguous;
fbink's `GRAY1..GRAYE` naming is easy to get backwards. The e-ink controller
dithers to its 16 levels.

**Batched draws.** Every element is drawn with `-b` (framebuffer only) and the
panel is flushed once at the end, so there is a single clean update instead of
six flickers. A full black flash runs every 10th refresh to clear ghosting.

**Everything is logged** to `dashboard/log/dashboard.log`, including which
powerd property was accepted. If standby behaviour is ever wrong, that file
says why.

---

## Troubleshooting

**Blank or partially drawn screen.**
Check the log. If you see `fbink OpenType failed`, the font path is wrong — run
`sh /mnt/us/dashboard/dashboard.sh probe` to see which fonts resolved.

**Weather never appears (shows `—`).**
The Kindle has no internet. Confirm it is joined to Wi-Fi and can reach the
outside world. Diagnostics prints the HTTP `Date` header it receives, which
proves connectivity on its own.

**The clock stops updating.**
The device suspended anyway. E-ink keeps the last image so the display still
looks right, it is just stale. Diagnostics prints the `powerd` state; if
`preventScreenSaver`/`preventSuspend`/`stayAwake` are all absent on your
firmware, raise `KEEP_AWAKE` handling or set `SCREEN_HOLD="framework"`.

**Card text is rendering in a courier-like bitmap font, or is in the wrong
place.** fbink fell back to its built-in bitmap font, which means an OpenType
draw failed. The log will say `render: fbink OpenType failed`. Almost always
this is a display-area problem: fbink's `left`/`right` are *margins measured in
from the screen edges*, not coordinates, so passing a coordinate for `right`
collapses the area to zero width. The daemon also probes the card font at
startup, so if the 16 MB `NotoSansCJKsc-Regular.otf` cannot be rendered you will
see `fbink cannot render` in the log instead of a silent downgrade.

**The date above the clock is missing.** Something is painting a background over
it. fbink paints a background across the entire *line box*, and a 200 px font
has a 272 px line box starting at `top` — which is why the clock is drawn bgless
and cleaned with an explicit band wipe instead. If you move the clock or change
`CLOCK_PX`, keep `CLOCK_BAND_TOP` below the date's ink and the band tall enough
to cover the clock's.

**The date above the clock is missing or overlapping.**
Vertical placement is chained from fbink's own reported line advance, so this
should not happen — see *Vertical layout is chained, not absolute* above. If it
does, run `sh /mnt/us/dashboard/dashboard.sh geo` and check that `next_top` is being
reported; if it comes back empty, fbink did not accept `-E` on your build and the
layout fell back to the estimated factor, which is less precise.

**The screen went white / blank when I started the animation.**
This was a real bug, now fixed. `find_fbink` search order **prefers
`/mnt/us/koreader/fbink`**, and that build is stripped with **image support
disabled at compile time** — it renders text perfectly but fails every `-g` call
with *"Image support is disabled in this FBInk build!"*. The dashboard cleared
the panel and then could not draw anything on it.

Image work now probes for a capable binary by **actually performing a draw** and
checking the exit status, preferring `/mnt/us/libkh/bin/fbink` (which has image
support). If nothing can draw, it refuses to start and shows an explanation
instead of blanking the screen. Check which builds work with:

```sh
# on the Kindle, or from Git Bash on the PC
sh tools/check-renderers.sh
```

Off-Windows note: Kindle binaries are ARM, so the live test can only run **on the
device**. From Git Bash it reports `SKIP` for that part rather than pretending.

**Only the middle of the screen showed the animation; the rest reverted to the stock UI.**
This was a real bug, now fixed. Frames only cover their own rectangle, so anything
the framework repaints stays visible indefinitely. The fix is to stop **`cvm`** as
well as `awesome`: `cvm` is the VM that renders the home screen and the KUAL
booklet, and it keeps drawing even when the window manager is frozen. KOReader
stops both for the same reason. The status bar is also explicitly hidden via
`interrogatePillow`, because merely calling `disableEnablePillow` is not enough on
FW >= 5.7.2 and the bar keeps refreshing its clock. As a backstop the whole panel
is now reclaimed before every burst.

**It flaps for a few seconds, then freezes for a minute, then flaps again.**
Not a bug — that is burst mode. E-ink holds one image with no power, so a
*deliberately* held frame is visually identical to a hung device. Set
`ANIM_EVERY_SECONDS=0` for continuous animation. The log states the cadence at
startup and logs `anim: holding a still frame for Ns` each time it rests.

**There is a brief full-screen flash every couple of minutes.**
Expected: the de-ghost flash. A2 accumulates residue, so the panel does a full
`GC16` refresh periodically. Tune with `ANIM_DEGHOST_SECONDS`, or set 0.

**The animation is much slower than expected (about 1 fps).**
Also fixed. `sleep_ms` probed for `usleep` with `command -v`, which fails in a
KUAL environment even though `usleep` exists and KOReader calls it directly, so
every frame fell back to a whole-second `sleep`. The probe now *runs* each
candidate in turn — `usleep`, `busybox usleep`, `/usr/bin/usleep`, a decimal
`sleep`, then whole seconds — and logs which one it settled on.

Note the panel update itself may still dominate. The log now records the real
rate:

```
anim: loop 12 took 3s (8 frames, ~375ms per frame)
```

That is the honest measurement. If the per-frame figure is close to
`ANIM_DELAY_MS`, the delay is the limiting factor and lowering it helps; if it is
far larger, the e-ink update is the bottleneck and no setting will fix it.

**Recovering from a blank screen.** Tap the screen 3× (the escape hatch worked
even in the broken version). If that does not respond, hold the power button
~40s to force a reboot, or plug/unplug USB to let the framework take over.

**I plugged it into the PC and the dashboard vanished.**
Expected — USB-drive mode. Set `INHIBIT_USBMS=1` to prevent it, at the cost of
not being able to see the Kindle's files while the dashboard runs. Otherwise
just unplug and restart from KUAL.

**`mntroot rw failed` when enabling autostart.**
The boot autostart job is the only part that writes outside `/mnt/us`. If your
device refuses, skip it — just start from KUAL, or leave the Kindle running.

---

## Layout

```
kindle_exp/
├── README.md
├── .gitignore
├── device/                     <- copied to the Kindle
│   ├── config.sh               <- the only file you normally edit
│   ├── dashboard.sh            <- entry point / daemon / power handling
│   ├── install.sh
│   ├── uninstall.sh
│   ├── lib/
│   │   ├── util.sh             <- logging, fbink + font discovery, LIPC,
│   │   │                          HTTP, the sed JSON helpers, clock sync
│   │   ├── weather.sh          <- VENDORED from weather/ -- do not edit here
│   │   ├── render.sh           <- the lock screen itself
│   │   ├── anim.sh             <- frame animation playback
│   │   └── update.sh           <- self-update from a GitHub archive
│   └── kual/                   <- KUAL extension (config.xml, menu.json, bin/)
├── artwork/                    <- frame sets; upload this folder to GitHub
│   ├── FORMAT.md               <- the animation format spec (for designers)
│   ├── README.md               <- how to upload and what URL to use
│   └── bird/                   <- manifest.json + frame_NNN.png + preview.png
├── weather/                    <- its OWN repo (kindle-weather-dashboard)
│   ├── weather.sh              <- the standalone fetcher -- source of truth
│   ├── test.sh                 <- 75 offline assertions, no network needed
│   └── README.md               <- its API, its cache format, its host contract
├── preview/
│   └── lockscreen.html         <- PC-side mock at 600x800
└── tools/
    ├── deploy.ps1              <- finds the Kindle, copies everything
    ├── verify.ps1              <- static checks + deployed-copy comparison
    ├── sync-weather.ps1        <- re-vendor weather/weather.sh into device/lib
    ├── make-animation.ps1      <- GIF/frames -> Kindle animation frames
    ├── check-artwork.ps1       <- validate an animation folder before sharing
    ├── fbink-capabilities.ps1  <- what the on-device fbink binary supports
    ├── check-update-source.sh  <- will this repo work as an update source?
    ├── check-renderers.sh      <- which fbink builds can draw images
    ├── check-device-tools.sh   <- what download/archive tools exist
    ├── test-parse.sh
    └── test-helpers.sh
```

Runtime state lives in `dashboard/state/` (weather cache, PID, the recorded
original powerd values) and `dashboard/log/`.

### The weather module is a separate repository

`device/lib/weather.sh` is a **vendored copy** of `weather/`, which is its own git
repository (`kindle-weather-dashboard`). It was split out because it has nothing to do with
e-ink: it is HTTP in, one line of pipe-separated text out, and it runs on a laptop
as happily as on a Kindle.

The device still needs the file inside `device/`, because the updater copies that
tree verbatim and never fetches a second repository at runtime. So the module is
vendored, and one tool keeps the copy honest:

```powershell
powershell -File tools\sync-weather.ps1          # re-copy after editing the module
powershell -File tools\sync-weather.ps1 -Check   # verify.ps1 runs exactly this
```

**Edit the weather code in `weather/`, then run the sync tool, then commit both.**
`verify.ps1` fails when the two drift apart. That matters more than it sounds:
every other check reads the vendored copy, so without this one the published
library and the code running on the device can stop matching and nothing complains.

The module knows nothing about this project — it cannot read `STATE_DIR`, because
that name means nothing on a laptop. `util.sh` does the wiring instead, handing it
`WX_CACHE_DIR`, and supplying `log`, `http_get`, `is_int`, `round0` and the JSON
helpers. The module defines all of those itself, guarded with `command -v`, so it
runs standalone *and* an embedding application keeps its own versions.

`weather/test.sh` asserts that independence, which is what makes it a property
rather than a claim. It runs as part of `verify.ps1` whenever `weather/` is checked
out.

---

## Attribution

Weather data by [Open-Meteo.com](https://open-meteo.com/) (CC BY 4.0), which
asks for attribution on non-commercial use. If you redistribute or show this
publicly, add a credit line — the footer is a natural place for it.
Fallback data by [wttr.in](https://wttr.in/).
