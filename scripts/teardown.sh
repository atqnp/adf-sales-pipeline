#!/usr/bin/env bash
# Delete everything the lab created (the whole resource group). Screenshot the
# pipeline canvas, Monitor runs and Data Flow graph for your portfolio first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lab.env"

read -r -p "Delete resource group '$RG' and everything in it? Type the name to confirm: " answer
[[ "$answer" == "$RG" ]] || { echo "Cancelled."; exit 1; }
az group delete -n "$RG" --yes --no-wait
echo "Deletion started; it finishes in the background in a few minutes."
