# Kindle dashboard animation format

A plain-language spec. If someone hands you a folder of frames, or you want to
design an animation for this display, this is everything you need.

**Short version:** an animation is a folder containing a `manifest.json` and a
numbered sequence of PNG images. There is no video and no GIF — the panel draws
one still image at a time, as fast as e-ink allows.

---

## Folder layout

```
myanimation/
├── manifest.json      required — describes the animation
├── frame_000.png      the frames, in order
├── frame_001.png
├── frame_002.png
└── preview.png        optional — all frames side by side, to check the cycle
```

The folder name becomes the animation's name. Put it under `artwork/` in this
project and the dashboard picks it up.

**A repository can hold several animations at once.** Each folder is a separate
animation, and they coexist on the device — adding a new folder never replaces an
existing one. The folder name is the animation's identity, so:

- a new folder name is a **new animation**
- reusing an existing folder name **updates** that animation

If you are contributing here, add your animation as a new folder rather than
editing someone else's.

## Choosing which animation is current

A repository can hold many animations. To say which one the display plays, put a
`config.json` at the repo root:

```json
{
  "active": "bird",
  "only_active": false
}
```

| Field | Meaning |
|---|---|
| `active` | the folder name of the animation to play. Change this one line to switch. |
| `only_active` | `true` = the device keeps only the active animation rather than every one in the repo. Useful when a repo holds hundreds. |

The device reads this file when it fetches, so **editing it on GitHub is how you
change the animation** — no cable, and no tapping through a list.

- A plain text file containing just the folder name also works, if you would
  rather not write JSON.
- Omit `active` to let the device decide for itself (its own setting, or the KUAL
  "Next animation" action).
- If `active` names a folder that does not exist, the device logs a warning and
  falls back rather than breaking. A stale name never wins.

This takes precedence over the device's own setting, so that editing the file has
a visible effect. Remove `active` to hand control back to the device.

### With very many animations

`only_active: true` stops the device filling up with art it is not playing — but
the whole repository is still downloaded each time, so thousands of animations
means a large download.

For that case, serve the frames individually instead. Set `ART_RAW_BASE` on the
device to the repository root:

```sh
ART_RAW_BASE="https://raw.githubusercontent.com/you/kindle-screensaver/main"
```

Then only the active animation's frames are fetched — a few kilobytes, however
many animations the repo holds. `config.json` still decides which one.

## manifest.json

```json
{
  "format": "kindle-dashboard-animation",
  "version": 1,
  "name": "bird",
  "screen": { "width": 600, "height": 800 },
  "frame": { "width": 420, "height": 320, "x": 90, "y": 240 },
  "count": 8,
  "delay_ms": 120,
  "loop": "continuous",
  "palette": "1-bit",
  "preview": "preview.png"
}
```

| Field | Meaning |
|---|---|
| `format` | Always `kindle-dashboard-animation`. Lets tools recognise the folder. |
| `version` | Format version. Currently `1`. |
| `name` | Informational; the folder name is what actually identifies the set. |
| `screen` | The panel size. **Always 600 × 800** for this device. |
| `frame.width` / `frame.height` | The size of every PNG in the folder. They must all match. |
| `frame.x` / `frame.y` | Where the frame's top-left corner is placed on the screen. |
| `count` | How many frames. Must equal the number of PNGs present. |
| `delay_ms` | Target gap between frames. 120 ≈ 8 fps requested. |
| `loop` | `continuous`, or `burst` to flap briefly then hold a still frame. |
| `palette` | `1-bit` (black and white only) or `grey16` (16 dithered levels). |
| `preview` | Optional filename of the preview image. Omit if you have none. |

Every field except `name` and `preview` is required.

## Frames

- **PNG, 8-bit greyscale.** ~1.5–3 KB each at typical sizes.
- **All frames the same size**, matching `frame.width`/`frame.height`.
- **Named `frame_000.png`, `frame_001.png`, …** Zero-padded to three digits.
  The player sorts them by name, so padding is what keeps the order right.
- **Start at 000 and do not skip numbers.** Gaps are fine but confusing.
- **6–12 frames per cycle** is the useful range. See the speed note below.

### Draw in pure black and white

Use **1-bit art with no anti-aliasing** — solid black shapes on white, like a
linocut or woodblock print. This is not a style preference:

The only waveforms fast enough for animation (`A2`/`DU`) are effectively 1-bit.
Grey pixels get dithered by the panel and leave ghosting that has to be cleaned up
with a periodic full-screen flash. Soft edges and gradients look worse *and*
animate worse. Bold solid shapes look best on this screen.

If you really need greys, set `"palette": "grey16"` — it works, but expect more
ghosting and a visible de-ghost flash.

### Why frames are not usually full-screen

This is the part that surprises people, so it is worth explaining.

`frame.width`/`frame.height` is the size of the artwork itself, and `frame.x`/
`frame.y` is where it sits on the 600 × 800 panel. Those are often **not** 600 × 800,
on purpose:

**The panel only refreshes the rectangle the image occupies.** A 420 × 320 frame
covers about 28% of the panel, so it redraws roughly 3–4× faster than a full-screen
image would. For animation, that difference is the whole game.

So a smaller frame around your subject is the fast path, and the rest of the screen
simply keeps whatever is already there (the dashboard clears it to white first).

**If you would rather think in full-screen frames, you can.** Make the PNGs
600 × 800 and set:

```json
"frame": { "width": 600, "height": 800, "x": 0, "y": 0 }
```

That is a completely valid animation and easier to design, because what you draw
is exactly what appears. It is just slower, because every frame repaints the whole
panel. Try both and see whether the speed is acceptable to you.

## Speed, honestly

E-ink cannot do video. Realistically the panel manages **roughly 5–10 fps**, and
often less. That is a property of the hardware, not of your frames.

Consequences for design:

- **8 frames ≈ one second per cycle.** A slow, deliberate flutter, not a flutter.
- **More frames do not buy smoothness.** 24 frames will not look like 24 fps; they
  will just make one cycle take three times as long.
- **Design for a slow, weighty motion.** That reads well. Fast, twitchy motion
  reads as broken.
- `delay_ms` is a *request*. The log records the real rate:
  `anim: loop 12 took 3s (8 frames, ~375ms per frame)`.

A periodic full-screen flash clears ghosting (`ANIM_DEGHOST_SECONDS`, default 120).
It is visible and it is normal.

## Making frames

From an animated GIF or a folder of images:

```powershell
# from a GIF, cropping a region out of each 600x800 frame
powershell -File tools\make-animation.ps1 -Source bird.gif -Crop 180,420,420,320 -OutDir artwork\bird

# from frames you drew, resizing them to the frame size
powershell -File tools\make-animation.ps1 -Source myframes\ -Width 420 -Height 320 -OutDir artwork\bird
```

The tool writes the PNGs, the `manifest.json`, and `preview.png` for you — so you
do not have to hand-write the manifest.

Useful options: `-Threshold` (how dark a pixel must be to become black),
`-Invert` (for light-on-dark art), `-EveryNth` (drop frames to slow a GIF down),
`-MaxFrames`, and `-Preview` to write the side-by-side image.

## Checking a set

```powershell
powershell -File tools\check-artwork.ps1 artwork\bird
```

Reports, in plain terms: is the manifest valid, do the frames match what it claims,
are they all the same size, are they actually PNGs, and does the count add up. Run
it before sharing an animation with anyone.

## A minimal working example

```
artwork/pong/
├── manifest.json
├── frame_000.png     (600x800, a ball at the left)
├── frame_001.png     (600x800, a ball in the middle)
└── frame_002.png     (600x800, a ball at the right)
```

```json
{
  "format": "kindle-dashboard-animation",
  "version": 1,
  "name": "pong",
  "screen": { "width": 600, "height": 800 },
  "frame": { "width": 600, "height": 800, "x": 0, "y": 0 },
  "count": 3,
  "delay_ms": 200,
  "loop": "continuous",
  "palette": "1-bit"
}
```

That is a complete, valid animation: three full-screen frames, shown in order.
