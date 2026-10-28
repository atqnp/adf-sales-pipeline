#!/usr/bin/env bash
# Delete everything the lab created (the whole resource group). Screenshot the
# pipeline canvas, Monitor runs and Data Flow graph for your portfolio first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lab.env"

read -r -p "Delete resource group '$RG' and everything in it? Type the name to confirm: " answer
[[ "$answer" == "$RG" ]] || { echo "Cancelled."; exit 1; }

# A deleted Key Vault stays soft-deleted (name reserved) unless purged.
if [[ -n "${KEYVAULT:-}" ]] && az keyvault show -n "$KEYVAULT" -o none 2>/dev/null; then
  az keyvault delete -n "$KEYVAULT" -g "$RG" -o none
  az keyvault purge -n "$KEYVAULT" -o none && echo "Key Vault $KEYVAULT deleted and purged."
fi

az group delete -n "$RG" --yes --no-wait
echo "Deletion started; it finishes in the background in a few minutes."
