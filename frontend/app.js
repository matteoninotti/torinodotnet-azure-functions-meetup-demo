// Pannello dimostrativo: manda la STESSA richiesta ai tre worker e mostra i
// risultati affiancati, per una o piu' immagini insieme.
//
// Non misura niente. I percentili li producono k6 e Application Insights; qui
// si vede solo che i tre backend rispondono allo stesso contratto e che le
// immagini che tornano sono equivalenti. Il tempo sulle card e' reale — e' il
// cronometro interno alla pipeline, la stessa strumentazione delle misure vere
// — ma un singolo click non ha ripetizioni ne' percentili, quindi non e' una
// misura statisticamente valida.

const BACKENDS = [
  { id: 'python', label: 'Python', host: 'torinodotnet-python.azurewebsites.net' },
  { id: 'dotnet', label: '.NET', host: 'torinodotnet-dotnet.azurewebsites.net' },
  { id: 'go', label: 'Go', host: 'torinodotnet-go.azurewebsites.net' },
];

const els = {
  form: document.getElementById('controls'),
  images: document.getElementById('images'),
  width: document.getElementById('width'),
  quality: document.getElementById('quality'),
  count: document.getElementById('count'),
  run: document.getElementById('run'),
  status: document.getElementById('status'),
  results: document.getElementById('results'),
};

const api = (backend, path) => `https://${backend.host}/api/${path}`;

const buildQuery = (params) => new URLSearchParams(params).toString();

// L'originale si chiede a UN SOLO backend: e' lo stesso file byte per byte nei
// tre pacchetti di deploy (verificato, D97), quindi chiederlo a tutti e tre
// direbbe solo che sappiamo scaricare tre volte la stessa cosa.
//
// QUALE dei tre pero' non e' fisso: lo decide loadCatalog scegliendo il primo
// che ha davvero risposto. Cablarlo su BACKENDS[0] significava che, con Python
// giu' e gli altri due vivi, il catalogo si popolava e le card di .NET e Go
// funzionavano, ma ogni anteprima e ogni "Originale" puntavano all'app morta:
// pagina piena di icone di immagine rotta proprio nello scenario che il
// controllo multi-backend esiste per far emergere.
let sourceBackend = BACKENDS[0];

const sourceUrl = (image) =>
  `${api(sourceBackend, 'source')}?${buildQuery({ image })}`;

// I nomi dei file finiscono dentro innerHTML: passano da qui prima, cosi' un
// nome con `&` o `<` non corrompe il markup. Sono nomi che scegliamo noi, non
// input di un utente — il punto non e' un attacco, e' che un file chiamato
// "prima & dopo.jpg" renderebbe la pagina in modo sbagliato senza dirlo.
const escapeHtml = (value) =>
  String(value).replace(
    /[&<>"']/g,
    (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]
  );

// Gli object URL creati per le immagini dei risultati. Il browser li tiene vivi
// finche' non si revocano esplicitamente: replaceChildren() stacca i nodi dal
// DOM ma NON libera il blob dietro. In una demo che si rilancia dieci volte
// sarebbero dieci JPEG pieni per backend a restare in memoria per tutta la
// sessione.
let liveObjectUrls = [];

function revokeLiveObjectUrls() {
  for (const url of liveObjectUrls) URL.revokeObjectURL(url);
  liveObjectUrls = [];
}

function setStatus(message, kind = '') {
  els.status.textContent = message;
  els.status.className = kind;
}

function formatBytes(bytes) {
  if (!Number.isFinite(bytes)) return '—';
  return bytes >= 1024 * 1024
    ? `${(bytes / (1024 * 1024)).toFixed(2)} MB`
    : `${(bytes / 1024).toFixed(1)} kB`;
}

// --- Catalogo delle immagini -------------------------------------------------

// Il catalogo si chiede a TUTTI e tre i backend, non solo al primo che
// risponde: se un pacchetto di deploy fosse partito senza le immagini, il
// worker resterebbe vivo e risponderebbe 404 solo al momento del resize (per
// costruzione: un'istanza senza immagini non va in crash all'avvio). Chiedere
// a tutti e tre e confrontare gli elenchi fa emergere subito la differenza,
// che e' esattamente il motivo per cui /api/images esiste.
let sourceBytes = new Map();

async function loadCatalog() {
  const answers = await Promise.allSettled(
    BACKENDS.map(async (backend) => {
      const response = await fetch(api(backend, 'images'));
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const body = await response.json();
      return { backend, images: body.images ?? [] };
    })
  );

  const reachable = answers.filter((a) => a.status === 'fulfilled').map((a) => a.value);
  const unreachable = answers
    .map((a, i) => (a.status === 'rejected' ? `${BACKENDS[i].label} (${a.reason.message})` : null))
    .filter(Boolean);

  if (reachable.length === 0) {
    els.images.innerHTML = '';
    setStatus(
      'Nessuno dei tre backend ha risposto. Se la console mostra un errore CORS, ' +
        "l'origine di questa pagina non e' ancora nell'allowlist delle function app.",
      'error'
    );
    return;
  }

  // Solo le immagini presenti su TUTTI i backend raggiungibili finiscono nel
  // selettore: offrirne una che un backend non ha significherebbe far scegliere
  // all'utente un 404 garantito.
  const names = reachable
    .map((r) => new Set(r.images.map((i) => i.name)))
    .reduce((shared, current) => new Set([...shared].filter((n) => current.has(n))));

  const divergent = reachable.filter((r) => r.images.length !== names.size);

  sourceBackend = reachable[0].backend;
  sourceBytes = new Map(reachable[0].images.map((i) => [i.name, i.bytes]));

  els.images.replaceChildren(
    ...[...names].sort().map((name, index) => {
      const option = document.createElement('label');
      option.className = 'option';
      // La prima parte gia' selezionata: aprire il pannello e trovare tutto
      // deselezionato costringerebbe a un click in piu' prima di far vedere
      // qualcosa, che dal vivo e' un tempo morto.
      option.innerHTML = `
        <input type="checkbox" value="${escapeHtml(name)}" ${index === 0 ? 'checked' : ''}>
        <img src="${escapeHtml(sourceUrl(name))}" alt="" loading="lazy">
        <span class="option-text">
          <span class="option-name">${escapeHtml(name)}</span>
          <span class="option-size">${formatBytes(sourceBytes.get(name))}</span>
        </span>
      `;
      return option;
    })
  );

  els.run.disabled = false;

  const warnings = [];
  if (unreachable.length) warnings.push(`non raggiungibili: ${unreachable.join(', ')}`);
  if (divergent.length) {
    warnings.push(
      `elenchi diversi fra i backend: ${divergent.map((d) => d.backend.label).join(', ')}`
    );
  }
  setStatus(
    warnings.length
      ? `⚠️ ${warnings.join(' · ')}`
      : `${names.size} immagini disponibili su tutti e tre.`,
    warnings.length ? 'warn' : ''
  );
}

const selectedImages = () =>
  [...els.images.querySelectorAll('input[type="checkbox"]:checked')].map((input) => input.value);

// --- Esecuzione --------------------------------------------------------------

async function runOne(backend, image, params) {
  const base = { image, width: params.width, quality: params.quality };

  // Due richieste, e la ragione e' che il contratto ne fa due cose diverse:
  // senza `return` l'endpoint risponde JSON con le misure, con `return=image`
  // risponde il JPEG. L'immagine si chiede con count=1 perche' `count` e' una
  // manopola sul TEMPO e non sul risultato — i test dei tre linguaggi
  // verificano proprio che l'output non cambi al variare di count.
  const metricsUrl = `${api(backend, 'resize')}?${buildQuery({ ...base, count: params.count })}`;
  const imageUrl = `${api(backend, 'resize')}?${buildQuery({ ...base, count: 1, return: 'image' })}`;

  const metricsResponse = await fetch(metricsUrl, { method: 'POST' });
  if (!metricsResponse.ok) {
    let detail = '';
    try {
      detail = (await metricsResponse.json()).error ?? '';
    } catch {
      /* un errore senza corpo JSON non deve nascondere lo status code */
    }
    throw new Error(`HTTP ${metricsResponse.status}${detail ? ` — ${detail}` : ''}`);
  }
  const metrics = await metricsResponse.json();

  const imageResponse = await fetch(imageUrl, { method: 'POST' });
  if (!imageResponse.ok) throw new Error(`HTTP ${imageResponse.status} sull'immagine`);

  const objectUrl = URL.createObjectURL(await imageResponse.blob());
  liveObjectUrls.push(objectUrl);
  return { metrics, objectUrl };
}

// --- Rendering ---------------------------------------------------------------

function sourceCard(image) {
  const card = document.createElement('article');
  card.className = 'card source';
  card.innerHTML = `
    <h3>Originale <span class="runtime">sorgente</span></h3>
    <img src="${escapeHtml(sourceUrl(image))}" alt="Immagine di partenza, prima del resize">
    <dl>
      <dt>Peso</dt><dd>${formatBytes(sourceBytes.get(image))}</dd>
      <dt>Nota</dt><dd class="muted">Lo stesso file per i tre worker.</dd>
    </dl>
  `;
  return card;
}

function pendingCard(backend) {
  const card = document.createElement('article');
  card.className = 'card pending';
  card.innerHTML = `<h3>${backend.label}</h3><p class="muted">in corso… (a freddo puo' richiedere qualche secondo)</p>`;
  return card;
}

function fillResult(card, backend, { metrics, objectUrl }, image) {
  const before = sourceBytes.get(image);
  const ratio = before ? `${((1 - metrics.output_bytes / before) * 100).toFixed(0)}% in meno` : '—';

  card.className = 'card';
  card.innerHTML = `
    <h3>${backend.label} <span class="runtime">${metrics.runtime}</span></h3>
    <img src="${objectUrl}" alt="Risultato del resize su ${backend.label}">
    <dl>
      <dt>Dimensioni</dt><dd>${metrics.width} × ${metrics.height}</dd>
      <dt>Peso</dt><dd>${formatBytes(metrics.output_bytes)} <span class="muted">(${ratio})</span></dd>
      <dt>Pipeline</dt><dd>${Math.round(metrics.total_ms).toLocaleString('it-IT')} ms <span class="muted">× ${metrics.count}</span></dd>
    </dl>
  `;
}

function fillError(card, backend, error) {
  card.className = 'card failed';
  card.innerHTML = `<h3>${backend.label}</h3><p class="error">${error.message}</p>`;
}

// Un blocco per immagine: intestazione col nome del file e dentro le quattro
// card — l'originale e i tre worker.
function createGroup(image) {
  const group = document.createElement('section');
  group.className = 'group';

  const title = document.createElement('h2');
  title.className = 'group-title';
  title.innerHTML = `${escapeHtml(image)} <span class="muted">${formatBytes(sourceBytes.get(image))}</span>`;

  const row = document.createElement('div');
  row.className = 'row';
  row.append(sourceCard(image));

  const cards = new Map();
  for (const backend of BACKENDS) {
    const card = pendingCard(backend);
    cards.set(backend.id, card);
    row.append(card);
  }

  group.append(title, row);
  return { group, cards };
}

els.form.addEventListener('submit', async (event) => {
  event.preventDefault();

  const images = selectedImages();
  if (images.length === 0) {
    setStatus('Seleziona almeno un’immagine.', 'warn');
    return;
  }

  const params = {
    width: els.width.value,
    quality: els.quality.value,
    count: els.count.value,
  };

  els.run.disabled = true;
  // Prima di buttare via i risultati precedenti, libera i blob che tenevano
  // vive le loro immagini: staccare i nodi dal DOM da solo non lo fa.
  revokeLiveObjectUrls();
  els.results.replaceChildren();

  let failures = 0;

  // Le immagini si eseguono UNA PER VOLTA, i tre backend in parallelo fra loro.
  //
  // Non e' una semplificazione: con la concorrenza server-side a 1, mandare tre
  // immagini insieme darebbe a ciascuna app tre richieste simultanee, quindi due
  // istanze da far nascere e due cold start da guardare in silenzio davanti al
  // pubblico. Sequenziale, ogni worker resta sulla sua istanza calda. In piu' i
  // blocchi compaiono a mano a mano, invece che tutti insieme dopo l'attesa.
  for (const [index, image] of images.entries()) {
    setStatus(`Immagine ${index + 1} di ${images.length}: ${image}…`);

    const { group, cards } = createGroup(image);
    els.results.append(group);

    await Promise.all(
      BACKENDS.map(async (backend) => {
        const card = cards.get(backend.id);
        try {
          fillResult(card, backend, await runOne(backend, image, params), image);
        } catch (error) {
          failures += 1;
          fillError(card, backend, error);
        }
      })
    );
  }

  els.run.disabled = false;
  setStatus(
    failures > 0
      ? `⚠️ ${failures} richieste fallite su ${images.length * BACKENDS.length}.`
      : 'Fatto. I risultati non sono byte per byte identici fra i tre, ed e’ atteso: encoder diversi.',
    failures > 0 ? 'warn' : ''
  );
});

els.run.disabled = true;
loadCatalog();
