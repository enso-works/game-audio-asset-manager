# Roadmap: from sound editor to game audio manager

**Status:** phase 1 (events and buses) is done; the rest is proposed.

Today Game Audio Asset Manager manages sound **files**: it cuts them, cleans them and exports them. A game also needs to know how each sound **plays**:

- which variant to pick, and at what pitch and volume;
- which mixer bus it goes through;
- which sounds layer together to form a place;
- how the music moves between sections;
- whether all of that is consistent.

The goal is for the project to become the single source of truth for all of that, exported as native engine resources instead of hand-written glue code.

Godot 4.7, which is installed here, has native resources for all of it: `AudioStreamRandomizer`, `AudioBusLayout`, `AudioStreamInteractive`, `AudioStreamSynchronized` and `AudioStreamPlaylist`, plus bus effects. For three.js we generate a small typed runtime helper.

## 1. Sound events

An **event** is what the game triggers, for example `player/jump`. It is not a file.

| Setting | Example |
| --- | --- |
| Sounds | `jump_01`, `jump_02`, `jump_03` (drag from the tree, or a whole group) |
| Playback | random, random without repeating the last one, sequence |
| Pitch / volume randomization | ±2 st, -3 to 0 dB (the Game Preview already does this) |
| Bus | `SFX/Player` |
| Limits | at most 3 instances, 80 ms cooldown |
| 3D | attenuation, max distance, unit size (for `AudioStreamPlayer3D` / `PositionalAudio`) |

**In the app:**

- An **Events** section in the sidebar.
- An event editor with an **Audition** button that plays the event the way the game will.
- Variation groups (`jump_01`...) can become events in one click.

**Export:**

- **Godot:** one `AudioStreamRandomizer` `.tres` per event (playback mode, `random_pitch`, `random_volume_offset_db`, weighted streams). `Sounds.play("player/jump", player)` sets the bus and limits.
- **three.js:** events in the manifest, plus a generated `SoundEvents.ts` that picks variants, applies random pitch and volume, routes to the bus's gain node, and respects instance limits and cooldowns.

## 2. Buses and mixing

A mixer tree for the project:

```
Master
├── Music
├── Ambience
├── SFX
│   ├── Player
│   ├── UI
│   └── World
└── Voice
```

- Each bus has a volume, and can have effects (low-pass, reverb send, compressor).
- **Ducking rules**, for example "Voice plays: Music -8 dB over 150 ms".
- Folders map to buses by default (`sfx/ui` → `SFX/UI`), and an event can override that.

**Mix view:** press play on a *scene* (a music cue plus an environment plus events firing on a timer or on keys) and adjust faders while listening. It shows live meters (short-term LUFS and true peak) per bus, so levels are set by ear once instead of guessed in code.

**Export:**

- **Godot:** `default_bus_layout.tres` (`AudioBusLayout` with bus names, volumes, sends and effects), plus a small ducking script.
- **three.js:** a `createMixer(listener)` helper that builds the gain-node tree with the same volumes and a ducking helper.

## 3. Environments

An **environment** is a named soundscape, such as `forest_day`, `cave` or `city_night`:

| Layer | What it does |
| --- | --- |
| Beds | 1-3 looping layers (wind, room tone, distant traffic) with their own volume and a crossfade on start and stop |
| One-shots | random details (bird call every 4-12 s, random pan and volume, never twice in a row) |
| Space | reverb preset and wet level applied to the Ambience and SFX buses while you're in it |
| Music | optional music cue |
| Transitions | crossfade time into and out of other environments |

**In the app:**

- An **Environments** section.
- A **live preview** that runs the environment with its randomized one-shots, and lets you switch between environments to hear the transitions.
- Existing tools feed it: **Auto-Split** pulls one-shots out of a field recording, and **Seamless** makes long beds loop.

**Export:**

- **Godot:** beds as `AudioStreamSynchronized` resources, one-shots as `AudioStreamRandomizer` resources, plus a generated `AmbiencePlayer.gd` node. Call `set_environment("cave")` and it crossfades beds, schedules one-shots and switches the reverb.
- **three.js:** an `AmbiencePlayer.ts` helper with the same API.

## 4. Matching: project health

A **Health** view that audits every sound against rules per folder or bus:

| Check | Default rule for SFX | Fix |
| --- | --- | --- |
| Loudness | -16 LUFS ±2 | Normalize to target |
| True peak | ≤ -1 dBTP | Limit |
| Leading silence | ≤ 10 ms | Trim silence |
| Channels / rate | mono, 44.1 kHz | Convert on export |
| DC offset, clipping | none | Remove DC, flag clipping |
| Loop seam | no jump at the seam | Snap to zero / make seamless |
| Noise floor | below -60 dB | Denoise |

Each rule applies to all sounds in its folder or bus.

- **One-click batch fixes**, which are undoable per file.
- **Match to reference:** pick a sound that sounds right and bring others to its loudness and tone (a matching EQ curve via spectral averages).
- **Duplicates and near-duplicates:** detected with audio fingerprints.
- **Unused sounds:** keys from `sounds.ts` / `sounds.gd` that never appear in the game's source folder.
- **Budget:** total size on disk and decoded memory, split by format and folder.

## 5. Adaptive music

A **music cue** built on the tempo grid we already have:

- **Sections:** intro, loop A, loop B, outro, stingers. Mark them on bar boundaries.
- **Transitions:** "A → B at the next bar, crossfade 1 beat", "any → outro at the next phrase".
- **Layers (stems)** that fade in with an intensity parameter, for example drums at intensity > 0.5.

**Export:**

- **Godot:** `AudioStreamInteractive` (clips and a transition table synced to beats and bars) and `AudioStreamSynchronized` (stems).
- **three.js:** `MusicPlayer.ts` that schedules sections on `AudioContext` time with sample-accurate bar boundaries.

## 6. Smaller items

- **Save Selection As:** save just the selected part as a new sound in one step.
- **Batch process a folder:** run normalize, trim silence or denoise on every sound in a folder.
- **Spatial preview:** hear an event at distance with the export's attenuation curve.
- **Dashboard:** counts, sizes, missing credits, export status per project.
- **Autosave / recovery** for unsaved edits.
- **Voice and dialogue** (later): line IDs, subtitles, per-language folders.

## Data model

Everything above lives in `project.json`, next to what's already there:

```jsonc
{
  "buses": [{ "path": "SFX/Player", "volumeDb": -3, "effects": [], "sends": {"Reverb": -12} }],
  "ducking": [{ "when": "Voice", "duck": "Music", "byDb": -8, "attackMs": 150, "releaseMs": 400 }],
  "events": {
    "player/jump": {
      "sounds": ["sfx/player/jump_01.wav", "sfx/player/jump_02.wav"], "mode": "randomNoRepeat",
      "pitch": 2, "volumeDb": [-3, 0], "bus": "SFX/Player", "maxInstances": 3, "cooldownMs": 80
    }
  },
  "environments": {
    "forest_day": {
      "beds": [{ "sound": "ambience/wind.wav", "volumeDb": -6 }],
      "oneShots": [{ "sounds": ["ambience/bird_01.wav"], "everySec": [4, 12], "pan": 0.8 }],
      "reverb": { "preset": "mediumHall", "wet": 20 }, "crossfadeSec": 3
    }
  },
  "music": {
    "exploration": {
      "sections": [{ "name": "A", "bars": [1, 8] }],
      "transitions": [{ "from": "A", "to": "B", "at": "nextBar", "fadeBeats": 1 }]
    }
  },
  "rules": { "sfx": { "lufs": -16, "tolerance": 2, "maxLeadingSilenceMs": 10, "channels": 1 } }
}
```

## Suggested order

| Phase | Scope | Why first |
| --- | --- | --- |
| 1 | ✅ **Events + buses** with Godot `AudioStreamRandomizer` / `AudioBusLayout` export and a Web Audio engine (3D included) | Everything else (environments, mix, music) builds on events and buses |
| 2 | **Health and matching** | Makes existing sounds consistent before building on them; mostly reuses tools we already have |
| 3 | **Environments** with live preview | The biggest win for how a game *feels* |
| 4 | **Mix view** with ducking and meters | Needs events, buses and environments to be meaningful |
| 5 | **Adaptive music** | Builds on the tempo grid; most complex |

Each phase ends the same way:

- Unit tests.
- Generated Godot resources loaded and played in a headless Godot project.
- Generated TypeScript checked with `tsc --strict`.

## Decisions

- Godot 4.3 or newer, so `AudioStreamInteractive` and `AudioStreamSynchronized` can be used for music.
- The web side uses raw Web Audio (no Howler or React Three Fiber); the generated `audio_engine.ts` has no dependencies.
- Positional (3D) audio is supported from phase 1.

## Open question

Which environments does the current game need first? Real examples keep phase 3 focused.
