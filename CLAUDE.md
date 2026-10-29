# TeoStackPro (ex TeoStackXt) — contesto del progetto (letto in automatico a inizio sessione)

Il software si chiama ora **TeoStackPro** (nome visibile: finestra, .app, installer, piè di pagina dei report, strumento nei file MHL). Nomi INTERNI invariati di proposito: prodotto/modulo Swift `TeoStackXt`, cartella dati `~/Library/Application Support/TeoStackXt`, bundle id `com.teostack.xt` (così progetti e impostazioni restano).

## Utente e preferenze
- Utente italiano, DIT. Rispondere SEMPRE in italiano, risposte brevi, molto approfondite e veritiere. Non inventare: se manca un'informazione, chiedere.
- Usa un Mac Intel (i9, macOS 26). Esegue i comandi dal Terminale copiandoli: dare comandi pronti e completi.
- Regole di sicurezza (priorità massima): mai modificare/cancellare nulla sulla sorgente (solo lettura); un file è «OK» solo dopo rilettura dal disco (F_NOCACHE)
  con XXH64 identico alla sorgente; mai inventare valori (campi sconosciuti vuoti nei report, «N/D» nelle tabelle); errori chiari (disco scollegato, spazio, file illeggibile), mai un falso OK.
- Implementare solo le funzioni richieste (niente transcodifica/playback/color grading/LUT).

## Ambiente di lavoro
- Sessione su Linux (cloud): si compila e si testa il nucleo (`TeoStackCore`), NON si può compilare/provare la UI SwiftUI né l'app macOS. La UI si controlla solo con `swiftc -parse` e con il modulo stub in `/tmp/claude-0/uicheck` (può non esistere in una nuova sessione).
- Swift (Linux): `export PATH=/tmp/claude-0/swiftdl/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin:$PATH` (se manca, scaricare la toolchain Swift 6.0.3 per Ubuntu 24.04).
- Test: `swift test` (≈140 test, 1 saltato = benchmark opzionale `TEOSTACK_BENCH=1 swift test --filter BenchmarkTests`). Verificati anche con ThreadSanitizer.
- Branch di sviluppo: `claude/teostackxt-macos-app-lea8qk` (push con `git push -u origin <branch>`). Non creare PR se non richiesto. Commit con i trailer richiesti dal sistema.
- Il build macOS su GitHub Actions (`.github/workflows/build-macos.yml`) è rimasto in coda (runner macOS non partito): l'utente costruisce l'installer sul suo Mac con `packaging/build-installer.sh`.

## Architettura (Swift Package)
- `Sources/CXXHash` (xxHash C), `TeoStackCore` (libreria: offload, progetti/SQLite via GRDB, metadata, anteprime, report), `TeoStackXt` (app SwiftUI), `CSQLiteLinuxShim` (solo Linux).
- Offload (`Offload/OffloadEngine.swift`): lettura unica della sorgente, XXH64 in lettura, scrittura parallela su 1–8 destinazioni (`OffloadJob.maxDestinations`) in `.teostackpart`, rilettura senza cache, rename solo dopo verifica,
  journal per «Riprendi», mai sovrascrivere file esistenti. Verifica sovrapposta alla copia (impostazione `overlapVerification`, di serie attiva), fsync differito + un solo flush della cache per file < 64 MB,
  nessuna ricreazione del percorso se il disco sparisce (`destinationAnchor`). FileVerifier legge e calcola l'hash in parallelo.
- Progetti (`Projects/`): Progetto → Library → [giorno] → [sottocartelle] → bin. Bin creato in automatico all'avvio dell'offload col nome della sorgente (modificabile; se esiste lo riusa).
  Sposta nodi (trascinamento o «Sposta in»), elimina solo il selezionato, cronologia per progetto (solo «Offload completato … tutti OK», cancellabile). Destinazione su disco = `<cartella scelta>/<nome bin>`.
- Metadata: ExifTool + art-cmd (ARRI, cartella `~/ARRI`); **ffprobe** per tutto il resto (MPG, WAV/BWF, LRF, MP4, ProRes: `FFprobeRunner` + `FFprobeMetadataParser`, solo ciò che il file dichiara; ExifTool sbaglia sui MPEG);
  WAV/BWF: `BroadcastWaveReader` (bext + iXML, senza ExifTool: ExifTool in JSON perde i nomi delle tracce duplicati); LRF/MP4 DJI: il `moov` sta in fondo al file (un ritaglio dell'inizio non basta, serve la coda);
  audio = `ClipRecord.isAudio` (colonna `clip.isAudio`, migrazione v6), file «._» di macOS mai clip (`MediaClassifier.isAppleDouble`); Sony Venice ancora in attesa di file di esempio (XML sidecar + output ExifTool). Metadata/anteprime in parallelo (`ParallelRunner`).
- Report (`Reports/`): 5 PDF separati nel formato Silverstack «Classic» (Shooting Day, Clips, Volume, Thumbnail, Contact Print), scritti da un PDF writer proprio con font DejaVu Sans Mono incorporato;
  nome file `<Report_Name>-<bin>-<aaaa-mm-gg-HHmm>.pdf`; report di una cartella = tutti i bin contenuti; Clips e Thumbnail stampano solo le colonne scelte dall'utente («Name» sempre). Campi sconosciuti vuoti.
- Lettori metadata (`Metadata/Readers/`): `MetadataReader` (canRead + read, mai errori) + `ReaderRegistry.standard()` (ordine: ARRI, RED, Phantom, Sony, Canon, Panasonic, Blackmagic, Kinefinity, BWF, ripiego art-cmd, generico ffprobe+ExifTool+sidecar XML).
  `ClipMetadata` (campi tutti opzionali ↔ chiavi del DB con `columns`/`init(columns:)`; `rawFields` → chiavi `raw.*`), `FileProbe` (riconoscimento dal contenitore, primi 64 KiB, sola lettura), `ClipFile` (cache per file di ExifTool/ffprobe/art-cmd).
  Nativi: R3D (`R3DParser`, validato contro ExifTool su file SINTETICI in `Tests/.../Fixtures/synthetic`), Cine (`CineParser`, non verificato), BWF, sidecar XML (Sony `…M01.XML`, P2/Canon `<clip>.XML`). Il resto passa da ExifTool/ffprobe.
  Regole: ApplicationSupplierName/ApplicationName di MXF = SOFTWARE, mai camera; i soli `raw.*` non contano come «letto»; foto/DPX/DNG senza durata né fps (`MediaClassifier.stillExtensions`, leggibili ma non clip); date «0000» scartate.
  Campioni veri: cartella `fixtures/` nella radice (`RealSamples` in `REDReaderTests.swift`: il test si salta con un messaggio se manca). Export JSON/CSV/ALE (`MetadataExport.swift`, con XXH64), import log ALE/CSV/XML (`SidecarImport.swift`, mai sovrascrive senza consenso).
  Verificato su clip VERE (JSON in `Fixtures/real`, `RealClipTests`): RED V-RAPTOR R3D (`Red:CameraType` = lettera camera, modello = `Brain`, reel = lettera+`ReelNumber`; i due timecode `Red_0x10ad/0x10ae` NON mappati in attesa di conferma), Sony VENICE 2 X-OCN MXF
  (nel MXF non ci sono modello/ISO/lente: stanno nel sidecar `…M01.XML`; riconosciuto «Sony» dal registratore AXS; dimensioni = DisplayWidth/Height), DJI Inspire 3 ProRes RAW (RDD18 in `Keys:*`; flusso `djmd` via `exiftool -ee`, posizioni `Dvtm_fc4280_*` in `DJIMapper`),
  DJI FC4280 CinemaDNG (`TimeCodes` BCD → `ExifMapper.dngTimecode`, XMP-drone-dji), ProRes Proxy di Resolve (reel dal flusso tmcd), H.264 generico. `ExifToolRunner` usa `-json -G1 -a -u -n` (+`-ee` con tempo massimo per i dati incorporati).
  ARRI ALEXA Mini LF (MXF ARRIRAW HDE e MXF ProRes 4444 XQ, art-cmd 1.0.0 + ExifTool, JSON in `Fixtures/real`): `exposureTime` può essere una frazione strana («3333/500000» = 1/150 s) → normalizzata; angolo shutter = 360° × tempo × sensorFPS (derivato);
  `tStop` = 2^((lensIris−1000)/2000) (schema ARRI lens_state: millesimi di stop, T1 = 1000); la Mini LF non scrive tilt/roll (Positional vuoto); un 0/1 nel JSON è un numero (bug `value is Bool` corretto, `NSNumber.isJSONBoolean`); ULs SMPTE grezzi mai come gamma.
  SDK di costruttori (R3DSDK, BRAW SDK, Sony RAW SDK, Canon): NON inclusi (download con registrazione/EULA, non automatizzabili); metadata dinamici per frame: rimandati su richiesta dell'utente.
- ASC MHL 2.0 (`MHL/`): a offload riuscito, su ogni destinazione i cui file sono TUTTI verificati OK, `ASCMHLWriter` scrive `<copia>/ascmhl/NNNN_<bin>_<data>Z.mhl` + `ascmhl_chain.xml` (processo «transfer», XXH64, hash di cartelle content/structure, C4 della catena in `C4ID.swift`).
  Usa gli hash già verificati dal motore; i file già presenti nella cartella ma non dell'offload vengono riletti; generazioni successive segnano «verified»/«failed»/«original». Mai su annullamento; mai se un file non è OK.
  Validato contro lo strumento ufficiale `ascmhl` 1.2 (stessi hash, XSD, `verify`). Opzione `Configuration.ascMHL` (casella «Crea certificato ASC MHL», di serie attiva, autore = operatore dei report), fase `OffloadPhase.certifying`, esito `OffloadResult.mhl`.
- Profili di esportazione report (`Reports/ReportPreset.swift`, `ReportPresetStore` su UserDefaults): nome + report + colonne + operatore, richiamabili dalla finestra «Esporta report» (si riparte dall'ultimo usato; «modificato» se le scelte cambiano; salva come, aggiorna, rinomina, elimina, esporta/importa JSON tra Mac, mai sovrascrive per nome).
  Le colonne dei report sono ora indipendenti da quelle del tab Clip (`reportColumns`; prima volta copiate da `clipColumns`).
- Aiuto: manuale utente PDF creato dall'app (`Help/ManualPDF.swift` layout A4 con copertina, indice con pagine, titoli, tabelle; `Help/ManualContent.swift` testo italiano). Menu Aiuto > «Manuale di TeoStackPro» (⌘?), pulsante «Aiuto» in basso a sinistra (`HelpActions`).
  Quando si aggiunge o cambia una funzione, aggiornare `ManualContent` (il test `ManualTests` controlla che i termini chiave siano documentati). Per vederlo: `TEOSTACK_MANUAL_OUT=/percorso.pdf TEOSTACK_MANUAL_VERSION=x.y.z swift test --filter testWriteManualForInspection`.
- Installer (`packaging/`): app universale Intel+ARM, icona dal logo, ExifTool/ffmpeg/ffprobe inclusi (`fetch-tools.sh`, con cache e ripiego GitHub se evermeet.cx dà 429), `.pkg` (scarica art-cmd da ARRI) e `.dmg`. Firma ad-hoc: al primo avvio clic destro → Apri.

## Lingue (Italiano / English / Castellano / Català)
- `Localization/Loc.swift` + `LocStrings.swift`: la chiave è il testo italiano, i segnaposto sono `{0}`, `{1}`… (mai interpolazioni Swift dentro `tr("…")`). Ogni testo nuovo va aggiunto come riga (it, en, es, ca)
  in `LocStrings.swift`: il test `LocalizationTests` cerca nei sorgenti tutti i `tr("…")`/`LocText("…")` e fallisce se manca una lingua o un segnaposto.
- UI: `tr()` ovunque; `LanguageSettings` + `LanguageMenu` (in basso a sinistra nella barra laterale); `.id(lingua)` sul contenuto di `ContentView` (non sul livello che possiede `AppModel`).
- I report PDF restano in inglese e con «N/D» (`ClipColumns.reportNotAvailable`); la cronologia salva chiave+parametri (`LocText`, colonna `event.i18n`) così segue la lingua.
- Importa media (`ProjectStore.importFiles`, stato clip `imported`, `ClipRecord.hasLocalFile`), pallino bin (`TreeNode.verification`), riepilogo a tabelle (`ProjectRecap`, `RecapPanel`).
- Altre funzioni: percorsi di destinazione salvati (`SavedPathsStore`, menu «Percorsi salvati»), riepilogo cartella (`ProjectRecap`, `RecapPanel`).

## Stato
- Tutto quanto sopra è implementato e pubblicato sul branch. Non provato su macOS reale: nuovi controlli UI (menu «Schede collegate», «Espelli sorgente», suono, trascinamento nodi, finestra «Esporta report» con colonne), gli effetti di velocità su dischi veri (da misurare col benchmark), `art-cmd process` per le anteprime ARRI.
- Windows: valutato (riscrittura in C#/Avalonia), l'utente ha scelto di rimandare e di rendere prima super efficiente la versione Mac.
- Idee non ancora fatte: parser Sony Venice, report automatico a fine offload, notifiche di sistema, ottimizzazioni misurate su Mac reale.
