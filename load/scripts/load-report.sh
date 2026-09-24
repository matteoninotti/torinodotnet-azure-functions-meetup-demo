#!/usr/bin/env bash
#
# Lettura della serie di carico, a serie finita: una riga di
# load/output/runs.tsv alla volta.
#
#   ./load/scripts/load-report.sh [etichetta...]     # default: tutte le righe
#
# Per ogni run, in load/output/<etichetta>/:
#   export-run.sh con http_reqs di k6 come richieste attese (I6, I7)
#   summary-server.json   run-summary.kql sulla finestra RUN_START..RUN_END
#   per-second.json       latency-per-second.kql (solo Metrica 3)
#   instances-other.json  InstanceCount delle altre due app nella finestra,
#                         con Count e mai Maximum (D55) (solo Metrica 3)
#   reuse.json            istanze della finestra gia' viste nel look_back di
#                         run-summary.kql prima di win_start. Su una Metrica 3
#                         deve essere zero: le app partono da zero, quindi
#                         un'istanza "gia' vista" vorrebbe dire che Azure
#                         riusa gli AppRoleInstance e che il look_back
#                         classifica come calde istanze nuove (D126).
#
# Da lanciare almeno 5 minuti dopo l'ultimo run (ingestion e ritardo delle
# metriche). Esce 1 se un export fallisce o se una Metrica 3 ha istanze
# riusate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LEDGER="$REPO_ROOT/load/output/runs.tsv"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-torinodotnet-demo}"
[ -f "$LEDGER" ] || { echo "manca ${LEDGER}" >&2; exit 2; }

WS=$(az monitor log-analytics workspace show --resource-group "$RESOURCE_GROUP" \
  --workspace-name torinodotnet-logs --query customerId -o tsv)

failed=0
while IFS=$'\t' read -r label lang run_start run_end http_reqs _; do
  if [ "$#" -gt 0 ] && ! printf '%s\n' "$@" | grep -qx "$label"; then continue; fi
  dir="$REPO_ROOT/load/output/$label"
  echo "=== ${label}"
  if ! "$SCRIPT_DIR/export-run.sh" "$label" "$run_start" "$run_end" "$http_reqs"; then
    failed=1
    continue
  fi
  "$SCRIPT_DIR/query-run.sh" "$REPO_ROOT/load/queries/run-summary.kql" "$run_start" "$run_end" json >"$dir/summary-server.json"

  case "$label" in m3-*) ;; *) continue ;; esac

  "$SCRIPT_DIR/query-run.sh" "$REPO_ROOT/load/queries/latency-per-second.kql" "$run_start" "$run_end" json >"$dir/per-second.json"

  # InstanceCount si legge con qualche minuto di ritardo (D56, D90): la
  # finestra si allunga di 5 minuti oltre RUN_END.
  end_plus=$(python3 -c "import sys,datetime as d;t=d.datetime.strptime(sys.argv[1][:19],'%Y-%m-%dT%H:%M:%S');print((t+d.timedelta(minutes=5)).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$run_end")
  printf '{' >"$dir/instances-other.json"
  sep=""
  for other in python dotnet go; do
    [ "$other" = "$lang" ] && continue
    id=$(az functionapp show -g "$RESOURCE_GROUP" -n "torinodotnet-${other}" --query id -o tsv)
    data=$(az monitor metrics list --resource "$id" --metric InstanceCount --aggregation Count --interval PT1M \
      --start-time "$run_start" --end-time "$end_plus" --query "value[0].timeseries[0].data[?count!=null]" -o json)
    printf '%s"%s": %s' "$sep" "$other" "$data" >>"$dir/instances-other.json"
    sep=","
  done
  printf '}\n' >>"$dir/instances-other.json"

  az monitor log-analytics query --workspace "$WS" -o json --analytics-query "
    let win_start = datetime(${run_start});
    let win_end = datetime(${run_end});
    let in_window = AppRequests
      | where TimeGenerated between (win_start .. win_end) and Name == 'resize'
      | distinct AppRoleInstance;
    AppRequests
    | where TimeGenerated between (win_start - 30m .. win_end) and Name == 'resize'
    | summarize first_seen = min(TimeGenerated) by AppRoleInstance
    | join kind=inner in_window on AppRoleInstance
    | summarize instances = count(), seen_before_window = countif(first_seen < win_start)" >"$dir/reuse.json"
  reused=$(python3 -c "import json,sys;r=json.load(open(sys.argv[1]))[0];print(r['seen_before_window'], r['instances'])" "$dir/reuse.json")
  echo "  istanze gia' viste prima della finestra / istanze: ${reused}"
  if [ "${reused%% *}" != 0 ]; then
    echo "  ERRORE: una Metrica 3 non deve avere istanze gia' viste: il look_back le classificherebbe calde." >&2
    failed=1
  fi
  python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print('  InstanceCount delle altre due app nella finestra:', {k: sum(p['count'] for p in v) for k,v in d.items()})" "$dir/instances-other.json"
done < <(tail -n +2 "$LEDGER")

[ "$failed" -eq 0 ] || { echo "REPORT CON ERRORI" >&2; exit 1; }
echo "REPORT OK"
