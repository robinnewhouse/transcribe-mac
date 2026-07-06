#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP="Transcribe.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

echo "Compiling…"
swift build -c release
BIN_TMP=".build/release/Transcribe"
cp .build/release/TranscribeCLI transcribe-cli

echo "Generating icon…"
swift make-icon.swift >/dev/null
iconutil -c icns Transcribe.iconset -o Transcribe.icns

rm -rf "$APP"
mkdir -p "$MACOS" "$CONTENTS/Resources"
cp "$BIN_TMP" "$MACOS/Transcribe"
cp Transcribe.icns "$CONTENTS/Resources/Transcribe.icns"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Transcribe</string>
    <key>CFBundleDisplayName</key>
    <string>Transcribe</string>
    <key>CFBundleIdentifier</key>
    <string>local.transcribe</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>Transcribe</string>
    <key>CFBundleIconFile</key>
    <string>Transcribe</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Audio File</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.audio</string>
                <string>public.movie</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
