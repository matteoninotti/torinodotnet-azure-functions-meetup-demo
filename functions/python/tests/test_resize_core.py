"""Test dell'implementazione Python contro i casi di conformita' condivisi.

Gli stessi casi verranno letti dai test di .NET e Go: e' il meccanismo con cui
si verifica che i tre linguaggi siano davvero d'accordo sulla geometria
dell'output, invece di assumerlo.
"""

import json
import os

import pytest

import resize_core

CONFORMANCE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "..", "..", "shared", "conformance", "height_cases.json",
)

with open(CONFORMANCE, encoding="utf-8") as handle:
    HEIGHT_CASES = json.load(handle)["cases"]


@pytest.mark.parametrize("case", HEIGHT_CASES, ids=lambda c: f"{c['src_width']}x{c['src_height']}->{c['dst_width']}")
def test_target_height_matches_conformance(case):
    got = resize_core.target_height(case["src_width"], case["src_height"], case["dst_width"])
    assert got == case["expected"], case["why"]


@pytest.mark.parametrize("src_w,src_h", [(0, 100), (100, 0), (-1, 100)])
def test_target_height_rejects_degenerate_source(src_w, src_h):
    with pytest.raises(resize_core.InvalidParameter):
        resize_core.target_height(src_w, src_h, 800)


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
