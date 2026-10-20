# TeoStackXt

App macOS (Swift + SwiftUI, macOS 14+) per DIT: offload con certificazione XXH64, progetti, metadata e report.
Versione semplificata ispirata a Silverstack XT. Interfaccia in italiano.

## Stato dei lavori

| Fase | Contenuto | Stato |
|------|-----------|-------|
| a | Offload + XXH64 + UI base | **fatta** (nucleo testato su Linux; UI da compilare su Mac) |
| b | Progetti (SQLite/GRDB, Progetto → Library → Giorno → Bin), tabella clip | **fatta** (database testato su Linux; UI da compilare su Mac) |
| c | Metadata ARRI / Sony Venice | da fare (servono informazioni, vedi domande) |
| d | Report fase 1 | da fare |
| e | Report fase 2 (thumbnail, contact print) | da fare |

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
