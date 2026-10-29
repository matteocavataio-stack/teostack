#!/bin/bash
# TeoStackPro — estrae i metadata di tutte le clip della cartella in cui si trova questo file.
# Uso: metti questo file nella cartella con le clip (anche dentro sottocartelle) e fai doppio clic.
# Non modifica e non copia le clip: le legge soltanto. Crea accanto a sé la cartella «METADATA_JSON_<data>» e il file .zip con i JSON.

DIR="$(cd "$(dirname "$0")" && pwd)"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$DIR/METADATA_JSON_$STAMP"
CUTS="$OUT/ritagli"          # inizio e fine di ogni file (2 MB ciascuno): facoltativi
LOG="$OUT/RIEPILOGO.txt"
CAP=1000000                  # massimo byte dei JSON «lunghi» (-ee, ffprobe -show_data)
LIMIT=120                    # secondi massimi per i passaggi lunghi su un file

pause() { echo; read -n 1 -s -r -p "Premi un tasto per chiudere…"; echo; }

find_tool() {
  local name="$1" d
  for d in "/Applications/TeoStackPro.app/Contents/Resources/tools" "$HOME/Applications/TeoStackPro.app/Contents/Resources/tools" \
           "/Applications/TeoStackXt.app/Contents/Resources/tools" "$HOME/Applications/TeoStackXt.app/Contents/Resources/tools" \
           "/opt/homebrew/bin" "/usr/local/bin" "/opt/local/bin" "/usr/bin"; do
    [ -x "$d/$name" ] && { echo "$d/$name"; return; }
  done
  command -v "$name" 2>/dev/null
}

EXIF="$(find_tool exiftool)"
PROBE="$(find_tool ffprobe)"
# art-cmd (ARRI Reference Tool): dà ISO, WB, tint, shutter, lente, ND, tilt/roll dei clip ARRI
ART="$(find "$HOME/ARRI" /Applications/ARRI /opt/ARRI /usr/local/ARRI -name art-cmd -type f 2>/dev/null | sort -r | head -1)"
[ -z "$ART" ] && ART="$(command -v art-cmd 2>/dev/null)"

echo "=== TeoStackPro · estrazione metadata ==="
echo "Cartella: $DIR"
if [ -z "$EXIF" ]; then
  echo
  echo "ERRORE: ExifTool non è installato. Installalo così (poi rilancia questo file):"
  echo "  cd ~/Downloads && curl -L -o ExifTool-13.59.pkg \"https://sourceforge.net/projects/exiftool/files/ExifTool-13.59.pkg/download\" && open ExifTool-13.59.pkg"
  pause; exit 1
fi
echo "ExifTool: $EXIF ($("$EXIF" -ver))"
if [ -n "$PROBE" ]; then echo "ffprobe:  $PROBE"; else echo "ffprobe:  NON TROVATO (si farà senza: va bene lo stesso, ma è meglio averlo)"; fi
if [ -n "$ART" ]; then echo "art-cmd:  $ART"; else echo "art-cmd:  non trovato (i clip ARRI saranno letti solo con ExifTool/ffprobe)"; fi

mkdir -p "$OUT" "$CUTS" || { echo "Impossibile creare $OUT"; pause; exit 1; }
{
  echo "TeoStackPro estrazione metadata — $(date)"
  echo "Cartella: $DIR"
  echo "ExifTool: $EXIF $("$EXIF" -ver)"
  echo "ffprobe: ${PROBE:-non trovato}"
  echo "art-cmd: ${ART:-non trovato}"
  echo
} > "$LOG"

# durata massima per un comando (macOS non ha «timeout»)
limited() { perl -e 'my $t = shift; alarm $t; exec @ARGV' "$LIMIT" "$@"; }

N=0; ERR=0
STILLS_DIR=""; STILLS_COUNT=0

# estensioni lette: clip, RAW, foto/sequenze, audio e file di accompagnamento
while IFS= read -r -d '' f; do
  rel="${f#$DIR/}"
  ext="$(echo "${f##*.}" | tr '[:upper:]' '[:lower:]')"
  # sequenze di fotogrammi (DNG, DPX, TIFF…): migliaia di file uguali → solo i primi 3 per cartella
  case "$ext" in
    dng|dpx|tif|tiff|exr|jpg|jpeg|arw|cr3|cr2|nef)
      d="$(dirname "$f")"
      if [ "$d" != "$STILLS_DIR" ]; then STILLS_DIR="$d"; STILLS_COUNT=0; fi
      STILLS_COUNT=$((STILLS_COUNT + 1))
      if [ "$STILLS_COUNT" -gt 3 ]; then continue; fi
      ;;
  esac
  safe="${rel//\//__}"
  N=$((N + 1))
  size=$(wc -c < "$f" | tr -d ' ')
  echo "[$N] $rel ($((size / 1048576)) MB)"
  echo "[$N] $rel  ($size byte)" >> "$LOG"

  # 1) tutti i tag di ExifTool (anche duplicati e sconosciuti), valori numerici grezzi
  if ! "$EXIF" -json -G1 -a -u -n "$f" > "$OUT/$safe.exiftool.json" 2> "$OUT/$safe.exiftool.err"; then
    echo "    ExifTool: errore (vedi .err)"; echo "    ExifTool: ERRORE" >> "$LOG"; ERR=$((ERR + 1))
  fi
  [ -s "$OUT/$safe.exiftool.err" ] || rm -f "$OUT/$safe.exiftool.err"

  # 2) dati registrati fotogramma per fotogramma (-ee): lenti, tilt, ecc. — lento sui file enormi, quindi con limite di tempo
  case "$ext" in
    dng|dpx|tif|tiff|exr|jpg|jpeg|wav|xml|srt|rmd) ;;
    *) limited "$EXIF" -json -G1 -a -u -ee "$f" 2>/dev/null | head -c "$CAP" > "$OUT/$safe.exiftool-ee.json"
       [ -s "$OUT/$safe.exiftool-ee.json" ] || rm -f "$OUT/$safe.exiftool-ee.json" ;;
  esac

  # 3) ffprobe: contenitore, flussi, codec, timecode, dati dei flussi
  if [ -n "$PROBE" ]; then
    limited "$PROBE" -v error -show_format -show_streams -show_data -of json "$f" 2>/dev/null | head -c "$CAP" > "$OUT/$safe.ffprobe.json"
    [ -s "$OUT/$safe.ffprobe.json" ] || rm -f "$OUT/$safe.ffprobe.json"
  fi

  # 3b) art-cmd sui clip ARRI (MXF, MOV ProRes, ARRIRAW): metadata del primo fotogramma
  if [ -n "$ART" ]; then
    case "$ext" in
      mov|mxf|ari|arx)
        limited "$ART" export --input "$f" --duration 1 --output "$OUT/$safe.art.json" > "$OUT/$safe.art.log" 2>&1
        if [ -s "$OUT/$safe.art.json" ]; then rm -f "$OUT/$safe.art.log"; else echo "    art-cmd: nessun metadata (vedi .art.log)"; rm -f "$OUT/$safe.art.json"; fi ;;
    esac
  fi

  # 4) file piccoli di accompagnamento (XML, SRT, RMD…): copiati interi
  case "$ext" in
    xml|srt|rmd|txt|csv|ale) [ "$size" -lt 5000000 ] && cp "$f" "$CUTS/$safe" ;;
    *) # inizio e fine del file (la fine serve ai MOV/MP4 con l'indice in coda)
       head -c 2000000 "$f" > "$CUTS/$safe.head"
       tail -c 2000000 "$f" > "$CUTS/$safe.tail" ;;
  esac
done < <(find "$DIR" -type f ! -path "$DIR/METADATA_JSON_*" ! -name '._*' ! -name '.DS_Store' ! -name '*.command' ! -name '*.zip' -print0 | sort -z)

echo
echo "Fatto: $N file letti, $ERR con errori." | tee -a "$LOG"

# archivio con i soli JSON (leggero, da caricare su GitHub); i ritagli restano nella cartella «ritagli»
ZIP="$DIR/METADATA_JSON_$STAMP.zip"
( cd "$OUT" && zip -q -r "$ZIP" . -x "ritagli/*" ) 2>/dev/null
if [ -s "$ZIP" ]; then
  mb=$(( $(wc -c < "$ZIP" | tr -d ' ') / 1048576 ))
  echo "Archivio JSON: $ZIP (${mb} MB)"
  [ "$mb" -ge 25 ] && echo "ATTENZIONE: supera i 25 MB, GitHub non lo accetta dal sito: dividi in due cartelle."
fi
echo "Cartella completa: $OUT"
open "$OUT" 2>/dev/null
pause
