#!/usr/bin/env bash
#
# Run "sotto il secondo": sotto il minimo fatturabile i tre linguaggi pagano
# la stessa bolletta, anche se le loro durate sono diverse (D126 punto 6).
#
#   ./load/scripts/sub-second.sh run <serie>      # le richieste
#   ./load/scripts/sub-second.sh report <serie>   # la lettura, >= 6 min dopo
#
# Per ciascun linguaggio, uno alla volta: una richiesta di riscaldamento e
# poi 20 in sequenza, count=1. Le 20 NON finiscono su un'istanza sola: con il
# tetto a 5 la prima richiesta a freddo accende 5 host insieme e le successive
# ruotano su quelli (D131).
#
# Il controllo che decide e' un INTERVALLO, non un'uguaglianza: riscaldamento
# e cold start finiscono negli stessi minuti della metrica delle 20 (D60).
# Quindi
#
#   20 x 1.000 ms x 2.048 MB  <=  unita' totali  <=  somma su OGNI richiesta
#   di 2.048 x ceil100(max(1.000, tempo client netto))
#
# e il minuto prima della prima richiesta deve essere a zero, altrimenti la
# coda di un run precedente sulla stessa app entrerebbe nella somma.
#
# Se fossero fatturate alla durata reale, il totale starebbe molto sotto il
# limite inferiore. Il rapporto Units/Count al minuto e' un controllo in piu',
# ausiliario: se contatore e unita' finissero in minuti diversi non darebbe
# 2.048.000 anche con una fatturazione corretta.

set -euo pipefail

MODE="${1:-}"
SERIES="${2:-}"
[[ "$MODE" =~ ^(run|report)$ ]] && [[ "$SERIES" =~ ^[A-Za-z0-9._-]+$ ]] \
  || { echo "uso: $0 <run|report> <serie> [linguaggio...]" >&2; exit 2; }
shift 2
LANGS=(python dotnet go)
# Il report si puo' limitare ad alcuni linguaggi, per esempio quando uno dei
# tre si e' interrotto a meta'.
[ "$MODE" = report ] && [ "$#" -gt 0 ] && LANGS=("$@")
N_WARM=20
COUNT=1
IMAGE=npm-install-7-years.jpg
WIDTH=800
QUALITY=80
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-torinodotnet-demo}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$REPO_ROOT/load/output/$SERIES"
TSV="$OUT_DIR/requests.tsv"
AZ_ERR=$(mktemp)
BODY=$(mktemp)
trap 'rm -f "$AZ_ERR" "$BODY"' EXIT
now_ms() { python3 -c "import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3]+'Z')"; }

if [ "$MODE" = run ]; then
  [ -e "$OUT_DIR" ] && { echo "esiste gia' ${OUT_DIR}" >&2; exit 2; }
  mkdir -p "$OUT_DIR"
  printf 'language\tseq\tkind\tt_send\tt_recv\thttp_code\ttime_appconnect\ttime_total\ttotal_ms\n' >"$TSV"
  for lang in "${LANGS[@]}"; do
    url="https://torinodotnet-${lang}.azurewebsites.net/api/resize?image=${IMAGE}&count=${COUNT}&width=${WIDTH}&quality=${QUALITY}"
    for seq in $(seq 0 "$N_WARM"); do
      kind=$([ "$seq" = 0 ] && echo riscaldamento || echo calda)
      t_send=$(now_ms)
      timings=$(curl -sS -X POST -o "$BODY" --max-time 120 -w '%{http_code}\t%{time_appconnect}\t%{time_total}' "$url") \
        || { echo "${lang}: curl fallito" >&2; exit 1; }
      t_recv=$(now_ms)
      total_ms=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('total_ms',''))" "$BODY" 2>/dev/null || echo "")
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$lang" "$seq" "$kind" "$t_send" "$t_recv" "$timings" "$total_ms" >>"$TSV"
      [ "$(printf '%s' "$timings" | cut -f1)" = 200 ] || { echo "${lang}: risposta non 200" >&2; exit 1; }
    done
    echo "${lang}: $((N_WARM + 1)) richieste fatte"
  done
  echo "Richieste finite alle $(date -u +%H:%M:%SZ). Report non prima di 6 minuti: $0 report ${SERIES}"
  exit 0
fi

[ -f "$TSV" ] || { echo "manca ${TSV}" >&2; exit 2; }
failed=0
for lang in "${LANGS[@]}"; do
  label="${SERIES}-${lang}"
  first=$(awk -F'\t' -v l="$lang" '$1==l{print $4}' "$TSV" | sort | head -n 1)
  last=$(awk -F'\t' -v l="$lang" '$1==l{print $5}' "$TSV" | sort | tail -n 1)
  "$SCRIPT_DIR/export-run.sh" "$label" "$first" "$last" $((N_WARM + 1)) || failed=1
  start=$(python3 -c "import sys,datetime as d;t=d.datetime.strptime(sys.argv[1][:16],'%Y-%m-%dT%H:%M');print((t-d.timedelta(minutes=1)).strftime('%Y-%m-%dT%H:%M:00Z'))" "$first")
  end=$(python3 -c "import sys,datetime as d;t=d.datetime.strptime(sys.argv[1][:16],'%Y-%m-%dT%H:%M');print((t+d.timedelta(minutes=6)).strftime('%Y-%m-%dT%H:%M:00Z'))" "$last")
  app_id=$(az functionapp show -g "$RESOURCE_GROUP" -n "torinodotnet-${lang}" --query id -o tsv 2>"$AZ_ERR") \
    || { echo "app ${lang} non trovata: $(cat "$AZ_ERR")" >&2; exit 1; }
  az monitor metrics list --resource "$app_id" --metric OnDemandFunctionExecutionUnits OnDemandFunctionExecutionCount \
    --aggregation Total --interval PT1M --start-time "$start" --end-time "$end" -o json >"$OUT_DIR/metrics-${lang}.json" 2>"$AZ_ERR" \
    || { echo "metriche ${lang} non leggibili: $(cat "$AZ_ERR")" >&2; exit 1; }
done
[ "$failed" -eq 0 ] || { echo "REPORT INTERROTTO: almeno una finestra non e' pulita." >&2; exit 1; }

python3 - "$REPO_ROOT" "$SERIES" "$TSV" "$OUT_DIR" "$N_WARM" "${LANGS[@]}" <<'EOF'
import json, math, sys
repo, series, tsv, out_dir, n_warm = sys.argv[1:6]
langs = sys.argv[6:]
n_warm = int(n_warm)
lines = open(tsv).read().splitlines()
hdr = lines[0].split("\t")
rows = [dict(zip(hdr, l.split("\t"))) for l in lines[1:]]
PER = 2048 * 1000
bad = False
for lang in langs:
    req = json.load(open(f"{repo}/load/output/{series}-{lang}/requests.json"))
    resize = sorted((x for x in req if x["Name"] == "resize"), key=lambda x: x["TimeGenerated"])
    durs = [float(x["DurationMs"]) for x in resize]
    mine = [r for r in rows if r["language"] == lang]
    nets = [(float(r["time_total"]) - float(r["time_appconnect"])) * 1000 for r in mine]
    m = {v["name"]["value"]: v["timeseries"][0]["data"] if v["timeseries"] else []
         for v in json.load(open(f"{out_dir}/metrics-{lang}.json"))["value"]}
    # Il primo minuto letto e' quello PRIMA della prima richiesta: deve essere
    # a zero, e poi si toglie dalla somma.
    before = m["OnDemandFunctionExecutionUnits"][0].get("total") or 0
    m = {k: v[1:] for k, v in m.items()}
    units = [p.get("total") or 0 for p in m["OnDemandFunctionExecutionUnits"]]
    counts = [p.get("total") or 0 for p in m["OnDemandFunctionExecutionCount"]]
    total_units, total_count = sum(units), sum(counts)
    # Limite inferiore: le 20 calde fatturate almeno al minimo (il
    # riscaldamento si esclude, per prudenza). Limite superiore: OGNI
    # richiesta fatturata al piu' per il suo tempo client netto, cold start e
    # attese comprese, arrotondato come da billing. Le 20 "calde" non stanno su
    # un'istanza sola: con il tetto a 5 una richiesta a freddo accende 5 host
    # insieme e le successive ruotano su quelli (D131), quindi piu' di una
    # porta un cold start.
    lo = n_warm * PER
    hi = sum(2048 * math.ceil(max(1000, n) / 100) * 100 for n in nets)
    at_real = 2048 * sum(math.ceil(d / 100) * 100 for d in durs[1:])
    closed = len(units) >= 2 and units[-1] == 0 and units[-2] == 0
    ok = lo <= total_units <= hi and closed and before == 0
    if before:
        print(f"{lang:7} ERRORE: {before:,.0f} MB-ms nel minuto prima della finestra: coda di un run precedente")
    bad |= not ok
    d_hot = sorted(durs[1:])
    print(f"{lang:7} durata server calda: mediana {d_hot[len(d_hot)//2]:.1f} ms, max {max(d_hot):.1f}")
    print(f"        unita' {total_units:,.0f} MB-ms, esecuzioni {total_count:.0f}")
    print(f"        intervallo atteso al minimo fatturabile: [{lo:,} , {hi:,}]  -> {'DENTRO' if ok else 'FUORI'}"
          + ("" if closed else " (coda non chiusa)"))
    print(f"        se fatturate alla durata reale (arrotondata ai 100 ms, senza minimo): ~{at_real:,} MB-ms")
    per_min = [f"{p['timeStamp'][11:16]} {u/c:,.0f}" for p, u, c in zip(m["OnDemandFunctionExecutionUnits"], units, counts) if c]
    print(f"        Units/Count al minuto (ausiliario): {', '.join(per_min)}")
if bad:
    print("ERRORE: almeno un linguaggio fuori dall'intervallo o con la coda non chiusa.", file=sys.stderr)
    sys.exit(1)
EOF
