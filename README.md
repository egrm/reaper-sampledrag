# SampleDrag

REAPER extension that fixes drag-and-drop from the timeline into third-party sampler plugins on macOS. Hit a shortcut, click an item, drag it into your sampler.

## Install

1. Download `reaper_sampledrag-arm64.dylib` from [Releases](https://github.com/egrm/reaper-sampledrag/releases).
2. Copy it to your REAPER resource path under `UserPlugins/`. On macOS this is usually `~/Library/Application Support/REAPER/UserPlugins/`.
3. Restart REAPER.
4. Open the Actions list (`?`), search for "SampleDrag: Arm drag from timeline", bind a shortcut.

## Usage

1. Press your shortcut. Cursor becomes a crosshair.
2. Click an audio item on the timeline.
3. Drag to your sampler plugin and drop.

Escape or clicking empty space cancels.

Cropped and split items render only the visible portion. Items with take FX render with FX baked in. Items that cover their full source file skip rendering entirely.

Rendered files go into your project's Media folder as `<name>_sd_1.wav`, `<name>_sd_2.wav`, etc. Sample rate, bit depth, and channel count match the source.

---

## Background

REAPER's FX chain window intercepts all drag-drop events on macOS. Only ReaSamplOmatic5000 and ReaVerb are exempt. Every third-party sampler is affected. Broken since at least 2022, unfixed as of REAPER 7.67.

On top of that, REAPER doesn't create new files when you split or trim items. It stores offset and length into the original source. So even if drag-drop worked, your sampler would get the full recording instead of the cropped slice.

SampleDrag works around both problems. It renders the visible item portion, then uses `SWELL_InitiateDragDropOfFileList` to start a native macOS drag session that bypasses the FX chain interception entirely.

## Building from source

macOS ARM64 only. Requires Xcode Command Line Tools.

```bash
git clone --recurse-submodules https://github.com/egrm/reaper-sampledrag.git
cd reaper-sampledrag
make
make install
```

`make install` copies the dylib to `~/Applications/REAPER/UserPlugins/` by default. Override with `make install INSTALL_DIR=/your/path/UserPlugins`.

For a debug build with console logging: `make debug`.

## License

MIT
