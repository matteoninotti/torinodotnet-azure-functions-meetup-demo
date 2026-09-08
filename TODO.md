# TODO

**Scadenza: 30 settembre 2026, Toolbox Torino** (D21). Aggiornato: 2026-09-08.

Ogni fase corrisponde a un branch `phase-N`. Si spunta nello **stesso commit** che completa il task. `D#` rimanda al decision log nel vault.

Priorità: **[M]** must — senza, il talk non sta in piedi · **[S]** should — il talk regge ma perde un pezzo · **[C]** could — se avanza tempo.

---

## Fase 0 — Fondamenta (percorso critico, blocca tutto il resto)

> Nessun codice. Finché questa fase non chiude, si può scrivere e testare in locale ma non misurare niente.

- [x] **[M] Creare l'account Azure.** Free account, $200 di credito (D27). ⚠️ Il credito scade a 30 giorni O a esaurimento, quello che viene prima — non ha uno spending limit in senso tecnico, oltre la soglia l'account si **disabilita**, non addebita. Vedi D27 per il dettaglio e il rischio residuo.
- [x] **[M] Enrollare MFA** con authenticator + metodo di backup. Non il giorno del talk.
- [ ] **[M] `az login`** dal Mac (appena fatto l'MFA) e verifica di quale sottoscrizione è attiva.
- [ ] **[M] Verificare che Flex Consumption sia disponibile in Italy North** per *quella* sottoscrizione, col comando documentato. Se non lo è → si ricade su Switzerland North o France Central e si aggiorna `instructions.md`.
- [ ] **[M] Controllare la quota regionale di core effettiva.** `instructions.md` cita 250 come default, ma le sottoscrizioni trial possono averne molti meno — e la Metrica 3 (burst) è esattamente ciò che sbatte contro una quota bassa. Se la quota è bassa, il target RPS della Metrica 3 va ridimensionato e la cosa va dichiarata.
- [ ] **[M] Registrare i resource provider**: `Microsoft.Web`, `Microsoft.Storage`, `Microsoft.Insights`, `Microsoft.OperationalInsights`, `Microsoft.App`.
- [ ] **[M] Creare il resource group** unico del progetto in Italy North. Teardown = cancellare questo.
- [ ] **[M] Budget alert a €5 / €10 / €18 — la priorità più alta ora che l'account esiste.** Con un free account non c'è addebito da prevenire (D27), ma c'è una **disabilitazione totale a sorpresa** da prevenire: se il credito finisce nel mezzo dei run finali o della prova generale, l'account si blocca senza preavviso automatico.
- [x] **[M] Installare la toolchain**: `az` 2.90.0 · `func` 4.14.0 · Go 1.27.1 · .NET SDK **10.0.400** (via script ufficiale, non brew cask — richiedeva `sudo` che non si può automatizzare; installato in `~/.dotnet`, aggiunto al PATH in `.zshrc`) · k6 2.2.0.
- [ ] **[M] Probe di rischio: hello-world Go deployato su Flex.** Da fare **subito**, prima di scrivere il worker Go vero. Go è in public preview e non compare nella tabella dei language stack supportati: se non si deploya affatto, la premessa del talk cambia e va saputo in settimana 1, non in settimana 3.
- [ ] **[S] Hello-world Python deployato su Flex** per validare la catena `func` → Azure prima di metterci dentro il codice vero.

## Fase 1 — Monorepo e function Python ⏳ in corso

- [x] Struttura del monorepo, `.gitignore`, `README.md`, `TODO.md` (residuo di D2).
- [x] Scheletro della function Python: contratto dell'endpoint, pipeline decode→resize→encode, strumentazione dei tempi (D3, D5, D6, D7, D8, D9).
- [x] `host.json` con sampling di Application Insights disattivato (D14) ed extension bundle `[4.0.0, 5.0.0)`.
- [x] Casi di conformità condivisi per l'altezza dell'output (`shared/conformance/`) — diventeranno i test di .NET e Go.
- [ ] **[M] Scegliere le immagini di test** (risoluzione, numero, licenza) e committarle. Finché non ci sono, l'endpoint risponde 404 su qualunque `image=`.
- [ ] **[M] Installare le dipendenze e far girare i test in locale**, poi **pinnare la versione di Pillow** in `requirements.txt` con quella effettivamente risolta.
- [ ] **[M] Provare `func start` in locale** e verificare il contratto della risposta end-to-end.
- [ ] **[S] Verificare i default di Pillow** su progressive e optimize, per confermare che i flag espliciti bastino (D8).

## Fase 2 — Infrastruttura Bicep e primo deploy

- [ ] **[M] Bicep** (D20): resource group, storage account, piano Flex + function app Python, Application Insights + Log Analytics.
- [ ] **[M] Impostare la HTTP trigger concurrency a 1** via Azure CLI (D22). **Non è opzionale e non si fa in `host.json`**: a 2.048 MB il default è 16 per .NET e Go e 1 per Python — lasciarlo così renderebbe il confronto privo di significato.
- [ ] **[M] Verificare che il sampling sia davvero spento** guardando la telemetria, non il file di configurazione (D14).
- [ ] **[M] Pipeline GitHub Actions** con OIDC federato, `workflow_dispatch` (D13). Richiede un'app registration su Entra ID.
- [ ] **[M] Deploy della function Python** e prima chiamata riuscita da internet.
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
- [ ] **[M] Concorrenza a 1** su questa app (D22).
- [ ] **[S] ReadyToRun come flag di CI**, non nel `.csproj` (D11). **Timebox: 30 minuti.** Se resiste, si toglie e si dichiara nelle limitazioni.
- [ ] **[S] Verificare il default di `ResizeOptions.Compand`** sulla doc Six Labors.

## Fase 5 — Worker Go

- [ ] **[M] Implementazione** con `golang.org/x/image/draw` + `image/jpeg`, `BiLinear` (**non** `ApproxBiLinear`, D9), contratto identico, formula dell'altezza verificata contro `shared/conformance/`.
- [ ] **[M] Build**: `CGO_ENABLED=0 GOOS=linux GOARCH=amd64`, compilazione in CI (Oryx non supportato per Go).
- [ ] **[M] Concorrenza a 1** su questa app (D22).
- [ ] **[M] Smoke test sotto il carico dei run finali.** Se cede, è un artefatto della preview e non una caratteristica di Go — e va detto così in slide.

## Fase 6 — Frontend

- [ ] **[M] Static Web App** che mostra prima/dopo il resize usando `return=image`.
- [ ] **[M] Decidere se punta a tutti e tre i backend** (selettore di linguaggio) o a uno solo. Non ancora deciso.
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

| Rischio | Impatto | Mitigazione |
|---|---|---|
| Account Azure non ancora creato a 3 settimane dal talk | Blocca tutto | Fase 0, oggi |
| Go in public preview non deploya o cede sotto carico | Perde un terzo del talk | Probe hello-world in Fase 0, non in Fase 5 |
| Quota di core bassa su sottoscrizione trial | La Metrica 3 non è eseguibile come progettata | Verificare in Fase 0, ridimensionare l'RPS e dichiararlo |
| Concorrenza non impostata a 1 su .NET e Go | **I numeri del confronto sarebbero falsi** | D22, task bloccante di Fase 2 |
| Immagini di test non ancora scelte | Blocca la taratura di `count` | Fase 1 |
