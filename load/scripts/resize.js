// Generatore di carico per le Metriche 1 e 3.
//
// Un solo script per entrambe: la differenza tra "throughput a regime" e
// "cold start sotto burst" non sta nella forma del carico — e' la stessa,
// tasso costante — ma nello stato dell'app quando il carico arriva (calda per
// la Metrica 1, a zero istanze per la Metrica 3) e nel modo in cui si leggono
// i risultati. Duplicare lo script per esprimere quella differenza vorrebbe
// dire tenere allineati a mano due file che devono restare identici.
//
// La Metrica 2 (cold start isolato) NON usa k6: e' una singola richiesta
// sequenziale, dove un generatore di carico aggiungerebbe solo rumore.
//
// Tutti i parametri arrivano da variabile d'ambiente (D15): niente valori
// cablati, perche' count e RPS andavano tarati dopo un run preliminare e la
// taratura definitiva richiedeva tutti e tre i worker (D43).
//
// Valori definitivi dei run finali, identici per Metrica 1 e Metrica 3 e per i
// tre linguaggi (D89, D92). I default qui sotto NON sono questi: passarli
// esplicitamente e' cio' che rende il comando leggibile in cronologia.
//
//   k6 run -e LANGUAGE=python -e RPS=10 -e DURATION=60s -e COUNT=80 \
//          -e PRE_ALLOCATED_VUS=300 -e MAX_VUS=400 load/scripts/resize.js
//
// Le richieste NON usano `return=image`: la banda di download dell'immagine
// entrerebbe nella latenza client, che e' esattamente il rumore che la forma
// `?image=` dell'endpoint serve a eliminare.

import http from 'k6/http';
import { check } from 'k6';
import { Counter, Trend } from 'k6/metrics';

// --- Parametri --------------------------------------------------------------

const LANGUAGE = __ENV.LANGUAGE || 'python';
const HOST = __ENV.HOST || `torinodotnet-${LANGUAGE}.azurewebsites.net`;

const IMAGE = __ENV.IMAGE || 'npm-install-7-years.jpg';
const COUNT = __ENV.COUNT || '1';
const WIDTH = __ENV.WIDTH || '800';
const QUALITY = __ENV.QUALITY || '80';

const RPS = Number(__ENV.RPS || 5);
const DURATION = __ENV.DURATION || '60s';

// Con concorrenza server-side a 1 ogni richiesta occupa un'istanza per tutta
// la sua durata, quindi il numero di VU necessari e' RPS x durata attesa della
// richiesta. Il default e' dimensionato su richieste fino a 10s: sotto stima,
// k6 non riesce a mantenere il tasso richiesto e lo segnala come dropped
// iterations — che e' un fallimento del generatore, non del backend, e va
// distinto (vedi la nota in fondo).
//
// ⚠️ Per i run finali il default NON basta, e il conto giusto non e' RPS x
// durata della RICHIESTA ma RPS x durata osservata dal CLIENT mentre la
// piattaforma scala: durante la rampa arriva a 30-40s. Con 120 VU il run su Go
// ha prodotto 13 dropped iterations; con 300 nessuna (D90). Si passano 300 a
// tutti e tre i linguaggi, anche dove ne basterebbero meno: un generatore
// configurato diversamente per ciascun backend sarebbe un'asimmetria in piu'
// da dichiarare, in cambio di niente.
const PRE_ALLOCATED_VUS = Number(__ENV.PRE_ALLOCATED_VUS || Math.ceil(RPS * 10));
const MAX_VUS = Number(__ENV.MAX_VUS || PRE_ALLOCATED_VUS * 2);

// --- Metriche custom --------------------------------------------------------
//
// k6 da' gia' http_req_failed, ma come tasso aggregato: non dice *come* una
// richiesta e' fallita. Sotto burst la distinzione conta — un 429 e' la
// piattaforma che limita lo scale-out, un 500 dopo 30s e' l'app init che
// sfora il timeout, e sono due storie diverse da raccontare in slide (D45).

const statusCodes = new Counter('resize_status_codes');
const serverTotalMs = new Trend('resize_server_total_ms', true);

export const options = {
  scenarios: {
    resize: {
      // Arrival rate e non VU: si impone quante richieste PARTONO al secondo,
      // indipendentemente da quanto ci mette il backend a rispondere. Con un
      // modello a utenti virtuali il linguaggio piu' lento riceverebbe meno
      // richieste, e i tre finirebbero sotto carichi offerti diversi.
      executor: 'constant-arrival-rate',
      rate: RPS,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: PRE_ALLOCATED_VUS,
      maxVUs: MAX_VUS,

      // Esplicito e NON il default. k6 aspetta questo tempo prima di
      // interrompere a forza le iterazioni ancora in volo a fine finestra, e
      // il default e' 30s ([Graceful
      // stop](https://grafana.com/docs/k6/latest/using-k6/scenarios/concepts/graceful-stop/)).
      // Trenta secondi non bastano: durante lo scale-out la coda lato client
      // arriva a 36s (p95 di http_req_duration sul run Go, D91), quindi le
      // ultime iterazioni verrebbero tagliate da k6 e il server registrerebbe
      // dei 499 — che non sono un fallimento del backend ne' del generatore, e
      // che sarebbero letti come il primo dei due. E' l'origine dei 7 `499` di
      // D89. 120s copre il p95 osservato con margine.
      //
      // Identico per i tre linguaggi: un generatore configurato diversamente
      // per ciascun backend sarebbe un'asimmetria in piu' da dichiarare.
      gracefulStop: '120s',
    },
  },
  // Nessuna soglia: una threshold che fallisce interrompe il run, e qui il run
  // E' la misura. I fallimenti si contano, non si usano per abortire.
  thresholds: {},
  // I tre linguaggi vanno confrontati sugli stessi percentili.
  summaryTrendStats: ['min', 'med', 'avg', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

const url =
  `https://${HOST}/api/resize` +
  `?image=${encodeURIComponent(IMAGE)}&count=${COUNT}&width=${WIDTH}&quality=${QUALITY}`;

export function setup() {
  // L'istante di inizio serve a delimitare la finestra della query di Log
  // Analytics: la query string e' redatta nella telemetria (D41), quindi il
  // run non e' identificabile dai parametri e si isola per finestra temporale.
  const startedAt = new Date().toISOString();
  console.log(`RUN_START ${startedAt} language=${LANGUAGE} rps=${RPS} duration=${DURATION} count=${COUNT} image=${IMAGE}`);
  return { startedAt };
}

export default function () {
  const res = http.post(url, null, {
    // Il tag rende i percentili leggibili per linguaggio quando si confrontano
    // piu' run nello stesso output.
    tags: { language: LANGUAGE },
  });

  statusCodes.add(1, { status: String(res.status) });

  check(res, {
    'status 200': (r) => r.status === 200,
  });

  // total_ms e' il cronometro interno alla function: il tempo di sola
  // pipeline, senza l'overhead host-worker. Raccoglierlo anche qui permette
  // di vedere subito lo scarto con http_req_duration senza aspettare i 2-4
  // minuti di ingestion di Application Insights. Resta comunque la telemetria
  // server-side la fonte autorevole — questa e' una lettura di comodo.
  if (res.status === 200) {
    try {
      const body = res.json();
      if (body && typeof body.total_ms === 'number') {
        serverTotalMs.add(body.total_ms, { language: LANGUAGE });
      }
    } catch (e) {
      // Un 200 con body non-JSON non deve far morire l'iterazione: verrebbe
      // contato come fallimento del backend quando non lo e'.
    }
  }
}

export function teardown(data) {
  console.log(`RUN_END ${new Date().toISOString()} (started ${data.startedAt})`);
}

// Nota di lettura dei risultati, per non confondere tre fallimenti diversi:
//
//   http_req_failed        -> il backend ha risposto male (o non ha risposto)
//   dropped_iterations     -> k6 non e' riuscito a PARTIRE al tasso richiesto,
//                             perche' i VU allocati non bastavano
//   interrupted iterations -> k6 ha TAGLIATO un'iterazione gia' partita allo
//                             scadere di gracefulStop; lato server e' un 499
//
// Il secondo non e' un dato sul backend: e' il generatore che non ha tenuto il
// passo, e invalida il run come misura di carico offerto. Se compare, si
// rialza PRE_ALLOCATED_VUS e si rifa'.
//
// Il terzo non e' ne' l'uno ne' l'altro: la richiesta era partita e il backend
// la stava servendo: e' k6 che ha chiuso la connessione. In
// `resize_status_codes` compare come 499 e sembra un fallimento del backend.
// gracefulStop a 120s esiste per non averne nessuno; se ne compaiono, si alza.
