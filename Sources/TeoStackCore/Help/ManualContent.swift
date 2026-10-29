import Foundation

/// Testo del manuale utente (italiano, lingua di origine; le altre lingue sono in `ManualStrings`). Descrive ciò che l'app fa davvero; ciò che non è stato provato su file reali è dichiarato come tale.
enum ManualContent {
    /// Il manuale nella lingua richiesta: ogni testo italiano è sostituito dalla sua traduzione (se manca, resta italiano).
    static func blocks(for language: AppLanguage) -> [ManualBlock] {
        guard language != .italian, let table = ManualStrings.tables[language] else { return blocks }
        func t(_ s: String) -> String { table[s] ?? s }
        return blocks.map { block in
            switch block {
            case .h1(let s): return .h1(t(s))
            case .h2(let s): return .h2(t(s))
            case .p(let s): return .p(t(s))
            case .bullets(let a): return .bullets(a.map(t))
            case .steps(let a): return .steps(a.map(t))
            case .note(let s): return .note(t(s))
            case .warning(let s): return .warning(t(s))
            case .code(let a): return .code(a.map(t))
            case .table(let header, let rows, let widths): return .table(header: header.map(t), rows: rows.map { $0.map(t) }, widths: widths)
            }
        }
    }

    static let blocks: [ManualBlock] = intro + install + interface + projects + offload + importMedia + clipTab + metadata + reports + settings + shortcuts + files + troubleshooting + limits + glossary

    // MARK: 1

    static let intro: [ManualBlock] = [
        .h1("1. Che cos'è TeoStackPro"),
        .p("TeoStackPro è un'app per macOS pensata per il lavoro del DIT (Digital Imaging Technician) sul set. Scarica le schede camera su uno o più dischi **verificando ogni file**, organizza il materiale in progetti, legge i metadata dei clip e crea i report in PDF."),
        .h2("Che cosa fa"),
        .bullets([
            "**Offload verificato**: copia una scheda o una cartella su 1-8 destinazioni insieme. Un file è «OK» solo dopo essere stato riletto dal disco di destinazione con un hash XXH64 identico a quello della sorgente.",
            "**Progetti**: Progetto > Library > giorno > cartelle > bin, con cronologia e riepilogo (spazio scaricato, clip, schede, durata per codec, formati, somme per camera).",
            "**Metadata dei clip**: ARRI, RED, Sony, DJI, Canon, Panasonic, Blackmagic, Phantom, ProRes, MXF, DNG, H.264, audio BWF e altri. Legge solo ciò che il file dichiara; ciò che manca resta «N/D».",
            "**Anteprime**: il primo fotogramma di ogni clip video.",
            "**Report PDF**: Shooting Day, Clips, Volume, Thumbnail e Contact Print, con profili di esportazione da salvare.",
            "**Certificato ASC MHL 2.0**: lo stesso tipo di file «mhl» creato da Silverstack, nella cartella della copia.",
            "**Esporta metadata** in JSON, CSV e ALE; **importa log** esterni (ALE, CSV, XML); **importa media** senza copiarli.",
            "**Personalizzazione**: colori, carattere e dimensione delle scritte; interfaccia in italiano, inglese, castellano e catalano.",
        ]),
        .h2("Principi di sicurezza"),
        .bullets([
            "La sorgente è **sola lettura**: l'app non modifica né cancella mai nulla sulla scheda.",
            "Un file è «OK» **solo dopo la rilettura dal disco** con hash identico. Nessun falso OK: un errore è sempre mostrato con un messaggio chiaro (disco scollegato, spazio insufficiente, file illeggibile).",
            "Un file già presente nella destinazione **non viene mai sovrascritto**.",
            "L'app **non inventa valori**: un dato sconosciuto resta vuoto nei report e «N/D» nelle tabelle.",
        ]),
        .h2("Che cosa NON fa"),
        .p("Non transcodifica, non riproduce i clip, non fa color grading e non applica LUT. Non include gli SDK dei costruttori (RED, Blackmagic, Sony, Canon): i dati che richiedono quegli SDK non sono letti."),
    ]

    // MARK: 2

    static let install: [ManualBlock] = [
        .h1("2. Installazione e primo avvio"),
        .h2("Requisiti"),
        .bullets([
            "Un Mac con macOS 14 o successivo.",
            "Spazio libero sui dischi di destinazione pari almeno alla dimensione della scheda (l'app controlla prima di iniziare).",
        ]),
        .h2("Installare l'app"),
        .steps([
            "Apri il file **TeoStackPro-<versione>.dmg** e trascina TeoStackPro nella cartella Applicazioni. In alternativa usa l'installer **.pkg**, che scarica anche art-cmd (vedi sotto).",
            "Al **primo avvio** fai clic destro sull'app e scegli **Apri**, poi conferma. L'app non ha la firma a pagamento di Apple: macOS lo chiede una sola volta.",
            "Se hai una versione precedente, chiudila prima e sostituiscila: progetti e impostazioni restano.",
        ]),
        .h2("Programmi esterni"),
        .p("Per leggere i metadata l'app usa alcuni programmi esterni. **ExifTool**, **ffprobe** e **ffmpeg** sono già dentro l'app. **art-cmd** (ARRI Reference Tool) va installato a parte e serve per i dati dei clip ARRI: ISO, bilanciamento del bianco, tint, shutter, lente, ND, look, scena/take, tilt e roll."),
        .p("Se un programma manca, in alto compare un avviso rosso con i pulsanti **Come installarli** (mostra i comandi da incollare nel Terminale), **Ricontrolla** e **Scegli art-cmd…** (per indicare a mano dove si trova). art-cmd viene cercato nella cartella **~/ARRI**."),
        .code(["mkdir -p ~/ARRI && cd ~/ARRI", "curl -L -o art-cmd.zip \"<indirizzo del download ARRI mostrato dall'app>\"", "unzip -q -o art-cmd.zip && xattr -dr com.apple.quarantine ~/ARRI"]),
        .note("Non spostare il file art-cmd fuori dalla sua cartella: ha bisogno della sottocartella «lib» che gli sta accanto."),
        .h2("Dove sono i tuoi dati"),
        .p("Progetti, cronologia e anteprime stanno nella cartella **~/Library/Application Support/TeoStackXt** (il vecchio nome interno è rimasto per non perdere i dati): il database **teostack.sqlite**, la cartella **Journal** (serve a «Riprendi») e **Thumbnails**. Le impostazioni (colori, colonne, profili dei report) sono nelle preferenze dell'app."),
    ]

    // MARK: 3

    static let interface: [ManualBlock] = [
        .h1("3. L'interfaccia"),
        .p("La finestra ha tre zone: la barra in alto, la barra laterale con l'albero del progetto e l'area centrale. A destra si può mostrare la cronologia."),
        .h2("Barra in alto"),
        .table(header: ["Pulsante", "Che cosa fa"], rows: [
            ["Nuovo progetto", "Crea un progetto (con la sua Library)."],
            ["Rinomina", "Rinomina il progetto selezionato, solo nel programma."],
            ["Elimina progetto", "Elimina l'INTERO progetto dal programma. I file sui dischi non vengono toccati."],
            ["Offload", "Mostra la schermata di scarico: sorgente, destinazioni, avanzamento."],
            ["Clip", "Mostra l'elenco dei clip con metadata, anteprime e riepilogo."],
            ["Importa media", "Aggiunge clip al progetto senza copiarli."],
            ["Esporta report", "Apre la finestra per creare i report PDF."],
            ["Impostazioni", "Suono al termine, colori, carattere e dimensione delle scritte."],
        ], widths: [1.4, 4]),
        .p("Il selettore a tendina «Progetto» sceglie il progetto su cui lavori."),
        .h2("Barra laterale"),
        .bullets([
            "L'**albero** del progetto: Library (radice), cartelle giorno, sottocartelle e bin. Ogni bin ha un pallino: **verde** = tutti i file verificati, **rosso** = ci sono problemi, un offload annullato o file importati senza copia, **arancione** = offload in corso.",
            "**+ Giorno** e **+ Cartella** creano cartelle dentro quella selezionata. **Elimina selezione…** elimina solo l'elemento selezionato.",
            "In basso: il menu della **lingua**, **Impostazioni** e **Aiuto** (questo manuale).",
        ]),
        .h2("Cronologia"),
        .p("Il pulsante **Mostra cronologia / Nascondi cronologia** apre il pannello di destra. Registra solo gli «Offload completato … tutti OK». **Cancella…** svuota la cronologia del progetto; clip, offload e file sui dischi non vengono toccati."),
    ]

    // MARK: 4

    static let projects: [ManualBlock] = [
        .h1("4. Progetti"),
        .h2("Struttura"),
        .p("Un progetto contiene una **Library**; dentro la Library si possono creare cartelle **giorno** (per esempio DAY01_20261016), eventuali **sottocartelle** (per esempio CAM_A) e infine i **bin**. I bin si creano da soli quando avvii un offload."),
        .steps([
            "Premi **Nuovo progetto** e dai un nome.",
            "Seleziona la Library (radice) o una cartella e usa **+ Giorno** per la cartella della giornata e **+ Cartella** per ordinare ulteriormente. Entrambe sono facoltative.",
            "Seleziona la cartella che deve ospitare il bin: l'offload lo creerà lì.",
        ]),
        .h2("Spostare, rinominare, eliminare"),
        .bullets([
            "**Sposta**: trascina un elemento sopra la nuova cartella, oppure clic destro > **Sposta in**.",
            "**Rinomina** (clic destro o pulsante in alto) cambia il nome solo nel programma: le cartelle già create sui dischi non vengono rinominate.",
            "**Elimina selezione…** elimina solo la cartella o il bin selezionati, con le sottocartelle, e mostra quanti offload e file registrati verrebbero rimossi dal programma. I file sui dischi NON vengono mai toccati.",
        ]),
        .h2("Riepilogo di una cartella"),
        .p("Selezionando la Library, un giorno, una cartella o un bin, la schermata Offload mostra il **riepilogo**: spazio verificato, numero di clip, schede scaricate, durata totale **separata per codec** (mai un totale per progetto), formati video e audio, bobine, somme per camera e tabella dei backup per numero di copie verificate. Se mancano i metadata di alcuni clip il riepilogo lo dice (usa «Leggi metadata» nel tab Clip)."),
    ]

    // MARK: 5

    static let offload: [ManualBlock] = [
        .h1("5. Offload: la copia verificata"),
        .h2("Passo per passo"),
        .steps([
            "**Progetto e posizione**: scegli il progetto e seleziona nella barra laterale la cartella che ospiterà il bin.",
            "**Sorgente**: premi **Scegli sorgente…**, oppure apri il menu **Schede collegate** (elenca schede e dischi esterni), oppure trascina la scheda nell'area «Trascina qui la scheda». L'app legge l'elenco dei file e mostra dimensione e numero. Collegamenti simbolici e file speciali non vengono copiati e sono segnalati.",
            "**Nome del bin**: è proposto dal nome della sorgente e lo puoi cambiare. Se esiste già un bin con quel nome, l'offload viene aggiunto a quello.",
            "**Destinazioni**: da 1 a 8. **Aggiungi destinazione** e poi **Scegli…** per ognuna. Sotto compare il percorso che verrà creato: la cartella scelta più il nome del bin.",
            "**Percorsi salvati**: il menu salva i percorsi che usi di solito («Salva i percorsi scelti»), li richiama per una destinazione, li applica tutti in una volta («Usa tutti i percorsi salvati») o li toglie.",
            "**Opzioni** (sotto la barra di avanzamento): vedi sotto. Il suono di fine offload si imposta in Impostazioni.",
            "Premi **Avvia**. Con **Annulla** fermi tutto in qualsiasi momento.",
        ]),
        .h2("Le opzioni"),
        .table(header: ["Opzione", "Significato"], rows: [
            ["Verifica durante la copia", "Ogni file viene riletto e confrontato appena scritto, mentre la copia prosegue: più veloce con gli SSD. Con dischi lenti (HDD) toglila: la verifica parte a copia finita."],
            ["Crea certificato ASC MHL", "Scrive la cartella «ascmhl» nella copia (vedi sotto). Attiva di serie."],
            ["Svuota la sorgente a fine offload", "Quando tutti i file sono OK, la parte «Sorgente» dell'app si svuota da sola, pronta per la scheda successiva. NON cancella nulla dalla scheda. Se ci sono problemi l'elenco resta."],
        ], widths: [1.6, 4]),
        .h2("Che cosa succede durante l'offload"),
        .steps([
            "**Controlli preliminari**: destinazioni raggiungibili, spazio sufficiente, nessuna destinazione dentro la sorgente.",
            "**Copia**: la sorgente è letta **una sola volta** e l'hash XXH64 è calcolato durante la lettura. Ogni destinazione riceve il file con il nome provvisorio «.teostackpart».",
            "**Verifica**: il file viene riletto dal disco, senza usare la cache, e il suo hash è confrontato con quello della sorgente. Solo se identico il file riceve il nome definitivo e diventa «OK».",
            "**Certificato ASC MHL**: scritto alla fine, solo per le destinazioni dove tutti i file sono OK.",
        ]),
        .p("Durante il lavoro vedi, per ogni destinazione, l'avanzamento di scrittura e di verifica, la velocità di lettura e di scrittura, il tempo trascorso e l'ETA. I file passano da «In attesa» a «Copia», «Da verificare», «Verifica» e infine **OK**, **MISMATCH** (hash diverso) o **ERRORE**."),
        .h2("Il risultato"),
        .bullets([
            "**Banner verde «TUTTI I FILE OK»**: tutti i file sono stati riletti dal disco con XXH64 identico alla sorgente.",
            "**Banner rosso «ATTENZIONE»**: indica quanti file sono in MISMATCH o in errore e quante destinazioni si sono interrotte. I file non OK non vanno considerati copiati.",
            "Con tutti i file OK compare **Espelli sorgente**, che smonta ed espelle la scheda (solo dopo un offload riuscito).",
            "L'esito entra nella cronologia e nel pallino del bin.",
        ]),
        .h2("Annullare, riprendere, problemi"),
        .bullets([
            "**Annulla** rimuove i file parziali e le cartelle create dall'offload. I file già verificati restano.",
            "**Riprendi** continua dai file già verificati (la memoria è nella cartella Journal): si ricopiano solo gli altri.",
            "Se un **disco di destinazione sparisce** o si riempie, quella destinazione si interrompe con un messaggio chiaro e le altre continuano. L'app non ricrea mai il percorso di un disco scollegato sul disco di avvio.",
            "Se nella destinazione esiste già un file con lo stesso nome e contenuto diverso, **non viene toccato** e il file risulta in MISMATCH.",
            "Le date di modifica dei file e delle cartelle sono riportate sulle copie.",
        ]),
        .h2("Certificato ASC MHL"),
        .p("A offload riuscito l'app scrive, dentro la cartella della copia, la cartella **ascmhl** con un file **.mhl** (formato ASC MHL 2.0, processo «transfer», hash XXH64 dei file e delle cartelle) e il file **ascmhl_chain.xml** con l'elenco delle generazioni. È quello che Silverstack chiama certificato di copia."),
        .bullets([
            "Viene scritto **solo** per le destinazioni dove **tutti** i file sono verificati OK, mai se annulli.",
            "Un secondo offload nella stessa cartella aggiunge una nuova **generazione**: i file uguali risultano «verified», quelli cambiati «failed», quelli nuovi «original».",
            "Il campo autore è il nome scritto in «Operatore» nella finestra dei report.",
            "Se la cartella «ascmhl» già presente non si legge, il certificato non viene scritto e l'app lo segnala.",
        ]),
    ]

    // MARK: 6

    static let importMedia: [ManualBlock] = [
        .h1("6. Importa media"),
        .p("**Importa media** aggiunge clip al progetto **senza copiarli**: servono a leggere i metadata, vedere le anteprime ed esportare i report di materiale che hai già su un disco. I file non vengono copiati né modificati."),
        .steps([
            "Seleziona nel progetto la cartella che deve ospitare i bin.",
            "Premi **Importa media** e scegli cartelle e/o file.",
            "Per ogni **cartella** scelta nasce un bin con il nome della cartella; per ogni **file** scelto nasce un bin con **lo stesso nome del file**.",
            "I metadata e le anteprime vengono letti subito.",
        ]),
        .note("I file importati hanno lo stato «importato»: non sono verificati, non contano come copia verificata e il bin resta col pallino rosso. Sono contati a parte nel riepilogo."),
    ]

    // MARK: 7

    static let clipTab: [ManualBlock] = [
        .h1("7. Il tab Clip"),
        .p("Il pulsante **Clip** mostra la tabella dei clip della cartella o del bin selezionati. Selezionando una riga, a destra compaiono l'anteprima (primo fotogramma) e i dati principali del clip, con l'elenco **Tutti i tag letti** (anche quelli senza colonna)."),
        .h2("Pulsanti sopra la tabella"),
        .table(header: ["Pulsante", "Che cosa fa"], rows: [
            ["Mostra anche i file non video", "Aggiunge alla tabella XML, sidecar e altri file registrati."],
            ["Crea anteprime", "Crea l'anteprima del primo fotogramma dei clip che non ce l'hanno (ARRI: con art-cmd e il look incorporato; gli altri con ffmpeg). I clip audio non hanno anteprima."],
            ["Leggi metadata", "Legge i metadata dei clip mostrati. Si legge sempre la copia verificata sul disco di destinazione (o il file importato), mai la scheda sorgente."],
            ["Importa log…", "Importa un log esterno (vedi sotto)."],
            ["Esporta metadata", "Salva i metadata dei clip mostrati in JSON, CSV o ALE."],
            ["Colonne", "Sceglie quali colonne mostrare."],
        ], widths: [1.7, 4]),
        .h2("Organizzare le colonne"),
        .bullets([
            "**Mostrare o nascondere**: menu **Colonne** (dati dell'offload e metadata camera).",
            "**Cambiare la larghezza**: trascina il bordo destro del titolo della colonna.",
            "**Spostare**: trascina il titolo sopra un'altra colonna, oppure clic destro sul titolo > **Sposta a sinistra / destra**.",
            "**Ordinare**: clicca il titolo (una seconda volta inverte l'ordine).",
            "Clic destro sul titolo: **Larghezza standard** e **Nascondi colonna**. Nel menu Colonne, **Ripristina ordine e larghezze** riporta tutto come prima.",
            "Ordine e larghezze si ricordano tra un avvio e l'altro.",
        ]),
        .h2("Esportare i metadata"),
        .p("**Esporta metadata** crea un file con i clip mostrati. Ogni riga include l'**XXH64** calcolato in copia: così ogni dato è legato alla verifica."),
        .bullets([
            "**JSON**: per ogni clip nome, percorso, bin, dimensione, XXH64, stato, stato per destinazione, tutti i campi e i tag extra.",
            "**CSV**: una riga per clip; i campi non letti restano celle vuote (mai «N/D»).",
            "**ALE** (Avid Log Exchange): colonne Name, Tracks, Start, End, Tape, Source File e i campi presenti; la riga FPS è quella più frequente tra i clip. «End» è calcolato da inizio e durata solo con frame rate intero.",
        ]),
        .h2("Importare un log esterno"),
        .p("**Importa log…** legge un file **ALE**, **CSV** (virgola, punto e virgola o tab) oppure **XML** a record ripetuti e aggiunge ai clip i dati scritti sul set: scena, take, tape/reel, camera, note e ogni altra colonna del file (conservata nei tag extra)."),
        .bullets([
            "I clip si abbinano per **nome del file** (con o senza estensione) oppure per **timecode iniziale e data**. Se più clip sono possibili la riga è ignorata e segnalata.",
            "I valori **già presenti non vengono mai sovrascritti**, a meno che spunti **Sovrascrivi i valori già presenti** nella finestra di scelta del file.",
            "Alla fine vedi quante righe sono state abbinate, quanti campi scritti e quante righe senza clip.",
        ]),
    ]

    // MARK: 8

    static let metadata: [ManualBlock] = [
        .h1("8. I metadata: che cosa legge"),
        .p("L'app legge i metadata dalla copia verificata (non dalla scheda) combinando più fonti: **art-cmd** per ARRI, **ExifTool** (tag del file), **ffprobe** (dati tecnici: codec, risoluzione, frame rate, durata, audio) e alcuni lettori propri (RED, Phantom, audio BWF, XML di accompagnamento). Per ogni campo vale ciò che il file dichiara."),
        .h2("Per formato"),
        .table(header: ["Formato", "Dati letti", "Stato della verifica"], rows: [
            ["ARRI (MXF, ProRes, ARRIRAW)", "Camera, seriale, firmware, risoluzione, fps, durata, timecode, reel, scena/take, ISO, WB, tint, shutter e angolo, ND, lente, focale, T-stop, fuoco, look, audio. Tilt e roll solo se la camera li scrive.", "Provato su clip reali Alexa 35 e Mini LF. I dati ARRI richiedono art-cmd."],
            ["RED (.R3D)", "Modello, lettera camera, reel, take, seriale, firmware, risoluzione, fps, ISO, WB, codec, data, timecode iniziale.", "Provato su un clip reale V-RAPTOR. Durata e numero di fotogrammi non sono nell'intestazione."],
            ["Sony (XAVC, MXF, X-OCN, RAW)", "Dati tecnici dal file; modello, seriale, data, fotogrammi e impostazioni dal file XML accanto al clip (…M01.XML).", "Provato su un MXF VENICE 2: parziale. Gli XML non sono provati su clip reali."],
            ["DJI (ProRes RAW, DNG, MP4)", "Camera, seriale, firmware, lente, ISO, WB, shutter, diaframma, reel, nome clip, timecode, look, GPS e dati di volo nei tag extra.", "Provato su Inspire 3."],
            ["ProRes, H.264, MPG, MOV, MP4, LRF", "Codec, risoluzione, fps, durata, fotogrammi, timecode, colore, audio, reel; camera solo se dichiarata.", "Provato su file reali."],
            ["Audio WAV/BWF", "Registratore, scena, take, nastro, tracce, timecode, frequenza, canali.", "Provato su un file reale."],
            ["Canon, Panasonic, Blackmagic, Kinefinity, Phantom", "Dati tecnici ed EXIF dichiarati; per BRAW, KRW e Cine solo l'identità del formato e quanto è leggibile.", "Scritti ma non provati su file reali."],
            ["Foto, DPX, DNG, TIFF", "Camera, modello, ISO, diaframma, focale, lente, shutter, data, dimensioni, timecode DNG. Mai durata né fps.", "Provato su DNG DJI."],
        ], widths: [1.5, 3.4, 2.2]),
        .h2("Le colonne"),
        .p("Camera, Costruttore, Serial camera, Firmware, Reel, Scena, Take, Indice camera, Shutter, Angolo shutter, Color space, Gamma, Look Info, ND Filter, Lente, Serial lente, Focale, Diaframma, T-stop, Distanza fuoco, ISO, WB, Tint, Tilt, Roll, Data ripresa, Durata, Fotogrammi, FPS (file), Sensor FPS, Codec, Contenitore, Risoluzione, Timecode, Audio codec, Audio tracce, Audio sample rate, Audio bit, Registratore, Nomi tracce. Più le colonne dell'offload: Anteprima, Nome, Giorno, Bin, Dimensione, XXH64, Stato, Offload, Percorso."),
        .h2("N/D e valori calcolati"),
        .bullets([
            "**N/D** significa che il file non contiene il dato (o che manca il programma che lo legge). Non è un errore. Per esempio la Mini LF non scrive tilt e roll.",
            "Pochi valori sono **calcolati** da due dati dichiarati: l'angolo dello shutter (360° × tempo × fps del sensore), il T-stop ARRI (dal valore dell'iride) e il numero di fotogrammi di un MXF (durata × fps).",
            "I dati dinamici ARRI sono quelli del **primo fotogramma**. Zoom, fuoco e ND variabili durante la ripresa non sono seguiti.",
            "Dopo aver aggiornato l'app, premi di nuovo **Leggi metadata** per aggiornare i clip già letti.",
        ]),
    ]

    // MARK: 9

    static let reports: [ManualBlock] = [
        .h1("9. Report PDF"),
        .p("**Esporta report** (anche con Maiusc+Comando+E) crea i report del bin, della cartella o del progetto selezionato nella barra laterale. Se scegli una cartella, il report comprende tutti i bin contenuti. Ogni report è un PDF separato."),
        .h2("I cinque report"),
        .table(header: ["Report", "Contenuto"], rows: [
            ["Shooting Day Report", "Statistiche della giornata: clip, workflow, backup per numero di copie verificate, bin, camere, formati video e audio."],
            ["Clips Report", "Una riga per clip con le colonne che scegli. «Name» c'è sempre."],
            ["Volume Report", "Elenco dei file con dimensione e hash XXH64 reali."],
            ["Thumbnail Report", "Anteprime dei clip con le colonne scelte. Le anteprime compaiono se sono già state create (tab Clip)."],
            ["Contact Print Report", "Griglia di anteprime, in pagina orizzontale."],
        ], widths: [1.7, 4]),
        .p("I report sono in inglese e usano «N/D» per i dati sconosciuti, come i report di riferimento. Il nome del file è «<Nome report>-<bin>-<aaaa-mm-gg-HHmm>.pdf»; un file esistente non viene mai sovrascritto (si aggiunge « 2», « 3»…)."),
        .h2("La finestra di esportazione"),
        .steps([
            "Scrivi il **nome del progetto** e l'**operatore** (il DIT).",
            "Spunta i **report da creare**.",
            "Spunta le **colonne** dei report Clips e Thumbnail. Questa scelta è indipendente da quella del tab Clip.",
            "Premi **Esporta PDF…**, scegli la cartella e, a fine lavoro, **Mostra nel Finder**.",
        ]),
        .h2("Profili di esportazione"),
        .p("Per non rifare le scelte ogni volta puoi salvare dei **profili**: ognuno ricorda quali report creare, quali colonne stampare e l'operatore."),
        .bullets([
            "**Salva come…** salva le scelte attuali con un nome (per esempio «Consegna produzione»). Due profili non possono avere lo stesso nome.",
            "Il menu **Profilo** applica un profilo in un colpo. Alla riapertura della finestra si riparte dall'ultimo usato.",
            "Se cambi una spunta compare **modificato**: **Aggiorna** salva le nuove scelte nel profilo, **Salva come…** ne crea uno nuovo.",
            "Il menu **Altro**: **Rinomina…**, **Elimina profilo…**, **Esporta profili…** (file da portare su un altro Mac) e **Importa profili…** (i profili con un nome già presente non sostituiscono quelli esistenti: prendono un nome tipo «… 2»).",
        ]),
    ]

    // MARK: 10

    static let settings: [ManualBlock] = [
        .h1("10. Impostazioni e lingua"),
        .h2("Generale"),
        .p("Il pulsante **Impostazioni** (anche Comando+virgola, o in basso a sinistra) apre la finestra delle impostazioni. In alto c'è la parte generale:"),
        .bullets([
            "**Suono al termine**: un suono a fine offload (diverso se ci sono problemi) e il Dock rimbalza se l'app non è in primo piano. Attivo di serie.",
        ]),
        .h2("Aspetto"),
        .p("Sotto, l'aspetto dell'app:"),
        .bullets([
            "**Modelli pronti**: Predefinito del sistema, Chiaro, Scuro, Contrasto alto, Seppia e Notte (rosso, per lavorare al buio sul set).",
            "**Colore dello sfondo** e **colore delle scritte**: con il selettore dei colori. «Predefinito» ripristina quello di sistema.",
            "**Carattere**: tra quelli installati sul Mac, o quello di sistema.",
            "**Dimensione delle scritte**: dall'80% al 150%.",
        ]),
        .p("Un'anteprima mostra il risultato. Se sfondo e scritte hanno colori troppo simili compare un avviso. **Ripristina predefiniti** riporta tutto com'era. Con uno sfondo scuro l'app passa da sola alla modalità scura. Tabelle di sistema, testi molto piccoli e finestre a parte (come «Esporta report») possono mantenere i colori di sistema."),
        .h2("Lingua"),
        .p("Il menu della lingua, in basso a sinistra, cambia l'interfaccia tra **Italiano**, **English**, **Castellano** e **Català**. La scelta si ricorda. I report PDF restano in inglese. Questo manuale (menu Aiuto) segue la lingua scelta: se cambi lingua, riaprilo per averlo nella nuova lingua."),
    ]

    // MARK: 11

    static let shortcuts: [ManualBlock] = [
        .h1("11. Scorciatoie"),
        .table(header: ["Tasti", "Azione"], rows: [
            ["Comando + virgola", "Apre le Impostazioni."],
            ["Maiusc + Comando + E", "Apre «Esporta report» (con un progetto selezionato)."],
            ["Invio", "Conferma il pulsante principale della finestra (per esempio «Avvia» nell'offload, «Esporta PDF…» nella finestra dei report)."],
            ["Esc", "Chiude la finestra aperta (per esempio «Esporta report»)."],
            ["Comando + ?", "Apre questo manuale."],
        ], widths: [2, 4.4]),
    ]

    // MARK: 12

    static let files: [ManualBlock] = [
        .h1("12. Quali file crea l'app"),
        .bullets([
            "**Sulle destinazioni**: la cartella del bin con la stessa struttura della sorgente. Durante la copia i file hanno l'estensione provvisoria **.teostackpart**, che sparisce a verifica riuscita (se resta, il file non è verificato). A offload riuscito anche la cartella **ascmhl**.",
            "**Sulla sorgente**: niente. L'app non scrive mai sulla scheda.",
            "**Nell'app**: ~/Library/Application Support/TeoStackXt con il database dei progetti (teostack.sqlite), il Journal degli offload e le anteprime in JPEG.",
            "**Report ed esportazioni**: solo nelle cartelle che scegli tu.",
        ]),
    ]

    // MARK: 13

    static let troubleshooting: [ManualBlock] = [
        .h1("13. Se qualcosa non va"),
        .table(header: ["Problema", "Causa probabile", "Che cosa fare"], rows: [
            ["Molti N/D nei clip ARRI", "art-cmd non è installato o non viene trovato.", "Guarda l'avviso in alto; installa art-cmd in ~/ARRI o usa «Scegli art-cmd…», poi «Leggi metadata»."],
            ["Metadata vuoti dopo un aggiornamento", "I clip erano stati letti con una versione precedente.", "Premi «Leggi metadata» sui clip."],
            ["macOS non apre l'app", "L'app non ha la firma Apple a pagamento.", "Clic destro sull'app > Apri, solo la prima volta."],
            ["L'offload non parte", "Spazio insufficiente, destinazione non raggiungibile o dentro la sorgente.", "Leggi il messaggio dei controlli preliminari e correggi la destinazione."],
            ["MISMATCH", "Il file riletto ha un hash diverso, oppure nella destinazione c'era già un file con quel nome.", "Non considerare il file copiato. Controlla disco e cavo; con «Riprendi» si ricopiano i file non OK."],
            ["Destinazione interrotta", "Disco scollegato o pieno.", "Ricollega o libera spazio e premi «Riprendi»."],
            ["Certificato ASC MHL non creato", "Qualche file non è OK, oppure l'offload è stato annullato, o la cartella «ascmhl» esistente non si legge.", "Risolvi i file non OK e ripeti; il messaggio sotto il banner indica il motivo."],
            ["Anteprime non create", "Mancano ffmpeg o art-cmd, o il file non è decodificabile (alcuni RAW).", "Controlla l'avviso dei programmi; il motivo è scritto nel pannello del clip."],
            ["Colonne sparite o spostate", "Scelte precedenti.", "Menu «Colonne» > «Ripristina ordine e larghezze»."],
            ["Un report non si crea", "Cartella non scrivibile o nessun clip nell'ambito.", "Il messaggio sotto i pulsanti lo spiega; scegli un'altra cartella."],
        ], widths: [1.6, 2.2, 3.2]),
        .h2("Per l'assistenza"),
        .p("Lo script **estrai-metadata.command** (nel repository del progetto) legge una cartella di clip e crea una cartella con i JSON di ExifTool, ffprobe e art-cmd di ogni file, più uno zip da inviare. Non modifica né copia le clip."),
    ]

    // MARK: 14

    static let limits: [ManualBlock] = [
        .h1("14. Limiti da conoscere"),
        .bullets([
            "Gli **SDK** di RED, Blackmagic RAW, Sony e Canon non sono inclusi: i dati che solo loro leggono non sono disponibili.",
            "I dati **per fotogramma** (lente, tilt, roll, ND variabile) sono letti solo per il primo fotogramma.",
            "Le **sequenze** di fotogrammi (DPX, DNG, TIFF) non sono raggruppate in un clip: foto e fotogrammi si leggono ma non contano come clip.",
            "I formati marcati «non provati» nella tabella dei metadata sono scritti secondo la documentazione ma non verificati su file reali: se trovi dati sbagliati o mancanti, segnalalo.",
            "L'app è per macOS. Non esiste una versione per Windows.",
        ]),
    ]

    // MARK: 15

    static let glossary: [ManualBlock] = [
        .h1("15. Glossario"),
        .table(header: ["Termine", "Significato"], rows: [
            ["Offload", "Lo scarico di una scheda camera su uno o più dischi, con verifica."],
            ["Bin", "La cartella di un progetto che raccoglie i clip di un offload o di un'importazione."],
            ["XXH64", "Hash veloce a 64 bit usato per confrontare sorgente e copia."],
            ["MISMATCH", "File riletto con hash diverso da quello della sorgente: copia non valida."],
            ["ASC MHL", "Formato standard (ASC Media Hash List) del certificato di copia con gli hash dei file."],
            ["Sidecar", "File accanto al clip, per esempio l'XML di una camera Sony."],
            ["Reel", "Nome della bobina o del magazzino del clip."],
            ["Timecode", "Codice orario del primo fotogramma, nella forma ore:minuti:secondi:fotogrammi."],
            ["ALE", "Avid Log Exchange: file di testo con i dati dei clip."],
            ["N/D", "Non disponibile: il file non contiene quel dato."],
        ], widths: [1.4, 4.6]),
    ]
}
