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

## Editing

- **Cut**: trim to selection, delete, silence, trim silence at both ends.
- **Process**: fades, gain, normalize, reverse.
- **Filter**: Low Cut removes rumble and hum, High Cut removes hiss (24 dB/octave).
- **Auto-Split** (Regions panel): finds every sound in a pack by silence. Adjust threshold, minimum gap, minimum length and padding while the matches are outlined on the waveform, then create regions in one click.
- **Game**: **Preview** plays the sound 6 times with random pitch and volume, like a game would. **Variations** saves pitched copies (`jump_01` ... `jump_05`, evenly spread over ±N semitones) so the game can pick one at random. Pitch changes speed too, like Godot's `pitch_scale` and three.js `playbackRate`, unless you tick "Keep original length".

- **View** (W): waveform, spectrogram (log frequency, 30 Hz to Nyquist), or both stacked. The spectrogram helps spot hum, hiss and where a sound really starts.
- **Clipboard**: Cmd C / Cmd X / Cmd V copy, cut and paste audio, also between files (rate and channels are converted).

Processing applies to the selection, or to the whole sound when nothing is selected.

## Export

- **Export Project** (Shift Cmd E, or the button at the bottom of the sidebar) converts every sound into the game folder, recreating the project folders. Each folder has its own format (subfolders inherit), e.g. `sfx` as WAV and `music` as OGG. "Only export changed sounds" makes re-exports fast.
  - `audio_manifest.json`: sound key to file, duration and loop points.
  - `CREDITS.md`: YouTube sources for attribution.
- **Export** (Cmd E) exports the open sound, its selection, or each region.
- **Batch Convert** (sidebar) converts any folder of audio files with one preset, keeping subfolders.

Presets: Godot SFX (WAV 16-bit mono), Godot Music (OGG), three.js SFX and Music (MP3). File and folder names are exported as `snake_case`.

**Loudness matching**: set a LUFS target per folder (e.g. -16 for `sfx`, -20 for `music`) so everything sits at the same perceived volume in the game. Each sound is measured (EBU R128) and gets one fixed gain, so its dynamics stay intact; true peaks are capped at -1 dBTP. Very short sounds are measured looped. Changing a folder's format or loudness marks its sounds as changed for the next export.

## Loops

Select the part that should repeat and press **K** (Set Loop). Then:

- **Play** (P) repeats the loop; Shift P plays the intro first, like the game will.
- **Seam** plays the end of the loop into its start so you can hear the join.
- **Snap** moves loop points to zero crossings to avoid clicks.
- **Seamless** crossfades the loop's end into its start and trims the file to the loop.
- Drag the green handles in the time ruler to adjust.
- **Tempo** (Loop row): detects BPM and the downbeat, draws a beat grid with bar numbers, and sets or snaps the loop to a whole number of bars so music loops stay in time. BPM is saved with the sound and written to the manifest.

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

Press **?** in the editor (or Help > Keyboard Shortcuts, Cmd /) for the full list. Highlights:

| Key | Action |
| --- | --- |
| Space | Play / stop |
| C or Delete | Cut the selection out |
| T / Shift T | Trim to selection / trim silence |
| S | Silence selection |
| Cmd C / X / V | Copy / cut / paste audio |
| [ / ] | Selection start / end at the playhead (works while playing) |
| ← → (Shift) | Move cursor 100 ms (1 s) |
| , / . | Previous / next region |
| I / O / N | Fade in / fade out / normalize |
| = / - | Louder / quieter |
| V / B / H | Reverse / low cut / high cut |
| R / Shift R | Add region / auto-split |
| K / Shift K | Set / clear loop |
| P / Shift P | Play loop / intro then loop |
| J / Z / M | Hear seam / snap to zero / make seamless |
| G / Shift G | Game preview / variations |
| W | Waveform, spectrogram, both |
| L | Loop playback |
| Esc | Stop, then clear selection |
| Cmd Z / Cmd S / Cmd E | Undo / save / export |

Mouse: drag to select, drag selection edges to adjust, shift-click to extend, double-click a region to select it, scroll vertically to zoom, horizontally to pan, pinch to zoom.
