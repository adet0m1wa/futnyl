#!/bin/bash
# Builds Futnyl.app: compiles the Swift package in release mode, bundles the
# signed Rive file (without its test bench) and the Rive runtime, and signs the
# app ad hoc (free).
#
#   ./build-app.sh            -> dist/Futnyl.app
#   ./build-app.sh --zip      -> also dist/Futnyl.zip, ready to upload
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
APP="$ROOT/dist/Futnyl.app"
VERSION="1.0.0"
RIVE="${RIVE:-$HOME/.rive/bin/rive}"

# The app's Rive file: the project without its dummy-Spotify test bench (no
# test songs), signed so its scripts run. Built from a copy.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
rsync -a --exclude build --exclude test --exclude dummySpotify.luau "$ROOT/../rive/" "$STAGE/rive/"
python3 "$ROOT/strip-bench.py" "$STAGE/rive/scene.rml"
"$RIVE" "$STAGE/rive" --publish --quiet
RIV="$STAGE/rive/build/futuristicvinyl.riv"
[[ -f "$RIV" ]] || { echo "the Rive build did not produce $RIV" >&2; exit 1; }

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/VinylWidget" "$APP/Contents/MacOS/Futnyl"
cp -R "$BIN/RiveRuntime.framework" "$APP/Contents/Frameworks/"
cp "$RIV" "$APP/Contents/Resources/futuristicvinyl.riv"
cp "$ROOT/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Futnyl"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Futnyl</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.adetomiwa.vinyl</string>
    <key>CFBundleName</key><string>Futnyl</string>
    <key>CFBundleDisplayName</key><string>Futnyl</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Futnyl controls Spotify's playback when you press its buttons, and reads the album art of what's playing.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: free, and enough for Apple Silicon. Sign inside-out.
codesign --force --sign - "$APP/Contents/Frameworks/RiveRuntime.framework"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "built $APP"

if [[ "${1:-}" == "--zip" ]]; then
    (cd dist && rm -f Futnyl.zip && ditto -c -k --keepParent Futnyl.app Futnyl.zip)
    echo "zipped dist/Futnyl.zip"
fi
