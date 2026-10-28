#!/usr/bin/env bash
# Apply the SQL schema, then deploy everything in adf/ (linked services,
# datasets, data flows, pipelines, stopped triggers) into the factory.
#
# Usage: ./scripts/deploy.sh                                  deploy only
#        ./scripts/deploy.sh --run PL_Ingest_Sales [--run ...] deploy, then run each pipeline in order
#        ./scripts/deploy.sh --no-deploy --run PL_Ingest_Sales run without redeploying
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lab.env"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

RUNS=(); DEPLOY=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) RUNS+=("$2"); shift 2 ;;
    --no-deploy) DEPLOY=0; shift ;;
    *) echo "unknown argument: $1"; exit 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }

# adf/ is kept in ADF's Git layout ({"name", "properties"}) with placeholders.
# Deployed with az rest (raw ARM PUT): the az datafactory commands re-serialize
# through old SDK models and silently drop fields such as a SecureString password.
render() {
  python3 -I - "$1" "$2" <<'PY'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
for key in ("STORAGE", "SQL_SERVER", "SQL_DB", "SQL_ADMIN", "SQL_PASSWORD"):
    text = text.replace(f"__{key}__", os.environ[key])
json.dump({"properties": json.loads(text)["properties"]}, open(dst, "w"))
PY
}
export STORAGE SQL_SERVER SQL_DB SQL_ADMIN SQL_PASSWORD

FACTORY_URL="https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.DataFactory/factories/$ADF"

deploy() {  # deploy <adf subfolder> <ARM collection name>
  [[ -d "$ROOT/adf/$1" ]] || return 0
  for f in "$ROOT/adf/$1"/*.json; do
    n="$(basename "$f" .json)"; render "$f" "$BUILD/$n.json"
    az rest --method put --url "$FACTORY_URL/$2/$n?api-version=2018-06-01" \
      --body "@$BUILD/$n.json" -o none
    echo "  $n"
  done
}

run_pipeline() {  # run_pipeline <name>: start a run, wait, print activity results
  step "Running $1"
  local run_id status
  run_id="$(az datafactory pipeline create-run --factory-name "$ADF" -g "$RG" --name "$1" --query runId -o tsv)"
  echo "  run id $run_id"
  while :; do
    status="$(az datafactory pipeline-run show --factory-name "$ADF" -g "$RG" --run-id "$run_id" --query status -o tsv)"
    [[ "$status" == "Queued" || "$status" == "InProgress" ]] || break
    printf '  %s...\n' "$status"; sleep 20
  done
  echo "  final status: $status"
  az datafactory activity-run query-by-pipeline-run --factory-name "$ADF" -g "$RG" --run-id "$run_id" \
    --last-updated-after "$(date -u -v-1d +%Y-%m-%dT%H:%M:%SZ)" \
    --last-updated-before "$(date -u -v+1d +%Y-%m-%dT%H:%M:%SZ)" \
    --query "value[].{activity:activityName, status:status, rows:output.rowsCopied, error:error.message}" -o table
  [[ "$status" == "Succeeded" ]]
}

if (( DEPLOY )); then
  step "Applying sql/01_schema.sql"
  if command -v sqlcmd >/dev/null; then
    SQLCMDPASSWORD="$SQL_PASSWORD" sqlcmd -S "$SQL_SERVER.database.windows.net" -d "$SQL_DB" \
      -U "$SQL_ADMIN" -b -i "$ROOT/sql/01_schema.sql"
  else
    echo "sqlcmd not found (brew install sqlcmd); run sql/01_schema.sql in the Portal Query editor first."
  fi

  step "Linked services";            deploy linkedService linkedservices
  step "Datasets";                   deploy dataset datasets
  step "Data flows";                 deploy dataflow dataflows
  step "Pipelines";                  deploy pipeline pipelines
  step "Triggers (created stopped)"; deploy trigger triggers
fi

for p in "${RUNS[@]+"${RUNS[@]}"}"; do run_pipeline "$p"; done
