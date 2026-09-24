#!/usr/bin/env bash
#
# Lettura di una serie di cold-start.sh: Metrica 2 per tutti i linguaggi,
# Metrica 4 sulle richieste Python.
#
#   ./load/scripts/cold-start-report.sh <serie>
#
# Da lanciare almeno 5 minuti dopo l'ultima richiesta: l'ingestion della
# telemetria ritarda di 2-4 minuti, e OnDemandFunctionExecutionUnits di 1-2
# minuti, spalmandosi su piu' minuti (D60).
#
# Per ogni richiesta di load/output/<serie>/requests.tsv:
#   1. export-run.sh <label> <t_send> <t_recv> 1: righe grezze salvate, e la
#      finestra deve contenere quella sola richiesta e nient'altro (I7);
#   2. durata server-side D dalla riga di AppRequests esportata;
#   3. cold start stimato = tempo client netto - D (D126 punto 5).
# Solo per Python (Metrica 4, D126 punto 3): somma di
# OnDemandFunctionExecutionUnits dal minuto della richiesta per 6 minuti, o
# fino al minuto prima della richiesta Python successiva se arriva prima; la
# somma vale solo se gli ultimi due minuti della finestra sono a zero, cioe'
# se la coda e' finita dentro la finestra.
#
# Scrive load/output/<serie>/report.tsv e stampa il riepilogo per linguaggio.
# Esce 1 se una qualunque finestra non e' pulita o una somma non e' chiusa.

set -euo pipefail

SERIES="${1:-}"
[[ "$SERIES" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "uso: $0 <serie>" >&2; exit 2; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$REPO_ROOT/load/output/$SERIES"
TSV="$OUT_DIR/requests.tsv"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-torinodotnet-demo}"
[ -f "$TSV" ] || { echo "manca ${TSV}" >&2; exit 2; }

AZ_ERR=$(mktemp)
UNITS="$OUT_DIR/units-python.json"
trap 'rm -f "$AZ_ERR"' EXIT

failed=0
while IFS=$'\t' read -r label lang round t_send t_recv _; do
  if [ -f "$REPO_ROOT/load/output/$label/requests.json" ] && [ -f "$REPO_ROOT/load/output/$label/export.ok" ]; then
    continue
  fi
  if "$SCRIPT_DIR/export-run.sh" "$label" "$t_send" "$t_recv" 1 >"$REPO_ROOT/load/output/$label.export.log" 2>&1; then
    touch "$REPO_ROOT/load/output/$label/export.ok"
  else
    echo "${label}: export-run FALLITO:" >&2
    sed 's/^/  /' "$REPO_ROOT/load/output/$label.export.log" >&2
    failed=1
  fi
done < <(tail -n +2 "$TSV")
[ "$failed" -eq 0 ] || { echo "REPORT INTERROTTO: almeno una finestra non e' pulita." >&2; exit 1; }

# Avvio dell'host di ogni istanza che ha servito una richiesta della serie.
# Una ripetizione vale come cold start solo se il suo host e' partito CON la
# richiesta: Python avvia a volte host senza nessuna richiesta (D132), e una
# richiesta finita su uno di quelli misurerebbe un cold start che non c'e'
# stato.
first_send=$(tail -n +2 "$TSV" | cut -f4 | sort | head -n 1)
last_recv=$(tail -n +2 "$TSV" | cut -f5 | sort | tail -n 1)
WS=$(az monitor log-analytics workspace show -g "$RESOURCE_GROUP" -n torinodotnet-logs --query customerId -o tsv 2>"$AZ_ERR") \
  || { echo "workspace non trovato: $(cat "$AZ_ERR")" >&2; exit 1; }
az monitor log-analytics query --workspace "$WS" -o json --analytics-query "
  AppTraces
  | where TimeGenerated between (datetime(${first_send}) - 30m .. datetime(${last_recv}))
  | where Message startswith 'Initializing Warmup Extension'
  | summarize host_start = min(TimeGenerated) by AppRoleInstance" >"$OUT_DIR/host-starts.json" 2>"$AZ_ERR" \
  || { echo "avvii degli host non leggibili: $(cat "$AZ_ERR")" >&2; exit 1; }

# Unita' fatturate di Python, al minuto, su tutta la serie piu' 10 minuti.
if tail -n +2 "$TSV" | cut -f2 | grep -qx python; then
  first=$(tail -n +2 "$TSV" | awk -F'\t' '$2=="python"{print $4}' | sort | head -n 1)
  last=$(tail -n +2 "$TSV" | awk -F'\t' '$2=="python"{print $4}' | sort | tail -n 1)
  start=$(python3 -c "import sys,datetime as d;t=d.datetime.strptime(sys.argv[1][:16],'%Y-%m-%dT%H:%M');print((t-d.timedelta(minutes=2)).strftime('%Y-%m-%dT%H:%M:00Z'))" "$first")
  end=$(python3 -c "import sys,datetime as d;t=d.datetime.strptime(sys.argv[1][:16],'%Y-%m-%dT%H:%M');print((t+d.timedelta(minutes=10)).strftime('%Y-%m-%dT%H:%M:00Z'))" "$last")
  app_id=$(az functionapp show -g "$RESOURCE_GROUP" -n torinodotnet-python --query id -o tsv 2>"$AZ_ERR") \
    || { echo "app python non trovata: $(cat "$AZ_ERR")" >&2; exit 1; }
  az monitor metrics list --resource "$app_id" --metric OnDemandFunctionExecutionUnits OnDemandFunctionExecutionCount \
    --aggregation Total --interval PT1M --start-time "$start" --end-time "$end" -o json >"$UNITS" 2>"$AZ_ERR" \
    || { echo "metriche non leggibili: $(cat "$AZ_ERR")" >&2; exit 1; }
fi

python3 - "$REPO_ROOT" "$TSV" "$UNITS" "$OUT_DIR/report.tsv" "$OUT_DIR/host-starts.json" <<'EOF'
import datetime as dt, json, math, os, sys

repo, tsv, units_path, report_path, starts_path = sys.argv[1:6]
host_start = {x["AppRoleInstance"]: x["host_start"] for x in json.load(open(starts_path))}
# Oltre questo anticipo l'host esisteva gia' quando e' arrivata la richiesta.
PREEXISTING_S = 5.0
rows = [dict(zip(open(tsv).readline().rstrip("\n").split("\t"), l.rstrip("\n").split("\t")))
        for l in open(tsv).readlines()[1:]]

def ts(s):
    return dt.datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S")

units = {}
counts = {}
if os.path.exists(units_path):
    for v in json.load(open(units_path))["value"]:
        target = units if v["name"]["value"] == "OnDemandFunctionExecutionUnits" else counts
        for p in v["timeseries"][0]["data"] if v["timeseries"] else []:
            target[ts(p["timeStamp"])] = p.get("total") or 0.0

def ceil100(ms):
    return math.ceil(ms / 100.0) * 100

python_sends = sorted(ts(r["t_send"]) for r in rows if r["language"] == "python")
out, bad = [], False
for r in rows:
    req = json.load(open(f"{repo}/load/output/{r['label']}/requests.json"))
    resize = [x for x in req if x["Name"] == "resize"]
    assert len(resize) == 1, r["label"]
    D = float(resize[0]["DurationMs"])
    inst = resize[0]["AppRoleInstance"]
    hs = host_start.get(inst)
    host_lead_s = (ts(resize[0]["TimeGenerated"]) - ts(hs)).total_seconds() if hs else None
    cold = host_lead_s is not None and host_lead_s <= PREEXISTING_S
    net = (float(r["time_total"]) - float(r["time_appconnect"])) * 1000
    total = float(r["time_total"]) * 1000
    rec = dict(label=r["label"], language=r["language"], round=r["round"], t_send=r["t_send"],
               result=resize[0]["ResultCode"], instance=resize[0]["AppRoleInstance"],
               client_total_ms=round(total, 1), client_net_ms=round(net, 1), server_ms=round(D, 1),
               cold_est_ms=round(net - D, 1), pipeline_ms=r["total_ms"],
               host_lead_s=host_lead_s, cold_start=cold,
               units_mbms="", billed_ms="", h0_ms="", h1_ms="", units_window="")
    if r["language"] == "python" and units:
        t0 = ts(r["t_send"]).replace(second=0)
        nxt = [t for t in python_sends if t > ts(r["t_send"])]
        t_end = t0 + dt.timedelta(minutes=6)
        if nxt:
            t_end = min(t_end, nxt[0].replace(second=0) - dt.timedelta(minutes=1))
        minutes = [t0 + dt.timedelta(minutes=i) for i in range(int((t_end - t0).total_seconds() // 60) + 1)]
        vals = [units.get(m, 0.0) for m in minutes]
        s = sum(vals)
        # Chiusa vuol dire: la coda e' tornata a zero DENTRO la finestra, la
        # finestra e' finita da almeno 3 minuti (la metrica ritarda, D60), e la
        # somma non e' zero. Una somma a zero su una richiesta servita non e' un
        # dato, e' la metrica che non e' ancora arrivata: letta cosi' dava
        # "0 ms fatturati" su una richiesta di 2,1 s.
        settled = dt.datetime.utcnow() - (t_end + dt.timedelta(minutes=1)) >= dt.timedelta(minutes=3)
        closed = len(vals) >= 4 and vals[-1] == 0 and vals[-2] == 0 and settled and s > 0
        rec.update(units_mbms=int(s), billed_ms=round(s / 2048, 1),
                   h0_ms=ceil100(max(1000, D)), h1_ms=ceil100(max(1000, net)),
                   units_window=f"{t0:%H:%M}-{t_end:%H:%M}" + ("" if closed else (" IN ATTESA" if not settled else " APERTA")))
        if not closed:
            bad = True
    out.append(rec)

cols = list(out[0].keys())
with open(report_path, "w") as f:
    f.write("\t".join(cols) + "\n")
    for rec in out:
        f.write("\t".join(str(rec[c]) for c in cols) + "\n")

def nearest_rank(xs, p):
    xs = sorted(xs)
    return xs[max(0, math.ceil(p / 100 * len(xs)) - 1)]

print(f"Report scritto in {report_path}")
print("Percentili a rango piu' vicino: con 10 campioni il p95 e' il massimo.")
for lang in ("python", "dotnet", "go"):
    all_rs = [x for x in out if x["language"] == lang]
    if not all_rs:
        continue
    warm = [x["label"] for x in all_rs if not x["cold_start"]]
    rs = [x for x in all_rs if x["cold_start"]]
    ok = sum(1 for x in rs if x["result"] == "200")
    print(f"{lang:7} n={len(rs)} ok={ok}" + (f"  ESCLUSE (host gia' avviato o sconosciuto): {', '.join(warm)}" if warm else ""))
    if warm:
        bad = True
    if not rs:
        continue
    for k in ("cold_est_ms", "client_net_ms", "server_ms"):
        xs = [x[k] for x in rs]
        print(f"   {k:14} mediana {nearest_rank(xs, 50):8.1f}  p95 {nearest_rank(xs, 95):8.1f}  min {min(xs):8.1f}")
    if lang == "python" and rs[0]["billed_ms"] != "":
        for x in rs:
            print(f"   M4 {x['label']:22} fatturati {x['billed_ms']:>8} ms  | H0 {x['h0_ms']:>5}  H1 {x['h1_ms']:>5}  D {x['server_ms']:>7}  [{x['units_window']}]")
if bad:
    print("ERRORE: almeno una ripetizione esclusa (host gia' avviato) o una somma delle unita' non chiusa.", file=sys.stderr)
    sys.exit(1)
EOF
