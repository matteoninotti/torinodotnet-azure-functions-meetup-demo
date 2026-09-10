# Generazione del carico (k6)

**k6**, scelto per un motivo metodologico e non di gusto: ha executor a **arrival rate**, cioè si impone quante richieste al secondo *partono*, indipendentemente dal tempo di risposta.

Con un modello a utenti virtuali (Locust, JMeter) il backend più lento riceverebbe automaticamente **meno richieste**: se Python è 3x più lento di Go, con 50 VU ne riceve circa un terzo, e i tre linguaggi finirebbero sotto carichi offerti diversi. Il confronto misurerebbe sé stesso.

## Come si usa

- **Iterazione e messa a punto** → k6 in locale dal Mac. Zero costo, ma la latenza di rete domestica entra nella misura client-side.
- **Numeri che finiscono nelle slide** → k6 in un **Azure Container Apps Job** in Italy North.

Sul job ACA, due impostazioni non sono opzionali:

- **`replicaRetryLimit` a 0.** I job presuppongono i retry: se un load test fallisce a metà e riparte, si genera carico due volte e i numeri sono spazzatura.
- **`replicaTimeout`** dimensionato sulla durata realistica del test più margine — allo scadere il job viene terminato.

## Struttura

| Percorso | Contenuto |
|---|---|
| `scripts/resize.js` | Il generatore di carico per Metrica 1 e Metrica 3. |
| `results/` | Solo i run che finiscono nelle slide, committati esplicitamente. Il resto va in `output/`, che è gitignorato. |

**Uno script per due metriche, non uno per metrica.** Metrica 1 e Metrica 3 usano la stessa forma di carico — tasso costante — e differiscono per lo stato dell'app quando il carico arriva (calda contro zero istanze) e per come si leggono i risultati, non per cosa fa il generatore. Due file identici da tenere allineati a mano sarebbero due occasioni di farli divergere.

**Metrica 2 non usa k6.** Il cold start isolato è una singola richiesta sequenziale: un generatore di carico ci aggiungerebbe solo rumore.

```
k6 run -e LANGUAGE=python -e RPS=5 -e DURATION=60s -e COUNT=1 load/scripts/resize.js
```

Tutti i parametri stanno in variabili d'ambiente (D15): `LANGUAGE`, `HOST`, `IMAGE`, `COUNT`, `WIDTH`, `QUALITY`, `RPS`, `DURATION`, `PRE_ALLOCATED_VUS`, `MAX_VUS`.

## Leggere i risultati senza sbagliare

Due contatori di fallimento che sembrano lo stesso e non lo sono:

- **`http_req_failed`** — il backend ha risposto male o non ha risposto. È un dato sull'esperimento.
- **`dropped_iterations`** — k6 non è riuscito a *far partire* le richieste al tasso richiesto, perché i VU allocati non bastavano. È un fallimento del generatore: invalida il run come misura di carico offerto. Se compare, si rialza `PRE_ALLOCATED_VUS` e si rifà.

Lo script conta anche gli status code uno per uno (`resize_status_codes`), perché sotto burst un `429` (la piattaforma limita lo scale-out) e un `500` dopo 30 secondi (app init che sfora il timeout) sono due storie diverse (D45).

`resize_server_total_ms` è il cronometro interno alla function, riletto dal corpo della risposta: comodo per vedere subito lo scarto con `http_req_duration` senza aspettare l'ingestion di Application Insights. **Non è la fonte autorevole** — quella resta la durata server-side nella telemetria, che è anche ciò che determina il costo.

`count=N`, RPS target e durata restano parametri esterni, tarati dopo un run preliminare e scritti nel decision log (D15): `count` va dimensionato perché **la più veloce delle tre** superi 1s, e quale sia la più veloce non si sa finché non si misura.
