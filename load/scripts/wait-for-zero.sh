#!/usr/bin/env bash
#
# Attende che una function app scali a zero istanze, e lo VERIFICA.
#
# Le Metriche 2 e 4 iniziano entrambe con "app a zero istanze". Se si aspetta
# troppo poco, la richiesta atterra su un'istanza ancora viva e si misura un
# cold start che non c'e' stato: un numero plausibile e sbagliato, senza nessun
# segnale che qualcosa non va. Questo script rende quella precondizione una
# verifica invece che una speranza.
#
#   ./load/scripts/wait-for-zero.sh python
#
# Perche' non un semplice `sleep 300`: il tempo di scale-to-zero misurato
# (~3-4 minuti, D56) e' un LIMITE SUPERIORE, non un valore fine — la metrica
# InstanceCount ritarda e non separa la deallocazione reale dal ritardo di
# reporting. Contare i minuti sarebbe fidarsi di un numero che non ha quella
# precisione; guardare l'assenza di campioni no.
#
# ⚠️ InstanceCount va interrogata con aggregazione `Count`, NON `Maximum`
# (D55): ogni istanza emette un campione di VALORE 1 ogni 30 secondi, quindi
# con `Maximum` il risultato e' sempre 1.0 e sembra che l'app non scali mai.
# E' il numero di campioni a rappresentare le istanze.

set -euo pipefail

LANGUAGE="${1:-python}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-torinodotnet-demo}"
APP_NAME="${APP_NAME:-torinodotnet-${LANGUAGE}}"

# Un campione ogni 30s per istanza: 210s senza campioni nuovi sono 7 intervalli
# mancati, abbastanza da escludere un buco isolato di reporting.
QUIET_SECONDS="${QUIET_SECONDS:-210}"
POLL_SECONDS="${POLL_SECONDS:-60}"
MAX_MINUTES="${MAX_MINUTES:-45}"

APP_ID=$(az functionapp show --resource-group "$RESOURCE_GROUP" --name "$APP_NAME" --query id -o tsv)
START_EPOCH=$(date -u +%s)
# La finestra parte da un'ora fa: abbastanza da vedere l'ultimo carico.
WINDOW_START=$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)

echo "In attesa dello zero su ${APP_NAME} (finestra da ${WINDOW_START})"

consecutive_quiet=0
for _ in $(seq 1 "$MAX_MINUTES"); do
  last_sample=$(az monitor metrics list \
    --resource "$APP_ID" \
    --metric InstanceCount \
    --interval PT1M \
    --aggregation Count \
    --start-time "$WINDOW_START" \
    --query "value[0].timeseries[0].data[?count!=null] | [-1].timeStamp" -o tsv 2>/dev/null || true)

  now=$(date -u +%H:%M:%SZ)

  if [ -z "$last_sample" ] || [ "$last_sample" = "None" ]; then
    echo "${now} | nessun campione nella finestra: zero istanze"
    echo "ZERO CONFERMATO dopo $(( ($(date -u +%s) - START_EPOCH) / 60 )) minuti di attesa"
    exit 0
  fi

  # macOS (BSD date) e Linux (GNU date) parsano diversamente: si provano entrambi.
  clean_ts="${last_sample%%.*}"; clean_ts="${clean_ts%Z}"
  last_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$clean_ts" +%s 2>/dev/null \
    || date -u -d "$clean_ts" +%s 2>/dev/null || echo 0)
  age=$(( $(date -u +%s) - last_epoch ))

  echo "${now} | ultimo campione ${last_sample} (${age}s fa)"

  if [ "$age" -gt "$QUIET_SECONDS" ]; then
    consecutive_quiet=$((consecutive_quiet + 1))
  else
    consecutive_quiet=0
  fi

  if [ "$consecutive_quiet" -ge 2 ]; then
    echo "ZERO CONFERMATO: nessun campione nuovo da ${age}s (atteso $(( ($(date -u +%s) - START_EPOCH) / 60 )) minuti)"
    exit 0
  fi

  sleep "$POLL_SECONDS"
done

echo "TIMEOUT: ${MAX_MINUTES} minuti senza raggiungere lo zero. Controllare che non ci sia traffico verso l'app." >&2
exit 1
