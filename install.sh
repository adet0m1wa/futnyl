#!/bin/bash
# Installs Futnyl: downloads the latest release from GitHub, puts Futnyl.app in
# /Applications (or ~/Applications if that isn't writable) and opens it.
# It does nothing else: no sudo, no background services, no data sent anywhere.
#
# To test against a local zip:  FUTNYL_URL=file:///path/Futnyl.zip FUTNYL_DEST=/tmp/Apps ./install.sh
set -euo pipefail

URL="${FUTNYL_URL:-https://github.com/adet0m1wa/futnyl/releases/latest/download/Futnyl.zip}"

[[ "$(uname)" == "Darwin" ]] || { echo "Futnyl is for macOS." >&2; exit 1; }
(( $(sw_vers -productVersion | cut -d. -f1) >= 14 )) || { echo "Futnyl needs macOS 14 or newer." >&2; exit 1; }

if [[ -n "${FUTNYL_DEST:-}" ]]; then
    DEST="$FUTNYL_DEST"
elif [[ -w /Applications ]]; then
    DEST="/Applications"
else
    DEST="$HOME/Applications"
fi
mkdir -p "$DEST"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Futnyl..."
curl -fsSL "$URL" -o "$TMP/Futnyl.zip"
ditto -x -k "$TMP/Futnyl.zip" "$TMP"
[[ -d "$TMP/Futnyl.app" ]] || { echo "The download did not contain Futnyl.app." >&2; exit 1; }

pkill -x Futnyl 2>/dev/null || true
rm -rf "$DEST/Futnyl.app"
ditto "$TMP/Futnyl.app" "$DEST/Futnyl.app"
xattr -dr com.apple.quarantine "$DEST/Futnyl.app" 2>/dev/null || true

echo "Installed to $DEST/Futnyl.app"
open "$DEST/Futnyl.app"
echo "macOS will ask to let Futnyl control Spotify. Click OK, then play something."
