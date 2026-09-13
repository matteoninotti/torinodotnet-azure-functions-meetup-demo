// Pannello dimostrativo: manda la STESSA richiesta ai tre worker e mostra i
// tre risultati affiancati.
//
// Non misura niente. I percentili li producono k6 e Application Insights; qui
// si vede solo che i tre backend rispondono allo stesso contratto e che le
// immagini che tornano sono equivalenti.

const BACKENDS = [
  { id: 'python', label: 'Python', host: 'torinodotnet-python.azurewebsites.net' },
  { id: 'dotnet', label: '.NET', host: 'torinodotnet-dotnet.azurewebsites.net' },
  { id: 'go', label: 'Go', host: 'torinodotnet-go.azurewebsites.net' },
];

const els = {
  form: document.getElementById('controls'),
  image: document.getElementById('image'),
  width: document.getElementById('width'),
  quality: document.getElementById('quality'),
  count: document.getElementById('count'),
  run: document.getElementById('run'),
  status: document.getElementById('status'),
  results: document.getElementById('results'),
};

const api = (backend, path) => `https://${backend.host}/api/${path}`;

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
    setStatus(
      'Nessuno dei tre backend ha risposto. Se la console mostra un errore CORS, ' +
        "l'origine di questa pagina non e' ancora nell'allowlist delle function app.",
      'error'
    );
    return;
  }

  // Solo le immagini presenti su TUTTI i backend raggiungibili finiscono nel
  // menu: offrirne una che un backend non ha significherebbe far scegliere
  // all'utente un 404 garantito.
  const names = reachable
    .map((r) => new Set(r.images.map((i) => i.name)))
    .reduce((shared, current) => new Set([...shared].filter((n) => current.has(n))));

  const divergent = reachable.filter((r) => r.images.length !== names.size);

  sourceBytes = new Map(reachable[0].images.map((i) => [i.name, i.bytes]));

  els.image.innerHTML = '';
  [...names].sort().forEach((name) => {
    const option = document.createElement('option');
    option.value = name;
    option.textContent = `${name} — ${formatBytes(sourceBytes.get(name))}`;
    els.image.append(option);
  });
  els.image.disabled = false;
  els.run.disabled = false;

  const warnings = [];
  if (unreachable.length) warnings.push(`non raggiungibili: ${unreachable.join(', ')}`);
  if (divergent.length) {
    warnings.push(
      `elenchi diversi fra i backend: ${divergent.map((d) => d.backend.label).join(', ')}`
    );
  }
  setStatus(
    warnings.length ? `⚠️ ${warnings.join(' · ')}` : `${names.size} immagini disponibili su tutti e tre.`,
    warnings.length ? 'warn' : ''
  );
}

// --- Esecuzione --------------------------------------------------------------

function buildQuery(params) {
  return new URLSearchParams(params).toString();
}

async function runOne(backend, params) {
  const base = { image: params.image, width: params.width, quality: params.quality };

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
  const blob = await imageResponse.blob();

  return { metrics, objectUrl: URL.createObjectURL(blob) };
}

function renderPending(backend) {
  const card = document.createElement('article');
  card.className = 'card pending';
  card.id = `card-${backend.id}`;
  card.innerHTML = `<h2>${backend.label}</h2><p class="muted">in corso… (a freddo puo' richiedere qualche secondo)</p>`;
  return card;
}

function renderResult(backend, { metrics, objectUrl }, params) {
  const card = document.getElementById(`card-${backend.id}`);
  const before = sourceBytes.get(params.image);
  const ratio = before ? `${((1 - metrics.output_bytes / before) * 100).toFixed(0)}% in meno` : '—';

  card.className = 'card';
  card.innerHTML = `
    <h2>${backend.label} <span class="runtime">${metrics.runtime}</span></h2>
    <img src="${objectUrl}" alt="Risultato del resize su ${backend.label}">
    <dl>
      <dt>Dimensioni</dt><dd>${metrics.width} × ${metrics.height}</dd>
      <dt>Peso</dt><dd>${formatBytes(before)} → ${formatBytes(metrics.output_bytes)} <span class="muted">(${ratio})</span></dd>
      <dt>Pipeline</dt><dd>${Math.round(metrics.total_ms).toLocaleString('it-IT')} ms <span class="muted">× ${metrics.count}</span></dd>
    </dl>
  `;
}

function renderError(backend, error) {
  const card = document.getElementById(`card-${backend.id}`);
  card.className = 'card failed';
  card.innerHTML = `<h2>${backend.label}</h2><p class="error">${error.message}</p>`;
}

els.form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const params = {
    image: els.image.value,
    width: els.width.value,
    quality: els.quality.value,
    count: els.count.value,
  };
  if (!params.image) return;

  els.run.disabled = true;
  setStatus('Richiesta inviata ai tre backend…');
  els.results.replaceChildren(...BACKENDS.map(renderPending));

  await Promise.all(
    BACKENDS.map(async (backend) => {
      try {
        renderResult(backend, await runOne(backend, params), params);
      } catch (error) {
        renderError(backend, error);
      }
    })
  );

  els.run.disabled = false;
  setStatus('Fatto. I tre risultati non sono byte per byte identici, ed e’ atteso: encoder diversi.');
});

els.run.disabled = true;
loadCatalog();
