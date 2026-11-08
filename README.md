# Song Creator

A native macOS multitrack recorder for getting a song down in one sitting: record an idea, overdub takes, mix it and export it. It's built around single-key shortcuts, like a hardware recorder, so you can keep your hands on your instrument.

## Features

**Recording**
- Audio from any interface or mic, MIDI from any device, and audio file import
- Non-destructive takes and comping, with punch in/out, count-in and a click
- Old takes go quiet while you record over them
- Loop recording, and **Jam mode**: solo as one long take over a loop, and the loop is pasted out to fill the whole take
- Optionally arm the next new track after each take, moving input monitoring along with it
- A tuner, plus feedback protection that keeps your input from playing through the laptop speakers

**MIDI**
- Instrument plug-ins (Audio Units) or outboard gear through a MIDI interface
- Use the computer keyboard as a MIDI keyboard (⌘K)
- Non-destructive quantize

**Arranging and mixing**
- Regions with split, copy, paste, duplicate, fades and automatic crossfades
- Loop and punch ranges you can drag, section markers, undo and redo
- A channel strip on every track (EQ, compressor, a send to each effect bus), plus Audio Unit effects
- Effect buses with their own Audio Unit effects and return faders: new songs start with a Reverb and a
  tempo-synced Delay bus, and you can add as many as you like (older songs keep their reverb and delay as buses)
- Audio Unit effects on the master too, before the master fader and limiter
- A resizable mixer (drag its top edge, or ⇧X to fill the window) that shows more effects as it grows
- Automation for any setting: volume, pan, mute, solo, EQ, compressor, sends and plugin parameters on each track, plus a Master row for the master fader, limiter, bus returns and their plugins
- A master limiter
- Offline mixdown to WAV (16 or 24 bit) or AAC, named with the date and time

**Song management**
- A song list with projects and multi-select
- Save a song's setup as the default for new songs
- Songs are plain folders in `~/Music/Song Creator/`, and each song remembers its zoom

## Install

Requires macOS 15 or later, on Apple Silicon or Intel.

1. Download `Song-Creator-1.0.0.zip` from the [latest release](https://github.com/koostix/song-creator/releases/latest).
2. Unzip it and move **Song Creator** to Applications.
3. Open it. The first time, macOS blocks it because the app isn't notarized (that takes a paid Apple Developer membership):
   - Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
   - Or remove the download flag in Terminal:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Song Creator.app"
   ```

4. Allow microphone access when asked. Without it, takes record silence.

You can also build it yourself from this source, which avoids the warning.

## Getting started

Press `T` to add an audio track, `A` to arm it, then `R` to record and `R` again to stop. Use headphones when you overdub, so the backing tracks don't bleed into the mic.

| Key | Action | Key | Action |
| --- | --- | --- | --- |
| Space | Play / stop | R | Record (again to stop) |
| Return | Go to start | ← → | Move a bar |
| ⌥← ⌥→ | Previous / next section | 1–9 | Jump to section |
| L / ⇧L | Loop on/off / loop selection | J | Jam over the loop |
| P / ⇧P | Punch on/off / punch selection | C | Click on/off |
| ⇧M | Add section marker | A M S | Arm / mute / solo track |
| B | Split at playhead | ⌘C ⌘V ⌘D | Copy / paste / duplicate regions |
| T / ⇧T | New audio / MIDI track | Z | Zoom to fit |
| ⌘K | Computer keyboard as MIDI | X / ⇧X | Mixer / mixer fills the window |
| ⌘E | Export mixdown | = / − | Zoom in / out (or pinch, ⌘-scroll) |
| ⌫ | Delete selected regions | Esc | Clear selection |
| ⌘Z ⇧⌘Z | Undo / redo | Tab | While renaming: next track |
| ⌘, | Audio settings | | |

## Known limits

- No plug-in delay compensation, so a high-latency plug-in will sound late against other tracks.
- No MP3 export.
- Outboard MIDI gear isn't captured in a mixdown. Record its audio to a track first.
- The app isn't notarized, so the first launch needs the steps above.
- Tested on Apple Silicon. The Intel code has only been run under Rosetta, not on an Intel Mac.

## Build from source

You'll need Xcode 16 or later. There are no third-party dependencies.

```bash
git clone https://github.com/koostix/song-creator.git
```

Then open `SongCreator.xcodeproj` and run it, or build and install a Release copy to `/Applications`:

```bash
scripts/install.sh
```

The Xcode project is generated from `project.yml`. If you change that file, regenerate the project with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

### Tests

A Debug build has a self-test that covers the model, rendering, recording and export:

```bash
xcodebuild -project SongCreator.xcodeproj -scheme SongCreator -configuration Debug -derivedDataPath build build
```

```bash
build/Build/Products/Debug/SongCreator.app/Contents/MacOS/SongCreator --selftest /tmp/song-creator-selftest
```

Any build, including the installed app, can also check the real audio setup. Each of these writes a report to the file you name:

- `--diagnose <file>` lists the audio devices and checks that input arrives
- `--smoketest <file>` runs the audio settings and recording paths
- `--plugintest <file>` loads and runs the installed Audio Units

```bash
open -n -a "/Applications/Song Creator.app" --args --smoketest /tmp/song-creator-smoke.txt
```

## License

[MIT](LICENSE)
