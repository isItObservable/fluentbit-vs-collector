#!/usr/bin/env bash
# ============================================================================
# ISI-1949 B1-v2 OTAP arm Config A — render the df_engine RELAY ConfigMap
# IN-CLUSTER (token never touches disk). Mirrors engines/render-df-engine-config.sh.
#
#   ./engines/render-df-engine-otap-relay.sh [namespace]
#
# Verify afterwards (without printing the token):
#   kubectl -n default get cm bench-df-engine-otap-config \
#     -o jsonpath='{.data.config\.yaml}' | grep -c 'Api-Token dt'
# ============================================================================
set -euo pipefail

NS="${1:-default}"
SECRET="${DT_SECRET:-gateway-dynatrace}"
CM="bench-df-engine-otap-config"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPL="$HERE/df-engine-otap-relay.tmpl.yaml"

[[ -f "$TMPL" ]] || { echo "FATAL: missing $TMPL" >&2; exit 1; }

TOKEN="$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.apiToken}' | base64 -d)"
if [[ -z "$TOKEN" ]]; then
  echo "FATAL: no apiToken in secret $NS/$SECRET" >&2
  exit 1
fi

# awk (not sed) so the token is never a shell-visible argument.
CONFIG="$(TOKEN="$TOKEN" awk '{gsub(/__DT_API_TOKEN__/, ENVIRON["TOKEN"]); print}' "$TMPL")"

kubectl create configmap "$CM" -n "$NS" \
  --from-literal=config.yaml="$CONFIG" \
  --dry-run=client -o yaml \
| kubectl label -f - --local --dry-run=client -o yaml \
    benchmark=isi1779 benchmark.engine=otap-config-a benchmark.component=relay \
| kubectl apply -f -

unset TOKEN CONFIG
echo "OK: configmap $NS/$CM rendered (token sourced from $NS/$SECRET, never written to disk)"
