# TODO

**Scadenza: 30 settembre 2026, Toolbox Torino** (D21).

Ogni fase corrisponde a un branch `phase-N`. Si spunta nello **stesso commit** che completa il task. `D#` rimanda al decision log nel vault.

Priorità: **[M]** must — senza, il talk non sta in piedi · **[S]** should — il talk regge ma perde un pezzo · **[C]** could — se avanza tempo.

---

## Fase 0 — Fondamenta (percorso critico, blocca tutto il resto)

> Nessun codice. Finché questa fase non chiude, si può scrivere e testare in locale ma non misurare niente.

- [x] **[M] Creare l'account Azure.** Free account, $200 di credito (D27). ⚠️ Il credito scade a 30 giorni O a esaurimento, quello che viene prima — non ha uno spending limit in senso tecnico, oltre la soglia l'account si **disabilita**, non addebita. Vedi D27 per il dettaglio e il rischio residuo.
- [x] **[M] Enrollare MFA** con authenticator + metodo di backup. Non il giorno del talk.
- [x] **[M] `az login`** — account Microsoft personale, sottoscrizione unica "Azure subscription 1", `Enabled`.
- [x] **[M] Verificare che Flex Consumption sia disponibile in Italy North.** Confermato con `az functionapp list-flexconsumption-locations`: `italynorth` è nell'elenco. Nessun ripiego di regione necessario.
- [x] **[M→S retrocesso] Controllare la quota regionale di core effettiva.** ⚠️ **Scoperta (D29)**: non esiste un comando `az` documentato per leggere la quota _corrente_ prima che esista un'app — l'unico strumento ufficiale è il Flex Consumption Quota tool nel portale, e richiede un'app già esistente. **Spostato in Fase 2** (voce lì sotto), non è più un blocco di Fase 0.
- [x] **[M] Registrare i resource provider**: `Microsoft.Web`, `Microsoft.Storage`, `Microsoft.Insights`, `Microsoft.OperationalInsights`, `Microsoft.App` — più `Microsoft.Quota`, tentativo per la riga sopra (non risolutivo, vedi D29).
- [x] **[M] Creare il resource group** unico del progetto in Italy North: `rg-torinodotnet-demo`. Teardown = cancellare questo.
- [x] **[M] Budget alert a €5 / €10 / €18.** Creato `budget-torinodotnet-demo` via ARM REST (`az consumption budget create` non espone le soglie di notifica in questa versione del CLI — usato `az rest` con il body documentato dall'API). €20/mese, alert a 25/50/90% via email all'indirizzo dell'account Azure. **Confermato (D30): la valuta di fatturazione è EUR**, non USD nonostante il credito sia pubblicizzato come "$200" — nessuna conversione necessaria, €20 resta €20. **Confermato anche `spendingLimit: On`** sul billing profile: la rete di sicurezza è più forte di quanto temuto in D27, non solo "nessun addebito automatico" ma proprio un limite di spesa attivo lato Azure.
- [x] **[M] Installare la toolchain**: `az` 2.90.0 · `func` 4.14.0 · Go 1.27.1 · .NET SDK **10.0.400** (via script ufficiale, non brew cask — richiedeva `sudo` che non si può automatizzare; installato in `~/.dotnet`, aggiunto al PATH in `.zshrc`) · k6 2.2.0.
- [x] **[M] Probe di rischio: hello-world Go deployato su Flex. ✅ FUNZIONA.** `func-torino-go-probe`, `sku: FlexConsumption`, 2.048 MB, Italy North. `curl` sull'endpoint pubblico → `200 Hello from Go Worker!`. **Gotcha nuovo trovato, non in `instructions.md` (D31)**: va disabilitato HTTP/2 sulla function app durante la preview Go (`az resource update ... --set properties.siteConfig.http20Enabled=false`), altrimenti la doc non garantisce il funzionamento. Provisioning app ~11 minuti (Application Insights + Log Analytics collegati). Risorse ancora **in piedi** per il Python probe — cleanup dopo (task sotto).
- [x] **[S] Hello-world Python deployato su Flex. ✅ FUNZIONA.** `func-torino-python-probe`, stesso storage account, deploy via Oryx remote build (come da D-decisione sul deploy Python). `curl` → `200`. Un solo warning locale, innocuo: il `func` locale segnala che l'interprete sul Mac (3.14.7) differisce dalla versione target (3.12) — irrilevante perché il build gira da remoto su Oryx con la versione configurata, non con l'interprete locale, ma **da tenere a mente**: se in futuro si testa in locale con `func start`, serve un venv Python 3.12 esplicito sul Mac, non l'interprete di sistema.
- [x] **[M] Cleanup dei due probe.** Resource group `rg-torinodotnet-demo` cancellato e ricreato vuoto — più pulito che scovare a mano ogni risorsa satellite (Application Insights, Smart Detection alert rule, App Service plan). Il budget (D30) è a livello di sottoscrizione, non di resource group: sopravvive intatto alla cancellazione/ricreazione del RG.

## Fase 1 — Monorepo e function Python ✅ completata

- [x] Struttura del monorepo, `.gitignore`, `README.md`, `TODO.md` (D2).
- [x] Scheletro della function Python: contratto dell'endpoint, pipeline decode→resize→encode, strumentazione dei tempi (D3, D5, D6, D7, D8, D9).
- [x] `host.json` con sampling di Application Insights disattivato (D14) ed extension bundle `[4.0.0, 5.0.0)`.
- [x] Casi di conformità condivisi per l'altezza dell'output (`shared/conformance/`) — diventeranno i test di .NET e Go.
- [x] **[M] Scegliere le immagini di test** (D33) e portarle nel pacchetto (D35, D36).
- [x] **[M] Installare le dipendenze, far girare i test in locale, pinnare Pillow** (D32).
- [x] **[M] Provare `func start` in locale** e verificare il contratto end-to-end (D32, D34).
- [x] **[S] Verificare i default di Pillow** su `progressive` e `optimize` (D8, D32).

## Fase 2 — Infrastruttura Bicep e primo deploy ✅ completata

- [x] **[M] Bicep** (D20): storage account, piano Flex + function app Python, Application Insights + Log Analytics. Il deploy è **a scope resource group**: `rg-torinodotnet-demo` esiste già dalla Fase 0 (D30) e il Bicep ci si appoggia invece di ricrearlo — così il teardown resta "cancella il resource group". **I parametri bloccati vanno scritti espliciti, non lasciati al default**: instance size **2.048 MB**, runtime **Python 3.12**, regione **Italy North**. Un default diverso non fa fallire niente, si scopre solo quando i numeri non tornano.
- [x] **[M] Scrivere il Bicep parametrico sul linguaggio fin da subito**, anche se in Fase 2 se ne istanzia uno solo. Su Flex vale **una sola app per piano** (`instructions.md`, § Considerations): i tre worker richiedono **tre piani e tre function app**, non tre app sullo stesso piano. Un modulo che prende il linguaggio come parametro si istanzia tre volte in Fase 4 e 5 senza riscritture; un Bicep monolitico su Python andrebbe rifatto. Lo storage account può invece restare **condiviso** — il vincolo riguarda il piano, non lo storage (verificato coi due probe di Fase 0, che condividevano `sttorinogo92557`).
- [x] **[M] HTTP trigger concurrency a 1 — dichiarata nel Bicep, non via CLI (D39).** `scaleAndConcurrency.triggers.http.perInstanceConcurrency` è una proprietà ARM valida: così un re-provisioning la **ri-imposta** invece di riportarla al default, che era il rischio residuo di D22.
- [x] **[M] Verificata rileggendola dall'app**: `perInstanceConcurrency: 1`, insieme a memoria 2048, Python 3.12, `FlexConsumption`, Italy North.
- [x] **[S] Quota regionale verificata dal portale (D42): 250 core, 512.000 MB — il default, non ridotta.** Nessun ridimensionamento dell'RPS target per la Metrica 3.
- [x] **[S] Come le immagini arrivano in CI: container privato nello stesso storage account (D40).** La pipeline è già autenticata su Azure via OIDC, quindi le scarica da lì senza nessun secret aggiuntivo. Scartato il secret di GitHub: le tre immagini in base64 superano il limite di 64 KB per secret.
- [x] **[M] Pipeline GitHub Actions** con OIDC federato, `workflow_dispatch` (D13, D40, D41). Role assignment fatto da Matteo, credenziale federata corretta per il formato "immutable subject" di GitHub (D41), primo deploy riuscito e verificato in modo indipendente.
- [x] **[M] Deploy della function Python e prima chiamata riuscita da internet.** `torinodotnet-python.azurewebsites.net`, verificato in modo indipendente dal workflow: `/api/images` con le tre immagini, `/api/resize?width=800` → `height: 690` come da formula D7.
- [x] **[S] Controllo post-deploy integrato nel workflow stesso** (ultimo step di `.github/workflows/deploy.yml`): interroga `/api/images` con retry, fallisce se la lista è vuota. Verde al primo deploy vero.
- [x] **[M] Sampling verificato sulla telemetria vera, non sulla config (D14, D41).** Burst di 20 richieste concorrenti, poi query su `AppRequests`: 21 righe, 21 `InvocationId` distinti, `ItemCount` sempre 1 su ogni riga — è il campo che segnala il fattore di sampling, e se fosse >1 vorrebbe dire eventi compressi/scartati.

## Fase 3 — Catena di misura ✅ completata

- [x] **[M] Script k6** con executor a arrival rate (`constant-arrival-rate`), parametri da variabile d'ambiente (D15).
- [x] **[M] Taratura provvisoria di `count=N` su Python: `count = 75`** (D43, D49). Oltre 1s con margine (`total_ms` 1.195-1.310 ms su 5 ripetizioni) e nella zona piatta della curva, dove il costo per iterazione ha smesso di calare. ⚠️ `count` **non è un moltiplicatore lineare** (D49): la prima iterazione costa 72 ms, il regime 17 ms. La taratura definitiva richiede tutti e tre i worker e vive in Fase 7: qui serve solo un valore che porti Python sopra 1s, abbastanza da esercitare la catena di misura end-to-end. Il valore va scritto nel log **come provvisorio**.
- [x] **[M] RPS target provvisorio** (D43). **Metrica 1: 10 req/s** — 301 richieste, 0 fallimenti, ~13 istanze contro un tetto di 200 (D54). **Metrica 3: 50 req/s** — burst da zero istanze verificato, 1.500 richieste, 0 fallimenti, ~63 istanze, time-to-steady-state 4-7 s (D57).
- [x] **[M] Query di Log Analytics** per estrarre durata server-side e i tempi interni della function (D6), riusabili identiche per i tre linguaggi.
- [x] **[M] Contabilizzare i fallimenti nelle query, non solo i successi** (D45). `RESIZE_METRICS` è emesso solo dopo una pipeline riuscita: un 4xx/5xx lascia una riga in `AppRequests` senza traccia corrispondente, quindi la join li esclude in silenzio. Ogni query che produce percentili deve riportare accanto il conteggio per `ResultCode` e la percentuale di successo.
- [x] **[M] Misurare il tempo di scale-to-zero**: **~3-4 minuti** dall'ultima richiesta, da usare come **limite superiore** perché la metrica stessa ritarda (D16, D56). Regola operativa: prima di una misura che presuppone zero istanze, aspettare ≥5 minuti **e verificare l'assenza di campioni**, non contare i minuti. ⚠️ `InstanceCount` va interrogata con **aggregazione `Count`, non `Maximum`** (D55): ogni istanza emette un campione di valore 1 ogni 30 s, quindi con `Maximum` il risultato è sempre `1.0` e sembra che l'app non scali mai. Serve un protocollo pulito: app a zero verificata, carico noto, stop netto, poi polling fino alla scomparsa dei campioni.

## Fase 4 — Worker .NET ✅ completata

- [x] **[M] Implementazione** isolated worker .NET 10 con ImageSharp (D71). `Compand = false` (D10), subsampling 4:2:0 esplicito (D8), `Triangle` (D9), formula dell'altezza verificata contro `shared/conformance/` — 29 test verdi, i 12 casi letti dal file condiviso. Due cose in più rispetto a quanto previsto: `ResizeMode.Stretch` e `Interleaved = true`, perché i loro default avrebbero ritagliato l'immagine ed ereditato il formato dall'input (D66, D71).
- [x] **[M] Tre endpoint, non uno**: `resize`, `health` e `images` (D34). Verificati con `func start` e non solo a unit test — i test non coprono la registrazione delle route. `POST /api/resize?image=npm-install-7-years.jpg&width=800` → `height: 690`, **lo stesso valore di Python** sulla stessa immagine.
- [x] **[M] Modulo Bicep per .NET istanziato** (D72, D76). `torinodotnet-plan-dotnet` + `torinodotnet-dotnet`, `FlexConsumption`, Italy North, `dotnet-isolated` versione `'10'`, 2.048 MB, tetto 200 istanze. Deployment `phase4-dotnet` `Succeeded`; l'app Python è stata riaffermata senza cambiamenti.
- [x] **[M] Worker Python rimesso in piedi** (D78). Container di deploy separati per linguaggio, poi redeploy: workflow verde, controllo su `/api/images` incluso.
- [x] **[M] Worker .NET deployato e verificato in modo indipendente dal workflow.** `GET /api/images` → le tre immagini coi byte esatti · `/api/health` → `runtime: .NET 10.0.10` · `POST /api/resize?image=npm-install-7-years.jpg&width=800` → **`height: 690`**, lo stesso valore di Python sulla stessa immagine. Cinque deploy falliti prima, tre cause indipendenti sovrapposte (D78, D79, D82).
- [x] **[M] Concorrenza a 1** su questa app (D22, D39). Dichiarata nel Bicep e **riletta dalla risorsa** con `az resource show --resource-type Microsoft.Web/sites --api-version 2024-04-01`: `perInstanceConcurrency: 1` su .NET, e ancora `1` su Python dopo il re-provisioning — che è la prova pratica del meccanismo di D72.
- [x] **[M] Percorso di build .NET nella pipeline** (D63, D73). `setup-dotnet`, `dotnet test` e `dotnet publish` condizionati al linguaggio, `package:` e `remote-build:` scelti da uno step, più il controllo che l'output di publish contenga le immagini. Esercitato da un deploy vero, verde in tutti gli step.
- [x] **[M] Telemetria simmetrica ai tre worker** (D64, D83). Niente integrazione diretta né `telemetryMode`: rimozione attiva dal template, che li genera. Verificata **sulla telemetria vera** col metodo di D41 — burst di 20 richieste → 21 righe `RESIZE_METRICS`, 21 `OperationId` distinti, `ItemCount` sempre 1. La join di `run-summary.kql` gira identica su .NET: `language: dotnet`, 21/21 con metriche, 0 fallimenti.
- [x] **[S] ReadyToRun attivo come flag di CI**, non nel `.csproj` (D11, D24, D84). Dentro il timebox. Il publish crossgen2 da macOS arm64 verso `linux-x64` funziona senza installare niente a mano — chiude il residuo di D19. **Costo misurato: il pacchetto passa da 5,96 a 12,1 MB** (zip deployato da 2,75 a 5,47 MB), e Flex lo scarica a ogni cold start: che il saldo sia positivo si misura in Fase 7, non si assume.
- [x] **[S] Verificato il default di `ResizeOptions.Compand`: `false`** — e con lui gli altri default che contano (D66). Sorgente ImageSharp v4.1.1: `Compand` non ha inizializzatore, quindi D10 chiede cio' che gia' succede; ma `Sampler` default e' **Bicubic** (non Triangle) e `JpegEncoder.ColorType`, se non impostato, **eredita il sottocampionamento dell'immagine sorgente**. Vanno passati tutti espliciti.

## Fase 5 — Worker Go ✅ completata

- [x] **[M] Implementazione** con `golang.org/x/image/draw` + `image/jpeg` (D85). `BiLinear` e **non** `ApproxBiLinear` (D9), destinazione `image.RGBA` perche' il decoder restituisce YCbCr e interpolare li' non sarebbe quello che fanno gli altri due, formula dell'altezza verificata contro `shared/conformance/` — 11 test verdi, i 12 casi letti dal file condiviso. Toolchain Go **pinnata a 1.27.1**: in Go la libreria di codifica e' la stdlib, quindi il compilatore e' una dipendenza da pinnare come Pillow e ImageSharp.
- [x] **[M] Tre endpoint, non uno**: `resize`, `health` e `images` (D34). Verificati con `func start` e non solo a unit test. Le tre immagini danno **690, 1005, 814** — le stesse altezze di Python e .NET; status code `400`/`404`/`400` e `return=image` con `image/jpeg` come negli altri due.
- [x] **[M] Build**: `CGO_ENABLED=0 GOOS=linux GOARCH=amd64`, compilazione in CI (Oryx non supportato per Go). Pacchetto assemblato a mano e **non** con `func pack`, che produce uno zip con dentro solo `app` e `host.json` — le immagini non ci entrano (D86). Esercitato da un deploy vero, verde al primo colpo.
- [x] **[M] Modulo Bicep per Go istanziato** (D85). `torinodotnet-plan-go` + `torinodotnet-go`, `runtime: {name: 'go', version: '1.0'}` letto dal campo ARM strutturato (D82) — chiude il residuo di D39, che temeva servisse `custom`. `deployment-packages-go` creato dal loop di D78 senza che nessuno dovesse ricordarsene.
- [x] **[M] HTTP/2 disabilitato — dichiarato nel Bicep, non via CLI** (D31, D85). `siteConfig.http20Enabled: false` su **tutti e tre** i worker. Riletto dalla risorsa dopo il deploy: `false` su Go, e ancora `false` su Python e .NET dopo il re-provisioning.
- [x] **[M] Concorrenza a 1** su questa app (D22, D39). Riletta dalla risorsa: `perInstanceConcurrency: 1` su Go, e ancora `1` su Python e .NET dopo il re-provisioning.
- [x] **[M] Deploy del worker Go e verifica indipendente dal workflow** (D87). `/api/images` le tre immagini coi byte esatti · `/api/health` → `runtime: go1.27.1` · le tre immagini danno **690, 1005, 814**, le stesse altezze di Python e .NET. Telemetria verificata sui dati veri: 23 richieste, 23 righe `RESIZE_METRICS`, `ItemCount` sempre 1, join di `run-summary.kql` che aggancia 23/23 — **dopo** aver corretto la query, che su Go falliva in silenzio (D87).

## Fase 6 — Frontend

- [ ] **[M] Static Web App** che mostra prima/dopo il resize usando `return=image`.
- [ ] **[M] Decidere se punta a tutti e tre i backend** (selettore di linguaggio) o a uno solo. Non ancora deciso.
- [ ] **[M] Selettore immagini** popolato dinamicamente da `GET /api/images` (D34) — mai hardcodare i nomi dei file, così cambiare il pool via redeploy aggiorna anche il frontend senza toccarlo.
- [ ] **[S] Configurare il CORS** con l'origine della Static Web App (D12). Spostato da Fase 2: non serve finché la SWA non esiste.
- [ ] **[M] CORS** verificato dal browser, non solo dalla configurazione.

## Fase 7 — Run finali e analisi

- [ ] **[M] Taratura definitiva di `count=N` e dell'RPS target, con tutti e tre i worker deployati** (D43). Va fatta qui e non prima: `count` si dimensiona perché **la più veloce delle tre** superi 1s, e quale sia la più veloce non è deducibile — è uno dei risultati dell'esperimento. Sostituisce i valori provvisori di Fase 3; entrambi vanno scritti nel log, il provvisorio e il definitivo.
- [ ] **[M] Decidere se serve il Container Apps Job con k6** — **da valutare dopo la taratura definitiva qui sopra** (D59), non prima: la domanda è se il Mac regga il tasso finale della Metrica 3 senza diventare lui il collo di bottiglia, e quel tasso non esiste finché i tre worker non sono misurati. Dato parziale: a 50 req/s con 500 VU il Mac ha retto senza una `dropped_iteration` (D57). Se serve: `replicaRetryLimit` a 0, `replicaTimeout` dimensionato. ⚠️ La misura non è `dropped_iterations`, che è confusa dal cold start del backend — servono VU fissi e abbondanti, CPU locale osservata, e tasso ottenuto contro tasso richiesto (D59).
- [ ] **[M] Smoke test del worker Go al carico dei run finali** (D87). Spostato qui da Fase 5: ha senso solo quando l'RPS definitivo esiste, cioè dopo la taratura qui sopra — al livello di carico sbagliato non dimostra niente. Se cede, è un artefatto della public preview e non una caratteristica di Go, e va detto così in slide.
- [ ] **[M] Metrica 1** — throughput a regime, tasso costante identico per i tre.
- [ ] **[M] Metrica 2** — cold start isolato: 10 ripetizioni per linguaggio, mediana e p95 (**mai la media**). Serve un piccolo **script di orchestrazione** che ripeta il ciclo `attendi zero → una richiesta cronometrata → leggi la durata server-side`: i pezzi esistono già (`load/scripts/wait-for-zero.sh`, le query in `load/queries/`), manca il ciclo che li mette insieme identico per i tre linguaggi. ⚠️ Costo di agenda: ~5 minuti di attesa per ripetizione, quindi ~2,5 ore per i tre linguaggi (D56).
- [ ] **[M] Metrica 3** — cold start sotto burst, 3 ripetizioni per linguaggio, percentili secondo per secondo, curve sovrapposte.
- [ ] **[M] Metrica 4** — il cold start è fatturato? Su Python, `count` tarato sopra 1s, confronto tra `OnDemandFunctionExecutionUnits` e `2048 × durata`. 3 ripetizioni. ⚠️ **Non leggere "quel minuto"**: la metrica ritarda 1-2 minuti e si spalma su più minuti, va sommata su una finestra (D60).
- [ ] **[S] Controllo differenziale della Metrica 4** (D61): due deploy della sola app Python identici tranne un import pesante a livello di modulo (pochi secondi, sotto il timeout di app init di 30 s), una richiesta singola a freddo su ciascuno, confronto dei MB-ms. Cancella le costanti ignote — allocazione istanza, avvio host, arrotondamento — perché identiche nei due deploy, e testa **direttamente** il corollario da slide (dove metti l'init cambia se lo paghi) invece di dedurlo. La misura assoluta resta `[M]`: questa è ciò che la rende conclusiva.
- [ ] **[M] Run "sotto il secondo"** per mostrare il minimo fatturabile che azzera il vantaggio di Go.
- [ ] **[M] Calcolo analitico always-ready** per linguaggio (nessuna istanza accesa davvero).
- [ ] **[M] Spegnere tutto** e verificare la spesa effettiva.

## Fase 8 — Presentazione

- [ ] **[M] Recuperare le fonti mancanti** e incollarle inline: SIMD libjpeg-turbo (incluso il crollo a qualità 98+), SIMD ImageSharp, licensing Six Labors, pricing Azure Load Testing, date di end of support .NET, filtri Pillow/ImageSharp.
- [ ] **[M] Slide** secondo la scaletta (60% linguaggi / 40% cloud), con la sezione limitazioni in chiusura.
- [ ] **[M] Il giorno prima: rileggere la tabella delle versioni supportate su Flex.** È già cambiata una volta durante il progetto.
- [ ] **[M] Prova generale della demo live**, con l'app già calda o già fredda a seconda di cosa si vuole mostrare.
- [ ] **[C] Un run su Azure Load Testing** solo per la slide sull'integrazione con le metriche Azure, senza che i numeri dell'esperimento dipendano da lui.

---

## Rischi aperti

| Rischio                                                | Impatto                                       | Mitigazione                                              |
| ------------------------------------------------------ | --------------------------------------------- | -------------------------------------------------------- |
| Account Azure non ancora creato a 3 settimane dal talk | Blocca tutto                                  | Fase 0, oggi                                             |
| Go in public preview non deploya o cede sotto carico   | Perde un terzo del talk                       | Probe hello-world in Fase 0, non in Fase 5               |
| Quota di core bassa su sottoscrizione trial            | La Metrica 3 non è eseguibile come progettata | Verificare in Fase 0, ridimensionare l'RPS e dichiararlo |
| Concorrenza non impostata a 1 su .NET e Go             | **I numeri del confronto sarebbero falsi**    | D22, task bloccante di Fase 2                            |
| Immagini di test non ancora scelte                     | Blocca la taratura di `count`                 | Fase 1                                                   |
