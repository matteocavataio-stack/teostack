#!/bin/bash
# Crea TeoStackXt.app (universale Intel + Apple Silicon), l'installer .pkg e il .dmg. Da eseguire su macOS.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-1.0.0}"
DIST="$PWD/dist"
APP="$DIST/TeoStackXt.app"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# UNIVERSAL=0: solo per l'architettura di questo Mac (basta con i soli «Command Line Tools»; l'app universale Intel+ARM richiede Xcode completo)
if [ "${UNIVERSAL:-1}" = "1" ]; then ARCHS=(--arch arm64 --arch x86_64); echo "== Compilazione (arm64 + x86_64)"; else ARCHS=(); echo "== Compilazione ($(uname -m))"; fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --product TeoStackXt
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/TeoStackXt"
cp "$BIN" "$APP/Contents/MacOS/TeoStackXt"
lipo -info "$APP/Contents/MacOS/TeoStackXt"

echo "== Icona"
iconutil -c icns packaging/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp packaging/teostack_logo.svg "$APP/Contents/Resources/teostack_logo.svg"
cp THIRD_PARTY_LICENSES.md "$APP/Contents/Resources/THIRD_PARTY_LICENSES.md"

echo "== Strumenti (ExifTool, ffmpeg, ffprobe)"
packaging/fetch-tools.sh "$APP/Contents/Resources/tools"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>TeoStackXt</string>
  <key>CFBundleDisplayName</key><string>TeoStackXt</string>
  <key>CFBundleIdentifier</key><string>com.teostack.xt</string>
  <key>CFBundleExecutable</key><string>TeoStackXt</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSRemovableVolumesUsageDescription</key><string>TeoStackXt legge le schede camera e scrive le copie sui dischi di destinazione.</string>
  <key>NSDesktopFolderUsageDescription</key><string>TeoStackXt salva i report e le copie nelle cartelle che scegli.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>TeoStackXt salva i report e le copie nelle cartelle che scegli.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>TeoStackXt salva i report e le copie nelle cartelle che scegli.</string>
  <key>NSHumanReadableCopyright</key><string>TeoStackXt</string>
</dict></plist>
PLIST

echo "== Firma (ad-hoc, senza Apple Developer ID)"
for f in "$APP"/Contents/Resources/tools/ffmpeg "$APP"/Contents/Resources/tools/ffprobe; do codesign --force --sign - "$f" || true; done
codesign --force --sign - "$APP/Contents/MacOS/TeoStackXt"
codesign --force --sign - "$APP"
codesign --verify --verbose "$APP" || true

echo "== Installer .pkg"
STAGE="$DIST/stage"; mkdir -p "$STAGE"; cp -R "$APP" "$STAGE/"
pkgbuild --analyze --root "$STAGE" "$DIST/components.plist"
plutil -replace 0.BundleIsRelocatable -bool false "$DIST/components.plist"
pkgbuild --root "$STAGE" --component-plist "$DIST/components.plist" --identifier com.teostack.xt --version "$VERSION" \
         --install-location /Applications --scripts packaging/scripts "$DIST/TeoStackXt-component.pkg"
sed "s/@VERSION@/$VERSION/" packaging/distribution.xml > "$DIST/distribution.xml"
productbuild --distribution "$DIST/distribution.xml" --resources packaging/resources --package-path "$DIST" "$DIST/TeoStackXt-$VERSION.pkg"

echo "== Immagine disco .dmg"
DMG_STAGE="$DIST/dmg"; mkdir -p "$DMG_STAGE"; cp -R "$APP" "$DMG_STAGE/"; ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "TeoStackXt" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DIST/TeoStackXt-$VERSION.dmg"

rm -rf "$STAGE" "$DMG_STAGE" "$DIST/components.plist" "$DIST/distribution.xml" "$DIST/TeoStackXt-component.pkg"
echo "== Pronto:"; ls -lh "$DIST"
