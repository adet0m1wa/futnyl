# Futnyl

A desktop turntable that follows Spotify (short for "futuristic vinyl"). Built from `../rive` (the Rive file) and this Swift package.

## Build

```bash
rive ../rive --publish     # signed futuristicvinyl.riv (scripts must be signed)
./build-app.sh             # -> dist/Futnyl.app
./build-app.sh --zip       # also dist/Futnyl.zip for sharing
./build-app.sh --dmg       # also dist/Futnyl.dmg with an Applications shortcut
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
- A track change swaps the records immediately. The incoming record has a neutral
  label until its art arrives. `hostManagesCovers` gives the native host ownership
  of cover opacity so the Rive script cannot reveal an old cover. Requests are
  cancelled on skips and checked against the current change before applying.
  Decoded covers and album URLs are cached; covers are centre-cropped to a square.
- Back: past 3 s Spotify restarts the song, so the record rewinds to 0° (lasting as long as
  Spotify takes to restart); otherwise the records swap to the previous song.
- Presses made in Spotify are mirrored on the keys (`showPlayPress`, `showNextPress`,
  `showBackPress`); restarts and seeks are caught by checking the position every 0.25 s.

## Debugging

`VINYL_DEBUG=1` logs every sync decision and enables a test hook: post the distributed
notification `com.adetomiwa.vinyl.debug` with object `click:x,y` (artboard units) to click.

## Lyrics and themes

`NowPlayingModel` receives snapshots separately from the menu status text. It
fetches lyrics only while inline lyrics are enabled, cancels obsolete requests, and caches
successful results in memory. `LyricsCore` handles the LRCLIB request and LRC
parsing independently of Rive. It validates title, artist, album (when supplied),
and duration within two seconds; a guarded search can recover an unusable exact
result. After LRCLIB fails or supplies no usable timing, `CommunityLyricsClient`
requests the AMLL LRC file for the exact Spotify track ID. Local tracks and invalid
IDs never create community requests. Both sources use the same parser and playback
clock; source changes do not restart that clock. The cache includes track identity. Single-zero placeholders, untimed lyrics and out-of-range timestamps are
rejected. See [LYRICS-RESEARCH.md](LYRICS-RESEARCH.md) for source limitations. Run `swift test` from this directory for parser,
seek-boundary and query tests. The compact view derives its line from the
extrapolated Spotify position, so pauses and seeks do not need a second clock.
Line navigation sends an identity-checked Spotify seek command.

`Appearance.swift` supplies the light/dark palette for bound surface colours in
`scene.rml`. Changing appearance updates the existing view model without reloading
Rive or restarting playback. The record artwork itself is never recoloured.

Rive checks: `rive ../rive --verify`, or render with
`rive ../rive --screenshot=build/preview.png --advance=60`. The app bundle still
requires the existing signed `--publish` build and a logged-in Rive CLI.

## Single-widget layouts

`WidgetLayout` keeps both modes square and the same height. The Rive view and
state machine stay alive across toggles. Numeric view-model bindings shrink and
reposition the current record; the body, speakers, waves and playback keys keep
their original geometry. In lyrics mode the tonearm/storage overlay is hidden,
and the script hides the spare record while continuing to spin the current one.
The small record and song title share a centered top row, with vertically centered lyrics beneath and
a larger return-to-turntable button.

`InlineLyricsView` and `LyricsToggle` are transparent native controls inside the
same device. There is no metadata footer or lyrics window. The original state
label binds to `songTitle`, using a smaller font and a Unicode-safe shortened
label; the full title stays in the widget tooltip and inline heading. State
animations no longer overwrite the title or its font.

Set `FUTNYL_RIV_TEST_PATH` to the signed asset in `dist/Futnyl.app/Contents/Resources`
when running `swift test` to verify native script execution and switching layouts.
Optional `FUTNYL_PREVIEW_SCENE_DIR` supplies rendered `normal-light.png`,
`normal-dark.png`, `lyrics-light.png` and `lyrics-dark.png` backgrounds for native
composite screenshots in the test runner’s temporary `FutnylPreviews` folder.

Set `FUTNYL_LIVE_LYRICS_TESTS=1` and filter `LiveLyricsTests` to exercise four
public song fixtures against LRCLIB and one public Spotify-ID fixture against AMLL. This opt-in test sends only those fixture
metadata, never the user's current Spotify playback. Default tests use mocked
HTTP responses to cover wrong versions, artists, albums, durations, timestamps,
network failures and guarded search recovery.

A Google search link is shown only when timed lookup fails. It opens a normal
browser search on click; the app never fetches snippets or invents timestamps for
plain lyrics. Source attribution follows the document that actually loaded.
