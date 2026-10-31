#!/usr/bin/env bash
# ============================================================================
# validate-app.sh — otel-demo APPLICATION-HEALTH gate (the "strange things"
# guard, step 1). Run this BEFORE validate-gate.sh and before any load/soak.
#
#   ./validate-app.sh
#
# A benchmark is only as honest as its load generator's target. A demo app that
# is pod-Running but only 500s produces beautiful, meaningless throughput. This
# gate proves the app is actually WORKING end to end:
#
#   1. frontend-proxy is deployed WITHOUT an Istio sidecar — assert the pod is
#      1/1, NOT 2/2. (The export hop must traverse the mesh from the engine, but
#      the proxy itself must not be meshed, or the probe measures the sidecar,
#      not the app.)
#   2. Core pages return 200.
#   3. A full browse → add-to-cart → checkout API journey returns 2xx/3xx.
#   4. frontend + checkout error-rate < ${APP_ERR_MAX:-2}% over the probe set.
#
# Env:
#   OTEL_DEMO_NS        otel-demo namespace            (default: otel-demo)
#   FE_LABEL            frontend-proxy pod label       (default: app.kubernetes.io/name=frontend-proxy)
#   APP_PROBES          journey iterations             (default: 30)
#   APP_ERR_MAX         max tolerated error-rate %     (default: 2)
#   LPORT               local port-forward port        (default: 18080; high port avoids clashes)
# ============================================================================
set -euo pipefail
OTEL_DEMO_NS="${OTEL_DEMO_NS:-otel-demo}"
FE_LABEL="${FE_LABEL:-app.kubernetes.io/name=frontend-proxy}"
APP_PROBES="${APP_PROBES:-30}"
APP_ERR_MAX="${APP_ERR_MAX:-2}"
LPORT="${LPORT:-18080}"
fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

echo "== otel-demo application-health gate (ns=$OTEL_DEMO_NS) =="

# ---- 1. frontend-proxy present and NOT meshed (1/1, not 2/2) ---------------
echo "[1/4] frontend-proxy ready and NOT Istio-meshed (expect READY 1/1)"
POD=$(kubectl -n "$OTEL_DEMO_NS" get pod -l "$FE_LABEL" -o name 2>/dev/null | head -1)
[ -z "$POD" ] && POD=$(kubectl -n "$OTEL_DEMO_NS" get pod -l app.kubernetes.io/component=frontend-proxy -o name 2>/dev/null | head -1)
if [ -z "$POD" ]; then
  bad "frontend-proxy pod not found"; fail=1
else
  READY=$(kubectl -n "$OTEL_DEMO_NS" get "$POD" -o jsonpath='{.status.containerStatuses[*].ready}' | tr ' ' '\n' | grep -c true || true)
  TOTAL=$(kubectl -n "$OTEL_DEMO_NS" get "$POD" -o jsonpath='{.status.containerStatuses[*].ready}' | wc -w)
  if [ "$TOTAL" -eq 1 ] && [ "$READY" -eq 1 ]; then
    ok "frontend-proxy READY 1/1 (no sidecar)"
  elif [ "$TOTAL" -ge 2 ]; then
    bad "frontend-proxy is $READY/$TOTAL — a sidecar is injected; probes would measure the mesh, not the app. Exclude frontend-proxy from mesh injection."; fail=1
  else
    bad "frontend-proxy not ready ($READY/$TOTAL)"; fail=1
  fi
fi

# ---- 2/3/4. journey over a port-forward ------------------------------------
if [ "$fail" -eq 0 ]; then
  kubectl -n "$OTEL_DEMO_NS" port-forward "$POD" "$LPORT:8080" >/tmp/validate-app-pf.log 2>&1 & PF=$!
  sleep 4
  BASE="http://127.0.0.1:$LPORT"
  code() { curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$@" 2>/dev/null || echo 000; }
  is2or3() { [[ "$1" =~ ^[23] ]]; }

  echo "[2/4] core pages return 200"
  for path in / /api/products; do
    c=$(code "$BASE$path")
    if is2or3 "$c"; then ok "GET $path -> $c"; else bad "GET $path -> $c"; fail=1; fi
  done

  echo "[3/4] browse -> add-to-cart -> checkout journey (2xx/3xx), $APP_PROBES iterations"
  errs=0; total=0
  # discover a real product id so the journey is representative
  PID=$(curl -s --max-time 8 "$BASE/api/products" 2>/dev/null | grep -oE '"id":"[^"]+"' | head -1 | cut -d'"' -f4)
  PID="${PID:-OLJCESPC7Z}"   # otel-demo canonical product id fallback
  SID="bench-$$"
  for i in $(seq 1 "$APP_PROBES"); do
    # browse
    c=$(code "$BASE/api/products/$PID");                 total=$((total+1)); is2or3 "$c" || errs=$((errs+1))
    # recommendations / currency (frontend fan-out)
    c=$(code "$BASE/api/recommendations?productIds=$PID"); total=$((total+1)); is2or3 "$c" || errs=$((errs+1))
    # add to cart
    c=$(code -X POST -H 'content-type: application/json' \
        -d "{\"userId\":\"$SID\",\"item\":{\"productId\":\"$PID\",\"quantity\":1}}" \
        "$BASE/api/cart");                                total=$((total+1)); is2or3 "$c" || errs=$((errs+1))
    # view cart
    c=$(code "$BASE/api/cart?sessionId=$SID");            total=$((total+1)); is2or3 "$c" || errs=$((errs+1))
    # checkout
    c=$(code -X POST -H 'content-type: application/json' \
        -d "{\"userId\":\"$SID\",\"email\":\"bench@example.com\",\"address\":{\"streetAddress\":\"1 Test\",\"city\":\"Test\",\"state\":\"TS\",\"country\":\"US\",\"zipCode\":\"00000\"},\"userCurrency\":\"USD\",\"creditCard\":{\"creditCardNumber\":\"4432801561520454\",\"creditCardCvv\":672,\"creditCardExpirationYear\":2030,\"creditCardExpirationMonth\":1}}" \
        "$BASE/api/checkout");                            total=$((total+1)); is2or3 "$c" || errs=$((errs+1))
  done
  kill "$PF" 2>/dev/null || true; wait "$PF" 2>/dev/null || true

  if [ "$total" -gt 0 ]; then
    rate=$(( errs * 100 / total ))
    echo "[4/4] error-rate = ${rate}% ($errs/$total)  (max ${APP_ERR_MAX}%)"
    if [ "$rate" -le "$APP_ERR_MAX" ]; then ok "journey error-rate ${rate}% <= ${APP_ERR_MAX}%"
    else bad "journey error-rate ${rate}% > ${APP_ERR_MAX}% — demo is erroring, NOT working"; fail=1; fi
  else
    bad "no journey probes executed"; fail=1
  fi
fi

echo "========================================================"
if [ "$fail" -ne 0 ]; then
  echo "APP GATE: FAIL — do NOT start load/soak. The app is not healthy; every downstream number would be a lie." >&2
  exit 1
fi
echo "APP GATE: PASS — otel-demo is working end to end. Proceed to validate-gate.sh."
