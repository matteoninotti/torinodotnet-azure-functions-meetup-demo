#!/usr/bin/env bash
#
# Fine campagna: riporta il tetto di istanze a 5 sulle tre app e lo VERIFICA
# rileggendolo dalla risorsa. Esce 0 solo se tutte e tre sono a 5.
#
#   ./load/scripts/postflight.sh            # imposta e verifica
#   ./load/scripts/postflight.sh --check    # verifica soltanto, non scrive
#
# E' il ritorno di preflight.sh: quello pretende 200 prima di un run di carico,
# questo pretende 5 dopo. Un ritorno dimenticato non fa fallire niente, e un
# `az deployment group create` riporta il tetto a 200 senza dirlo: il modo
# di saperlo e' rileggere, ed e' anche il controllo della checklist
# pre-presentazione.

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-torinodotnet-demo}"
WANT_MAX=5
MODE="${1:-set}"
case "$MODE" in
  set|--check) ;;
  *) echo "uso: $0 [--check]" >&2; exit 2 ;;
esac

AZ_ERR=$(mktemp)
trap 'rm -f "$AZ_ERR"' EXIT

failed=0
for lang in python dotnet go; do
  app="torinodotnet-${lang}"
  if [ "$MODE" = set ]; then
    if ! az functionapp scale config set --resource-group "$RESOURCE_GROUP" --name "$app" \
      --maximum-instance-count "$WANT_MAX" -o none 2>"$AZ_ERR"; then
      echo "${app}: impostazione del tetto fallita: $(cat "$AZ_ERR")" >&2
      failed=1
      continue
    fi
  fi
  if ! max_instances=$(az resource show --resource-group "$RESOURCE_GROUP" --name "$app" \
    --resource-type Microsoft.Web/sites --api-version 2024-04-01 \
    --query "properties.functionAppConfig.scaleAndConcurrency.maximumInstanceCount" -o tsv 2>"$AZ_ERR"); then
    echo "${app}: tetto non leggibile: $(cat "$AZ_ERR")" >&2
    failed=1
    continue
  fi
  echo "${app}: maximumInstanceCount=${max_instances}"
  if [ "$max_instances" != "$WANT_MAX" ]; then
    echo "${app}: il tetto e' ${max_instances}, fuori dalle finestre di misura deve essere ${WANT_MAX}." >&2
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "POSTFLIGHT FALLITO: almeno un'app non e' a ${WANT_MAX} istanze." >&2
  exit 1
fi
echo "POSTFLIGHT OK: tetto a ${WANT_MAX} su tutte e tre le app."
