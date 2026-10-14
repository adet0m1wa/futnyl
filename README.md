# Futnyl

A little turntable that sits on your Mac's desktop and follows Spotify. Songs change on the record, the tonearm tracks the song, and the keys on the front control Spotify. The name is short for "futuristic vinyl".

Free and open source. Works with Spotify.

## Install

Open Terminal and paste:

```bash
curl -fsSL https://raw.githubusercontent.com/adet0m1wa/futnyl/main/install.sh | bash
```

It downloads the latest [release](https://github.com/adet0m1wa/futnyl/releases/latest), puts `Futnyl.app` in `/Applications` and opens it. The script is [short](install.sh), so read it first if you like. You can also download `Futnyl.zip` from the releases page and drag the app anywhere.

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

Futnyl collects nothing and sends nothing anywhere. It talks to Spotify on your Mac, and it downloads the cover art of the current song from Spotify's image server.

## Build from source

You need the Xcode command line tools and the [Rive CLI](https://rive.app) (expected at `~/.rive/bin/rive`, or set `RIVE`).

```bash
cd app
./build-app.sh          # -> app/dist/Futnyl.app
./build-app.sh --zip    # also app/dist/Futnyl.zip
```

`rive/` is the Rive file (the turntable, its animation and the cover/colour effects). `app/` is the Swift app that hosts it and talks to Spotify. See [app/README.md](app/README.md) for how the sync works.

## Not affiliated

Futnyl is an independent project. It is not affiliated with, endorsed by or sponsored by Spotify or any artist. Spotify is a trademark of Spotify AB.

Song titles and cover art shown in the demo video belong to their owners and appear only to demonstrate how the app works. The video is not meant to promote any artist or product, and nothing here is for sale.

## Licence

MIT, see [LICENSE](LICENSE).

Third-party: the Rive runtime ([rive-ios](https://github.com/rive-app/rive-ios), MIT) and IBM Plex Mono (SIL Open Font License 1.1, see `rive/IBM Plex Mono OFL.txt`).
