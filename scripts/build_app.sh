#!/bin/bash
# Compila TeoStackXt in release e crea dist/TeoStackXt.app (firma ad-hoc, uso locale).
# Uso: ./scripts/build_app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

[[ "$(uname)" == "Darwin" ]] || { echo "Questo script va eseguito su macOS."; exit 1; }

swift build -c release --arch arm64 --arch x86_64    # binario universale (Apple Silicon + Intel)
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/TeoStackXt"

APP="dist/TeoStackXt.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TeoStackXt"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TeoStackXt</string>
    <key>CFBundleDisplayName</key><string>TeoStackXt</string>
    <key>CFBundleIdentifier</key><string>com.teostack.xt</string>
    <key>CFBundleExecutable</key><string>TeoStackXt</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>TeoStackXt legge le schede camera e scrive sui dischi di destinazione per l'offload.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>TeoStackXt copia file da e verso cartelle da te scelte.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>TeoStackXt copia file da e verso cartelle da te scelte.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Creato: $APP"
echo "Per aprirlo la prima volta: tasto destro > Apri (firma ad-hoc, non notarizzata)."
