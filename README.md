# SampleDrag

A REAPER extension that lets you drag audio items from the timeline into third-party sampler plugins on macOS.

## The Problem

REAPER's FX chain window intercepts all drag-drop events on macOS. When you try to drag audio onto a plugin, the FX chain grabs the event before the plugin sees it. Only REAPER's own ReaSamplOmatic5000 and ReaVerb are exempt. Every third-party sampler (Kontakt, TAL-Sampler, Vital, Redux, etc.) is affected. This has been broken since at least 2022 and remains unfixed as of REAPER 7.67.

On top of that, REAPER stores trimmed/split items as offset+length references into source files. Splitting an item doesn't create a new file. So even if drag-drop worked, the sampler would receive the full original recording, not the cropped portion you see on the timeline.

SampleDrag fixes both problems.

## How It Works

1. **Hit your shortcut** (no item needs to be selected). Your cursor changes to a crosshair.
2. **Click on any audio item** on the timeline. SampleDrag renders the visible portion to a standalone WAV and initiates a native macOS drag.
3. **Drag to your sampler** and drop.

Press **Escape** to cancel the armed state. Clicking on empty space also cancels.

### What gets rendered

- **Cropped/split items**: Renders only the visible portion to a new WAV file in your project's Media folder. Matches the source sample rate, bit depth, and channel count.
- **Full-file items** (no trimming): Uses the original source file directly. No render, no delay.
- **Items with take FX**: Renders with FX baked in using REAPER's own render pipeline, then undoes the action to keep your project clean. The rendered file stays on disk.

## Requirements

- macOS (Apple Silicon)
- REAPER 7.x
- Xcode Command Line Tools (for building)

## Building from Source

```bash
git clone --recurse-submodules https://github.com/egrm/reaper-sampledrag.git
cd reaper-sampledrag
make
make install
```

The `install` target copies the dylib to `~/Applications/REAPER/UserPlugins/`. Override with:

```bash
make install INSTALL_DIR=/path/to/REAPER/UserPlugins
```

### Binding a Shortcut

1. Restart REAPER after installing.
2. Open the Actions list (`?` key or Actions > Show action list).
3. Search for **"SampleDrag"**.
4. Select "SampleDrag: Arm drag from timeline" and click "Add shortcut."
5. Press your preferred key combo.

## File Output

Rendered files go into your project's recording path (usually the `Media/` folder). They are named `sampledrag_<itemname>_001.wav`, `sampledrag_<itemname>_002.wav`, etc. The suffix auto-increments to avoid overwriting anything.

These files travel with your project. REAPER's "File > Clean current project directory" can remove unused ones later.

For unsaved projects, rendered files go to the system temp directory.

## Limitations

- macOS ARM64 only (Apple Silicon). No Windows or Linux support.
- Single item drag only (no batch/multi-item).
- Items with take FX briefly show REAPER's render progress dialog during the render step.

## How It Works (Technical)

SampleDrag is a native REAPER C++ extension compiled as an Objective-C++ dynamic library. It:

1. Registers an action via `plugin_register("gaccel", ...)`.
2. On trigger, installs NSEvent local monitors for mouse-down and key-down.
3. On mouse-down, calls REAPER action 40528 ("Select item under mouse cursor") to find the target item.
4. Reads the item's PCM_source to render the cropped audio region to a WAV file. For items with take FX, it uses REAPER action 40209 ("Apply FX to items as new take") followed by an undo.
5. Calls `SWELL_InitiateDragDropOfFileList` to start a native macOS drag session with the rendered file.
6. The user completes the drag by moving to the plugin and releasing.

## License

MIT
