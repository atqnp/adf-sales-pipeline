#!/usr/bin/env bash
# Module 0: provision the ADF lab in one resource group.
#   rg-adf-lab -> ADLS Gen2 (raw, curated) + Azure SQL (serverless) + Data Factory V2
#   + Storage Blob Data Contributor for the factory's managed identity
#   + sample CSVs uploaded to raw/landing/
#
# Prereqs: brew install azure-cli && az login
# Usage:   ./scripts/setup.sh            (re-runnable; existing resources are reused)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/lab.env"

# Names are kept in lab.env so reruns and teardown use the same ones.
if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
else
  SUFFIX="$(openssl rand -hex 3 | cut -c1-5)"
  LOCATION="${LOCATION:-japaneast}"
  RG="rg-adf-lab"
  STORAGE="stadflab${SUFFIX}"            # globally unique, lowercase, 3-24 chars
  SQL_SERVER="sql-adf-lab-${SUFFIX}"     # globally unique
  SQL_DB="sqldb-sales"
  SQL_ADMIN="sqladminuser"
  SQL_PASSWORD="Adf!$(openssl rand -hex 10)"
  ADF="adf-sales-lab-${SUFFIX}"          # factory names are globally unique too
  umask 077
  cat >"$ENV_FILE" <<EOF
LOCATION=$LOCATION
RG=$RG
STORAGE=$STORAGE
SQL_SERVER=$SQL_SERVER
SQL_DB=$SQL_DB
SQL_ADMIN=$SQL_ADMIN
SQL_PASSWORD='$SQL_PASSWORD'
ADF=$ADF
EOF
  echo "Saved names and SQL password to lab.env (keep it out of Git)."
fi

step() { printf '\n==> %s\n' "$*"; }

step "Checking Azure login"
az account show --query "{subscription:name, user:user.name}" -o table

step "Registering resource providers (first run on a new subscription can take a minute)"
for ns in Microsoft.Storage Microsoft.Sql Microsoft.DataFactory; do
  az provider register --namespace "$ns" --wait -o none
done
az extension add --name datafactory --upgrade --only-show-errors -o none

step "Resource group $RG ($LOCATION)"
az group create -n "$RG" -l "$LOCATION" -o none

step "ADLS Gen2 storage account $STORAGE (hierarchical namespace on)"
az storage account create -n "$STORAGE" -g "$RG" -l "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 --hns true \
  --min-tls-version TLS1_2 --allow-blob-public-access false -o none
KEY="$(az storage account keys list -n "$STORAGE" -g "$RG" --query '[0].value' -o tsv)"
for c in raw curated; do
  az storage fs create -n "$c" --account-name "$STORAGE" --account-key "$KEY" -o none 2>/dev/null || true
done

step "Uploading sample CSVs to raw/landing/"
[[ -f "$ROOT/data/orders.csv" ]] || python3 -I "$ROOT/scripts/generate_data.py"
az storage blob upload-batch -d raw --destination-path landing -s "$ROOT/data" \
  --pattern "*.csv" --account-name "$STORAGE" --account-key "$KEY" --overwrite -o none

step "Azure SQL server $SQL_SERVER"
if ! az sql server show -n "$SQL_SERVER" -g "$RG" -o none 2>/dev/null; then
  az sql server create -n "$SQL_SERVER" -g "$RG" -l "$LOCATION" \
    -u "$SQL_ADMIN" -p "$SQL_PASSWORD" -o none
fi

step "Firewall: allow Azure services + your current IP"
az sql server firewall-rule create -g "$RG" -s "$SQL_SERVER" -n AllowAzureServices \
  --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 -o none
MY_IP="$(curl -fsS -m 10 https://api.ipify.org || curl -fsS -m 10 https://ifconfig.me || true)"
if [[ -n "$MY_IP" ]]; then
  az sql server firewall-rule create -g "$RG" -s "$SQL_SERVER" -n MyClientIP \
    --start-ip-address "$MY_IP" --end-ip-address "$MY_IP" -o none
else
  echo "Could not detect your IP; add it in Portal > SQL server > Networking."
fi

step "Database $SQL_DB (free offer if available, else serverless with auto-pause)"
if ! az sql db show -n "$SQL_DB" -s "$SQL_SERVER" -g "$RG" -o none 2>/dev/null; then
  az sql db create -n "$SQL_DB" -s "$SQL_SERVER" -g "$RG" \
    --edition GeneralPurpose --compute-model Serverless --family Gen5 --capacity 2 \
    --use-free-limit --free-limit-exhaustion-behavior AutoPause -o none \
  || { echo "Free offer not available; creating serverless (0.5-1 vCore, auto-pause 60 min)."
       az sql db create -n "$SQL_DB" -s "$SQL_SERVER" -g "$RG" \
         --edition GeneralPurpose --compute-model Serverless --family Gen5 --capacity 1 \
         --min-capacity 0.5 --auto-pause-delay 60 --backup-storage-redundancy Local -o none; }
fi

step "Data Factory $ADF (V2, system-assigned managed identity)"
az datafactory create -n "$ADF" -g "$RG" -l "$LOCATION" -o none
ADF_PRINCIPAL="$(az datafactory show -n "$ADF" -g "$RG" --query identity.principalId -o tsv)"
if [[ -z "$ADF_PRINCIPAL" ]]; then
  echo "Factory has no managed identity; enable it in Portal > Data factory > Managed identities, then rerun."
  exit 1
fi

step "Granting Storage Blob Data Contributor to the factory's managed identity"
STORAGE_ID="$(az storage account show -n "$STORAGE" -g "$RG" --query id -o tsv)"
az role assignment create --assignee-object-id "$ADF_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" --scope "$STORAGE_ID" -o none 2>/dev/null \
  || echo "(role assignment already exists)"

SUB_ID="$(az account show --query id -o tsv)"
cat <<EOF

Done. Values you will type into ADF Studio:
  ADLS Gen2 URL      https://$STORAGE.dfs.core.windows.net
  SQL server         $SQL_SERVER.database.windows.net
  SQL database       $SQL_DB
  SQL user           $SQL_ADMIN   (password is in lab.env)
  Factory principal  $ADF_PRINCIPAL

Next:
  1. Open the Portal > SQL database $SQL_DB > Query editor, sign in, run sql/01_schema.sql
  2. Open ADF Studio: https://adf.azure.com/en/home?factory=/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.DataFactory/factories/$ADF
  3. When finished with the lab: ./scripts/teardown.sh
EOF
