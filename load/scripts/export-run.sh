#!/usr/bin/env bash
#
# Esporta su file le righe grezze di un run e verifica che la finestra
# contenga esattamente le richieste del run, e nient'altro.
#
#   ./load/scripts/export-run.sh <etichetta> <win_start> <win_end> <richieste_attese>
#   ./load/scripts/export-run.sh m1-go-r1 2026-09-26T10:00:00Z 2026-09-26T10:02:10Z 600
#
# <win_start> e <win_end> sono RUN_START e RUN_END stampati da k6, in UTC.
# <richieste_attese> viene da una fonte che non e' la telemetria: `http_reqs`
# del riepilogo di k6 per le Metriche 1 e 3, `1` per le Metriche 2 e 4.
#
# Scrive in load/output/<etichetta>/:
#   requests.json   tutte le righe di AppRequests dei tre worker nella finestra
#   traces.json     tutte le righe di AppTraces dei tre worker nella finestra
#
# Perche' le righe grezze e non i riepiloghi: la telemetria vive quanto la
# ritenzione del workspace Log Analytics (30 giorni, infra/main.bicep), non
# quanto quella dichiarata su Application Insights. Un riepilogo salva le
# domande che si sono gia' fatte; le righe salvano anche quelle che verranno.
#
# Esce 0 solo se:
#   - le richieste nella finestra, su tutte e tre le app, sono esattamente
#     <richieste_attese> e sono tutte `resize`. Per le Metriche 2 e 4 e' il
#     controllo "nessun altro traffico": una richiesta estranea (anche un
#     /api/health da una pagina del frontend rimasta aperta) la fa fallire,
#     mentre "c'e' almeno una resize" sarebbe verde anche in quel caso.
#   - il numero di righe scritte in ciascun file coincide con il count() della
#     stessa finestra. Un file vuoto o troncato non basta a far passare niente.
#
# L'ingestion ritarda di 2-4 minuti: un conteggio basso appena finito il run
# si rilancia dopo qualche minuto, non si corregge a mano.

set -euo pipefail

LABEL="${1:-}"
WIN_START="${2:-}"
WIN_END="${3:-}"
EXPECTED="${4:-}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-torinodotnet-demo}"
WORKSPACE_NAME="${WORKSPACE_NAME:-torinodotnet-logs}"

usage() { echo "uso: $0 <etichetta> <win_start> <win_end> <richieste_attese>" >&2; exit 2; }
[ -n "$LABEL" ] && [ -n "$WIN_START" ] && [ -n "$WIN_END" ] && [ -n "$EXPECTED" ] || usage
[[ "$LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "etichetta non valida: ${LABEL}" >&2; exit 2; }
# Le due date finiscono dentro una query KQL: solo il formato che k6 stampa.
TS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$'
[[ "$WIN_START" =~ $TS_RE ]] && [[ "$WIN_END" =~ $TS_RE ]] || { echo "date attese in UTC, es. 2026-09-26T10:00:00Z" >&2; exit 2; }
[[ "$EXPECTED" =~ ^[0-9]+$ ]] && [ "$EXPECTED" -gt 0 ] || { echo "richieste_attese deve essere un intero > 0" >&2; exit 2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="$REPO_ROOT/load/output/$LABEL"
mkdir -p "$OUT_DIR"

AZ_ERR=$(mktemp)
trap 'rm -f "$AZ_ERR"' EXIT

WS=$(az monitor log-analytics workspace show --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$WORKSPACE_NAME" --query customerId -o tsv 2>"$AZ_ERR") \
  || { echo "workspace non trovato: $(cat "$AZ_ERR")" >&2; exit 1; }

WINDOW="TimeGenerated between (datetime(${WIN_START}) .. datetime(${WIN_END})) and AppRoleName startswith 'torinodotnet-'"
# Le tracce: quelle della finestra, piu' quelle scritte fino a 5 minuti dopo
# da un'operazione cominciata DENTRO la finestra. L'orologio del server e'
# avanti rispetto a quello che stampa RUN_END (~52 ms, sntp, 2026-09-24): la
# traccia dell'ultima richiesta cadeva oltre win_end e mancava dall'export.
TRACES="AppTraces | where ${WINDOW} or (TimeGenerated between (datetime(${WIN_END}) .. datetime(${WIN_END}) + 5m) and OperationId in ((AppRequests | where ${WINDOW} | distinct OperationId)))"

query() {
  az monitor log-analytics query --workspace "$WS" --analytics-query "$1" -o json 2>"$AZ_ERR" \
    || { echo "query fallita: $(cat "$AZ_ERR")" >&2; exit 1; }
}

query "AppRequests | where ${WINDOW} | order by TimeGenerated asc" >"$OUT_DIR/requests.json"
query "${TRACES} | order by TimeGenerated asc" >"$OUT_DIR/traces.json"
counts=$(query "union (AppRequests | where ${WINDOW} | summarize n=count() | extend t='requests'), (${TRACES} | summarize n=count() | extend t='traces')")

python3 - "$OUT_DIR" "$EXPECTED" "$counts" <<'EOF'
import collections, json, sys

out_dir, expected, counts = sys.argv[1], int(sys.argv[2]), json.loads(sys.argv[3])
expected_rows = {c["t"]: int(c["n"]) for c in counts}
failed = False

for name in ("requests", "traces"):
    rows = json.load(open(f"{out_dir}/{name}.json"))
    print(f"{name}.json: {len(rows)} righe, count() della finestra: {expected_rows.get(name)}")
    if len(rows) != expected_rows.get(name):
        print(f"  ERRORE: il file non contiene tutte le righe della finestra", file=sys.stderr)
        failed = True

requests = json.load(open(f"{out_dir}/requests.json"))
by_app_name = collections.Counter((r["AppRoleName"], r["Name"]) for r in requests)
for (app, name), n in sorted(by_app_name.items()):
    print(f"  {app:22} {name:8} {n}")

resize = sum(n for (_, name), n in by_app_name.items() if name == "resize")
others = sum(n for (_, name), n in by_app_name.items() if name != "resize")
if others:
    print(f"ERRORE: {others} richieste non-resize nella finestra: la finestra non e' pulita", file=sys.stderr)
    failed = True
if resize != expected:
    print(f"ERRORE: {resize} richieste resize nella finestra, attese {expected}"
          + (" (ingestion in ritardo? rilanciare fra qualche minuto)" if resize < expected else ""),
          file=sys.stderr)
    failed = True

if failed:
    sys.exit(1)
print(f"EXPORT OK: {resize} richieste resize su {expected} attese, nessun altro traffico, file completi.")
EOF
