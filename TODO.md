# TODO

**Scadenza: 30 settembre 2026, Toolbox Torino** (D21). Aggiornato: 2026-09-08.

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

## Fase 2 — Infrastruttura Bicep e primo deploy ⏳ in corso

- [ ] **[M] Bicep** (D20): resource group, storage account, piano Flex + function app Python, Application Insights + Log Analytics. **I parametri bloccati vanno scritti espliciti, non lasciati al default**: instance size **2.048 MB**, runtime **Python 3.12**, regione **Italy North**. Un default diverso non fa fallire niente, si scopre solo quando i numeri non tornano.
- [ ] **[M] Scrivere il Bicep parametrico sul linguaggio fin da subito**, anche se in Fase 2 se ne istanzia uno solo. Su Flex vale **una sola app per piano** (`instructions.md`, § Considerations): i tre worker richiedono **tre piani e tre function app**, non tre app sullo stesso piano. Un modulo che prende il linguaggio come parametro si istanzia tre volte in Fase 4 e 5 senza riscritture; un Bicep monolitico su Python andrebbe rifatto. Lo storage account può invece restare **condiviso** — il vincolo riguarda il piano, non lo storage (verificato coi due probe di Fase 0, che condividevano `sttorinogo92557`).
- [ ] **[M] Impostare la HTTP trigger concurrency a 1** via Azure CLI (D22). **Non è opzionale e non si fa in `host.json`**: a 2.048 MB il default è 16 per .NET e Go e 1 per Python — lasciarlo così renderebbe il confronto privo di significato.
- [ ] **[M] Verificare che la concorrenza sia davvero applicata**, rileggendola dall'app e non dando per riuscito il comando (D22). Va fatto **prima del primo run buono, non dopo** — e ripetuto dopo ogni re-provisioning, perché ricreare l'app la riporta silenziosamente a 16.
- [ ] **[S] Controllare la quota regionale di core effettiva**, ora che l'app Python esiste: portale → app → "Diagnose and solve problems" → "Flex Consumption Quota" (D29 — nessun comando `az` la espone prima che un'app esista). Se bassa, ridimensionare l'RPS target della Metrica 3 e dichiararlo.
- [ ] **[M] Verificare che il sampling sia davvero spento** guardando la telemetria, non il file di configurazione (D14).
- [ ] **[S] Decidere come le immagini arrivano in `functions/images/` in CI**: secret di GitHub Actions vs artifact vs storage privato. Problema separato da `sync-images.sh`, che legge dalla sorgente e basta — non si occupa di come ci è arrivata.
- [ ] **[M] Pipeline GitHub Actions** con OIDC federato, `workflow_dispatch` (D13). Richiede un'app registration su Entra ID. **Deve chiamare `./scripts/sync-images.sh <linguaggio>` prima del publish** (D36): è il passo che porta le immagini nel pacchetto, e senza di lui il deploy riesce con un'app muta.
- [ ] **[M] Deploy della function Python** e prima chiamata riuscita da internet.
- [ ] **[S] Controllo post-deploy: `GET /api/images` non deve restituire lista vuota.** Una copia dimenticata **non** fa fallire il deploy — l'app parte lo stesso con zero immagini e risponde 404 su tutto. È voluto, ma va intercettato guardando, non sperando.
- [ ] **[S] Configurare il CORS** con l'origine della Static Web App (D12). Può aspettare la Fase 6.

## Fase 3 — Catena di misura

- [ ] **[M] Script k6** con executor a arrival rate (`constant-arrival-rate`), parametri da variabile d'ambiente (D15).
- [ ] **[M] Tarare `count=N`** perché la più veloce delle tre superi 1s, e **scrivere il valore nel log**.
- [ ] **[M] Tarare l'RPS target** per Metrica 1 e Metrica 3.
- [ ] **[M] Query di Log Analytics** per estrarre durata server-side e i tempi interni della function (D6), riusabili identiche per i tre linguaggi.
- [ ] **[M] Misurare il tempo di scale-to-zero** osservando `InstanceCount`, e scriverlo nel log (D16).
- [ ] **[S] Container Apps Job con k6** per i run finali: `replicaRetryLimit` a 0, `replicaTimeout` dimensionato.

## Fase 4 — Worker .NET

- [ ] **[M] Implementazione** isolated worker .NET 10 con ImageSharp, contratto identico, `Compand = false` (D10), subsampling 4:2:0 esplicito (D8), stesso filtro (D9), stessa formula dell'altezza verificata contro `shared/conformance/` (D7).
- [ ] **[M] Tre endpoint, non uno**: `resize`, `health` e `images` (D34) — il contratto dev'essere identico nei tre linguaggi, altrimenti il frontend funziona con un backend e non con gli altri.
- [ ] **[M] Istanziare il modulo Bicep per .NET**: piano Flex dedicato + function app, `--runtime dotnet-isolated`, stessa instance size e stessa regione. Piano dedicato perché su Flex vale una sola app per piano.
- [ ] **[M] Concorrenza a 1** su questa app (D22).
- [ ] **[S] ReadyToRun come flag di CI**, non nel `.csproj` (D11). **Timebox: 30 minuti.** Se resiste, si toglie e si dichiara nelle limitazioni.
- [ ] **[S] Verificare il default di `ResizeOptions.Compand`** sulla doc Six Labors.

## Fase 5 — Worker Go

- [ ] **[M] Implementazione** con `golang.org/x/image/draw` + `image/jpeg`, `BiLinear` (**non** `ApproxBiLinear`, D9), contratto identico, formula dell'altezza verificata contro `shared/conformance/`.
- [ ] **[M] Tre endpoint, non uno**: `resize`, `health` e `images` (D34), stesso contratto degli altri due worker.
- [ ] **[M] Build**: `CGO_ENABLED=0 GOOS=linux GOARCH=amd64`, compilazione in CI (Oryx non supportato per Go).
- [ ] **[M] Istanziare il modulo Bicep per Go**: piano Flex dedicato + function app, `--runtime go --runtime-version 1.0`, stessa instance size e stessa regione.
- [ ] **[M] Disabilitare HTTP/2 sulla function app Go** (D31): `az resource update --resource-type Microsoft.Web/sites --set properties.siteConfig.http20Enabled=false`. È **richiesto durante la public preview** e non compare tra le "Known limitations" della reference — sta solo nella quickstart CLI, quindi è facile non trovarlo. Il probe di Fase 0 ha funzionato **con** questo passo eseguito.
- [ ] **[M] Concorrenza a 1** su questa app (D22).
- [ ] **[M] Smoke test sotto il carico dei run finali.** Se cede, è un artefatto della preview e non una caratteristica di Go — e va detto così in slide.

## Fase 6 — Frontend

- [ ] **[M] Static Web App** che mostra prima/dopo il resize usando `return=image`.
- [ ] **[M] Decidere se punta a tutti e tre i backend** (selettore di linguaggio) o a uno solo. Non ancora deciso.
- [ ] **[M] Selettore immagini** popolato dinamicamente da `GET /api/images` (D34) — mai hardcodare i nomi dei file, così cambiare il pool via redeploy aggiorna anche il frontend senza toccarlo.
- [ ] **[M] CORS** verificato dal browser, non solo dalla configurazione.

## Fase 7 — Run finali e analisi

- [ ] **[M] Metrica 1** — throughput a regime, tasso costante identico per i tre.
- [ ] **[M] Metrica 2** — cold start isolato: 10 ripetizioni per linguaggio, mediana e p95 (**mai la media**).
- [ ] **[M] Metrica 3** — cold start sotto burst, 3 ripetizioni per linguaggio, percentili secondo per secondo, curve sovrapposte.
- [ ] **[M] Metrica 4** — il cold start è fatturato? Su Python, `count` tarato sopra 1s, confronto tra `OnDemandFunctionExecutionUnits` e `2048 × durata`. 3 ripetizioni.
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
