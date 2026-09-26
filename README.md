# Audio Prepare

Native macOS app for preparing game audio: download YouTube audio as MP3 in bulk, cut and clean it up, and export clips for Godot and three.js.

## Requirements

```sh
brew install yt-dlp ffmpeg xcodegen
```

## Build and run

```sh
make run       # generate the Xcode project, build Release, launch
make install   # copy to /Applications
```

Or run `xcodegen generate` and open `AudioPrepare.xcodeproj` in Xcode.

## Features

- **YouTube to MP3**: paste many links (one per line), downloads run in parallel through yt-dlp.
- **Library** in `~/Music/AudioPrepare` (`downloads/`, `edited/`, `imported/`). Drag files onto the sidebar to import.
- **Editor**: waveform with zoom, trim to selection, delete, silence, fades, gain, normalize, trim silence, reverse, undo/redo.
- **Regions**: mark many sounds in one long file and export each as its own file.
- **Export presets**: Godot SFX (WAV), Godot Music (OGG), three.js SFX/Music (MP3). Files get game-friendly `snake_case` names.

## Shortcuts

| Key | Action |
| --- | --- |
| Space | Play / stop (plays the selection if there is one) |
| Delete | Delete selection |
| T / Cmd T | Trim to selection |
| R | Add region from selection |
| I / O | Fade in / fade out |
| N | Normalize |
| L | Toggle loop |
| Esc | Stop, then clear selection |
| Return | Cursor to start |
| Cmd A | Select all |
| Cmd = / Cmd - / Cmd 0 | Zoom in / out / fit |
| Cmd Z / Shift Cmd Z | Undo / redo |
| Cmd S | Save a WAV copy to the library |
| Cmd E | Export |

Mouse: drag to select, drag selection edges to adjust, shift-click to extend, double-click a region to select it, scroll vertically to zoom, horizontally to pan, pinch to zoom.

If YouTube downloads start failing, update yt-dlp: `brew upgrade yt-dlp`.
