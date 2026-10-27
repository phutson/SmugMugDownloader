#!/bin/bash
# Builds "SmugMug Downloader.app" into ./build. Copy it to /Applications if you like.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/SmugMug Downloader.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SmugMugDownloader" "$APP/Contents/MacOS/SmugMugDownloader"
cp AppBundle/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature so macOS will launch it locally.
codesign --force --deep --sign - "$APP"

echo "Built $(pwd)/$APP"
