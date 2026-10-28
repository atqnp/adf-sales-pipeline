#!/usr/bin/env bash
# Connect the factory to this GitHub repo: collaboration branch main, root
# folder /adf. After this, ADF Studio authors in Git mode (feature branches,
# pull requests) and Publish writes ARM templates to the adf_publish branch.
#
# Usage: ./scripts/connect_git.sh [github-account] [repo-name]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lab.env"
ACCOUNT="${1:-atqnp}"
REPO="${2:-adf-sales-pipeline}"

SUB_ID="$(az account show --query id -o tsv)"
FACTORY_ID="/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.DataFactory/factories/$ADF"

az rest --method post -o none \
  --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.DataFactory/locations/$LOCATION/configureFactoryRepo?api-version=2018-06-01" \
  --body "{
    \"factoryResourceId\": \"$FACTORY_ID\",
    \"repoConfiguration\": {
      \"type\": \"FactoryGitHubConfiguration\",
      \"accountName\": \"$ACCOUNT\",
      \"repositoryName\": \"$REPO\",
      \"collaborationBranch\": \"main\",
      \"rootFolder\": \"/adf\",
      \"disablePublish\": false
    }
  }"

az datafactory show -n "$ADF" -g "$RG" --query repoConfiguration -o json
cat <<EOF

Connected. Open ADF Studio; if it asks, authorize the "AzureDataFactory" GitHub app for $ACCOUNT.
  https://adf.azure.com/en/home?factory=$FACTORY_ID
EOF
