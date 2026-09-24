#!/usr/bin/env bash
#
# Metrica 2 (cold start isolato) e, sulle ripetizioni Python, Metrica 4 (il
# cold start e' fatturato?). Solo le richieste: la lettura della telemetria la
# fa cold-start-report.sh, a serie finita.
#
#   ./load/scripts/cold-start.sh <serie> <giri> <linguaggio>...
#   ./load/scripts/cold-start.sh m2 10 python dotnet go
#   ./load/scripts/cold-start.sh d61-variante 3 python
#
# A ogni giro (D126 punto 4):
#   1. zero istanze su TUTTE E TRE le app (preflight.sh 2, attese in
#      parallelo), con il primo linguaggio del giro riconfermato per ultimo;
#   2. una richiesta per linguaggio, in SEQUENZA: ognuna parte dopo la
#      risposta della precedente, quindi le finestre non si sovrappongono e
#      export-run.sh con 1 richiesta attesa vale per ciascuna;
#   3. l'ordine ruota a ogni giro (py-dn-go, dn-go-py, go-py-dn, ...).
#
# Parametri espliciti e uguali a quelli dei run di carico (D126 punto 3): i
# default di resize.js non valgono qui, perche' questo non e' k6.
#
# Il tempo client lo misura curl (`-w`), su una connessione nuova a ogni
# richiesta. Si registrano sia il totale sia il netto `time_total -
# time_appconnect`: DNS, TCP e TLS sono rete del Mac, non avvio dell'istanza
# (D126 punto 5).
#
# Scrive load/output/<serie>/requests.tsv, una riga per richiesta.

set -euo pipefail

SERIES="${1:-}"
ROUNDS="${2:-}"
shift 2 || true
LANGS=("$@")
usage() { echo "uso: $0 <serie> <giri> <python|dotnet|go>..." >&2; exit 2; }
[[ "$SERIES" =~ ^[A-Za-z0-9._-]+$ ]] || usage
[[ "$ROUNDS" =~ ^[0-9]+$ ]] && [ "$ROUNDS" -gt 0 ] || usage
[ "${#LANGS[@]}" -gt 0 ] || usage
for l in "${LANGS[@]}"; do case "$l" in python|dotnet|go) ;; *) usage ;; esac; done

COUNT=80
IMAGE=npm-install-7-years.jpg
WIDTH=800
QUALITY=80

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$REPO_ROOT/load/output/$SERIES"
TSV="$OUT_DIR/requests.tsv"
BODY=$(mktemp)
trap 'rm -f "$BODY"' EXIT

if [ ! -e "$TSV" ]; then
  mkdir -p "$OUT_DIR"
  printf 'label\tlanguage\tround\tt_send\tt_recv\thttp_code\ttime_namelookup\ttime_connect\ttime_appconnect\ttime_starttransfer\ttime_total\ttotal_ms\n' >"$TSV"
  START_ROUND=1
else
  # Ripresa di una serie interrotta: si riparte dal giro dopo l'ultimo completo.
  START_ROUND=$(( $(tail -n +2 "$TSV" | cut -f3 | sort -n | tail -n 1) + 1 ))
  echo "Serie ${SERIES} gia' iniziata: riprendo dal giro ${START_ROUND}."
fi

now_ms() { python3 -c "import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3]+'Z')"; }

n=${#LANGS[@]}
for round in $(seq "$START_ROUND" "$ROUNDS"); do
  order=()
  for i in $(seq 0 $((n - 1))); do order+=("${LANGS[$(( (i + round - 1) % n ))]}"); done

  echo "=== $(date -u +%H:%M:%SZ) giro ${round}/${ROUNDS}: ${order[*]}"
  "$SCRIPT_DIR/preflight.sh" 2 "${order[0]}"

  for lang in "${order[@]}"; do
    url="https://torinodotnet-${lang}.azurewebsites.net/api/resize?image=${IMAGE}&count=${COUNT}&width=${WIDTH}&quality=${QUALITY}"
    t_send=$(now_ms)
    timings=$(curl -sS -X POST -o "$BODY" --max-time 120 \
      -w '%{http_code}\t%{time_namelookup}\t%{time_connect}\t%{time_appconnect}\t%{time_starttransfer}\t%{time_total}' "$url") \
      || { echo "${lang}: curl fallito, serie interrotta" >&2; exit 1; }
    t_recv=$(now_ms)
    total_ms=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('total_ms',''))" "$BODY" 2>/dev/null || echo "")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${SERIES}-${lang}-g${round}" "$lang" "$round" "$t_send" "$t_recv" "$timings" "$total_ms" >>"$TSV"
    echo "  ${lang}: $(printf '%s' "$timings" | cut -f1) in $(printf '%s' "$timings" | cut -f6) s (pipeline ${total_ms} ms)"
    [ "$(printf '%s' "$timings" | cut -f1)" = 200 ] || { echo "${lang}: risposta non 200, serie interrotta" >&2; exit 1; }
  done
done

echo "=== $(date -u +%H:%M:%SZ) SERIE ${SERIES} COMPLETA: ${TSV}. Poi: cold-start-report.sh ${SERIES}"
