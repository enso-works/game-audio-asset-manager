# Changelog

## 0.1.0

The first public release.

### Added
- **Download**: search YouTube inside the app, or paste a batch of links. Add a time range such as `1:30-2:05` to download only that part. Sources are saved for `CREDITS.md`.
- **Edit**: a waveform and spectrogram editor with trim, fades, gain, normalize, reverse, low and high cut, **denoise**, remove DC, mono, pitch and speed, reverb and compression. Undo covers everything.
- **Cut and loop**: auto-split sound packs by silence, regions, loop points written into the WAV `smpl` chunk, snap to zero crossings, seamless crossfaded loops, and tempo detection with bar-length loops.
- **Projects**: one project per game, with folders that mirror the game's sound folders.
- **Sound events and mixer buses**: variants with weights, random pitch and volume, polyphony limits, cooldowns and 3D falloff, auditioned the way the game will play them.
- **Export**: mirrors project folders into the game with a format and loudness target per folder. It writes a manifest, credits, audio sprites, `sounds.gd`, Godot `AudioStreamRandomizer` and `AudioBusLayout` resources, `sounds.ts`, and a dependency-free Web Audio engine (`audio_engine.ts`) with 3D audio. Auto-export on save is optional.
- Single-key shortcuts for every tool, with hover cards that explain each one.
- The app is signed with a Developer ID and notarized, and ships as a universal (Apple Silicon and Intel) DMG and zip.
- Automatic updates via Sparkle, with **Check for Updates** in the app menu and a toggle in Settings.
- Homebrew cask: `brew install --cask enso-works/tap/game-audio-asset-manager`.
