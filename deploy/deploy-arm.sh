#!/usr/bin/env bash
# ============================================================================
# Deploy ONE benchmark arm, in the one order that produces a comparable run.
# ----------------------------------------------------------------------------
#   ENGINE=otel-collector ./deploy/deploy-arm.sh
#   ENGINE=fluentbit-v5   ./deploy/deploy-arm.sh
#   ENGINE=otel-arrow-native ./deploy/deploy-arm.sh
#
# The order is not stylistic. Steps 3-6 each undo something an earlier step did
# if they are run out of sequence:
#
#   * `helm upgrade otel-demo` RECREATES the component Services, wiping the
#     appProtocol patch — so step 3 must follow step 2 every single time.
#   * istiod re-reads meshConfig only on restart; `helm upgrade --wait` reports
#     success without rolling it, leaving a control plane that never saw the new
#     config and looks perfectly healthy.
#   * Sidecars pick up the new providers and the new port classification only
#     when the app pods restart.
#
# Skipping any of them does not fail loudly. It produces a run that is missing
# a whole class of telemetry and still looks like data — which is worse than a
# run that did not happen.
#
# This script does NOT start load and does NOT run the gate. Run
# benchmark/validate-phase.sh next; all six checks must pass first.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="${ENGINE:?set ENGINE to otel-collector | fluentbit-v5 | otel-arrow-native}"
: "${KUBECONFIG:?set KUBECONFIG to the benchmark cluster (see .env.example)}"
: "${CLUSTER_NAME:?set CLUSTER_NAME (see .env.example)}"
: "${DT_ENDPOINT_HOST:?set DT_ENDPOINT_HOST (see .env.example)}"
NS_ENGINE="${NS_ENGINE:-default}"

case "$ENGINE" in
  otel-collector|fluentbit-v5|otel-arrow-native) ;;
  *) echo "unknown ENGINE '$ENGINE'" >&2; exit 2 ;;
esac

# Substitute the two environment placeholders and nothing else. A blanket
# `envsubst` would also eat OTTL expressions and Fluent Bit's own ${} syntax,
# which is how a config silently loses a processor.
render_manifest() {
  sed -e "s|__CLUSTER_NAME__|${CLUSTER_NAME}|g" \
      -e "s|__DT_ENDPOINT_HOST__|${DT_ENDPOINT_HOST}|g" "$1"
}

step() { printf '\n== %s\n' "$*"; }

# ---------------------------------------------------------------- 1. engine
step "1/6 engine: $ENGINE -> namespace $NS_ENGINE"
render_manifest "$HERE/engines/${ENGINE}.yaml" | kubectl apply -n "$NS_ENGINE" -f -
if [[ "$ENGINE" == "otel-arrow-native" ]]; then
  # df_engine has no ${env:VAR} expansion, so its pipeline config is rendered
  # in-cluster from the Secret and never written to disk with a token in it.
  "$HERE/engines/render-df-engine-config.sh" "$NS_ENGINE"
fi

# ---------------------------------------------------------------- 2. apps
step "2/6 apps: otel-demo + hipster-shop, pointed at this engine"
helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
  --version 0.40.10 -n otel-demo --create-namespace \
  -f "$HERE/apps/otel-demo-values-${ENGINE}.yaml" --wait
kubectl apply -f "$HERE/apps/hipster-shop-${ENGINE}.yaml"

# ---------------------------------------------------------------- 3. appProtocol
step "3/6 appProtocol on every app Service port — MANDATORY after step 2"
"$HERE/apps/appprotocol.sh"

# ---------------------------------------------------------------- 4. ns labels
step "4/6 namespace labels: sidecars in, Dynatrace pod injection out"
kubectl label ns otel-demo hipster-shop istio-injection=enabled --overwrite
kubectl label ns otel-demo hipster-shop oneagent=false --overwrite

# ---------------------------------------------------------------- 5. istio
step "5/6 istiod values + Telemetry CR"
helm upgrade istiod istio/istiod -n istio-system \
  -f "$HERE/istio/values-${ENGINE}.yaml" --wait
kubectl rollout restart deploy/istiod -n istio-system
kubectl rollout status  deploy/istiod -n istio-system --timeout=5m
kubectl apply -f "$HERE/istio/telemetry-${ENGINE}.yaml"

# ---------------------------------------------------------------- 6. restart
step "6/6 restart the apps so sidecars pick up the new mesh config"
kubectl -n otel-demo    rollout restart deploy
kubectl -n hipster-shop rollout restart deploy

cat <<EOF

Arm '$ENGINE' deployed.

A mass restart on a cluster with no spare CPU can appear to deadlock:
single-replica Deployments default to maxSurge=1/maxUnavailable=0, so the new
pod cannot schedule until the old one frees CPU, and the old one will not go
until the new one is Ready. It resolves within a few minutes. If it does not,
delete the old-generation pods rather than adding capacity mid-campaign.

Next:
  ./benchmark/validate-phase.sh $ENGINE --window 15m   # all 6 checks must pass
  ./benchmark/attr-landing.sh   $ENGINE --window 15m   # per-signal, diagnostic
EOF
