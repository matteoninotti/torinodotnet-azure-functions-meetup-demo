# Istruzioni di progetto — Confronto Azure Functions tra linguaggi

## Obiettivo
Presentazione tecnica (45–60 minuti, con demo live) rivolta a un pubblico professionale IT, incentrata sul confronto di performance e costi di Azure Functions tra diversi linguaggi di programmazione.

**Lingua di output**: italiano — slide, testo rivolto al pubblico, commenti nel codice destinati alla presentazione. Codice sorgente e nomi delle variabili restano in **inglese** (vedi decision log `<vault>/altro/dotnet_lambda/dotnet_lambda-log.md`, D18).

---

## REGOLA SULLE FONTI (vincolante)

Ogni affermazione fattuale in questo documento e in tutto il materiale del progetto deve avere il **link inline alla fonte, incollato accanto all'affermazione**. Non basta descrivere la pagina ("docs Microsoft Learn su Flex Consumption"): serve l'URL cliccabile.

- Le fonti devono essere **ufficiali**: Microsoft Learn per Azure, documentazione del progetto per le librerie.
- Quando una fonte ufficiale **non esiste o non è stata trovata**, va scritto esplicitamente `⚠️ FONTE UFFICIALE NON TROVATA` accanto all'affermazione, insieme a quello che si è comunque trovato (fonte community, inferenza) e a come si intende verificarlo.
- Le fonti community valgono solo come conferma incrociata, mai come base per un numero da slide.
- Se una fonte nuova corregge una vecchia, va segnalato il cambiamento, non sostituito silenziosamente.

---

## Principi guida (in tensione tra loro — vanno bilanciati caso per caso)

### 1. Regola del realismo
Si privilegia la scelta **realistica e idiomatica** per ciascun ecosistema rispetto alla purezza teorica del confronto. Sono ammesse stdlib e librerie di terze parti anche quando internamente usano codice nativo C/C++ (es. Pillow).

### 2. Simmetria degli strumenti
Le tre implementazioni devono usare **parametri e algoritmi equivalenti** ovunque sia tecnicamente possibile. Dove la parità non è raggiungibile si sceglie il **minimo comune denominatore** disponibile in tutti e tre.

### 3. Come si risolve la tensione
Realismo per la **scelta della libreria**, simmetria per la **configurazione della libreria**. Ogni asimmetria residua va dichiarata nelle limitazioni.

---

## Architettura sperimentale (decisa — non cambiare senza discuterne prima)

- **Frontend fisso**: Static Web App. Mostra l'immagine prima/dopo il resize. Metriche e percentili sono delegati al generatore di carico e ad Application Insights.
- **Backend variabile**: solo l'Azure Function cambia tra i linguaggi testati
- **Nessun database**. Workload CPU-bound e in-memory.
- **Piano**: Flex Consumption (obbligatorio — è l'unico che supporta Go)
- **Instance size**: **2.048 MB**
- **Regione**: **Italy North**
- **Linguaggi**: Python, .NET, Go
- **Rust escluso**: l'overhead del custom handler avrebbe inquinato il confronto
- **Ranking di leggerezza runtime** (dal più leggero): Go → .NET → Python

### Instance size: tabella ufficiale
Fonte: [Flex Consumption plan hosting § Instance sizes](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#instance-sizes)

| Instance Memory (MB) | CPU Cores |
|---|---|
| 512 | 0,25 |
| 2048 | 1 |
| 4096 | 2 |

Dalla stessa pagina: i valori di core sono **allocazioni tipiche**, e le istanze iniziali possono avere allocazioni leggermente diverse per migliorare le prestazioni. Ogni istanza include **272 MB di memoria extra** per i processi di sistema e host, che **non incidono sulla fatturazione**. Microsoft raccomanda 2.048 MB come default per la maggior parte degli scenari. CPU e banda di rete sono proporzionali alla taglia dell'istanza.

Confermato indirettamente dalla quota regionale sulla stessa pagina ([§ Regional subscription memory quotas](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#regional-subscription-memory-quotas)): 250 core equivalgono a 512.000 MB, cioè 2.048 MB per core.

**Perché 2.048 MB e non 512 MB.** Scendere a 512 MB **non fa risparmiare** su workload CPU-bound: con 1/4 di CPU la durata quadruplica, e siccome costo = `memoria × durata`, si ottiene `0,5 GB × 4T = 2 GB × T`. Identico. 2.048 MB dà in più: 1 vCPU intera (niente throttling su CPU frazionaria) e un modello mentale pulito che combacia con la concorrenza a 1.

### Regione
Flex Consumption non è disponibile in tutte le regioni ([§ Considerations](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#considerations)); l'elenco aggiornato si ottiene con il comando indicato in [View currently supported regions](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-how-to#view-currently-supported-regions).

Candidate per vicinanza a Torino: Italy North (Milano) · Switzerland North (Zurigo) · France Central (Parigi) · Germany West Central (Francoforte) · West Europe (Paesi Bassi) · North Europe (Irlanda).

⚠️ **FONTE UFFICIALE NON TROVATA** per il confronto di prezzo tra regioni: va verificato con il selettore di regione sulla [pagina pricing di Azure Functions](https://azure.microsoft.com/en-us/pricing/details/functions/). Incide comunque poco, perché il compute rientrerà nel free grant.

---

## Runtime e modelli di esecuzione

Versioni supportate su Flex — fonte: [Flex Consumption plan § Supported language stack versions](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#supported-language-stack-versions). La tabella ufficiale elenca C# isolated (.NET 8, 9, 10), Java, Node.js, PowerShell, Python 3.10–3.14 e custom handlers.

| Linguaggio | Versione scelta | Note |
|---|---|---|
| Python | **3.12** | Nella tabella supportata |
| .NET | **10**, isolated worker | Nella tabella supportata |
| Go | **1.24+**, Core Tools 4.12+ | Public preview, documentato a parte |

⚠️ **PROMEMORIA OPERATIVO — rileggere la tabella prima della presentazione.** Le versioni supportate su Flex possono cambiare nel tempo: tra la prima e la seconda verifica fatta in questo progetto, la tabella ufficiale è già passata da Python 3.10–3.13 a **3.10–3.14**, e sono comparse le versioni Node.js 22/24. Le scelte fatte qui (Python 3.12, .NET 10) restano valide, ma **rileggere la [tabella ufficiale](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#supported-language-stack-versions) il giorno prima della presentazione**, non fidarsi di questo documento per l'elenco completo delle versioni disponibili in quel momento.

**Chiarimento concettuale da fare in presentazione**: "isolated worker" è un concetto **esclusivamente .NET**. Python e Go girano per costruzione in un processo worker separato dall'host. La stessa tabella specifica che il [modello C# in-process](https://learn.microsoft.com/en-us/azure/azure-functions/functions-dotnet-class-library) non è supportato su Flex e che occorre [migrare al modello isolated worker](https://learn.microsoft.com/en-us/azure/azure-functions/migrate-dotnet-to-isolated-model). Risultato: tutti e tre girano out-of-process.

**Perché .NET 10 e non .NET 8** (deroga consapevole alla regola del realismo): .NET 8 è ancora più diffuso, ma è vicino alla fine del supporto mentre .NET 10 è coperto più a lungo.
⚠️ **FONTE UFFICIALE NON TROVATA / DA RECUPERARE**: le date esatte di end of support vanno prese dalla [.NET support policy](https://dotnet.microsoft.com/platform/support/policy/dotnet-core) prima di citarle in slide.

### Stato e vincoli di Go
Fonte: [Azure Functions Go developer reference](https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference-go)

La pagina dichiara che il supporto Go per Azure Functions è in **public preview** e che durante la preview le function app Go sono supportate **solo sul piano Flex Consumption**. Il worker usa un modello di programmazione **code-first** (niente `function.json`): si definisce `main()`, si registra la FunctionApp e si avvia il worker. Prerequisiti: **Go 1.24 o successivo**, **Core Tools 4.12 o successiva**, Azure CLI 2.87 o successiva.

*first-class ≠ GA*: Microsoft usa "first-class language" riferendosi al modello di programmazione, non alla maturità del rilascio.

Vincoli della preview (dalla stessa pagina):
- **`CGO_ENABLED=0`** nel comando di build documentato → **niente librerie con binding CGo** (`bimg`, `govips`, libvips)
- **`func new` non supportato**: le function si aggiungono modificando `main.go`
- **Durable Functions non supportate**
- **Remote build (Oryx) non supportato**: compilazione locale in binario statico
- **Solo Linux** in Azure
- **Go non compare nella tabella "Supported language stack versions"** della pagina Flex Consumption. Normale per una preview, ma è un rischio pratico da mettere in conto.
- **HTTP/2 va disabilitato esplicitamente sulla function app** durante la preview (`az resource update ... --set properties.siteConfig.http20Enabled=false`). Fonte: [How to create a function in Azure from the command line, pivot Go](https://learn.microsoft.com/en-us/azure/azure-functions/how-to-create-function-azure-cli?pivots=programming-language-go) — passo esplicito nella quickstart, **non menzionato** nella pagina "Known limitations" della reference. Verificato con un deploy reale: senza questo passo il comportamento non è garantito dalla documentazione.

**✅ Probe di rischio superato (2026-09-08).** Un hello-world Go è stato deployato su Flex Consumption (2.048 MB, Italy North) e ha risposto `200` da internet. Il rischio strutturale "Go in preview potrebbe non deployarsi affatto" è chiuso. Dettagli e comandi esatti nel decision log, D31.

Trigger disponibili per il worker Go: HTTP, Timer, Service Bus, Event Hubs, Event Grid, Cosmos DB, Blob Storage.

---

## Demo use case — DECISO

**Image resizing / CDN**, workload CPU-bound, esposto come **endpoint HTTP-triggered**.

### Forma dell'endpoint (per le misurazioni)

```
POST /api/resize?image=sample.jpg&count=N&width=800&quality=80
```

- **Immagini di test incluse nel pacchetto di deploy**, committate nel repo, caricate in memoria una volta al cold start.
- **Poche immagini (2–3, pochi MB totali), identiche in tutti e tre i deploy**, così l'offset sul peso del pacchetto è costante.
- **Risposta di default = JSON** (dimensioni output, byte, hash). `&return=image` per la demo visiva, **mai durante i run di misura**.

### Perché questa forma invece del POST con body

| | POST con body | `?image=` |
|---|---|---|
| Banda upload/download nella latenza client | Sì (rumore) | No |
| Parsing multipart | Sì — codice molto diverso tra i worker, confound | No |
| Input identico garantito tra linguaggi | Difficile | Sì, byte-identico |
| Manopola per superare 1s di durata | Assente | `count=N` |

### Parametri del workload

| Parametro | Valore | Motivazione |
|---|---|---|
| Formato output | **JPEG** | Vedi sotto |
| Qualità JPEG | **80** (mai ≥ 98) | Trappola SIMD, vedi Gotchas |
| Filtro resampling | **Bilineare** | Unico filtro presente in tutti e tre |
| Immagini di test | **TBD** | Da tarare col codice |
| `count=N` | **TBD** | Deve portare anche la più veloce sopra 1s |

**Perché JPEG e non PNG.** Nessuno dei due elimina l'asimmetria nativo/managed, la sposta soltanto: con JPEG è sul codec, con PNG sulla compressione DEFLATE. Si sceglie JPEG perché è ciò che fa realmente un image-CDN su foto, perché il lavoro CPU è genuinamente image-specific (DCT, quantizzazione, Huffman) invece che compressione generica, e perché l'asimmetria è documentabile.

**Filtro bilineare: perché.** `golang.org/x/image/draw` offre solo NearestNeighbor / ApproxBiLinear / BiLinear / CatmullRom — niente Lanczos. Il bilineare è l'unico presente in tutti e tre.
⚠️ **FONTE UFFICIALE DA CITARE**: [pkg.go.dev golang.org/x/image/draw](https://pkg.go.dev/golang.org/x/image/draw) per i kernel disponibili; documentazione Pillow e ImageSharp per i rispettivi filtri. Da inserire quando si scrivono le slide.

---

## Stack per linguaggio

| Linguaggio | Libreria | Codec JPEG | Accelerazione |
|---|---|---|---|
| Python | **Pillow** | libjpeg-turbo (C) | SIMD scritto a mano in assembly |
| .NET | **SixLabors.ImageSharp** | Encoder managed proprio | SIMD portabile (Vector128/256/512, x64 e ARM) |
| Go | **`golang.org/x/image/draw`** + `image/jpeg` stdlib | Stdlib pura Go | Nessuna SIMD esplicita |

**Questa tabella a tre livelli è più interessante della dicotomia nativo/managed**: il livello di ottimizzazione **non coincide col linguaggio**. .NET è managed ma vettorizzato; Go è managed e non vettorizzato.

⚠️ **FONTI DA RECUPERARE PRIMA DELLE SLIDE**: le affermazioni su SIMD in libjpeg-turbo e in ImageSharp provengono dalla documentazione dei rispettivi progetti (libjpeg-turbo.org, docs.sixlabors.com), ma gli URL puntuali non sono ancora stati salvati. Vanno recuperati e incollati qui prima di usare questi dati in presentazione.

### Alternative scartate e perché
- **Go + `bimg`/`govips` (libvips)**: la scelta più realistica per un image-CDN in produzione, ma richiede CGo, incompatibile con `CGO_ENABLED=0`. *Vincolo da portare in slide.*
- **Go + `disintegration/imaging`**: libreria storica, non più mantenuta. La fork `kovidgoyal/imaging` è meno difendibile di un pacchetto `golang.org/x` ufficiale.
- **Approccio "stesso motore nativo per tutti" (pyvips / NetVips / govips)**: contraddice la regola del realismo.
- **PNG e WebP come output**: PNG per le ragioni sopra; WebP perché `golang.org/x/image/webp` è **solo decoder**.

### Talking point sul licensing
Da ImageSharp v3.0.0, le aziende sopra una soglia di fatturato annuo lordo che usano la libreria in software closed-source devono acquistare una licenza commerciale Six Labors; sotto soglia e per open source/no-profit resta Apache 2.0.
⚠️ **FONTE DA RECUPERARE**: la soglia esatta (1M USD, da confermare) e le condizioni vanno prese dalla pagina licensing ufficiale di Six Labors prima di finire in slide.

---

## Concorrenza — decisa

**Nessun parallelismo interno alla function.** Una richiesta = un thread di lavoro. **HTTP trigger concurrency = 1.**

Motivazione documentata: in uno scenario CPU-bound non c'è vantaggio a processare più richieste in parallelo nella stessa istanza, ed è meglio distribuire ogni richiesta alla propria istanza impostando una [HTTP trigger concurrency](https://learn.microsoft.com/en-us/azure/azure-functions/functions-concurrency#http-trigger-concurrency) pari a 1 — fonte: [Estimating consumption-based costs § esempio CPU-bound](https://learn.microsoft.com/en-us/azure/azure-functions/functions-consumption-costs?tabs=flex-consumption-plan#consumption-based-costs).

Effetto collaterale positivo: elimina il **GIL** di Python come variabile confondente. Il parallelismo è orizzontale.

⚠️ **FONTE UFFICIALE NON TROVATA** per il comportamento del GIL in Pillow (rilascio durante `Image.resize` e il compressore PNG, non durante la decodifica). Proviene da changelog e thread storici del progetto. Irrilevante ai fini dell'esperimento data la concorrenza a 1, ma **da non citare in slide senza recuperare la fonte**.

---

## Modello di billing — verificato

Fonti: [Flex Consumption plan § Billing](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#billing) · [Estimating consumption-based costs](https://learn.microsoft.com/en-us/azure/azure-functions/functions-consumption-costs?tabs=flex-consumption-plan) · [Monitoring data reference § Metrics](https://learn.microsoft.com/en-us/azure/azure-functions/monitor-functions-reference?tab=flex-consumption-plan#metrics)

1. **In modalità on demand si paga solo il tempo in cui il codice della funzione è in esecuzione**, e la voce fatturata è la memoria provisionata mentre ciascuna istanza sta *attivamente eseguendo funzioni*, meno un free grant mensile.
2. **La CPU non entra nel calcolo**: il calcolo dei GB-secondi si basa su tempo di inizio/fine della funzione e memoria in quel periodo, e l'attività CPU non è un fattore.
3. **Si paga la taglia dell'istanza configurata**, non la memoria realmente consumata: nel piano Flex si paga per il tempo in cui l'istanza gira in base alla instance size scelta, che ha un limite di memoria prefissato.
4. **Conseguenza**: il costo è puramente funzione della **durata wall-clock**. Il rapporto di costo tra linguaggi *è* il rapporto di durata.
5. **Conseguenza 2**: il vantaggio di footprint di Go non si traduce in risparmio diretto su Flex.
6. **Minimo fatturabile 1.000 ms**, poi arrotondamento ai 100 ms superiori.
7. **Metriche di fatturazione**: `OnDemandFunctionExecutionUnits` è il totale di MB-millisecondi dalle istanze on demand *mentre eseguono attivamente funzioni*; diviso 1.024.000 dà i GB-secondi del meter On Demand Execution Time. Tutte le execution unit si calcolano moltiplicando la taglia fissa di memoria per i tempi totali di esecuzione in millisecondi.

Prezzi correnti: [pagina pricing di Azure Functions](https://azure.microsoft.com/en-us/pricing/details/functions/).

### Il cold start è fatturato? → vedi Metrica 4, sezione Metodologia di misurazione
Questione aperta, senza dichiarazione ufficiale esplicita. Protocollo di verifica empirica descritto lì per tenerlo insieme alle altre metriche misurate.

### Due run pianificati
- **Run "sopra il secondo"**: `count=N` dimensionato perché **la più veloce delle tre** superi 1s.
- **Run "sotto il secondo"**: mostra come il minimo fatturabile azzeri il vantaggio di Go su .NET.

### Always-ready — analisi analitica, non benchmark
Un'istanza always-ready è un'istanza calda: i tempi di esecuzione sono identici a quelli a regime, quindi come benchmark di throughput è ridondante.

**L'angolo interessante incrocia i due assi**: always-ready elimina il cold start, e siccome il cold start differisce per linguaggio, il *valore economico* di always-ready differisce per linguaggio.

Dalla [tabella Billing](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#billing): con always ready si paga la memoria provisionata su tutte le istanze always ready (il *baseline*), più la memoria durante l'esecuzione attiva, più le esecuzioni — e **nella fatturazione always ready non ci sono free grant**. Le istanze always ready [contano contro la quota core](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#regional-subscription-memory-quotas) e non contano nel maximum instance count.

**Da calcolare analiticamente**, senza tenere istanze accese.

---

## Metodologia di misurazione

**Premessa che orienta tutte le scelte**: la metrica che conta per i costi è la **durata server-side** della function. Il client serve a *produrre* carico e a dare percentili di esperienza utente, non a stabilire il costo.

### Generatore di carico — DECISO: k6 in Azure Container Apps Job

- **Iterazione e messa a punto** → **k6 in locale** dal Mac.
- **Numeri finali per le slide** → **k6 in un [Azure Container Apps Job](https://learn.microsoft.com/en-us/azure/container-apps/jobs)** in Italy North.

**Perché k6 e non Locust/JMeter su Azure Load Testing — scelta metodologica, non di gusto.**

k6 ha executor a **arrival rate**: si impone **quante richieste al secondo partono**, indipendentemente dal tempo di risposta. Locust e JMeter sono nativamente VU-based. Con un modello VU-based **il backend più lento riceve automaticamente meno richieste**: se Python è 3x più lento di Go, con 50 VU riceve circa un terzo delle richieste, e i tre linguaggi finirebbero sotto **carichi offerti diversi**. Lo stesso requisito vale per la Metrica 3.

Motivo secondario e dirimente: [Azure Load Testing non supporta framework diversi da Apache JMeter e Locust](https://learn.microsoft.com/en-us/azure/app-testing/load-testing/overview-what-is-azure-load-testing) — k6 non è utilizzabile sul servizio managed. Per i test JMeter gli engine usano JDK 21 e JMeter 5.6.3; per quelli Locust, Python 3.9.19 e Locust 2.33.2 ([Key concepts](https://learn.microsoft.com/en-us/azure/app-testing/load-testing/concept-load-testing-concepts)).

**Concessione opzionale**: se avanza budget, un singolo run su Azure Load Testing serve a mostrare in una slide l'integrazione con le metriche delle risorse Azure, senza che i numeri dell'esperimento dipendano da lei.

*Se per qualche motivo si dovesse ripiegare su Azure Load Testing: scegliere Locust, non JMeter — è Python (già usato nel progetto) ed è code-first, quindi versionabile nel repo.*

#### Confronto delle piattaforme di esecuzione

| Opzione | Pro | Contro |
|---|---|---|
| k6 locale dal Mac | Zero costo, iterazione istantanea | Latenza di rete nella misura client-side; banda upstream domestica; il Mac può diventare collo di bottiglia |
| **k6 in ACA Job** (scelto) | Latenza trascurabile, banda alta, riproducibile, pagato al secondo solo durante il run, `parallelism` nativo, storico esecuzioni | Serve un Container Apps Environment; log via Log Analytics; retry e timeout da configurare |
| Container semplice (ACI) | Più immediato per un run singolo | Nessun `parallelism` orchestrato; va cancellato a mano; peggiore per run ripetuti |
| Azure Load Testing | Managed, dashboard, metriche Azure integrate, multi-region | Solo JMeter e Locust; addebito minimo per run |
| Script sequenziale + App Insights | Zero infra, elimina la rete dalla misura | Non è un load test. *Va bene però per la Metrica 2.* |

Scartato: runner GitHub Actions come generatore (rete e risorse non controllate).

### Metrica 1 — Throughput a regime
Carico a **tasso costante** (arrival rate) identico per i tre linguaggi, a regime. Percentili client-side da k6, durata server-side da Application Insights.

### Metrica 2 — Cold start isolato
**Strumento: script sequenziale + Application Insights.**

1. Deploy una volta sola.
2. Attendere che l'app scali a zero. **Misurato: ~3-4 minuti dall'ultima richiesta** (decision log D56) — ma è un *limite superiore*, perché la metrica `InstanceCount` ritarda e non separa la deallocazione reale dal ritardo di reporting. Regola operativa: aspettare **almeno 5 minuti** e **verificare lo zero dall'assenza di campioni**, non contando i minuti trascorsi. ⚠️ `InstanceCount` va interrogata con aggregazione **`Count`, non `Maximum`**: ogni istanza emette un campione di valore 1, quindi con `Maximum` il risultato è sempre `1.0` e sembra che l'app non scali mai (D55). **Costo di agenda da mettere in conto**: 10 ripetizioni × 3 linguaggi × ~5 minuti di attesa ≈ 2,5 ore di sola attesa.
3. Inviare **una singola richiesta**, cronometrare la latenza client-side totale.
4. Leggere in Application Insights la **durata server-side**.
5. Differenza ≈ overhead di avvio (piattaforma + worker + runtime).
6. Ripetere **10 volte per linguaggio**; riportare **mediana e p95**, mai la media.

Scartato il metodo "deploy fresco per ogni misura": misura anche il tempo di deploy, che non è cold start.

### Metrica 3 — Cold start sotto burst (probabilmente la più interessante)
Con concorrenza 1 e scale-to-zero, **un burst di N richieste simultanee forza N cold start contemporanei**. È lo scenario reale; la Metrica 2 è il caso di laboratorio.

Il comportamento della piattaforma è documentato in [Flex Consumption plan § Scale-out rate](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#scale-out-rate): la piattaforma aggiunge istanze in raffiche brevi e ripetute seguendo una *scale curve* — l'allocazione per intervallo è massima quando l'app gira su poche istanze e diventa più graduale man mano che cresce. La documentazione avverte esplicitamente di non progettare su numeri specifici per intervallo, ma sul *pattern*: veloce all'inizio, poi progressivamente più misurato. Le istanze always ready non sono soggette a questo rate.

**Protocollo:**
1. App a zero istanze.
2. Burst a tasso costante (arrival rate) verso il target di RPS.
3. Registrare i percentili di latenza **secondo per secondo** per i primi 60–120 secondi.
4. Metrica derivata: **time-to-steady-state**.
5. Tre ripetizioni per linguaggio.

**Output visivo**: tre curve di latenza nel tempo partendo da zero istanze, sovrapposte.

Limitazione: non separa nettamente piattaforma e linguaggio. La differenza rispetto alla Metrica 2 dà una stima.

Utile per il monitoraggio: la metrica `InstanceCount` ("Automatic Scaling Instance Count") è emessa ogni 30 secondi e, dato che Flex scala rapidamente, il valore è un aggregato di tutte le nuove istanze usate nel periodo — la [Monitoring reference](https://learn.microsoft.com/en-us/azure/azure-functions/monitor-functions-reference?tab=flex-consumption-plan#metrics) raccomanda di usare la granularità minima possibile e l'aggregazione "count".

### Metrica 4 — Il cold start è fatturato?

⚠️ **NESSUNA DICHIARAZIONE ESPLICITA NELLA DOCUMENTAZIONE UFFICIALE.** Questo è un vero esperimento da eseguire, non solo una lettura della documentazione.

Tre formulazioni ufficiali convergono ma non chiudono la questione:
- La modalità On Demand è definita come fatturazione del solo tempo in cui *il codice della funzione è in esecuzione* / la memoria provisionata mentre l'istanza sta *attivamente eseguendo funzioni* ([Billing](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#billing)).
- La metrica di fatturazione è definita come MB-millisecondi *mentre si eseguono attivamente funzioni* ([Monitoring reference](https://learn.microsoft.com/en-us/azure/azure-functions/monitor-functions-reference?tab=flex-consumption-plan#metrics)).
- La sezione [Behaviors affecting execution time](https://learn.microsoft.com/en-us/azure/azure-functions/functions-consumption-costs?tabs=flex-consumption-plan#behaviors-affecting-execution-time) elenca **solo** binding e attese asincrone. L'inizializzazione dell'app **non è menzionata**.

**Interpretazione più coerente: il cold start non è fatturato.** Non va scritto in slide come fatto certo senza questa verifica empirica.

**Corollario potenzialmente molto interessante**, se l'interpretazione regge: **dove si mette il codice di inizializzazione cambia se lo si paga**. Import pesanti a livello di modulo → eseguiti durante l'app init → non fatturati. Gli stessi import fatti pigramente dentro l'handler → fatturati a ogni cold start. Vale per tutti e tre i linguaggi.

**Protocollo:**
1. App a zero istanze, nessun altro traffico.
2. **Una sola richiesta**, con `count=N` tarato perché la durata superi 1.000 ms (così il minimo fatturabile non maschera il risultato).
3. Da Application Insights: durata server-side `D` ms.
4. Da Azure Monitor: `OnDemandFunctionExecutionUnits` in quel minuto, aggregazione Sum.
5. Se ≈ `2048 × D` → init **non** fatturato. Se ≈ `2048 × (D + cold start)` → init fatturato.
6. Tre ripetizioni. Farlo su **Python**, che ha il cold start più lungo e quindi il segnale più forte.

### Budget — €20 massimo
- **Azure Functions**: il free grant mensile per sottoscrizione è indicato sulla [pagina pricing](https://azure.microsoft.com/en-us/pricing/details/functions/) (250.000 esecuzioni e 100.000 GB-s in on-demand, al momento della verifica). I test non ci arriveranno vicino.
- **ACA Job**: piano Consumption, pagato al secondo solo durante l'esecuzione.
- **Azure Load Testing** (solo per l'eventuale run dimostrativo): ⚠️ **URL DELLA PAGINA PRICING DA SALVARE**. Dati raccolti finora: nessun canone mensile sulla risorsa (la fee di $10/mese è stata rimossa), $0,15/VUH fino a 10.000 VUH mensili, e un addebito minimo per run introdotto dal 1° marzo 2026. **Da riverificare sulla pagina ufficiale prima di usarli.**
- **Regola operativa**: iterare con k6 locale, usare l'ACA Job solo per i run che finiranno nelle slide.

---

## Doppio trigger (parte narrativa, non misurata)

Logica di resize in una funzione condivisa, wrappata in **due trigger**: HTTP (sottoposto a load test) e Blob (solo mostrato).

Momento di presentazione: *"questa è la forma di produzione, questa è la forma che riesco a misurare, ed ecco perché sono diverse."*

**Vincolo**: su Flex il [Blob storage trigger supporta solo la sorgente Event Grid](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#considerations).

---

## COSE DA ESPLICITARE NELLE SLIDE

### Sul metodo
1. **Non parallelizziamo dentro le function**: concorrenza HTTP = 1, per raccomandazione Microsoft sui workload CPU-bound.
2. **Spiegazione del GIL** e perché nel modello serverless lo scaling orizzontale lo aggira.
3. **"isolated worker" è un concetto solo .NET**: su Flex tutti e tre girano out-of-process.
4. **Perché `?image=` invece del POST con body**: eliminare banda e parsing multipart dalla misura.
5. **La metrica che determina il costo è la durata server-side**, non la latenza client.
6. **Cold start misurato separatamente**, con mediana e p95 (mai la media).
7. **Perché il carico è a tasso costante e non a utenti virtuali**: con un modello VU-based il backend più lento riceve meno richieste.
8. **Il cold start sotto burst è lo scenario reale**, non quello isolato.

### Sul billing
9. **Su Flex si paga solo taglia dell'istanza × durata wall-clock.** CPU e memoria realmente consumata non entrano nel calcolo.
10. **Differenza rispetto al Consumption classico**, dove la memoria media veniva misurata e arrotondata a multipli di 128 MB.
11. **Minimo fatturabile di 1 secondo**, con la run dimostrativa "sotto il secondo".
12. **Il vantaggio di footprint di Go non si traduce in risparmio diretto** su Flex.
13. **Quanto costa eliminare il cold start con always-ready, e per quale linguaggio conviene di più.**
14. **Se il cold start non è fatturato** (da verificare empiricamente): dove metti il codice di inizializzazione cambia se lo paghi.
15. **Il "costo di un linguaggio" non è solo compute**: il licensing di ImageSharp sopra soglia di fatturato.

### Sui linguaggi e il tooling
16. **I tre livelli di ottimizzazione** (C + SIMD assembly / managed + SIMD portabile / managed senza SIMD). Il livello di ottimizzazione non coincide col linguaggio.
17. **`CGO_ENABLED=0` su Go** esclude libvips e simili: maturità disomogenea del tooling.
18. **Go: first-class ≠ GA.** Public preview, non presente nella tabella dei language stack supportati.
19. **`disintegration/imaging` non è più mantenuta.**
20. **`golang.org/x/image/webp` è solo decoder**: motivo per cui l'output è JPEG.
21. **Durable Functions non disponibili su Go** in preview.
22. **Blob trigger vs HTTP trigger**: forma di produzione e forma misurabile sono diverse.

### Fonti che correggono informazioni obsolete
23. Fee mensile di Azure Load Testing rimossa, ma introdotto un addebito minimo per run.
24. System.Drawing.Common deprecata per cross-platform.

---

## GOTCHAS

### Fatturazione
- **Minimo fatturabile 1.000 ms**, poi arrotondamento ai 100 ms superiori ([fonte](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#billing)).
- **Always ready: nessun free grant**, e si paga il baseline anche a riposo ([fonte](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#billing)). Ricordarsi di **disabilitare** dopo le demo.
- Le istanze always ready **contano contro la quota core** e non contano nel maximum instance count ([fonte](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#regional-subscription-memory-quotas)).
- **272 MB extra per istanza non fatturati**: si paga la taglia configurata ([fonte](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#instance-sizes)).
- **Azure Load Testing: addebito minimo per run.** ⚠️ Cifre da riverificare sulla pagina pricing ufficiale.

### Piattaforma Flex Consumption
Tutti da [§ Considerations](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#considerations) salvo diversa indicazione:
- **App init timeout: 30 secondi, non configurabile.** Oltre, si vedono errori `System.TimeoutException` legati a gRPC.
- **Blob trigger: solo sorgente Event Grid.**
- **Una sola app per piano. Niente deployment slots.**
- **Niente migrazione in-place** da o verso Flex.
- **Azure Functions Proxies non disponibili** (erano una feature delle runtime 1.x–3.x).
- **App non-C# devono usare extension bundle `[4.0.0, 5.0.0)`** o successiva.
- **`WEBSITE_TIME_ZONE` e `TZ` non supportati.**
- **Scale massimo configurabile: da 1 a 1.000.**
- **Quota regionale di default: 250 core** per sottoscrizione/regione; le app scalate a zero non contano ([fonte](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#regional-subscription-memory-quotas)).
- **Solo Linux.**

### Librerie e codec
- **Qualità JPEG 98–100 disattiva la quantizzazione SIMD di libjpeg-turbo**, con calo di prestazioni rilevante. Impostare 98+ **handicapperebbe accidentalmente Python**. Restare a 80. ⚠️ **URL DA RECUPERARE** dalla documentazione libjpeg-turbo.
- **`golang.org/x/image/webp` è solo decoder.**
- **`x/image/draw` non ha Lanczos.**
- **ImageSharp: licenza commerciale sopra soglia di fatturato.** ⚠️ Soglia e condizioni da confermare sulla pagina Six Labors.

### Go
Tutti da [Go developer reference](https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference-go):
- **`CGO_ENABLED=0`** nel build path documentato.
- **`func new` non supportato.**
- **Remote build (Oryx) non supportato.**
- **Durable Functions non supportate.**
- **Go 1.24+, Core Tools 4.12+, Azure CLI 2.87+.**

### Strumenti di test
- **Azure Load Testing supporta solo JMeter e Locust** ([fonte](https://learn.microsoft.com/en-us/azure/app-testing/load-testing/overview-what-is-azure-load-testing)).
- **ACA Job: impostare `replicaRetryLimit` a 0.** I job presuppongono i retry; se un load test fallisce parzialmente e riparte, si genera carico due volte.
- **ACA Job: dimensionare `replicaTimeout`** sulla durata realistica del test più margine — allo scadere il job viene terminato ([fonte](https://learn.microsoft.com/en-us/azure/container-apps/jobs)).
- **ACA Job richiede un Container Apps Environment**; i log passano da Log Analytics.
- I core per instance size sono **allocazioni tipiche**, non garanzie.

---

## Limitazioni dell'esperimento (sezione di CHIUSURA)

- **Asimmetria su tre livelli di ottimizzazione**: Python potrebbe risultare competitivo *nonostante* il runtime più lento. È la scelta di libreria, conseguenza della regola del realismo.
- **L'output NON è byte-identico tra i tre linguaggi.** Si dimostra: input byte-identico, parametri identici, output con dimensioni e formato identici, determinismo *interno* a ciascun linguaggio. **Formulare così, mai come "output identico".**
- **Filtro bilineare imposto dal minimo comune denominatore.**
- **Concorrenza forzata a 1**: il confronto non dice nulla sui modelli di concorrenza dei tre linguaggi in altri scenari.
- **Le immagini di test nel pacchetto di deploy** influenzano il cold start (offset costante tra i tre).
- **`?image=` riduce il realismo**: in produzione l'immagine arriverebbe dall'esterno.
- **Go è in public preview**: risultati potenzialmente non rappresentativi della futura GA.
- **.NET 10 invece di .NET 8**: deroga alla regola del realismo.
- **Metrica 3**: non separa il contributo della piattaforma da quello del linguaggio.
- **L'autoscaling penalizza due volte il linguaggio più lento, ed è dentro la misura.** Con concorrenza 1, un linguaggio più lento occupa ogni istanza più a lungo, quindi ne richiede — e ne fa nascere — di più, quindi paga più cold start. La **curva client-side della Metrica 3 misura quindi il sistema (linguaggio + piattaforma), non il linguaggio**: va formulata così, mai come "X è N volte più veloce sotto burst". Le affermazioni sul solo linguaggio si prendono dalla durata server-side a regime, che non include il provisioning. Dettagli nel decision log, D58.
- **La riproducibilità della Metrica 3 è limitata per costruzione**: la documentazione ufficiale dichiara che la scale curve è gestita dalla piattaforma e che forma e ritmo [possono cambiare nel tempo](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#how-the-scale-curve-works). I tre linguaggi vanno quindi misurati il più vicino possibile nel tempo, e i numeri valgono per quella finestra.
- **I percentili client-side sono latenza del backend vista da un client vicino, non da un utente reale.** Il generatore gira in un Container Apps Job nella stessa regione delle function: la latenza di rete è eliminata di proposito, perché è un offset costante e identico per i tre linguaggi e mascherare le differenze è tutto ciò che otterrebbe. Non vanno quindi letti come esperienza utente. Ordine di grandezza di quel che si toglie: dal Mac verso Italy North il RTT misurato è ~34 ms, e l'apertura di una connessione HTTPS ~120 ms fra DNS, TCP e TLS.
- **`count=N` non è un moltiplicatore lineare**: le prime iterazioni costano molto più delle successive (su Python, 72 ms la prima contro ~17 ms a regime). Il valore di `count` scelto decide se si misura il riscaldamento o la velocità a regime, e non è garantito che la curva abbia la stessa forma nei tre linguaggi.
- **L'overhead host↔worker va riportato separando la prima richiesta di ogni istanza dalle successive**: su Python la prima costa ~206 ms e le successive ~7,5 ms. Un valore aggregato dipenderebbe da quante istanze sono state create durante il run, cioè dalla forma del carico, non dal linguaggio.
- **Core allocati per instance size sono valori tipici**, non garantiti al singolo run.
- La scelta della libreria fa parte del "costo del linguaggio", ma non è il linguaggio.

---

## Struttura della presentazione
- Split contenuti: **60% confronto linguaggi / 40% contesto cloud**
- La sezione "limitazioni dell'esperimento" va nella **chiusura**

---

## Contesto d'uso reale (per la parte "cloud")
- **Pattern comuni**: HTTP trigger + autoscaling, elaborazione file (blob trigger), automazione schedulata (timer trigger), disaccoppiamento job lunghi via coda, IoT, orchestrazione agenti AI con Durable Functions / Durable Task Scheduler
- **Pain point generali**: cold start, debug difficile in cloud, gestione errata di connessioni/DI, bolletta imprevedibile, opacità operativa
- **Pain point specifici sul linguaggio**: cold start diverso tra runtime; maturità disomogenea del tooling (Durable Functions non su Go in preview; `CGO_ENABLED=0`; assenza di encoder WebP nella stdlib Go)

---

## Come lavorare su questo progetto
- **Livello**: studente IT junior — profondità tecnica adeguata, senza banalizzare ma senza dare per scontato gergo avanzato non ancora introdotto
- **Fai domande di chiarimento mirate** prima di produrre output. Meglio troppe domande che output sbagliato.
- **Mai inventare** numeri, benchmark, prezzi, comandi, flag o URL.
- **Regola sulle fonti**: vedi la sezione in cima. Link inline obbligatorio, fonte ufficiale, o dichiarazione esplicita che non è stata trovata.
- **Segnala sempre se una fonte trovata aggiorna o corregge informazioni più vecchie.**
- **Checklist pre-presentazione**: rileggere la [tabella delle versioni linguaggio supportate su Flex](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#supported-language-stack-versions) il giorno prima, perché cambia nel tempo (già cambiata una volta durante questo progetto).

---

## Punti ancora aperti
1. **Il tempo di cold start / inizializzazione è fatturato?** → Metrica 4, sezione Metodologia di misurazione. Nessuna dichiarazione ufficiale esplicita; l'esperimento va eseguito.
2. ✅ **Immagini di test: scelte** (tre, decision log D33/D36). Restano fuori dal repo e vengono iniettate nel pacchetto a deploy-time.
3. 🟡 **`count=N`: valore provvisorio 75**, tarato su Python (D49). Definitivo in Fase 7, quando esistono tutti e tre i worker: il criterio è che **la più veloce delle tre** superi 1s, e quale sia è uno dei risultati dell'esperimento. ⚠️ Scoperta collegata: `count` **non è un moltiplicatore lineare** — la prima iterazione costa ~4× quelle a regime.
4. 🟡 **RPS target: provvisori 10 req/s per Metrica 1 e 50 req/s per Metrica 3**, entrambi misurati (D54, D57). Definitivi in Fase 7 per lo stesso motivo del punto 3.
5. **URL da recuperare** e incollare inline: libjpeg-turbo SIMD, ImageSharp SIMD, licensing Six Labors, pricing Azure Load Testing, date di supporto .NET, filtri Pillow/ImageSharp
6. 🟡 Flag della dashboard web di k6: su **k6 2.2.0** (la versione installata) `k6 run --help` non elenca nessun flag di dashboard e `K6_WEB_DASHBOARD=true` non produce output che la menzioni. ⚠️ **FONTE UFFICIALE NON TROVATA** per questa versione: non è chiaro se la funzione sia stata rimossa, spostata o rinominata. Resta aperto, ma è un `[C]`.
7. **Smoke test preliminare del worker Go** al livello di carico scelto per i run finali. Essendo in public preview, eventuali errori sotto carico sarebbero un artefatto della preview, non una caratteristica di Go, e andrebbero dichiarati.

---

## Indice delle fonti ufficiali usate finora

| Argomento | URL |
|---|---|
| Instance size, CPU cores, billing, quota, considerations, scale-out rate, language stacks | https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan |
| Calcolo dei costi, CPU non fatturata, esempio CPU-bound, metriche di billing | https://learn.microsoft.com/en-us/azure/azure-functions/functions-consumption-costs?tabs=flex-consumption-plan |
| Definizione delle metriche di fatturazione e di scaling | https://learn.microsoft.com/en-us/azure/azure-functions/monitor-functions-reference?tab=flex-consumption-plan |
| Worker Go: preview, prerequisiti, build, vincoli | https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference-go |
| Azure Load Testing: framework supportati | https://learn.microsoft.com/en-us/azure/app-testing/load-testing/overview-what-is-azure-load-testing |
| Azure Load Testing: versioni engine JMeter/Locust | https://learn.microsoft.com/en-us/azure/app-testing/load-testing/concept-load-testing-concepts |
| Container Apps Jobs: tipi di trigger, timeout, retry, parallelism | https://learn.microsoft.com/en-us/azure/container-apps/jobs |
| Prezzi Azure Functions e free grant | https://azure.microsoft.com/en-us/pricing/details/functions/ |
| HTTP trigger concurrency | https://learn.microsoft.com/en-us/azure/azure-functions/functions-concurrency#http-trigger-concurrency |
| Regioni supportate da Flex | https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-how-to#view-currently-supported-regions |
