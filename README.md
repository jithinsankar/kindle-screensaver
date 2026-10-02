# Kindle screensaver animations

Frame sets for using a jailbroken Kindle as an always-on e-ink display, plus the
tools to make your own.

An "animation" here is a folder containing a `manifest.json` and a numbered
sequence of black-and-white PNGs. `fbink` has no animation player, so an animation
is literally a folder of still images replayed by a loop — as fast as e-ink allows,
which is slower than you probably expect. **[FORMAT.md](FORMAT.md) is the spec;
read that first.**

## What is in here

| Path | What it is |
|---|---|
| [`FORMAT.md`](FORMAT.md) | the format spec — start here |
| [`bird/`](bird) | a worked example: 8 frames, 420×320, drawn at (90, 240) |
| `tools/make-animation.ps1` | turn a GIF or a folder of images into a valid frame set |
| `tools/check-artwork.ps1` | validate a set before sharing it |

## Make your own

**1. Read [FORMAT.md](FORMAT.md).** The short version: pure 1-bit black and white,
6–12 frames, named `frame_NNN.png`, with a `manifest.json` describing the set.

**2. Author the frames.**

```powershell
# from an animated GIF, cropping a region out of each 600x800 frame
powershell -File tools\make-animation.ps1 -Source my.gif -Crop 180,420,420,320 -OutDir myanimation

# from frames you drew yourself, resized to the frame size
powershell -File tools\make-animation.ps1 -Source myframes\ -Width 420 -Height 320 -OutDir myanimation
```

The tool writes the frames, the `manifest.json` and a preview image, so you never
hand-write the manifest.

**3. Validate it.**

```powershell
powershell -File tools\check-artwork.ps1 myanimation
```

It reports in plain language whether the set is valid and what to fix if it is not.

**4. Share it** — open a pull request adding your folder here, or send the folder
to whoever gave you this repo.

## The design rules that actually matter

- **Pure 1-bit black and white, no anti-aliasing.** The only waveforms fast enough
  for animation are effectively 1-bit; grey pixels get dithered by the panel and
  ghost badly. Think linocut or woodblock print, not photograph.
- **6–12 frames per cycle.** The panel manages roughly 5–10 fps, so extra frames
  make the cycle *longer*, not smoother. Design slow, weighty motion.
- **Frames are usually smaller than the screen** — 420×320 here, not 600×800 —
  because the panel only refreshes the rectangle the image occupies, so a smaller
  frame is 3–4× faster. Full-screen frames work fine, they are just slower.
- A periodic full-screen flash clears ghosting. That is normal, not a fault.

## Using a set on a Kindle

Point the dashboard at a URL serving this repo and it fetches the frames at start:

```sh
ART_URL="https://codeload.github.com/jithinsankar/kindle-screensaver/tar.gz/refs/heads/main"
ART_ON_START=1
```

`codeload.github.com/<owner>/<repo>/tar.gz/refs/heads/<branch>` is the form to use;
for a pinned version, `refs/tags/<tag>`.

## About `tools/`

These two scripts are **mirrored from the main dashboard project**, which is where
they are developed. If you want to change them, change them there and copy the
result across — otherwise the two copies drift apart. They are included here so
this repo is usable on its own by someone who only has the artwork.
