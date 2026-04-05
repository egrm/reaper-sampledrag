# SampleDrag

REAPER extension that fixes drag-and-drop from the timeline into third-party sampler plugins on macOS. Hit a shortcut, click an item, drag it into your sampler.

## Install

1. Download `reaper_sampledrag-arm64.dylib` from [Releases](https://github.com/egrm/reaper-sampledrag/releases).
2. Copy it to your REAPER `UserPlugins/` folder.
3. Restart REAPER.
4. Open the Actions list, search "SampleDrag", bind a shortcut.

## Usage

1. Press your shortcut. Cursor becomes a crosshair.
2. Click an audio item on the timeline.
3. Drag to your sampler plugin and drop.

Escape or clicking empty space cancels.

Items with take FX get rendered with FX baked in. Cropped items render only the visible portion. Full-file items use the source directly.

Rendered files go into your project's Media folder as `<name>_sd_1.wav`, `<name>_sd_2.wav`, etc.

---

## Background

REAPER's FX chain window intercepts all drag-drop events on macOS. Only ReaSamplOmatic5000 and ReaVerb are exempt. Every third-party sampler is affected. Broken since at least 2022, unfixed as of REAPER 7.67.

On top of that, REAPER doesn't create new files when you split or trim items. It stores offset and length into the original source. So even if drag-drop worked, your sampler would get the full recording instead of the cropped slice.

SampleDrag works around both problems. It renders the visible item portion (respecting source sample rate, bit depth, and channel count), then uses `SWELL_InitiateDragDropOfFileList` to start a native macOS drag session that bypasses the FX chain interception entirely.

## Building from source

macOS ARM64 only. Requires Xcode Command Line Tools.

```bash
git clone --recurse-submodules https://github.com/egrm/reaper-sampledrag.git
cd reaper-sampledrag
make
make install  # copies to ~/Applications/REAPER/UserPlugins/
```

Override install path: `make install INSTALL_DIR=/your/path/UserPlugins`

## License

MIT
