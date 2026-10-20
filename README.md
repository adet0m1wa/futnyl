# Futnyl

A little turntable that sits on your Mac's desktop and follows Spotify. Songs change on the record, the tonearm tracks the song, and the keys on the front control Spotify. The name is short for "futuristic vinyl".

Free and open source. Works with Spotify.

## Install

Open Terminal and paste:

```bash
curl -fsSL https://raw.githubusercontent.com/adet0m1wa/futnyl/main/install.sh | bash
```

It downloads the latest [release](https://github.com/adet0m1wa/futnyl/releases/latest), puts `Futnyl.app` in `/Applications` and opens it. The script is [short](install.sh), so read it first if you like. You can also download `Futnyl.zip` from the releases page and drag the app anywhere. Because the app isn't notarized by Apple (that needs a paid developer account), macOS will block a browser download the first time. Right-click `Futnyl.app`, choose **Open**, then **Open** again. The Terminal install above doesn't have this step.

Needs macOS 14 or newer and the Spotify desktop app.

The first time it runs, macOS asks whether Futnyl may control Spotify. Click OK. Without that, the keys and the cover art can't work.

## Use

- **Play, pause, next, back:** click the keys on the turntable, or use Spotify as usual. Both stay in sync.
- **Seek:** drag Spotify's progress bar and the record and tonearm follow.
- **Move it:** hold ⌘ (or ⌥) and drag.
- **Size, float above windows, trackpad haptics, reset position, quit:** right-click the turntable, or use the disc icon in the menu bar.
- With Spotify closed, it shows the last song you played.

## Uninstall

```bash
pkill -x Futnyl; rm -rf /Applications/Futnyl.app ~/Applications/Futnyl.app ~/Library/Application\ Support/Vinyl; defaults delete com.adetomiwa.vinyl 2>/dev/null; tccutil reset AppleEvents com.adetomiwa.vinyl
```

That quits the app, removes it and its saved data (last song, settings), and takes back its permission to control Spotify.

## Privacy

Futnyl has no analytics. It talks to Spotify on your Mac and downloads the current cover from Spotify’s image server. When you enable lyrics, it looks up the song on LRCLIB using its title, artist, album and duration, then checks the AMLL community database by Spotify track ID if needed; see below.

## Build from source

You need the Xcode command line tools and the [Rive CLI](https://rive.app) (expected at `~/.rive/bin/rive`, or set `RIVE`).

```bash
cd app
./build-app.sh          # -> app/dist/Futnyl.app
./build-app.sh --zip    # also app/dist/Futnyl.zip
./build-app.sh --dmg    # also app/dist/Futnyl.dmg (drag to Applications)
```

`rive/` is the Rive file (the turntable, its animation and the cover/colour effects). `app/` is the Swift app that hosts it and talks to Spotify. See [app/README.md](app/README.md) for how the sync works.

## Not affiliated

Futnyl is an independent project. It is not affiliated with, endorsed by or sponsored by Spotify or any artist. Spotify is a trademark of Spotify AB.

Song titles and cover art shown in the demo video belong to their owners and appear only to demonstrate how the app works. The video is not meant to promote any artist or product, and nothing here is for sale.

## Licence

MIT, see [LICENSE](LICENSE).

Third-party: the Rive runtime ([rive-ios](https://github.com/rive-app/rive-ios), MIT) and IBM Plex Mono (SIL Open Font License 1.1, see `rive/IBM Plex Mono OFL.txt`).

## Song details, lyrics and appearance

The turntable’s former Playing/Paused label now shows the song title in a smaller
font. Long titles end with an ellipsis; hover over the widget for the full title.
There is no separate song-and-artist strip.

Click the lyrics button near the top of the turntable (or choose **Show Lyrics**
from the right-click/menu-bar menu). The widget keeps its full height: a smaller
spinning record and song title share the top row, with one timed lyric line below.
The speakers and playback keys keep their original positions. Click the line to
replay it; the larger disc button returns to the turntable. No new window opens.
Missing lyrics, instrumental tracks and connection errors have compact states
inside the widget. Untimed lyrics are not presented as synchronized lyrics.

Choose **Appearance → System, Light or Dark** from the menu. System follows macOS;
your choice is saved and applies to the turntable and inline lyrics.

Lyrics sources are tried in this order:

1. [LRCLIB](https://lrclib.net): title, artist, album and duration must match.
2. [AMLL community database](https://github.com/amll-dev/amll-ttml-db): timed LRC
   files indexed by the exact Spotify track ID.
3. **Find lyrics on Google**: an explicit browser search when neither source has
   usable timed lyrics. Search results are for discovery and do not replace the
   synchronized display.

Enabling lyrics sends metadata to LRCLIB over HTTPS. Fallback requests send the
Spotify track ID to GitHub's raw-content host. No Spotify credentials are sent.
Google receives the title and artist only when you click the search link.
Turning lyrics off cancels pending lyric requests. Successful lookups are cached
in memory for the session, and the widget identifies the source it displays.
Both sources require usable timestamps and follow the same Spotify playback
clock. Community lyrics can still have transcription or timing errors; coverage
is not guaranteed. See the [source research](app/LYRICS-RESEARCH.md).
