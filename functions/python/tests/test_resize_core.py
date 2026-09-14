"""Test dell'implementazione Python contro i casi di conformita' condivisi.

Gli stessi casi verranno letti dai test di .NET e Go: e' il meccanismo con cui
si verifica che i tre linguaggi siano davvero d'accordo sulla geometria
dell'output, invece di assumerlo.
"""

import io
import json
import os

import pytest
from PIL import Image, JpegImagePlugin

import resize_core

CONFORMANCE_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "..", "..", "shared", "conformance",
)

with open(os.path.join(CONFORMANCE_DIR, "height_cases.json"), encoding="utf-8") as handle:
    HEIGHT_CASES = json.load(handle)["cases"]

with open(os.path.join(CONFORMANCE_DIR, "param_cases.json"), encoding="utf-8") as handle:
    PARAM_SPEC = json.load(handle)
PARAM_CASES = PARAM_SPEC["cases"]


def test_conformance_file_is_not_empty():
    """Se i casi condivisi si svuotassero, il test parametrizzato sotto
    sparirebbe senza fallire: zero casi eseguiti e suite verde.

    Lo stesso guardrail esiste gia' in .NET (ConformanceFileIsNotEmpty) e in Go
    (TestTargetHeightMatchesConformance): mancava solo qui, ed e' proprio il
    linguaggio da cui i casi sono nati.
    """
    assert len(HEIGHT_CASES) == 12


@pytest.mark.parametrize("case", HEIGHT_CASES, ids=lambda c: f"{c['src_width']}x{c['src_height']}->{c['dst_width']}")
def test_target_height_matches_conformance(case):
    got = resize_core.target_height(case["src_width"], case["src_height"], case["dst_width"])
    assert got == case["expected"], case["why"]


@pytest.mark.parametrize("src_w,src_h", [(0, 100), (100, 0), (-1, 100)])
def test_target_height_rejects_degenerate_source(src_w, src_h):
    with pytest.raises(resize_core.InvalidParameter):
        resize_core.target_height(src_w, src_h, 800)


# --- Parsing dei parametri: casi condivisi ----------------------------------


def test_param_conformance_file_is_not_empty():
    """Stesso guardrail di height_cases: se i casi si svuotassero, il test
    parametrizzato sotto sparirebbe senza fallire."""
    assert len(PARAM_CASES) == 16


def test_param_conformance_limits_match_the_worker():
    """I limiti scritti nel file devono essere quelli davvero applicati.

    Se qualcuno alzasse MAX_COUNT nel codice e non nel file, i casi continuerebbero
    a passare pur non descrivendo piu' il contratto vero — e i tre linguaggi
    potrebbero divergere senza che nessun test lo dica.
    """
    assert PARAM_SPEC["min"] == resize_core.MIN_COUNT
    assert PARAM_SPEC["max"] == resize_core.MAX_COUNT
    assert PARAM_SPEC["default"] == 1


@pytest.mark.parametrize("case", PARAM_CASES, ids=lambda c: repr(c["raw"]))
def test_parse_int_matches_conformance(case):
    raw, expected = case["raw"], case["expected"]
    call = lambda: resize_core._parse_int(
        raw, PARAM_SPEC["parameter"], PARAM_SPEC["default"], PARAM_SPEC["min"], PARAM_SPEC["max"]
    )
    if expected == "invalid":
        with pytest.raises(resize_core.InvalidParameter):
            call()
    elif expected == "default":
        assert call() == PARAM_SPEC["default"], case["why"]
    else:
        assert call() == expected, case["why"]


# --- Parsing dei parametri --------------------------------------------------


def _params(**overrides):
    values = {"image": None, "count": None, "width": None, "quality": None, "hash": None, "return": None}
    values.update(overrides)
    return values.get


def test_parse_params_requires_image():
    with pytest.raises(resize_core.InvalidParameter):
        resize_core.parse_params(_params())


def test_parse_params_unknown_image_is_not_found():
    with pytest.raises(resize_core.ImageNotFound):
        resize_core.parse_params(_params(image="non-esiste.jpg"))


@pytest.mark.parametrize(
    "field,value",
    [
        ("count", "0"),
        ("count", "abc"),
        ("width", "0"),
        ("quality", "0"),
        ("quality", "96"),  # Pillow documenta la scala 0-95: 96 e' fuori dal minimo comune denominatore
    ],
)
def test_parse_params_rejects_out_of_range(field, value):
    # Serve un'immagine valida perche' il controllo su image viene prima.
    images = resize_core.available_images()
    if not images:
        pytest.skip("nessuna immagine di test nel pacchetto (task aperto, Fase 1)")
    with pytest.raises(resize_core.InvalidParameter):
        resize_core.parse_params(_params(image=images[0], **{field: value}))


# --- Pipeline (richiede le immagini di test) --------------------------------

requires_images = pytest.mark.skipif(
    not resize_core.available_images(),
    reason="nessuna immagine di test nel pacchetto (task aperto, Fase 1)",
)


@requires_images
def test_pipeline_is_deterministic_within_python():
    """Stesso input, stessi parametri, stesso output byte per byte.

    E' quanto l'esperimento promette: determinismo INTERNO a ciascun
    linguaggio. Non promette che i tre producano lo stesso file.
    """
    params = resize_core.parse_params(_params(image=resize_core.available_images()[0], hash="1"))
    first = resize_core.run_pipeline(params)
    second = resize_core.run_pipeline(params)
    assert first.sha256 == second.sha256
    assert first.output_bytes == second.output_bytes


@requires_images
def test_pipeline_count_does_not_change_the_output():
    """count=N e' una manopola sul tempo, non sul risultato."""
    image = resize_core.available_images()[0]
    once = resize_core.run_pipeline(resize_core.parse_params(_params(image=image, hash="1")))
    thrice = resize_core.run_pipeline(resize_core.parse_params(_params(image=image, count="3", hash="1")))
    assert once.sha256 == thrice.sha256
    assert once.height == thrice.height


@requires_images
def test_pipeline_hash_is_off_by_default():
    params = resize_core.parse_params(_params(image=resize_core.available_images()[0]))
    assert resize_core.run_pipeline(params).sha256 is None


def _require_named_image(name):
    """Byte di un'immagine PRECISA, per i test che hanno bisogno di dimensioni note."""
    payload = resize_core.source_bytes(name)
    if payload is None:
        pytest.skip(f"{name} non e' in functions/python/images/: lanciare ./scripts/sync-images.sh python")
    return payload


def test_pipeline_height_follows_the_shared_formula():
    """La formula condivisa dev'essere quella davvero usata dalla pipeline.

    Non basta testarla in isolamento: un resize che ignorasse target_height
    passerebbe comunque i casi di conformita'. E non basta `height > 0`, che
    e' vero per qualunque resize — era l'asserzione dei gemelli .NET e Go, e
    il commento prometteva un controllo che l'asserzione non faceva.
    """
    name = "npm-install-7-years.jpg"
    source = _require_named_image(name)

    # Le dimensioni si leggono dal file con il decoder QUI nel test, non dal
    # codice sotto test: altrimenti si confronterebbe la pipeline con se stessa.
    with Image.open(io.BytesIO(source)) as original:
        src_w, src_h = original.size
    assert (src_w, src_h) == (1322, 1140), f"{name} non ha le dimensioni attese"

    expected_height = resize_core.target_height(src_w, src_h, 640)
    assert expected_height == 552

    result = resize_core.run_pipeline(resize_core.parse_params(_params(image=name, width="640")))
    assert (result.width, result.height) == (640, expected_height)
    assert result.output_bytes > 0

    # E il JPEG prodotto deve avere davvero quelle dimensioni. `height` nel
    # risultato e' il valore che la pipeline ha CALCOLATO: confrontarlo con la
    # formula sarebbe una tautologia. I pixel veri no.
    with Image.open(io.BytesIO(result.payload)) as produced:
        assert produced.size == (640, expected_height)


# --- Parametri dell'encoder (D8) --------------------------------------------


def _read_jpeg_encoding(data):
    """Marker SOF e fattori di campionamento della luma, letti dai byte.

    Si leggono dall'output e non dalla configurazione dell'encoder: la
    configurazione dice cosa abbiamo chiesto, i byte dicono cosa e' uscito. Per
    Pillow la differenza non e' teorica — la documentazione dichiara che senza
    `subsampling` esplicito "the setting will be determined by libjpeg or
    libjpeg-turbo", cioe' dipende dalla build installata.

    Struttura di un segmento SOF: lunghezza (2 byte), precisione (1), altezza
    (2), larghezza (2), numero di componenti (1), poi per ogni componente id
    (1), fattori di campionamento impacchettati in un byte (1) e tabella di
    quantizzazione (1). Per la Y, 0x22 significa h=2 v=2, cioe' 4:2:0.
    """
    assert data[:2] == b"\xff\xd8", "il payload non comincia con il marker SOI"
    i = 2
    while i + 3 < len(data):
        assert data[i] == 0xFF, f"segmento malformato all'offset {i}"
        marker = data[i + 1]
        length = (data[i + 2] << 8) | data[i + 3]
        # SOF0 = baseline, SOF1 = extended sequential, SOF2 = progressive.
        # Gli altri FF Cx sono DHT (C4), RSTn, DAC (CC): non sono SOF.
        if marker in (0xC0, 0xC1, 0xC2):
            return marker, data[i + 2 + 2 + 1 + 4 + 1 + 1]
        i += 2 + length
    raise AssertionError("nessun marker SOF trovato nel JPEG prodotto")


@requires_images
def test_pipeline_output_is_baseline_420():
    """I tre worker devono produrre lo STESSO formato di JPEG.

    Il minimo comune denominatore lo impone la stdlib Go, che sa fare solo
    "4:2:0 baseline" (D8). Fino a ora era verificato a mano; il README pero'
    promette che la simmetria e' verificata invece che sperata.
    """
    result = resize_core.run_pipeline(
        resize_core.parse_params(_params(image=resize_core.available_images()[0]))
    )
    sof, luma_sampling = _read_jpeg_encoding(result.payload)
    assert sof == 0xC0, f"atteso SOF0 (baseline), ottenuto 0x{sof:02X}"
    assert luma_sampling == 0x22, f"atteso 4:2:0 (0x22), ottenuto 0x{luma_sampling:02X}"

    # Seconda lettura con l'API di Pillow, che dice la stessa cosa in una forma
    # piu' leggibile: (2, 2, 1, 1, 1, 1) e' 4:2:0.
    with Image.open(io.BytesIO(result.payload)) as produced:
        assert JpegImagePlugin.get_sampling(produced) == 2  # 2 = 4:2:0
        assert not produced.info.get("progressive")


@requires_images
def test_pipeline_output_honours_the_quality_parameter():
    """Qualita' piu' bassa deve produrre meno byte.

    La qualita' non si legge dai marker senza reimplementare le tabelle di
    quantizzazione, ma un effetto osservabile ce l'ha.
    """
    image = resize_core.available_images()[0]
    small = resize_core.run_pipeline(
        resize_core.parse_params(_params(image=image, quality="20"))
    ).output_bytes
    large = resize_core.run_pipeline(
        resize_core.parse_params(_params(image=image, quality="95"))
    ).output_bytes
    assert small < large, f"qualita' 20 ha prodotto {small} byte, qualita' 95 ne ha prodotti {large}"


# --- Catalogo per il selettore del frontend ---------------------------------


def test_image_catalog_is_consistent_with_available_images():
    """I nomi del catalogo devono essere esattamente quelli accettati da ?image=.

    E' il contratto su cui si regge il selettore della SWA: se divergessero,
    il frontend offrirebbe scelte che l'endpoint di resize rifiuta con 404.
    """
    catalog = resize_core.image_catalog()
    assert [entry["name"] for entry in catalog] == resize_core.available_images()


@requires_images
def test_image_catalog_reports_real_byte_sizes():
    for entry in resize_core.image_catalog():
        assert entry["bytes"] > 0


@requires_images
def test_source_bytes_matches_the_catalog_size():
    """I byte serviti dalla demo devono essere gli stessi che il catalogo conta.

    Se divergessero, la pagina mostrerebbe come "originale" qualcosa di diverso
    da cio' che la pipeline ha davvero ricevuto in ingresso, e il confronto
    prima/dopo direbbe una cosa falsa.
    """
    for entry in resize_core.image_catalog():
        payload = resize_core.source_bytes(entry["name"])
        assert payload is not None
        assert len(payload) == entry["bytes"]
        # Un JPEG comincia sempre con il marker SOI: conferma che stiamo
        # servendo il file grezzo e non una ricodifica.
        assert payload[:2] == b"\xff\xd8"


def test_source_bytes_unknown_image_is_none():
    assert resize_core.source_bytes("non-esiste.jpg") is None
