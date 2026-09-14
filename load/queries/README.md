# Query di Log Analytics

Le query che estraggono i numeri dei run. Sono **identiche per i tre linguaggi**: raggruppano per il campo `language` che arriva dal payload di `RESIZE_METRICS`, non dal nome della function app.

| File | A cosa serve |
|---|---|
| `run-summary.kql` | Riepilogo di un run: percentili server-side, tempo di sola pipeline, overhead, tasso di successo. Metrica 1. |
| `latency-per-second.kql` | Percentili secondo per secondo, per le curve sovrapposte. Metrica 3. |

## Come si lanciano

```bash
WS=$(az monitor log-analytics workspace show -g rg-torinodotnet-demo -n torinodotnet-logs --query customerId -o tsv)
az monitor log-analytics query -w "$WS" --analytics-query "$(cat load/queries/run-summary.kql)" -o table
```

Prima di lanciarle si sostituiscono `win_start` e `win_end` in cima al file con la finestra del run. k6 stampa `RUN_START` e `RUN_END` già in UTC apposta.

## `run-summary.kql` restituisce **due righe per linguaggio**

La colonna `phase` separa la **prima richiesta servita da ciascuna istanza** (`1-prima sull istanza`) da **tutte le successive** (`2-successive`). Non è un raffinamento: è il motivo per cui D50 ha dovuto ritrattare un numero già detto.

L'overhead host↔worker vale ~180–200 ms sulla prima richiesta di un'istanza e ~7 ms sulle successive. Un valore unico dipende quindi da **quante istanze sono nate durante il run**, cioè dalla forma del carico, non dal linguaggio — e su un run in scale-out dà un numero venticinque volte più grande di quello a regime.

Tre conseguenze pratiche:

- `p50_overhead_ms` è la **mediana delle differenze riga per riga**, non la differenza di due mediane. La seconda non corrisponde a nessuna richiesta realmente servita.
- Le due righe si sommano solo sui **conteggi** (`requests`, `ok`, `failed`). **Mai sui percentili.**
- «Prima richiesta servita da quell'istanza» significa **a partire da `win_start - look_back`**, non da `win_start`. Il `look_back` (30 minuti) esiste perché un run è quasi sempre preceduto da poco da un altro sulla stessa app — D90 punto 1 impone un riscaldamento identico subito prima della Metrica 1 — e senza di esso un'istanza già calda verrebbe contata come cold start: sul ladder Go del 13 settembre erano 4 istanze su 190. Il valore va tenuto **sopra il tempo di scale-to-zero** (~3–4 minuti, D56), altrimenti la garanzia decade in silenzio.

La colonna `instances` dice quante istanze compaiono in ciascuna fase: senza quel contesto i percentili dell'altra riga non si interpretano.

## Tre cose che è facile sbagliare

**La query string è redatta nella telemetria.** L'host di Azure Functions sostituisce i valori dei parametri (`?image=Redacted&width=Redacted`, D41), quindi da `AppRequests` **non** si può sapere con che `count` o `width` è stata servita una richiesta. È il motivo per cui la join con `AppTraces` non è un'ottimizzazione ma l'unico modo di saperlo — e perché i run si isolano per finestra temporale e non per parametro.

**La join è `leftouter`, mai `inner`.** `RESIZE_METRICS` viene emesso solo dopo una pipeline riuscita: un `inner` scarterebbe in silenzio ogni 4xx e 5xx, cioè proprio le richieste che sotto burst interessano di più. Un p95 calcolato solo sui successi *migliora* mentre il backend peggiora (D45).

**L'ingestion ha 2–4 minuti di ritardo.** Una query lanciata appena finito il run restituisce meno righe di quante ne siano state servite davvero. Il controllo è `requests` contro le `http_reqs` riportate da k6: se non combaciano, si aspetta e si rilancia.

## `sampling_max` va guardato a ogni run

`run-summary.kql` riporta `max(ItemCount)`. È il campo con cui Application Insights dichiara il fattore di sampling effettivo su ogni riga: **deve essere sempre 1**. Se fosse maggiore, la telemetria sarebbe stata campionata e i percentili sarebbero calcolati su un campione non uniforme — cioè non sarebbero percentili (D14).

Il sampling è spento in due punti (`host.json` e `SamplingPercentage` sulla risorsa), ma la verifica che conta è questa, sui dati veri, non sulla configurazione.

## Cosa queste query non coprono

`InstanceCount` **non è una tabella di Log Analytics**: è una metrica di Azure Monitor e si legge con `az monitor metrics list`, non in KQL. Il tempo di scale-to-zero (D16) si misura da lì.
