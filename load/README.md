# Generazione del carico (k6)

**k6**, scelto per un motivo metodologico e non di gusto: ha executor a **arrival rate**, cioè si impone quante richieste al secondo *partono*, indipendentemente dal tempo di risposta.

Con un modello a utenti virtuali (Locust, JMeter) il backend più lento riceverebbe automaticamente **meno richieste**: se Python è 3x più lento di Go, con 50 VU ne riceve circa un terzo, e i tre linguaggi finirebbero sotto carichi offerti diversi. Il confronto misurerebbe sé stesso.

## Come si usa

- **Iterazione e messa a punto** → k6 in locale dal Mac. Zero costo, ma la latenza di rete domestica entra nella misura client-side (~34 ms di RTT verso Italy North, misurati in D53). Questo è deciso.
- **Numeri che finiscono nelle slide** → **ancora da decidere in Fase 7 (D59)**: Mac o **Azure Container Apps Job** in Italy North.

⚠️ Questa riga diceva "numeri finali → ACA Job" come se fosse deciso. Non lo è: l'ACA Job era stato promosso sulla base di ~765 ms che sembravano latenza di rete e invece erano cold start (D53 corregge D48), e caduta la premessa la decisione è tornata aperta. Va presa **a parametri congelati**, misurando se il Mac regge il tasso finale senza diventare lui il collo di bottiglia — e la misura non è `dropped_iterations`, che il cold start del backend confonde: servono VU fissi e abbondanti, CPU locale osservata, e tasso ottenuto contro tasso richiesto (D59).

Se il job ACA servirà, due impostazioni non sono opzionali:

- **`replicaRetryLimit` a 0.** I job presuppongono i retry: se un load test fallisce a metà e riparte, si genera carico due volte e i numeri sono spazzatura.
- **`replicaTimeout`** dimensionato sulla durata realistica del test più margine — allo scadere il job viene terminato.

## Struttura

| Percorso | Contenuto |
|---|---|
| `scripts/resize.js` | Il generatore di carico per Metrica 1 e Metrica 3. |
| `results/` | Solo i run che finiscono nelle slide, committati esplicitamente. Il resto va in `output/`, che è gitignorato. |

**Uno script per due metriche, non uno per metrica.** Metrica 1 e Metrica 3 usano la stessa forma di carico — tasso costante — e differiscono per lo stato dell'app quando il carico arriva (calda contro zero istanze) e per come si leggono i risultati, non per cosa fa il generatore. Due file identici da tenere allineati a mano sarebbero due occasioni di farli divergere.

**Metrica 2 non usa k6.** Il cold start isolato è una singola richiesta sequenziale: un generatore di carico ci aggiungerebbe solo rumore.

Il comando dei run finali, identico per i tre linguaggi e per Metrica 1 e Metrica 3 (D89, D92):

```
k6 run -e LANGUAGE=python -e RPS=10 -e DURATION=60s -e COUNT=80 \
       -e PRE_ALLOCATED_VUS=300 -e MAX_VUS=400 load/scripts/resize.js
```

Tutti i parametri stanno in variabili d'ambiente (D15): `LANGUAGE`, `HOST`, `IMAGE`, `COUNT`, `WIDTH`, `QUALITY`, `RPS`, `DURATION`, `PRE_ALLOCATED_VUS`, `MAX_VUS`.

## Leggere i risultati senza sbagliare

Tre contatori di fallimento che sembrano lo stesso e non lo sono:

- **`http_req_failed`** — il backend ha risposto male o non ha risposto. È un dato sull'esperimento.
- **`dropped_iterations`** — k6 non è riuscito a *far partire* le richieste al tasso richiesto, perché i VU allocati non bastavano. È un fallimento del generatore: invalida il run come misura di carico offerto. Se compare, si rialza `PRE_ALLOCATED_VUS` e si rifà.
- **Iterazione interrotta da k6** — la richiesta era partita e il backend la stava servendo, ma allo scadere di `gracefulStop` k6 ha chiuso la connessione. Lato server diventa un **`499`**, e in `resize_status_codes` è indistinguibile da un errore del backend: **non lo è**, e non è nemmeno un fallimento del generatore. k6 le conta a parte nel riepilogo (`... complete and N interrupted iterations`).

Il terzo è il motivo per cui `gracefulStop` è **esplicito a `120s`** nello scenario invece del [default di `30s`](https://grafana.com/docs/k6/latest/using-k6/scenarios/concepts/graceful-stop/): durante lo scale-out la coda lato client arriva a 36 s (p95 di `http_req_duration` sul run Go, D91), quindi con il default le ultime iterazioni della finestra verrebbero tagliate. I 7 `499` di D89 sono questo. Se ne compaiono ancora, si alza `gracefulStop`, non `PRE_ALLOCATED_VUS`.

Lo script conta anche gli status code uno per uno (`resize_status_codes`), perché sotto burst un `429` (la piattaforma limita lo scale-out) e un `500` dopo 30 secondi (app init che sfora il timeout) sono due storie diverse (D45).

`resize_server_total_ms` è il cronometro interno alla function, riletto dal corpo della risposta: comodo per vedere subito lo scarto con `http_req_duration` senza aspettare l'ingestion di Application Insights. **Non è la fonte autorevole** — quella resta la durata server-side nella telemetria, che è anche ciò che determina il costo.

`count=N`, RPS target e durata restano parametri esterni, tarati dopo un run preliminare e scritti nel decision log (D15): `count` va dimensionato perché **la più veloce delle tre** superi 1s, e quale sia la più veloce non si sa finché non si misura. **La taratura è stata fatta** con i tre worker deployati (D89): `count=80`, 10 req/s, 60s.

**La Metrica 1 va preceduta da una finestra di riscaldamento che si scarta.** A questo carico la piattaforma impiega decine di secondi ad arrivare alla capacità richiesta, e su una finestra di 60 secondi la rampa domina la misura: senza riscaldamento si misura lo scale-out, che è oggetto della Metrica 3 (D90).
