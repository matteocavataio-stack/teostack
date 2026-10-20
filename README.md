# TeoStackXt

App macOS (Swift + SwiftUI, macOS 14+) per DIT: offload con certificazione XXH64, progetti, metadata e report.
Versione semplificata ispirata a Silverstack XT. Interfaccia in italiano.

## Stato dei lavori

| Fase | Contenuto | Stato |
|------|-----------|-------|
| a | Offload + XXH64 + UI base | **fatta** (nucleo testato su Linux; UI da compilare su Mac) |
| b | Progetti (SQLite/GRDB, Progetto → Library → Giorno → Bin), tabella clip | **fatta** (database testato su Linux; UI da compilare su Mac) |
| c | Metadata ARRI / Sony Venice | **ARRI fatta** (ExifTool + art-cmd, testata su dati reali ALEXA 35); Sony in attesa di dati di esempio |
| d | Report: i 5 PDF del formato Silverstack «Classic» (Shooting Day, Clips, Volume, Thumbnail, Contact Print) | **fatta** (generazione testata su Linux e confrontata con i PDF di riferimento; UI da compilare su Mac) |

## Struttura

- `Sources/CXXHash` – libreria xxHash ufficiale v0.8.3 (BSD-2) inclusa in sorgente.
- `Sources/TeoStackCore` – logica senza interfaccia: XXH64, I/O (F_NOCACHE), scansione sorgente, motore di offload, registro per «Riprendi».
- `Sources/TeoStackXt` – app SwiftUI (solo macOS).
- `Tests/TeoStackCoreTests` – test automatici.

## Progetti (fase b)

- Database SQLite in `~/Library/Application Support/TeoStackXt/teostack.sqlite` (libreria GRDB).
- Struttura: Progetto → Library → cartelle giorno (es. `DAY01_20261016`) → bin (es. `A_0001_1DET`). Sidebar ad albero con conteggio clip.
- Crea / rinomina / elimina giorni e bin (clic destro nella sidebar o pulsanti «+ Giorno», «+ Bin»). Selettore progetto in alto
  (nome, data creazione, numero clip) e «Nuovo progetto».
- **Eliminare o rinominare nel programma non tocca mai i file sui dischi.** Le finestre di conferma lo dicono.
- I nomi diventano cartelle: sono vietati `/ \ : * ? " < > |`, i nomi che iniziano/finiscono con punto e quelli oltre 100 caratteri.
- **Offload:** scegli un bin nella sidebar, poi le cartelle base dei dischi. I file finiscono in
  `<cartella scelta>/<Bin>/…`: sul disco viene creata solo la cartella del bin; Progetto, Library e giorno esistono solo nel programma. L'offload viene registrato nel bin
  all'avvio e aggiornato alla fine (anche se annullato o con errori). «Riprendi» riusa lo stesso record.
- **Clip:** contano come clip solo i file con estensione `ari, arx, mov, mxf, mp4` (valore predefinito modificabile in
  `MediaClassifier`) **e** con tutte le destinazioni OK. Gli altri file (XML, sidecar…) sono registrati e visibili con
  «Mostra anche i file non video». Un file MISMATCH/ERRORE è registrato ma non conta come clip.
- **Tabella clip:** colonne configurabili dal menu «Colonne» (Nome, Giorno, Bin, Dimensione, XXH64, Stato, Offload, Percorso e i metadata
  Camera, Codec, Risoluzione, Sensor FPS, ND Filter, Look Info, Lente, ISO, WB, Timecode). Clic sull'intestazione per ordinare.
  I metadata non ancora letti mostrano **N/D** (verranno popolati nella fase c).

## Metadata (fase c)

- **Programmi esterni** (non inclusi nell'app): ExifTool (necessario) e ffprobe (consigliato). All'avvio l'app li cerca in `/opt/homebrew/bin`,
  `/usr/local/bin`, `/opt/local/bin`, `/usr/bin` e nel PATH; se mancano mostra un avviso arancione con le istruzioni di installazione e «Ricontrolla».
  - ExifTool: installer `.pkg` da SourceForge (vedi avviso nell'app) → `/usr/local/bin/exiftool`.
  - ffprobe: build per Intel da evermeet.cx → `/usr/local/bin/ffprobe`.
- **Quando vengono letti:** automaticamente dopo ogni offload completato, sui clip con tutte le destinazioni OK, oppure con il pulsante
  «Leggi metadata» nel tab Clip. Si legge la **copia verificata** sul disco di destinazione, mai la scheda sorgente, e solo in lettura.
- **Un modulo parser per famiglia di camera:** `ARRIMetadataParser` (riconosce `MXF:ApplicationSupplierName = ARRI`). Sony Venice: da scrivere
  quando avrò un XML sidecar e un output ExifTool/ffprobe reali.
- **ARRI Meta Extract è dismesso** da ARRI e non si usa. Lo sostituisce l'**ARRI Reference Tool CMD** (`art-cmd`, gratuito, nessuna registrazione):
  l'app lo cerca in `~/ARRI/*/bin`, `/Applications/ARRI*`, `/usr/local/bin`, nel PATH, oppure in un percorso scelto con «Scegli art-cmd…».
  Comando usato: `art-cmd export --input clip.mxf --duration 1 --output <temp>/metadata.json` (cartella temporanea sempre eliminata).
- **ARRI — cosa si legge davvero** (verificato su un clip MXF/ARRIRAW di ALEXA 35, fixture in `Tests/TeoStackCoreTests/Fixtures`):
  - ExifTool: camera, firmware, risoluzione, **durata**, FPS del file, timecode iniziale, data di ripresa.
  - art-cmd: camera + serial, firmware, codec, risoluzione, **sensor FPS, ISO, shutter, WB (K e tint), filtro ND (densità), look, lente (modello e focale),
    color space, scena, take, reel**, timecode. Dove i due strumenti si sovrappongono prevale art-cmd.
  - I valori "dinamici" (ISO, lente, ND, WB, shutter, sensor FPS, timecode) sono quelli del **primo fotogramma**: su uno zoom o un ND variabile possono cambiare
    durante la ripresa. Le unità sono state verificate negli schemi JSON ufficiali ARRI (focale in µm, ISO lineare, ND = densità ottica).
  - La durata vera viene da ExifTool: nell'export di art-cmd `clipDuration` vale 1 perché si esporta un solo fotogramma.
  - Il campo data di creazione di art-cmd (`clipCreationTime`) è marcato «Z» ma coincide con l'ora locale del nome file: non viene usato.
  - Con timecode drop-frame (ExifTool) il timecode resta N/D (non si calcola un valore dubbio).
  - Senza art-cmd restano N/D: ISO, WB, lente, ND, look, sensor FPS, scena, take, reel, serial, codec.
- Formati non riconosciuti: nessun valore scritto (N/D) e conteggiati nel messaggio «Metadata: N clip letti, M formato non supportato».

## Report (fase d)

Menu **Report → Esporta report…** (⇧⌘E) oppure pulsante «Esporta report…» in alto. Ambito = elemento selezionato nella sidebar (progetto, giorno o bin).
Si scelgono quali report creare e la cartella: **ogni report è un PDF separato**, con nome `<Report_Name>-<bin>-<aaaa-mm-gg-HHmm>.pdf`
(es. `Clips_Report-A_9001_1C3S-2026-10-20-1455.pdf`). Un file esistente non viene mai sovrascritto (si aggiunge « 2»).

| Report | Contenuto (stesso impaginato dei PDF di riferimento) |
|--------|-------------------------------------------------------|
| Shooting Day | Production Info, Clips Overview, Workflow, Labels & Flags, Ratings, Backups, Bins, Video Reels, Camera Sums, Video Formats, Audio Tapes |
| Clips | una pagina larga con TUTTE le 150 colonne di Silverstack e una riga per file (anteprima o icona, flag, stelle, label, timecode, camera, lente, hash…) |
| Volume | una pagina per volume (sorgente e ogni destinazione): cartelle e file con `xxHash64` e `xxHash64BE` |
| Thumbnail | una scheda per file: anteprima (o icona) e tutti i campi |
| Contact Print | griglia 4 colonne di anteprime dei clip video con il nome sotto |

- Nessun valore inventato: i campi che l'app non conosce (es. ShotID/ShotHub, Play Status, Wild Track, Missing) restano **vuoti**, non «N/D» né valori finti.
  Compaiono solo dati letti dai clip (ExifTool / art-cmd) o calcolati dall'offload (dimensioni, date, volumi, backup, verifica, XXH64).
- «Verified Backups» conta solo i file riletti dal disco con XXH64 identico alla sorgente.
- Le anteprime nei report sono quelle già generate nel tab Clip; senza anteprima un clip mostra «No preview».
- Le etichette dei report sono in inglese come nei PDF di riferimento; il piè di pagina dice «TeoStackXt».
- Font: DejaVu Sans Mono incorporato (sottoinsieme, licenza in `THIRD_PARTY_LICENSES.md`) con le stesse misure di Menlo; Helvetica per intestazione e piè di pagina.
  Le forme dei caratteri differiscono leggermente da quelle dei riferimenti, le posizioni coincidono entro circa 1 pt.
- PDF scritto dall'app senza librerie esterne; verificato con `pdftotext`, `pdfinfo` e confronto numerico con i PDF di riferimento.

## Anteprima del primo fotogramma

- Nel tab **Clip** la colonna **Anteprima** mostra il primo fotogramma di ogni clip; cliccando una riga si apre a destra il pannello con il fotogramma grande
  e i dati principali (camera, lente, ISO, WB, ND, sensor FPS, shutter, risoluzione, codec, timecode, durata).
- Le anteprime vengono create **dopo ogni offload** (dopo la lettura dei metadata) oppure con il pulsante **Crea anteprime**. Si legge la copia verificata sul disco di
  destinazione, mai la scheda. I JPEG sono in `~/Library/Application Support/TeoStackXt/Thumbnails/`.
- **Clip ARRI:** `art-cmd process --input clip.mxf --start 0 --duration 1 --embedded-look --target-colorspace Rec.709/D65/BT.1886 --output <temp>/%07d.tif`
  (look incorporato nel clip, Rec.709); se il look non è supportato riprova senza. Il TIFF a 16 bit viene ridotto a JPEG con ImageIO (macOS).
- **Altri video** (ProRes, Sony XAVC…) e ripiego per i clip ARRI: `ffmpeg` (primo fotogramma, JPEG largo al massimo 640 px, senza ingrandire).
- **Dove nessuno strumento riesce a decodificare** (es. ARRIRAW senza art-cmd, Sony X-OCN) l'anteprima manca: la tabella mostra un triangolo e il pannello
  spiega il motivo. Non viene mai mostrata un'immagine inventata.
- ffmpeg non è incluso: l'app avvisa se manca e mostra come installarlo (stesso avviso di ExifTool e art-cmd).
- Nota: la parte `art-cmd process` segue la sintassi del manuale ufficiale ma è stata provata solo con un finto `art-cmd` (il programma reale è solo per macOS).

## Cronologia del progetto

Colonna a destra (pulsante «Nascondi/Mostra cronologia») per il progetto selezionato, dalla più recente.
**Per scelta dell'utente registra solo gli offload completati con tutti i file OK**, per esempio:
«Offload completato nel bin «a001»: 4 file, 8.11 GB, tutti OK — Riletti dal disco con XXH64 identico alla sorgente su 1 destinazione/i. Durata 00:00:09».
Problemi (MISMATCH/ERRORE), annullamenti e operazioni su giorni/bin non compaiono nella cronologia (restano visibili nella finestra
principale e nella tabella clip). Per registrarne altri basta aggiungere il tipo a `ProjectStore.recordedEventKinds`.
Le voci sono salvate nel database, restano dopo il riavvio e sono per progetto; eliminando il progetto si elimina la sua cronologia.

## Come funziona la sicurezza

1. La sorgente è aperta solo con `O_RDONLY`; non viene mai scritto, rinominato o cancellato nulla su di essa.
   Il test `testOffloadToThreeDestinationsAllOKAndIdentical` confronta elenco, dimensioni e date della sorgente prima/dopo.
2. Ogni file viene letto una sola volta; XXH64 è calcolato durante la lettura e i dati sono scritti in parallelo su 1–3 destinazioni.
3. La copia è scritta in `nomefile.teostackpart`. Dopo la copia (e `F_FULLFSYNC`) il file viene **riletto dal disco con `F_NOCACHE`**,
   si ricalcola XXH64 e lo si confronta con la sorgente.
   Solo se coincide il file prende il nome definitivo: **un file con nome definitivo creato dall'app è sempre verificato**.
4. Stati per file/destinazione: `OK`, `MISMATCH`, `ERRORE`. Un file MISMATCH resta come `.teostackpart` e non ha mai il nome definitivo.
5. Un file già presente in destinazione non viene mai sovrascritto: viene solo verificato (OK se identico, MISMATCH se diverso).
6. Disco pieno / scollegato / I/O: controllo dello spazio prima di partire; errori gravi in scrittura fermano solo quella destinazione,
   con messaggio in italiano. Se la sorgente cambia durante la lettura (dimensione diversa) il file è ERRORE.
7. Annulla: rimuove solo i `.teostackpart` creati da questa esecuzione e le cartelle create da essa (se vuote). I file già verificati restano.
8. Riprendi: il registro in `~/Library/Application Support/TeoStackXt/Journal` ricorda i file già verificati; si ripartono solo gli altri.

Voci di sistema sul volume (`.Spotlight-V100`, `.fseventsd`, `.Trashes`, `.TemporaryItems`, `.DocumentRevisions-V100`, `.DS_Store`,
`$RECYCLE.BIN`, `System Volume Information`) e i collegamenti simbolici non vengono copiati; l'interfaccia li segnala.

## Provare su Mac

```bash
brew install xxhash           # fornisce xxhsum, usato dai test come riferimento
swift test                    # test del nucleo
swift run TeoStackXt          # avvia l'app (oppure vedi sotto per il .app)
```

## Creare l'app (.app) e usarla sul tuo Mac

```bash
./scripts/build_app.sh        # crea dist/TeoStackXt.app (universale, firma ad-hoc)
cp -R dist/TeoStackXt.app /Applications/
```

La prima volta: tasto destro → **Apri** (l'app non è notarizzata). Alla prima lettura di una scheda macOS chiede il permesso
per i volumi rimovibili: consentirlo (Impostazioni di Sistema → Privacy e sicurezza → Accesso al disco / Volumi rimovibili).

Per distribuirla ad altri Mac serve un Apple Developer ID: firmare con `codesign --sign "Developer ID Application: …"` e
notarizzare con `xcrun notarytool`. Senza, ogni Mac dovrà usare «tasto destro → Apri».
