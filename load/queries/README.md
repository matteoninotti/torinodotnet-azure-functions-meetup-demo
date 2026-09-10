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

## Tre cose che è facile sbagliare

**La query string è redatta nella telemetria.** L'host di Azure Functions sostituisce i valori dei parametri (`?image=Redacted&width=Redacted`, D41), quindi da `AppRequests` **non** si può sapere con che `count` o `width` è stata servita una richiesta. È il motivo per cui la join con `AppTraces` non è un'ottimizzazione ma l'unico modo di saperlo — e perché i run si isolano per finestra temporale e non per parametro.

**La join è `leftouter`, mai `inner`.** `RESIZE_METRICS` viene emesso solo dopo una pipeline riuscita: un `inner` scarterebbe in silenzio ogni 4xx e 5xx, cioè proprio le richieste che sotto burst interessano di più. Un p95 calcolato solo sui successi *migliora* mentre il backend peggiora (D45).

**L'ingestion ha 2–4 minuti di ritardo.** Una query lanciata appena finito il run restituisce meno righe di quante ne siano state servite davvero. Il controllo è `requests` contro le `http_reqs` riportate da k6: se non combaciano, si aspetta e si rilancia.

## `sampling_max` va guardato a ogni run

`run-summary.kql` riporta `max(ItemCount)`. È il campo con cui Application Insights dichiara il fattore di sampling effettivo su ogni riga: **deve essere sempre 1**. Se fosse maggiore, la telemetria sarebbe stata campionata e i percentili sarebbero calcolati su un campione non uniforme — cioè non sarebbero percentili (D14).

Il sampling è spento in due punti (`host.json` e `SamplingPercentage` sulla risorsa), ma la verifica che conta è questa, sui dati veri, non sulla configurazione.

## Cosa queste query non coprono

`InstanceCount` **non è una tabella di Log Analytics**: è una metrica di Azure Monitor e si legge con `az monitor metrics list`, non in KQL. Il tempo di scale-to-zero (D16) si misura da lì.
