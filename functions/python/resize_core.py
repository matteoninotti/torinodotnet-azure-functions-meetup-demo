"""Pipeline di resize e strumentazione delle misure.

Questo modulo contiene tutto il lavoro CPU-bound che l'esperimento misura.
Le sue scelte non sono idiomatiche per caso: ognuna corrisponde a una
decisione del log, e cambiarne una qui senza cambiarla anche in .NET e Go
rompe la simmetria su cui poggia l'intero confronto.

Gli import pesanti stanno a livello di modulo di proposito: finiscono nella
fase di app init, che secondo la Metrica 4 potrebbe non essere fatturata.
Spostarli dentro l'handler cambierebbe il risultato di quell'esperimento.
"""

import hashlib
import io
import os
import time
from typing import NamedTuple, Optional

from PIL import Image

# --- Parametri fissati dall'esperimento -------------------------------------

DEFAULT_WIDTH = 800
DEFAULT_QUALITY = 80

# Pillow accetta 0 (4:4:4), 1 (4:2:2), 2 (4:2:0). Va passato esplicitamente:
# la documentazione dichiara che senza questo parametro "the setting will be
# determined by libjpeg or libjpeg-turbo", cioe' non e' deterministico.
# 4:2:0 e' il minimo comune denominatore, imposto dalla stdlib Go che non
# sa fare altro (D8).
JPEG_SUBSAMPLING = 2

# Pillow documenta la qualita' su scala 0-95, non 0-100: e' il tetto piu'
# basso dei tre linguaggi, quindi e' quello che vale per tutti (D8).
MIN_QUALITY = 1
MAX_QUALITY = 95

MIN_WIDTH = 1
MAX_WIDTH = 10_000
MIN_COUNT = 1
MAX_COUNT = 10_000

IMAGES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "images")
_IMAGE_SUFFIXES = (".jpg", ".jpeg")


# --- Errori -----------------------------------------------------------------


class InvalidParameter(ValueError):
    """Parametro di query malformato o fuori intervallo."""


class ImageNotFound(LookupError):
    """L'immagine richiesta non e' nel pacchetto di deploy."""


# --- Caricamento delle immagini (app init, non fatturato se D-Metrica4 regge)


def _load_images() -> dict:
    """Carica i file di test come byte JPEG grezzi, senza decodificarli.

    La decodifica resta dentro il percorso misurato di ogni richiesta (D3):
    e' li' che vive l'asimmetria tra libjpeg-turbo, ImageSharp e la stdlib Go,
    ed e' la cosa piu' interessante da confrontare.
    """
    if not os.path.isdir(IMAGES_DIR):
        return {}
    images = {}
    for name in sorted(os.listdir(IMAGES_DIR)):
        if name.lower().endswith(_IMAGE_SUFFIXES):
            with open(os.path.join(IMAGES_DIR, name), "rb") as handle:
                images[name] = handle.read()
    return images


_IMAGES = _load_images()


def available_images() -> list:
    return sorted(_IMAGES.keys())


# --- Geometria --------------------------------------------------------------


def target_height(src_width: int, src_height: int, dst_width: int) -> int:
    """Altezza proporzionale, in aritmetica intera.

    Deliberatamente NON usa round(): l'arrotondamento di libreria non e' la
    stessa operazione nei tre linguaggi (Python e C# arrotondano 0.5 al pari,
    Go per eccesso in valore assoluto), e su un caso limite darebbero altezze
    diverse. Questa espressione e' half-up esatto e va replicata carattere per
    carattere in Go e C#, inclusa la divisione intera di src_width (D7).

    I casi attesi sono fissati in shared/conformance/height_cases.json, che i
    test dei tre linguaggi leggono per verificare di essere d'accordo.
    """
    if src_width <= 0 or src_height <= 0:
        raise InvalidParameter("dimensioni sorgente non valide")
    return max(1, (src_height * dst_width + src_width // 2) // src_width)


# --- Validazione dei parametri ----------------------------------------------


def _parse_int(raw: Optional[str], name: str, default: int, lo: int, hi: int) -> int:
    if raw is None or raw == "":
        return default
    try:
        value = int(raw)
    except ValueError:
        raise InvalidParameter(f"{name} deve essere un intero, ricevuto {raw!r}")
    if not lo <= value <= hi:
        raise InvalidParameter(f"{name} deve stare tra {lo} e {hi}, ricevuto {value}")
    return value


class Params(NamedTuple):
    image: str
    count: int
    width: int
    quality: int
    want_hash: bool
    return_image: bool


def parse_params(get) -> Params:
    """Legge i parametri dalla query string. `get` e' una funzione nome -> valore."""
    image = get("image")
    if not image:
        available = ", ".join(available_images()) or "nessuna"
        raise InvalidParameter(f"parametro 'image' obbligatorio. Disponibili: {available}")
    if image not in _IMAGES:
        available = ", ".join(available_images()) or "nessuna"
        raise ImageNotFound(f"immagine {image!r} non trovata. Disponibili: {available}")
    return Params(
        image=image,
        count=_parse_int(get("count"), "count", 1, MIN_COUNT, MAX_COUNT),
        width=_parse_int(get("width"), "width", DEFAULT_WIDTH, MIN_WIDTH, MAX_WIDTH),
        quality=_parse_int(get("quality"), "quality", DEFAULT_QUALITY, MIN_QUALITY, MAX_QUALITY),
        want_hash=get("hash") == "1",
        return_image=get("return") == "image",
    )


# --- Pipeline ---------------------------------------------------------------


class PipelineResult(NamedTuple):
    width: int
    height: int
    output_bytes: int
    decode_ms: float
    resize_ms: float
    encode_ms: float
    total_ms: float
    payload: bytes
    sha256: Optional[str]


def run_pipeline(params: Params) -> PipelineResult:
    """Esegue decode -> resize -> encode `count` volte sulla stessa immagine.

    Sempre la stessa immagine, mai a rotazione: ruotare introdurrebbe varianza
    nel carico a seconda di come cade N sul ciclo, che e' rumore gratuito in un
    esperimento il cui unico scopo e' confrontare durate (D4).

    I tre sotto-tempi servono a vedere *dove* va il tempo in ciascun linguaggio,
    non solo quanto ne va: e' li' che si legge l'effetto dei tre livelli di
    ottimizzazione (D6).
    """
    raw = _IMAGES[params.image]
    decode_ns = 0
    resize_ns = 0
    encode_ns = 0
    payload = b""
    height = 0

    for _ in range(params.count):
        t0 = time.perf_counter_ns()
        source = Image.open(io.BytesIO(raw))
        source.load()  # Image.open e' lazy: senza load() il decode slitterebbe
        if source.mode != "RGB":
            source = source.convert("RGB")
        height = target_height(source.width, source.height, params.width)
        t1 = time.perf_counter_ns()

        resized = source.resize((params.width, height), resample=Image.Resampling.BILINEAR)
        t2 = time.perf_counter_ns()

        buffer = io.BytesIO()
        resized.save(
            buffer,
            format="JPEG",
            quality=params.quality,
            subsampling=JPEG_SUBSAMPLING,
            progressive=False,
            optimize=False,
        )
        t3 = time.perf_counter_ns()

        decode_ns += t1 - t0
        resize_ns += t2 - t1
        encode_ns += t3 - t2
        payload = buffer.getvalue()

    # L'hash sta fuori dai cronometri ed e' spento di default: SHA-256 e'
    # accelerato in hardware su .NET e Go ma non in Python, quindi tenerlo
    # acceso durante le misure infilerebbe nel confronto una differenza di
    # velocita' che non c'entra nulla con l'image processing (D5).
    digest = hashlib.sha256(payload).hexdigest() if params.want_hash else None

    return PipelineResult(
        width=params.width,
        height=height,
        output_bytes=len(payload),
        decode_ms=decode_ns / 1_000_000,
        resize_ms=resize_ns / 1_000_000,
        encode_ms=encode_ns / 1_000_000,
        total_ms=(decode_ns + resize_ns + encode_ns) / 1_000_000,
        payload=payload,
        sha256=digest,
    )
