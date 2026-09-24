#!/usr/bin/env bash
#
# Controlli prima di ogni run di misura, identici per le quattro metriche e
# per i tre linguaggi. Esce 0 solo se sono veri tutti.
#
#   ./load/scripts/preflight.sh 1 go      # Metrica 1 o 3: carico, servono 200 istanze
#   ./load/scripts/preflight.sh 2 python  # Metrica 2 o 4: una richiesta singola
#
# Il secondo argomento e' il linguaggio che si sta per misurare.
#
# 1. Configurazione di scala delle tre app, letta dalla RISORSA e non dal
#    Bicep: 2.048 MB e concorrenza HTTP 1 sempre, e per le Metriche 1 e 3
#    `maximumInstanceCount` a 200. Fuori dalle finestre di misura il tetto sta
#    basso (vedi load/README.md, "Protocollo di ogni run"): un run di carico
#    lanciato col tetto basso misurerebbe il tetto invece del linguaggio, e lo
#    farebbe senza nessun errore.
# 2. Zero istanze su TUTTE E TRE le app, non solo su quella da misurare. La
#    quota regionale di core e' condivisa fra le app Flex della sottoscrizione
#    e regione ([Regional subscription memory quotas](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#regional-subscription-memory-quotas)):
#    istanze ancora vive su un'altra app sono capacita' sottratta a quella
#    misurata. Le tre attese girano in parallelo, poi l'app da misurare viene
#    RICONFERMATA da sola: la sua conferma e' la piu' recente quando il run
#    parte.
#
# ⚠️ Niente richieste verso le app fra questo script e il run: anche un
# /api/health sveglia un'istanza. Il runtime (runtime-snapshot.sh) si legge
# PRIMA di lanciare questo script.

set -euo pipefail

METRIC="${1:-}"
TARGET="${2:-}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-torinodotnet-demo}"
LANGUAGES=(python dotnet go)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$METRIC" in
  1|3) WANT_MAX=200 ;;
  2|4) WANT_MAX="" ;;
  *) echo "uso: $0 <1|2|3|4> <python|dotnet|go>  (metrica, linguaggio da misurare)" >&2; exit 2 ;;
esac
case "$TARGET" in
  python|dotnet|go) ;;
  *) echo "uso: $0 <1|2|3|4> <python|dotnet|go>  (metrica, linguaggio da misurare)" >&2; exit 2 ;;
esac

AZ_ERR=$(mktemp)
trap 'rm -f "$AZ_ERR"' EXIT

failed=0
for lang in "${LANGUAGES[@]}"; do
  app="torinodotnet-${lang}"
  if ! cfg=$(az resource show --resource-group "$RESOURCE_GROUP" --name "$app" \
    --resource-type Microsoft.Web/sites --api-version 2024-04-01 \
    --query "[properties.functionAppConfig.scaleAndConcurrency.maximumInstanceCount, properties.functionAppConfig.scaleAndConcurrency.instanceMemoryMB, properties.functionAppConfig.scaleAndConcurrency.triggers.http.perInstanceConcurrency]" \
    -o tsv 2>"$AZ_ERR"); then
    echo "${app}: configurazione non leggibile: $(cat "$AZ_ERR")" >&2
    failed=1
    continue
  fi
  # -o tsv mette i tre valori su tre righe.
  read -r max_instances memory_mb concurrency <<<"$(echo $cfg)"
  echo "${app}: maximumInstanceCount=${max_instances} instanceMemoryMB=${memory_mb} perInstanceConcurrency=${concurrency}"

  if [ "$memory_mb" != "2048" ] || [ "$concurrency" != "1" ]; then
    echo "${app}: memoria o concorrenza diverse da 2048 / 1. Sono fatti bloccati: non si misura." >&2
    failed=1
  fi
  if [ -n "$WANT_MAX" ] && [ "$max_instances" != "$WANT_MAX" ]; then
    echo "${app}: maximumInstanceCount e' ${max_instances}, la Metrica ${METRIC} ne vuole ${WANT_MAX}. Prima del run:" >&2
    echo "  az functionapp scale config set -g ${RESOURCE_GROUP} -n ${app} --maximum-instance-count ${WANT_MAX}" >&2
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "PREFLIGHT FALLITO: configurazione." >&2
  exit 1
fi

# Le tre attese partono in parallelo: si aspetta la piu' lenta, non la somma.
# Poi l'app da misurare si riconferma da sola, cosi' la sua conferma resta la
# piu' recente quando il run parte (D119). Ogni attesa scrive nel proprio log,
# stampato alla fine, perche' tre output intrecciati non si leggono.
WAIT_DIR=$(mktemp -d)
trap 'rm -f "$AZ_ERR"; rm -rf "$WAIT_DIR"' EXIT

pids=()
for lang in "${LANGUAGES[@]}"; do
  RESOURCE_GROUP="$RESOURCE_GROUP" "$SCRIPT_DIR/wait-for-zero.sh" "$lang" >"$WAIT_DIR/$lang.log" 2>&1 &
  pids+=("$!")
done
zero_failed=0
for i in "${!LANGUAGES[@]}"; do
  lang="${LANGUAGES[$i]}"
  if wait "${pids[$i]}"; then
    echo "torinodotnet-${lang}: $(tail -n 1 "$WAIT_DIR/$lang.log")"
  else
    echo "torinodotnet-${lang}: attesa dello zero FALLITA:" >&2
    sed 's/^/  /' "$WAIT_DIR/$lang.log" >&2
    zero_failed=1
  fi
done
if [ "$zero_failed" -ne 0 ]; then
  echo "PREFLIGHT FALLITO: almeno un'app non e' a zero istanze." >&2
  exit 1
fi

echo "Riconferma di torinodotnet-${TARGET}, per ultima:"
RESOURCE_GROUP="$RESOURCE_GROUP" "$SCRIPT_DIR/wait-for-zero.sh" "$TARGET" || {
  echo "PREFLIGHT FALLITO: torinodotnet-${TARGET} non e' a zero istanze alla riconferma." >&2
  exit 1
}

echo "PREFLIGHT OK per la Metrica ${METRIC} su ${TARGET}: configurazione verificata, tre app a zero istanze, ${TARGET} confermata per ultima."
