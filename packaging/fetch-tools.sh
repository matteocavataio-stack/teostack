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

# fetch <url> <file-in-cache> [tentativi]: riprova solo se il server è occupato (evermeet.cx risponde 429 se riceve troppe richieste
# ravvicinate); un 404 o altro errore definitivo non viene ripetuto.
fetch() {
    local url="$1" out="$CACHE/$2" tries="${3:-6}" n code
    [ -s "$out" ] && { echo "già scaricato: $2"; return 0; }
    for ((n = 1; n <= tries; n++)); do
        code="$(curl -sSL --max-time 600 -o "$out.part" -w '%{http_code}' "$url" || true)"
        if [ "$code" = "200" ]; then mv "$out.part" "$out"; return 0; fi
        rm -f "$out.part"
        case "$code" in 429|500|502|503|504|000) ;; *) echo "errore HTTP $code: $url"; return 1;; esac
        [ "$n" -lt "$tries" ] && { echo "server occupato (HTTP $code), tentativo $n/$tries: riprovo tra $((n * 30)) s"; sleep $((n * 30)); }
    done
    rm -f "$out.part"; return 1
}

echo "== ExifTool"
VER="$(curl -fsSL --max-time 30 https://exiftool.org/ver.txt || true)"
VER="${VER//[$'\r\n ']/}"
[ -n "$VER" ] || VER="13.59"
if ! fetch "https://github.com/exiftool/exiftool/archive/refs/tags/$VER.tar.gz" "exiftool-$VER.tgz" 3; then
    echo "mirror GitHub non disponibile: provo exiftool.org"
    fetch "https://exiftool.org/Image-ExifTool-$VER.tar.gz" "exiftool-$VER.tgz" 1
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
    if ! fetch "$URL" "$(basename "$URL")"; then
        if [ "${ALLOW_MISSING_TOOLS:-0}" = "1" ]; then echo "ATTENZIONE: $tool non scaricato, l'app lo segnalerà come mancante"; continue; fi
        echo "Scarica a mano $URL dal browser e copialo in $CACHE, poi rilancia lo script (oppure usa ALLOW_MISSING_TOOLS=1)."
        exit 1
    fi
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
