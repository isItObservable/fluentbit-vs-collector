#!/usr/bin/env bash
# ============================================================================
# B1-v2 — render the df_engine ConfigMap IN-CLUSTER
# ----------------------------------------------------------------------------
# df_engine has no ${env:VAR} expansion, so the Dynatrace token has to be
# literal inside its pipeline YAML. This script keeps that YAML off disk: it
# reads the token from the existing in-cluster secret, substitutes, and pipes
# straight into `kubectl apply`. Nothing with a token in it is ever written to
# _artifacts/ or to a temp file.
#
#   ./engines/render-df-engine-config.sh [namespace]
#
# Verify afterwards (still without printing the token):
#   kubectl -n default get cm bench-otel-arrow-native-config \
#     -o jsonpath='{.data.config\.yaml}' | grep -c 'Api-Token dt'
# ============================================================================
set -euo pipefail

NS="${1:-default}"
SECRET="${DT_SECRET:-gateway-dynatrace}"
CM="bench-otel-arrow-native-config"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPL="$HERE/df-engine-config.tmpl.yaml"

[[ -f "$TMPL" ]] || { echo "FATAL: missing $TMPL" >&2; exit 1; }

TOKEN="$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.apiToken}' | base64 -d)"
if [[ -z "$TOKEN" ]]; then
  echo "FATAL: no apiToken in secret $NS/$SECRET" >&2
  exit 1
fi

# Substitute with awk rather than sed so the token is never a shell-visible
# argument (it would show up in `ps` and in any command trace).
CONFIG="$(TOKEN="$TOKEN" awk '{gsub(/__DT_API_TOKEN__/, ENVIRON["TOKEN"]); print}' "$TMPL")"

kubectl create configmap "$CM" -n "$NS" \
  --from-literal=config.yaml="$CONFIG" \
  --dry-run=client -o yaml \
| kubectl label -f - --local --dry-run=client -o yaml \
    benchmark=logship benchmark.engine=otel-arrow-native \
| kubectl apply -f -

unset TOKEN CONFIG
echo "OK: configmap $NS/$CM rendered (token sourced from $NS/$SECRET, never written to disk)"
