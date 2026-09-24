#!/usr/bin/env bash
#
# Registra la versione di runtime che ciascun worker dichiara su /api/health.
#
#   ./load/scripts/runtime-snapshot.sh inizio          # all'inizio della campagna
#   ./load/scripts/runtime-snapshot.sh fine inizio     # alla fine: confronta con "inizio"
#
# Python e .NET dichiarano solo il canale (3.12, 10.0) e la patch la sceglie la
# piattaforma, anche senza nessun deploy in mezzo; Go la fissa la pipeline.
# Una campagna i cui run girano su patch diverse non e' un confronto a runtime
# fermo, e dirlo e' possibile solo se il runtime e' stato letto prima e dopo.
# Il confronto e' fra stringhe esatte: "e' ancora .NET 10" resterebbe vero
# attraverso qualunque patch.
#
# Il file va in load/output/runtime-<etichetta>.txt, una riga per worker.
#
# ⚠️ /api/health sveglia le app: si lancia PRIMA di preflight.sh, mai fra
# preflight.sh e il run.

set -euo pipefail

LABEL="${1:-}"
COMPARE_TO="${2:-}"
[ -n "$LABEL" ] || { echo "uso: $0 <etichetta> [etichetta-da-confrontare]" >&2; exit 2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="$REPO_ROOT/load/output"
OUT="$OUT_DIR/runtime-${LABEL}.txt"
mkdir -p "$OUT_DIR"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

for lang in python dotnet go; do
  url="https://torinodotnet-${lang}.azurewebsites.net/api/health"
  # --max-time largo: la prima richiesta puo' essere un cold start.
  if ! body=$(curl -sS --fail --max-time 90 "$url"); then
    echo "${lang}: ${url} non ha risposto" >&2
    exit 1
  fi
  runtime=$(printf '%s' "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('runtime') or '')" 2>/dev/null || true)
  [ -n "$runtime" ] || { echo "${lang}: /api/health non riporta il runtime: ${body}" >&2; exit 1; }
  printf '%s %s\n' "$lang" "$runtime" >>"$tmp"
done

mv "$tmp" "$OUT"
echo "Runtime registrato in ${OUT} ($(date -u +%Y-%m-%dT%H:%M:%SZ)):"
cat "$OUT"

if [ -n "$COMPARE_TO" ]; then
  REF="$OUT_DIR/runtime-${COMPARE_TO}.txt"
  [ -f "$REF" ] || { echo "manca ${REF}: niente con cui confrontare" >&2; exit 1; }
  if diff -u "$REF" "$OUT"; then
    echo "RUNTIME INVARIATO rispetto a '${COMPARE_TO}'."
  else
    echo "RUNTIME CAMBIATO durante la campagna: i run prima e dopo il cambio non sono a runtime fermo, va dichiarato." >&2
    exit 1
  fi
fi
