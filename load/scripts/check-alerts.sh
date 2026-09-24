#!/usr/bin/env bash
#
# Elenca gli alert di Azure Monitor scattati sul resource group a partire da
# un istante, interrogandoli invece di aspettare una notifica.
#
#   ./load/scripts/check-alerts.sh 2026-09-24T12:00:00Z
#
# Su questa sottoscrizione le regole scattano ma le mail dell'action group non
# arrivano: l'alert esiste, la notifica no. Questo script e' il modo di
# saperlo.
#
# Esce:
#   0  nessun alert scattato dopo l'istante dato
#   1  almeno un alert scattato: li elenca
#   2  la domanda non ha avuto risposta (az fallito, risposta illeggibile).
#      Non e' "nessun alert": un errore non deve mai sembrare un silenzio.
#
# L'istante di partenza e' la fine dell'ultima campagna di misura: i run di
# carico fanno scattare le regole di consumo per costruzione, quindi un alert
# che parte dopo quel momento e' traffico non nostro. L'API guarda al massimo
# gli ultimi 30 giorni.

set -euo pipefail

SINCE="${1:-}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-torinodotnet-demo}"
TS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
[[ "$SINCE" =~ $TS_RE ]] || { echo "uso: $0 <istante UTC, es. 2026-09-24T12:00:00Z>" >&2; exit 2; }

AZ_ERR=$(mktemp)
OUT=$(mktemp)
trap 'rm -f "$AZ_ERR" "$OUT"' EXIT

SUB=$(az account show --query id -o tsv 2>"$AZ_ERR") \
  || { echo "sottoscrizione non leggibile: $(cat "$AZ_ERR")" >&2; exit 2; }

url="https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&timeRange=30d&targetResourceGroup=${RESOURCE_GROUP}"
: >"$OUT"
# Le risposte possono essere paginate: si segue nextLink fino in fondo.
while [ -n "$url" ]; do
  page=$(az rest --method get --url "$url" -o json 2>"$AZ_ERR") \
    || { echo "interrogazione degli alert fallita: $(cat "$AZ_ERR")" >&2; exit 2; }
  # Una pagina per riga, compattata: il parser sotto legge riga per riga.
  printf '%s' "$page" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)))" >>"$OUT" \
    || { echo "risposta degli alert illeggibile" >&2; exit 2; }
  url=$(printf '%s' "$page" | python3 -c "import sys,json; print(json.load(sys.stdin).get('nextLink') or '')") \
    || { echo "risposta degli alert illeggibile" >&2; exit 2; }
done

# Il codice di uscita 1 vuol dire "alert trovati": un errore del parser non
# deve poterlo produrre. Qualunque eccezione esce con 2.
python3 - "$OUT" "$SINCE" <<'EOF'
import json, sys, traceback
sys.excepthook = lambda *exc: (traceback.print_exception(*exc), sys.exit(2))
from datetime import datetime, timezone

path, since = sys.argv[1], sys.argv[2]
since_dt = datetime.strptime(since, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)

def parse(ts):
    # Frazioni di secondo con 7 cifre: si tagliano a 6 per fromisoformat.
    ts = ts.rstrip("Z")
    if "." in ts:
        head, frac = ts.split(".", 1)
        ts = head + "." + frac[:6]
    return datetime.fromisoformat(ts).replace(tzinfo=timezone.utc)

alerts = []
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        for a in json.loads(line).get("value", []):
            e = a["properties"]["essentials"]
            start = parse(e["startDateTime"])
            if start >= since_dt:
                alerts.append((start, e))

if not alerts:
    print(f"NESSUN ALERT scattato dopo {since}.")
    sys.exit(0)

print(f"ALERT SCATTATI dopo {since}: {len(alerts)}")
for start, e in sorted(alerts, key=lambda x: x[0]):
    rule = e.get("alertRule", "").rsplit("/", 1)[-1]
    print(f"  {start:%Y-%m-%dT%H:%M:%SZ}  {rule:40} {e.get('targetResourceName', ''):22} "
          f"{e.get('monitorCondition', '')}")
sys.exit(1)
EOF
