"""HTTP trigger dell'endpoint di resize — implementazione Python.

Contratto (identico nei tre linguaggi):

    POST /api/resize?image=<nome>&count=<N>&width=<px>&quality=<1-95>[&hash=1][&return=image]

La risposta di default e' JSON. `return=image` restituisce il JPEG per la demo
visiva e non va mai usato durante i run di misura: aggiungerebbe alla latenza
la banda di download dell'immagine, che e' esattamente il rumore che la forma
`?image=` dell'endpoint serve a eliminare.
"""

import json
import logging
import platform

import azure.functions as func

import resize_core

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

LANGUAGE = "python"
RUNTIME = platform.python_version()

# Prefisso su cui si aggancia la query di Log Analytics. Un'unica riga di log
# con un payload JSON stabile, invece delle customDimensions: funziona allo
# stesso modo nei tre worker e non dipende da come ciascuno inoltra i campi
# strutturati. Vedi il residuo su D6 nel log.
METRICS_PREFIX = "RESIZE_METRICS"


def _error(status: int, message: str) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps({"error": message}),
        status_code=status,
        mimetype="application/json",
    )


@app.route(route="resize", methods=["POST"])
def resize(req: func.HttpRequest) -> func.HttpResponse:
    try:
        params = resize_core.parse_params(req.params.get)
    except resize_core.ImageNotFound as exc:
        return _error(404, str(exc))
    except resize_core.InvalidParameter as exc:
        return _error(400, str(exc))

    result = resize_core.run_pipeline(params)

    metrics = {
        "language": LANGUAGE,
        "image": params.image,
        "count": params.count,
        "width": result.width,
        "height": result.height,
        "quality": params.quality,
        "output_bytes": result.output_bytes,
        "total_ms": round(result.total_ms, 3),
    }
    logging.info("%s %s", METRICS_PREFIX, json.dumps(metrics, separators=(",", ":")))

    if params.return_image:
        return func.HttpResponse(result.payload, status_code=200, mimetype="image/jpeg")

    body = dict(metrics)
    body["runtime"] = RUNTIME
    body["sha256"] = result.sha256
    return func.HttpResponse(json.dumps(body), status_code=200, mimetype="application/json")


@app.route(route="health", methods=["GET"])
def health(req: func.HttpRequest) -> func.HttpResponse:
    """Diagnostica: conferma quali immagini l'istanza ha caricato all'avvio.

    Non fa parte dell'esperimento — serve a scoprire dal browser che il
    pacchetto di deploy e' arrivato completo, senza dover leggere i log.

    NON e' la fonte dati del frontend: per quello c'e' /api/images. La
    sovrapposizione nel payload e' voluta, i due endpoint hanno consumatori e
    contratti diversi e devono poter evolvere separatamente.
    """
    body = {
        "language": LANGUAGE,
        "runtime": RUNTIME,
        "images": resize_core.available_images(),
    }
    return func.HttpResponse(json.dumps(body), status_code=200, mimetype="application/json")


@app.route(route="images", methods=["GET"])
def images(req: func.HttpRequest) -> func.HttpResponse:
    """Elenco delle immagini selezionabili: contratto per il selettore della SWA.

    Esiste perche' il frontend possa popolarsi da solo invece di avere i nomi
    dei file cablati dentro: cambiando il pool con un redeploy, il selettore si
    aggiorna senza che nessuno lo tocchi. I nomi restituiti qui sono gli stessi
    che `POST /api/resize` accetta come `?image=`.
    """
    body = {"images": resize_core.image_catalog()}
    return func.HttpResponse(json.dumps(body), status_code=200, mimetype="application/json")
