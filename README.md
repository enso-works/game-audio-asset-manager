# Audio Prepare

Native macOS app for preparing game audio: grab sounds from YouTube, cut and loop them, organize them per game project, and export the whole project into your Godot or three.js asset folder.

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

## Projects

Each game gets a project in `~/Music/AudioPrepare/projects/<Name>/`:

```
<Name>/
  Inbox/                 raw downloads and imports (never exported)
  sfx/player/jump.wav    your folders, mirrored on export
  music/theme.wav
  .audioprepare/project.json   loop points, regions, sources, folder formats
```

Switch or create projects from the menu at the top of the sidebar. Drag sounds between folders, or drop files from Finder onto a folder.

Workflow: download into the Inbox, open a sound, cut it, then **Save As** (Shift Cmd S) into a project folder. **Save Regions as Sounds** splits one long recording (like an SFX pack video) into separate files.

## Export

- **Export Project** (Shift Cmd E, or the button at the bottom of the sidebar) converts every sound into the game folder, recreating the project folders. Each folder has its own format (subfolders inherit), e.g. `sfx` as WAV and `music` as OGG. "Only export changed sounds" makes re-exports fast.
  - `audio_manifest.json`: sound key to file, duration and loop points.
  - `CREDITS.md`: YouTube sources for attribution.
- **Export** (Cmd E) exports the open sound, its selection, or each region.
- **Batch Convert** (sidebar) converts any folder of audio files with one preset, keeping subfolders.

Presets: Godot SFX (WAV 16-bit mono), Godot Music (OGG), three.js SFX and Music (MP3). File and folder names are exported as `snake_case`.

## Loops

Select the part that should repeat and press **K** (Set Loop). Then:

- **Play** (P) repeats the loop; Shift P plays the intro first, like the game will.
- **Seam** plays the end of the loop into its start so you can hear the join.
- **Snap** moves loop points to zero crossings to avoid clicks.
- **Seamless** crossfades the loop's end into its start and trims the file to the loop.
- Drag the green handles in the time ruler to adjust.

In the game:

- **Godot 4**: WAV exports carry the loop points in a `smpl` chunk, so they loop automatically (Import dock Loop Mode: Detect From WAV). For OGG, tick Loop and set Loop Offset in the Import dock.
- **three.js**: read the manifest:

```js
const manifest = await (await fetch('/audio/audio_manifest.json')).json();
const info = manifest.sounds['music/theme'];
new THREE.AudioLoader().load('/audio/' + info.file, (buffer) => {
  sound.setBuffer(buffer);
  sound.setLoop(info.loop);
  if (info.loop) {
    sound.setLoopStart(info.loopStart);
    sound.setLoopEnd(info.loopEnd);
  }
  sound.play();
});
```

MP3 adds a few ms of silence at both ends, so use OGG or WAV for loops.

## YouTube

- **Paste Links**: one per line. Add a time range after a link to download only that part: `https://youtu.be/abc 1:30-2:05`.
- **Search YouTube**: search in the app, then download a result directly or add it to the links box to set a time range.
- The source link, title and channel are saved with each sound and end up in `CREDITS.md`. Check each source's license before shipping.

If downloads start failing, update yt-dlp: `brew upgrade yt-dlp`.

## Shortcuts

| Key | Action |
| --- | --- |
| Space | Play / stop (plays the selection if there is one) |
| Delete | Delete selection |
| T / Cmd T | Trim to selection |
| R | Add region from selection |
| K | Set loop from selection |
| P / Shift P | Play loop / play intro then loop |
| I / O | Fade in / fade out |
| N | Normalize |
| L | Toggle loop playback of the selection |
| Esc | Stop, then clear selection |
| Return | Cursor to start |
| Cmd A | Select all |
| Cmd = / Cmd - / Cmd 0 | Zoom in / out / fit |
| Cmd Z / Shift Cmd Z | Undo / redo |
| Cmd S / Shift Cmd S | Save / Save As into a project folder |
| Cmd E / Shift Cmd E | Export sound / export project |

Mouse: drag to select, drag selection edges to adjust, shift-click to extend, double-click a region to select it, scroll vertically to zoom, horizontally to pan, pinch to zoom.
