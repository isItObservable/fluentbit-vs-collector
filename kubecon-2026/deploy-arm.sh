#!/usr/bin/env bash
# ============================================================================
# deploy-arm.sh — repeatable DEPLOY automation.
#
#   ./deploy-arm.sh --foundation            # one-time: storage + ns + backend operator
#   ./deploy-arm.sh <fluentbit|collector|arrow|otap>
#
# Serial single-engine model: deploy the apps (otel-demo + hipster-shop) wired to
# engine E, deploy engine E, leave the cluster with exactly ONE engine present.
# Run validate-app.sh + validate-gate.sh next; only start a run on GREEN gates.
#
# Idempotent: every step is apply/upgrade-install, safe to re-run.
# ============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
MF="$ART_DIR/manifests"
CMD="${1:?usage: deploy-arm.sh --foundation | <fluentbit|collector|arrow|otap>}"

# Name of the Secret (in ns `dynatrace`) holding your backend API URL + token.
# Create it yourself from dynatrace-secret.example.yaml — never commit real creds.
BACKEND_SECRET="${BACKEND_SECRET:-benchmark-cluster}"

deploy_foundation() {
  log "foundation: local-path StorageClass (v0.0.31)"
  kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml"
  kubectl patch storageclass local-path -p \
    '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' || true

  log "foundation: benchmark namespaces (no backend agent on the engine ns)"
  kubectl apply -f "$MF/00-namespaces.yaml"

  log "foundation: OpenTelemetry Operator (chart 0.126.1 — manages the Arm-B & Arm-D-edge collectors)"
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true
  helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
    -n opentelemetry-operator-system --create-namespace --version 0.126.1 \
    --set admissionWebhooks.certManager.enabled=false \
    --set admissionWebhooks.autoGenerateCert.enabled=true \
    --set manager.collectorImage.repository=otel/opentelemetry-collector-contrib \
    --wait --timeout 5m

  log "foundation: backend operator + collector (requires the backend secret — see dynatrace-secret.example.yaml)"
  if kubectl -n dynatrace get secret "$BACKEND_SECRET" >/dev/null 2>&1; then
    helm repo add dynatrace https://raw.githubusercontent.com/Dynatrace/dynatrace-operator/main/config/helm/repos/stable >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1 || true
    helm upgrade --install dynatrace-operator dynatrace/dynatrace-operator \
      -n dynatrace --create-namespace --version 1.11.0 --set installCRD=true --wait
    kubectl apply -f "$MF/10-dynakube.yaml"
  else
    log "  SKIP backend operator — secret dynatrace/$BACKEND_SECRET missing. Create it from dynatrace-secret.example.yaml, then re-run --foundation."
  fi
  log "foundation done. Deploy apps+engine with: deploy-arm.sh <arm>"
}

deploy_apps() {
  # otel-demo + hipster-shop, wired to export OTLP to the engine-under-test's
  # in-cluster service. ENGINE_OTLP is the per-arm collector service endpoint.
  local engine_otlp="$1"
  log "apps: otel-demo (OTLP -> $engine_otlp)"
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true
  helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
    -n otel-demo --create-namespace --version 0.42.6 \
    --set-string default.envOverrides[0].name=OTEL_EXPORTER_OTLP_ENDPOINT \
    --set-string default.envOverrides[0].value="$engine_otlp" \
    --set opentelemetry-collector.enabled=false \
    --wait --timeout 15m
  # IMPORTANT (the Arm B "zero spans" lesson): helm envOverrides do NOT always win over
  # each otel-demo component's hardcoded OTEL_EXPORTER_OTLP_ENDPOINT (component.env is
  # appended last). Force the endpoint onto every Deployment post-helm so OTLP actually
  # reaches the engine. Idempotent. This is exactly what validate-gate.sh step 3 catches.
  local gw_host gw_port proto
  gw_host="$(printf '%s' "$engine_otlp" | sed -E 's#^https?://##; s#:[0-9]+$##')"
  gw_port="$(printf '%s' "$engine_otlp" | sed -E 's#.*:##')"
  proto="http/protobuf"; [ "$gw_port" = "4317" ] && proto="grpc"
  for d in $(kubectl -n otel-demo get deploy -o name); do
    kubectl -n otel-demo set env "$d" \
      OTEL_EXPORTER_OTLP_ENDPOINT="$engine_otlp" \
      OTEL_EXPORTER_OTLP_PROTOCOL="$proto" >/dev/null 2>&1 || true
  done
  log "apps: hipster-shop / Online Boutique (OTLP -> $engine_otlp)"
  kubectl get ns hipster-shop >/dev/null 2>&1 || kubectl create ns hipster-shop
  kubectl label ns hipster-shop istio.io/dataplane-mode=ambient --overwrite
  log "  NOTE: apply your hipster-shop manifest set with COLLECTOR_SERVICE_ADDR / OTLP target = $engine_otlp"
}

case "$CMD" in
  --foundation) deploy_foundation ;;
  fluentbit|collector|arrow|otap)
    ARM="$CMD"; NS=$(arm_ns "$ARM")
    ENGINE_SVC="bench-${ARM}-otlp.${NS}.svc.cluster.local"
    log "=== deploy arm=$ARM (engine OTLP svc = ${ENGINE_SVC}:4318) ==="
    deploy_apps "http://${ENGINE_SVC}:4318"
    log "engine: apply $MF/arm-$ARM/  (engine-under-test $ARM, no backend agent on ns $NS)"
    if [ -d "$MF/arm-$ARM" ]; then kubectl apply -f "$MF/arm-$ARM/"
    else log "  engine manifest dir $MF/arm-$ARM missing — see manifests/README.md"; fi
    log "=== arm=$ARM deployed. Next: validate-app.sh && validate-gate.sh $ARM (both GREEN before run) ==="
    ;;
  *) echo "unknown command: $CMD" >&2; exit 2 ;;
esac
