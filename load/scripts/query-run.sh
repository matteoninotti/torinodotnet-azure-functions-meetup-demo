#!/usr/bin/env bash
#
# Lancia una delle query di load/queries/ su una finestra data, senza
# modificare il file: le due righe `let win_start` e `let win_end` vengono
# sostituite al volo.
#
#   ./load/scripts/query-run.sh <file.kql> <win_start> <win_end> [table|json|tsv]
#   ./load/scripts/query-run.sh load/queries/run-summary.kql 2026-09-24T13:30:00Z 2026-09-24T13:32:10Z
#
# Le date sono RUN_START e RUN_END di load/output/runs.tsv.

set -euo pipefail

KQL="${1:-}"
WIN_START="${2:-}"
WIN_END="${3:-}"
FORMAT="${4:-table}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-torinodotnet-demo}"
WORKSPACE_NAME="${WORKSPACE_NAME:-torinodotnet-logs}"

TS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$'
[ -f "$KQL" ] && [[ "$WIN_START" =~ $TS_RE ]] && [[ "$WIN_END" =~ $TS_RE ]] \
  || { echo "uso: $0 <file.kql> <win_start> <win_end> [table|json|tsv]" >&2; exit 2; }
case "$FORMAT" in table|json|tsv) ;; *) echo "formato: table, json o tsv" >&2; exit 2 ;; esac

# Esattamente una riga per ciascuna delle due: altrimenti la sostituzione
# lascerebbe in piedi la finestra scritta nel file, in silenzio.
[ "$(grep -c '^let win_start *= *datetime(' "$KQL")" = 1 ] && [ "$(grep -c '^let win_end *= *datetime(' "$KQL")" = 1 ] \
  || { echo "${KQL}: attese esattamente una riga 'let win_start' e una 'let win_end'" >&2; exit 1; }

query=$(sed -E \
  -e "s|^let win_start *= *datetime\([^)]*\);|let win_start = datetime(${WIN_START});|" \
  -e "s|^let win_end *= *datetime\([^)]*\);|let win_end   = datetime(${WIN_END});|" "$KQL")

WS=$(az monitor log-analytics workspace show --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$WORKSPACE_NAME" --query customerId -o tsv)
az monitor log-analytics query --workspace "$WS" --analytics-query "$query" -o "$FORMAT"
