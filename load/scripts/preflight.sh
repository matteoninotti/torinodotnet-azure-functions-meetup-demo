#!/usr/bin/env bash
#
# Controlli prima di ogni run di misura, identici per le quattro metriche e
# per i tre linguaggi. Esce 0 solo se sono veri tutti.
#
#   ./load/scripts/preflight.sh 1     # Metrica 1 o 3: carico, servono 200 istanze
#   ./load/scripts/preflight.sh 2     # Metrica 2 o 4: una richiesta singola
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
#    misurata.
#
# ⚠️ Niente richieste verso le app fra questo script e il run: anche un
# /api/health sveglia un'istanza. Il runtime (runtime-snapshot.sh) si legge
# PRIMA di lanciare questo script.

set -euo pipefail

METRIC="${1:-}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-torinodotnet-demo}"
LANGUAGES=(python dotnet go)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$METRIC" in
  1|3) WANT_MAX=200 ;;
  2|4) WANT_MAX="" ;;
  *) echo "uso: $0 <1|2|3|4>  (numero della metrica)" >&2; exit 2 ;;
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

for lang in "${LANGUAGES[@]}"; do
  RESOURCE_GROUP="$RESOURCE_GROUP" "$SCRIPT_DIR/wait-for-zero.sh" "$lang" || {
    echo "PREFLIGHT FALLITO: torinodotnet-${lang} non e' a zero istanze." >&2
    exit 1
  }
done

echo "PREFLIGHT OK per la Metrica ${METRIC}: configurazione verificata, tre app a zero istanze."
