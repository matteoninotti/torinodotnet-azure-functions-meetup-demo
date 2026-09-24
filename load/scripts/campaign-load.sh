#!/usr/bin/env bash
#
# La serie di carico della Fase 7: tre ripetizioni della Metrica 3 per
# linguaggio, e la Metrica 1 subito dopo la prima ripetizione di ciascuno.
#
#   ./load/scripts/campaign-load.sh [prima-ripetizione]
#
# La ripetizione di M3 fa da riscaldamento di M1 (D126 punto 2, cambia D90
# punto 1): partono dallo stesso stato e con lo stesso comando, quindi il
# riscaldamento che il protocollo buttava via era gia' un run di Metrica 3.
# M1 parte subito dopo, SENZA preflight in mezzo: l'app deve arrivare calda.
#
# Fra un burst e il successivo, preflight.sh 3 <linguaggio>: zero istanze su
# tutte e tre le app, perche' la quota regionale di core e' condivisa (I4).
#
# L'ordine dei linguaggi ruota a ogni ripetizione, cosi' nessuno parte sempre
# per primo, e i tre restano vicini nel tempo (la scale curve puo' cambiare).
#
# Si ferma al primo errore. Se una ripetizione di M3 esce invalida (exit 3 di
# run-load.sh), la serie si ferma PRIMA di M1: una M1 riscaldata da un run
# invalido va rifatta insieme a lui.
#
# Prerequisiti, fuori da questo script (load/README.md, "Protocollo di ogni
# run"): runtime-snapshot.sh inizio, tetto a 200 sulle tre app. Dopo:
# export-run.sh su ogni riga di load/output/runs.tsv, postflight.sh.

set -euo pipefail

FIRST_REP="${1:-1}"
[[ "$FIRST_REP" =~ ^[1-3]$ ]] || { echo "uso: $0 [prima-ripetizione 1-3]" >&2; exit 2; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

order_for_rep() {
  case "$1" in
    1) echo "python dotnet go" ;;
    2) echo "dotnet go python" ;;
    3) echo "go python dotnet" ;;
  esac
}

for rep in $(seq "$FIRST_REP" 3); do
  for lang in $(order_for_rep "$rep"); do
    echo "=== $(date -u +%H:%M:%SZ) preflight Metrica 3, ${lang}, ripetizione ${rep}"
    "$SCRIPT_DIR/preflight.sh" 3 "$lang"

    echo "=== $(date -u +%H:%M:%SZ) Metrica 3, ${lang}, ripetizione ${rep}"
    "$SCRIPT_DIR/run-load.sh" "m3-${lang}-r${rep}" "$lang"

    if [ "$rep" = 1 ]; then
      echo "=== $(date -u +%H:%M:%SZ) Metrica 1, ${lang} (app calda dal run precedente)"
      "$SCRIPT_DIR/run-load.sh" "m1-${lang}" "$lang"
    fi
  done
done

echo "=== $(date -u +%H:%M:%SZ) SERIE COMPLETA. Ora: export-run.sh sulle righe di load/output/runs.tsv, poi postflight.sh."
