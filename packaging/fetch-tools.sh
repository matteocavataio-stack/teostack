#!/bin/bash
# Scarica gli strumenti da includere nell'app: ExifTool (Perl), ffmpeg, ffprobe. Uso: fetch-tools.sh <cartella-di-destinazione>
set -euo pipefail
DEST="$1"
mkdir -p "$DEST"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== ExifTool"
VER="$(curl -fsSL --max-time 30 https://exiftool.org/ver.txt || true)"
VER="${VER//[$'\r\n ']/}"
[ -n "$VER" ] || VER="13.59"
if ! curl -fsSL --max-time 300 -o "$WORK/exif.tgz" "https://exiftool.org/Image-ExifTool-$VER.tar.gz"; then
    echo "exiftool.org non raggiungibile: uso il mirror GitHub"
    curl -fsSL --max-time 300 -o "$WORK/exif.tgz" "https://github.com/exiftool/exiftool/archive/refs/tags/$VER.tar.gz"
fi
mkdir "$WORK/exif" && tar -xzf "$WORK/exif.tgz" -C "$WORK/exif" --strip-components=1
cp "$WORK/exif/exiftool" "$DEST/exiftool"
cp -R "$WORK/exif/lib" "$DEST/lib"
chmod +x "$DEST/exiftool"
echo "ExifTool $VER"

echo "== ffmpeg / ffprobe (evermeet.cx, build statiche)"
for tool in ffmpeg ffprobe; do
    URL="$(curl -fsSL --max-time 30 "https://evermeet.cx/ffmpeg/info/$tool/release" | python3 -c 'import json,sys; print(json.load(sys.stdin)["download"]["zip"]["url"])')"
    echo "$URL"
    curl -fsSL --max-time 600 -o "$WORK/$tool.zip" "$URL"
    unzip -q -o "$WORK/$tool.zip" -d "$WORK/$tool"
    cp "$WORK/$tool/$tool" "$DEST/$tool"
    chmod +x "$DEST/$tool"
done

cat > "$DEST/LICENSES.txt" <<'TXT'
Programmi inclusi in TeoStackXt (Contents/Resources/tools):

- ExifTool di Phil Harvey — https://exiftool.org — licenza Perl Artistic / GPL.
- ffmpeg e ffprobe (build statiche di evermeet.cx) — https://evermeet.cx/ffmpeg — licenza GPL v3;
  il codice sorgente è disponibile sul sito indicato e su https://ffmpeg.org.

art-cmd (ARRI Reference Tool) NON è incluso: lo scarica l'installer dal sito ARRI nella cartella ~/ARRI ed è soggetto alla licenza ARRI.
TXT
echo "Strumenti pronti in $DEST"
