# Generazione del carico (k6)

**k6**, scelto per un motivo metodologico e non di gusto: ha executor a **arrival rate**, cioè si impone quante richieste al secondo *partono*, indipendentemente dal tempo di risposta.

Con un modello a utenti virtuali (Locust, JMeter) il backend più lento riceverebbe automaticamente **meno richieste**: se Python è 3x più lento di Go, con 50 VU ne riceve circa un terzo, e i tre linguaggi finirebbero sotto carichi offerti diversi. Il confronto misurerebbe sé stesso.

## Come si usa

- **Iterazione e messa a punto** → k6 in locale dal Mac. Zero costo, ma la latenza di rete domestica entra nella misura client-side.
- **Numeri che finiscono nelle slide** → k6 in un **Azure Container Apps Job** in Italy North.

Sul job ACA, due impostazioni non sono opzionali:

- **`replicaRetryLimit` a 0.** I job presuppongono i retry: se un load test fallisce a metà e riparte, si genera carico due volte e i numeri sono spazzatura.
- **`replicaTimeout`** dimensionato sulla durata realistica del test più margine — allo scadere il job viene terminato.

## Struttura prevista

| Percorso | Contenuto |
|---|---|
| `scripts/` | Gli script k6, uno per metrica. |
| `results/` | Solo i run che finiscono nelle slide, committati esplicitamente. Il resto va in `output/`, che è gitignorato. |

`count=N`, RPS target e durata restano parametri esterni, tarati dopo un run preliminare e scritti nel decision log (D15): `count` va dimensionato perché **la più veloce delle tre** superi 1s, e quale sia la più veloce non si sa finché non si misura.
