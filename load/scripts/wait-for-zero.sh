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

# Lo stderr di `az` va in un file e NON dentro il valore letto. Con `2>&1` ci
# finiva dentro anche quando il comando riusciva: l'Azure CLI scrive su stderr
# anche i warning, non solo gli errori ([configurazione ufficiale di
# `core.only_show_errors`](https://learn.microsoft.com/en-us/cli/azure/azure-cli-configuration#cli-configuration-values-and-environment-variables):
# "only errors are written to stderr. It suppresses warnings from preview,
# deprecated and experimental commands"). Un warning davanti al timestamp lo
# rendeva impossibile da interpretare, e il ramo sotto leggeva quel fallimento
# come silenzio.
AZ_ERR=$(mktemp)
trap 'rm -f "$AZ_ERR"' EXIT

# Fuori dal ciclo e con il suo messaggio: un APP_NAME sbagliato qui faceva
# cadere lo script su `set -euo pipefail` senza stampare niente — e siccome
# l'uscita era comunque != 0, sembrava che il controllo dentro il ciclo avesse
# funzionato. E' il punto da cui passava il criterio di verifica dell'audit,
# che quindi non esercitava affatto il ramo che pretendeva di provare (D101).
if ! APP_ID=$(az functionapp show --resource-group "$RESOURCE_GROUP" \
  --name "$APP_NAME" --query id -o tsv 2>"$AZ_ERR"); then
  echo "Impossibile risolvere la function app ${APP_NAME} nel gruppo ${RESOURCE_GROUP}: $(cat "$AZ_ERR")" >&2
  exit 1
fi

START_EPOCH=$(date -u +%s)
# La finestra parte da un'ora fa: abbastanza da vedere l'ultimo carico.
WINDOW_START=$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)

echo "In attesa dello zero su ${APP_NAME} (finestra da ${WINDOW_START})"

consecutive_quiet=0
for _ in $(seq 1 "$MAX_MINUTES"); do
  # Tre esiti, non due, e vanno tenuti distinti: "az e' fallito", "az ha
  # risposto senza campioni" e "az ha risposto con un campione". Il primo non e'
  # ne' conferma ne' smentita e il poll si scarta; solo il secondo e' silenzio.
  # Un errore transitorio (throttling, token scaduto, blip di rete) non deve mai
  # poter diventare un "zero istanze confermato": e' esattamente la precondizione
  # che questo script esiste per verificare, resa falsa da un errore di rete
  # invece che da un'istanza viva.
  if ! last_sample=$(az monitor metrics list \
    --resource "$APP_ID" \
    --metric InstanceCount \
    --interval PT1M \
    --aggregation Count \
    --start-time "$WINDOW_START" \
    --query "value[0].timeseries[0].data[?count!=null] | [-1].timeStamp" -o tsv 2>"$AZ_ERR"); then
    now=$(date -u +%H:%M:%SZ)
    echo "${now} | comando az fallito, poll scartato (non e' ne' conferma ne' smentita): $(cat "$AZ_ERR")" >&2
    sleep "$POLL_SECONDS"
    continue
  fi

  now=$(date -u +%H:%M:%SZ)

  if [ -z "$last_sample" ] || [ "$last_sample" = "None" ]; then
    # Nessun campione nella finestra e' un segnale forte, ma passa comunque
    # dallo stesso contatore di conferme dell'altro ramo: una sola lettura,
    # per quanto pulita, resta una sola lettura.
    consecutive_quiet=$((consecutive_quiet + 1))
    echo "${now} | nessun campione nella finestra (conferma ${consecutive_quiet}/2)"
    if [ "$consecutive_quiet" -ge 2 ]; then
      echo "ZERO CONFERMATO dopo $(( ($(date -u +%s) - START_EPOCH) / 60 )) minuti di attesa"
      exit 0
    fi
    sleep "$POLL_SECONDS"
    continue
  fi

  # macOS (BSD date) e Linux (GNU date) parsano diversamente: si provano entrambi.
  #
  # ⚠️ Il fallback NON e' `|| echo 0`. Un epoch a zero significa "campione del
  # 1970", cioe' un'eta' di miliardi di secondi, cioe' la conferma piu' forte
  # possibile che l'app e' ferma: il ramo d'errore darebbe la risposta piu'
  # verde che esiste. Un timestamp che non si riesce a leggere e' un poll
  # scartato come un fallimento di az, non un silenzio.
  clean_ts="${last_sample%%.*}"; clean_ts="${clean_ts%Z}"
  last_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$clean_ts" +%s 2>/dev/null \
    || date -u -d "$clean_ts" +%s 2>/dev/null || echo "")
  if [ -z "$last_epoch" ]; then
    echo "${now} | timestamp non interpretabile, poll scartato: [${last_sample}]" >&2
    sleep "$POLL_SECONDS"
    continue
  fi
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
