#!/bin/bash
# Scarica gli strumenti da includere nell'app: ExifTool (Perl), ffmpeg, ffprobe. Uso: fetch-tools.sh <cartella-di-destinazione>
set -euo pipefail
DEST="$1"
mkdir -p "$DEST"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# I download riusciti restano in packaging/.cache: rilanciando lo script non si riscarica nulla.
CACHE="$(cd "$(dirname "$0")" && pwd)/.cache"
mkdir -p "$CACHE"

# fetch <url> <file-in-cache>: riprova più volte (evermeet.cx risponde 429 se riceve troppe richieste ravvicinate).
fetch() {
    local url="$1" out="$CACHE/$2" n
    [ -s "$out" ] && { echo "già scaricato: $2"; return 0; }
    for n in 1 2 3 4 5 6; do
        if curl -fsSL --max-time 600 -o "$out.part" "$url"; then mv "$out.part" "$out"; return 0; fi
        echo "download non riuscito (tentativo $n/6), riprovo tra $((n * 30)) s"; sleep $((n * 30))
    done
    rm -f "$out.part"; return 1
}

echo "== ExifTool"
VER="$(curl -fsSL --max-time 30 https://exiftool.org/ver.txt || true)"
VER="${VER//[$'\r\n ']/}"
[ -n "$VER" ] || VER="13.59"
if ! fetch "https://exiftool.org/Image-ExifTool-$VER.tar.gz" "exiftool-$VER.tgz"; then
    echo "exiftool.org non raggiungibile: uso il mirror GitHub"
    fetch "https://github.com/exiftool/exiftool/archive/refs/tags/$VER.tar.gz" "exiftool-$VER.tgz"
fi
mkdir "$WORK/exif" && tar -xzf "$CACHE/exiftool-$VER.tgz" -C "$WORK/exif" --strip-components=1
cp "$WORK/exif/exiftool" "$DEST/exiftool"
cp -R "$WORK/exif/lib" "$DEST/lib"
chmod +x "$DEST/exiftool"
echo "ExifTool $VER"

echo "== ffmpeg / ffprobe (evermeet.cx, build statiche)"
for tool in ffmpeg ffprobe; do
    URL="$(curl -fsSL --retry 5 --retry-delay 30 --max-time 60 "https://evermeet.cx/ffmpeg/info/$tool/release" | python3 -c 'import json,sys; print(json.load(sys.stdin)["download"]["zip"]["url"])')"
    echo "$URL"
    fetch "$URL" "$(basename "$URL")"
    unzip -q -o "$CACHE/$(basename "$URL")" -d "$WORK/$tool"
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
