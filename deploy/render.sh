#!/usr/bin/env bash
# ============================================================================
# B1-v2 — render the per-engine artifacts from _templates/
# ----------------------------------------------------------------------------
#   ./render.sh
#
# Emits, for each of the three engines:
#   istio/values-<engine>.yaml            istiod Helm values
#   istio/telemetry-<engine>.yaml         Telemetry CRs (tracing + accessLogging)
#   apps/otel-demo-values-<engine>.yaml   otel-demo Helm values
#   apps/hipster-shop-<engine>.yaml       fully resolved Online Boutique manifest
#
# The point of rendering rather than hand-maintaining nine files is that
# "only the engine service differs between the three" becomes something you
# can PROVE instead of something you assert:
#
#   diff <(sed 's/otel-collector/E/g;s/fluentbit-v5/E/g' istio/values-otel-collector.yaml) \
#        <(sed 's/otel-collector/E/g;s/fluentbit-v5/E/g' istio/values-fluentbit-v5.yaml)
#
# ./render.sh --check re-renders into a temp dir and fails if anything in the
# committed output drifted from the templates.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINES=(otel-collector fluentbit-v5 otel-arrow-native)
NS_ENGINE="${NS_ENGINE:-default}"

OUT="$HERE"
CHECK=0
if [[ "${1:-}" == "--check" ]]; then
  CHECK=1
  OUT="$(mktemp -d)"
  mkdir -p "$OUT/istio" "$OUT/apps"
  trap 'rm -rf "$OUT"' EXIT
fi

# Online Boutique v0.10.2: every instrumented service runs a container named
# `server`. redis-cart (container `redis`) is stock redis with no OTel SDK and
# loadgenerator is deleted outright, so neither is patched.
HS_SERVICES=(adservice cartservice checkoutservice currencyservice emailservice
             frontend paymentservice productcatalogservice recommendationservice
             shippingservice)

# ---------------------------------------------------------------------------
# ENABLE_TRACING — added 2026-07-23 (R1P2). DO NOT REMOVE.
# ---------------------------------------------------------------------------
# Online Boutique gates its OTel SDK on `ENABLE_TRACING == "1"`; without it the
# Go and Python services log `"Tracing disabled."` at startup and export NOTHING,
# no matter where COLLECTOR_SERVICE_ADDR points. It was absent from this file,
# from all three rendered manifests, and from the entire git history --
# `git log --all -S ENABLE_TRACING` returns empty.
#
# R1P1 nevertheless ran WITH hipster-shop app-SDK tracing on: 647,243 app spans
# in the 15-minute slice 2026-07-22T16:30-16:45Z, from exactly the five services
# below. Those pods carried the variable from a live, uncommitted mutation --
# most likely the hand-applied 2026-07-21 hipster-shop stack that `kubectl apply`
# merged over rather than replaced. R1P1's teardown deleted the Deployments, so
# R1P2's clean apply produced pods without it and hipster-shop app spans fell to
# ZERO while its mesh spans stayed at 134k. CHECK 2 caught it; nothing else would
# have, and the run would have compared fluent-bit against a collector arm that
# had ~40% more app-span load.
#
# The subset is deliberate and evidence-matched, not a guess: these are exactly
# the five service identities that emitted app-SDK spans in R1P1. The other five
# (adservice/Java, cartservice/C#, currencyservice + paymentservice/Node,
# shippingservice/Go) emitted zero there, so granting them the flag would ADD
# load R1P1 never had and break comparability in the other direction.
HS_TRACING_SERVICES=" checkoutservice emailservice frontend productcatalogservice recommendationservice "

hs_patches() {
  local engine="$1" svc="$2" d
  for d in "${HS_SERVICES[@]}"; do
    cat <<EOF
  - target:
      kind: Deployment
      name: $d
    patch: |
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: $d
      spec:
        template:
          spec:
            containers:
              - name: server
                env:
                  - name: COLLECTOR_SERVICE_ADDR
                    value: "$svc:4317"
                  - name: OTEL_EXPORTER_OTLP_ENDPOINT
                    value: "http://$svc:4317"
                  - name: OTEL_RESOURCE_ATTRIBUTES
                    value: "service.namespace=hipster-shop,benchmark.engine=$engine,benchmark.run=logship-b1v2"
EOF
    if [[ "$HS_TRACING_SERVICES" == *" $d "* ]]; then
      cat <<EOF
                  - name: ENABLE_TRACING
                    value: "1"
EOF
    fi
  done
}

render() {
  local tmpl="$1" dest="$2" engine="$3" svc="$4"
  sed -e "s|@@ENGINE@@|$engine|g" -e "s|@@ENGINE_SVC@@|$svc|g" "$tmpl" > "$dest"
}

for engine in "${ENGINES[@]}"; do
  svc="bench-${engine}.${NS_ENGINE}.svc.cluster.local"

  render "$HERE/_templates/istio-values.tmpl.yaml"     "$OUT/istio/values-${engine}.yaml"        "$engine" "$svc"
  render "$HERE/_templates/istio-telemetry.tmpl.yaml"  "$OUT/istio/telemetry-${engine}.yaml"     "$engine" "$svc"
  render "$HERE/_templates/otel-demo-values.tmpl.yaml" "$OUT/apps/otel-demo-values-${engine}.yaml" "$engine" "$svc"

  # hipster-shop: build the overlay in a scratch dir, then resolve it to a
  # single self-contained manifest so a phase never fetches from the network.
  work="$(mktemp -d)"
  render "$HERE/_templates/hipster-shop-kustomization.tmpl.yaml" "$work/kustomization.yaml" "$engine" "$svc"
  hs_patches "$engine" "$svc" > "$work/patches.frag"
  # Substitute via a file rather than inlining the fragment into the script:
  # the patch bodies contain quotes, and inlining them corrupts the quoting.
  python3 - "$work/kustomization.yaml" "$work/patches.frag" <<'PY'
import sys
kust, frag = sys.argv[1], sys.argv[2]
body = open(kust).read()
patches = open(frag).read().rstrip("\n")
open(kust, "w").write(body.replace("@@HS_PATCHES@@", patches))
PY
  rm -f "$work/patches.frag"

  {
    sed -n '1,45p' "$work/kustomization.yaml" | sed 's|^|# |; s|^# ##|##|'
    echo "# --- RESOLVED BY render.sh FROM THE OVERLAY ABOVE — DO NOT EDIT ---"
    kubectl kustomize "$work" 2>/dev/null || kubectl kustomize "$work"
  } > "$OUT/apps/hipster-shop-${engine}.yaml"
  rm -rf "$work"

  echo "rendered: $engine -> $svc"
done

if [[ $CHECK -eq 1 ]]; then
  drift=0
  for engine in "${ENGINES[@]}"; do
    for f in "istio/values-${engine}.yaml" "istio/telemetry-${engine}.yaml" \
             "apps/otel-demo-values-${engine}.yaml" "apps/hipster-shop-${engine}.yaml"; do
      if ! diff -q "$HERE/$f" "$OUT/$f" >/dev/null 2>&1; then
        echo "DRIFT: $f"
        drift=1
      fi
    done
  done
  [[ $drift -eq 0 ]] && echo "OK: committed artifacts match templates"
  exit $drift
fi
