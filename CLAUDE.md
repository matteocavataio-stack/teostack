# TeoStackXt — contesto del progetto (letto in automatico a inizio sessione)

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
  audio = `ClipRecord.isAudio` (colonna `clip.isAudio`, migrazione v6), file «._» di macOS mai clip (`MediaClassifier.isAppleDouble`); Sony Venice ancora in attesa di file di esempio (XML sidecar + output ExifTool). Metadata/anteprime in parallelo (`ParallelRunner`).
- Report (`Reports/`): 5 PDF separati nel formato Silverstack «Classic» (Shooting Day, Clips, Volume, Thumbnail, Contact Print), scritti da un PDF writer proprio con font DejaVu Sans Mono incorporato;
  nome file `<Report_Name>-<bin>-<aaaa-mm-gg-HHmm>.pdf`; report di una cartella = tutti i bin contenuti; Clips e Thumbnail stampano solo le colonne scelte dall'utente («Name» sempre). Campi sconosciuti vuoti.
- Installer (`packaging/`): app universale Intel+ARM, icona dal logo, ExifTool/ffmpeg/ffprobe inclusi (`fetch-tools.sh`, con cache e ripiego GitHub se evermeet.cx dà 429), `.pkg` (scarica art-cmd da ARRI) e `.dmg`. Firma ad-hoc: al primo avvio clic destro → Apri.

## Lingue (Italiano / English / Castellano / Català)
- `Localization/Loc.swift` + `LocStrings.swift`: la chiave è il testo italiano, i segnaposto sono `{0}`, `{1}`… (mai interpolazioni Swift dentro `tr("…")`). Ogni testo nuovo va aggiunto come riga (it, en, es, ca)
  in `LocStrings.swift`: il test `LocalizationTests` cerca nei sorgenti tutti i `tr("…")`/`LocText("…")` e fallisce se manca una lingua o un segnaposto.
- UI: `tr()` ovunque; `LanguageSettings` + `LanguageMenu` (in basso a sinistra nella barra laterale); `.id(lingua)` sul contenuto di `ContentView` (non sul livello che possiede `AppModel`).
- I report PDF restano in inglese e con «N/D» (`ClipColumns.reportNotAvailable`); la cronologia salva chiave+parametri (`LocText`, colonna `event.i18n`) così segue la lingua.
- Altre funzioni: percorsi di destinazione salvati (`SavedPathsStore`, menu «Percorsi salvati»), riepilogo cartella (`ProjectRecap`, `RecapPanel`).

## Stato
- Tutto quanto sopra è implementato e pubblicato sul branch. Non provato su macOS reale: nuovi controlli UI (menu «Schede collegate», «Espelli sorgente», suono, trascinamento nodi, finestra «Esporta report» con colonne), gli effetti di velocità su dischi veri (da misurare col benchmark), `art-cmd process` per le anteprime ARRI.
- Windows: valutato (riscrittura in C#/Avalonia), l'utente ha scelto di rimandare e di rendere prima super efficiente la versione Mac.
- Idee non ancora fatte: parser Sony Venice, report automatico a fine offload, notifiche di sistema, ottimizzazioni misurate su Mac reale.
