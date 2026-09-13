#!/usr/bin/env bash
#
# Pubblica il contenuto di frontend/ sulla Static Web App.
#
# Perche' non e' un job della pipeline di GitHub Actions come il resto.
# Collegare la SWA al repo (repositoryUrl nel Bicep) farebbe generare a Azure
# un workflow che deploya a ogni push sul branch: nel resto del progetto il
# deploy e' workflow_dispatch apposta, perche' un deploy involontario nel mezzo
# di un run di misura invalida la misura (D44). L'alternativa via Actions
# richiederebbe di mettere in GitHub il deployment token della SWA, che e' una
# credenziale di lunga durata: qui il token si legge da Azure al momento e non
# viene scritto da nessuna parte.
#
# Il frontend non fa parte del percorso misurato, quindi un deploy manuale non
# costa niente al metodo.
#
# Uso: ./scripts/deploy-frontend.sh [resource-group]
#
# Richiede: az CLI autenticata, npx (Node).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTENT_DIR="$REPO_ROOT/frontend"
RESOURCE_GROUP="${1:-rg-torinodotnet-demo}"

command -v az  >/dev/null || { echo "manca az CLI" >&2; exit 1; }
command -v npx >/dev/null || { echo "manca npx (Node)" >&2; exit 1; }

# index.html e' il file senza il quale la SWA pubblica una cartella vuota
# rispondendo 404, e lo farebbe senza che questo script fallisca.
[ -f "$CONTENT_DIR/index.html" ] || { echo "manca $CONTENT_DIR/index.html" >&2; exit 1; }

APP_NAME="$(az staticwebapp list \
  --resource-group "$RESOURCE_GROUP" \
  --query "[0].name" -o tsv)"

[ -n "$APP_NAME" ] || { echo "nessuna Static Web App in $RESOURCE_GROUP: manca il deploy del Bicep?" >&2; exit 1; }

echo "Static Web App: $APP_NAME (gruppo $RESOURCE_GROUP)"

TOKEN="$(az staticwebapp secrets list \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.apiKey" -o tsv)"

[ -n "$TOKEN" ] || { echo "deployment token non recuperato" >&2; exit 1; }

# --env production: senza, il contenuto finisce in un ambiente di preview con
# un hostname diverso, che il CORS dei worker non ammette.
npx --yes @azure/static-web-apps-cli deploy "$CONTENT_DIR" \
  --deployment-token "$TOKEN" \
  --env production

HOSTNAME="$(az staticwebapp show \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "defaultHostname" -o tsv)"

echo
echo "Pubblicato su: https://$HOSTNAME"
