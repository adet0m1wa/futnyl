# Futnyl

A desktop turntable that follows Spotify (short for "futuristic vinyl"). Built from `../rive` (the Rive file) and this Swift package.

## Build

```bash
rive ../rive --publish     # signed futuristicvinyl.riv (scripts must be signed)
./build-app.sh             # -> dist/Futnyl.app
./build-app.sh --zip       # also dist/Futnyl.zip for sharing
```

## Use

- ⌘-drag (or ⌥-drag) the vinyl to move it.
- Right-click the vinyl (or use the menu bar disc icon): size, float above windows,
  trackpad haptics, reset position, quit.
- First run asks to let Futnyl control Spotify (needed for the buttons and album art).

## How it syncs

- Spotify → vinyl: Spotify's `com.spotify.client.PlaybackStateChanged` notifications
  drive `isPlaying`, track changes and `progress` (the tonearm).
- Futnyl → Spotify: the keys fire view-model triggers; the app sends AppleScript
  commands and a trackpad haptic.
- Album art goes onto the hidden record, then `showingRecordB` toggles to swap it in.
  When a key started the change, Rive already swapped, so the art goes on the visible record.
  Covers are shown whole: the largest square that fits the round label, on a colour from the art's edges.
- Back: past 3 s Spotify restarts the song, so the record rewinds to 0° (lasting as long as
  Spotify takes to restart); otherwise the records swap to the previous song.
- Presses made in Spotify are mirrored on the keys (`showPlayPress`, `showNextPress`,
  `showBackPress`); restarts and seeks are caught by checking the position every 2 s.

## Debugging

`VINYL_DEBUG=1` logs every sync decision and enables a test hook: post the distributed
notification `com.adetomiwa.vinyl.debug` with object `click:x,y` (artboard units) to click.
