#!/usr/bin/env bash
# ============================================================================
# ISI-1815 / ISI-1779 B1-v2 — set appProtocol on every app Service port
# ----------------------------------------------------------------------------
#   ./apps/appprotocol.sh            # patch + report
#   ./apps/appprotocol.sh --verify   # report only, non-zero if anything missing
#
# RUN THIS AFTER `helm upgrade otel-demo` AND AFTER `kubectl apply -f
# apps/hipster-shop-<engine>.yaml`, IN EVERY PHASE. It is idempotent.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# Istio decides a port's L7 protocol from `appProtocol`, falling back to the
# PREFIX of the port name (`<protocol>-<suffix>`). A port it cannot classify is
# treated as plain TCP: no HTTP filter chain, no HTTP/2, and therefore NO
# ISTIO-GENERATED SPANS for that hop.
#
# The otel-demo Helm chart hardcodes `name: tcp-service` for nearly every
# component (templates/_objects.tpl) and exposes no appProtocol field, so this
# CANNOT be expressed in the values file -- it has to be patched afterwards.
#
# Measured on observable-otelarrow before this fix, same window, both apps
# under comparable load:
#
#     hipster-shop   688,747 mesh spans     (ports named grpc-* / http-*)
#     otel-demo        6,820 mesh spans     (ports named tcp-service)
#
# ~100:1. The only otel-demo services contributing were flagd's `rpc`/`ofrep`
# ports -- the two that are not called `tcp-service`. CHECK 4 summed both
# namespaces and went green, which is exactly the aggregate-vs-per-entity
# blindness D12 already forced us to fix for pods. CHECK 4e now asserts mesh
# spans per namespace.
#
# ---------------------------------------------------------------------------
# HOW THE TABLE WAS DERIVED -- MEASURED, NOT ASSUMED
# ---------------------------------------------------------------------------
# Every entry below was probed live against the running service (raw HTTP/1.1
# GET, inspect the first bytes of the reply):
#
#   immediate HTTP/2 SETTINGS frame (0x00 0x00 xx 0x04)  -> grpc
#   HTTP/1.1 400 "sent to an HTTP/2 only endpoint"       -> grpc  (Kestrel)
#   a real HTTP/1.1 response with a body                 -> http
#
# That second case matters: `cart` answers HTTP/1.1 and is still gRPC-only, so
# a naive "did it speak HTTP/1.1" probe misclassifies it. Labelling cart as
# http would break every add-to-cart and checkout in the demo.
#
# Ports carrying a non-HTTP binary wire protocol (postgres, redis/valkey,
# kafka) are set to `tcp` EXPLICITLY. That is not a no-op: it pins the
# classification so Istio never protocol-sniffs them, and it documents that
# their lack of mesh spans is intended rather than another silent misconfig.
# ============================================================================
set -uo pipefail

VERIFY_ONLY=0
[[ "${1:-}" == "--verify" ]] && VERIFY_ONLY=1

# ns|service|port|appProtocol|evidence
TABLE=$(cat <<'EOF'
otel-demo|ad|8080|grpc|H2 SETTINGS frame
otel-demo|cart|8080|grpc|HTTP/1.1 400 "HTTP/2 only endpoint" (Kestrel)
otel-demo|checkout|8080|grpc|H2 SETTINGS frame
otel-demo|currency|8080|grpc|H2 SETTINGS frame
otel-demo|payment|8080|grpc|H2 SETTINGS frame
otel-demo|product-catalog|8080|grpc|H2 SETTINGS frame
otel-demo|product-reviews|3551|grpc|H2 SETTINGS frame
otel-demo|recommendation|8080|grpc|H2 SETTINGS frame
otel-demo|shipping|8080|grpc|tonic gRPC (oteldemo.ShippingService)
otel-demo|email|8080|http|Sinatra 404 (x-cascade: pass)
otel-demo|quote|8080|http|ReactPHP/1 404
otel-demo|frontend|8080|http|Next.js 200
otel-demo|frontend-proxy|8080|http|Envoy front proxy, no sidecar
otel-demo|image-provider|8081|http|nginx 403
otel-demo|llm|8000|http|Werkzeug/3.1.4 404
otel-demo|load-generator|8089|http|Locust web UI, no sidecar
otel-demo|flagd|8013|http|connect-go; already proxied L7 by Envoy
otel-demo|flagd|8016|http|OFREP over HTTP
otel-demo|flagd|4000|http|flagd-ui
otel-demo|postgresql|5432|tcp|postgres wire protocol
otel-demo|valkey-cart|6379|tcp|redis/valkey wire protocol
otel-demo|kafka|9092|tcp|kafka wire protocol
otel-demo|kafka|9093|tcp|kafka controller
hipster-shop|adservice|9555|grpc|Online Boutique proto
hipster-shop|cartservice|7070|grpc|Online Boutique proto
hipster-shop|checkoutservice|5050|grpc|Online Boutique proto
hipster-shop|currencyservice|7000|grpc|Online Boutique proto
hipster-shop|emailservice|5000|grpc|Online Boutique proto
hipster-shop|paymentservice|50051|grpc|Online Boutique proto
hipster-shop|productcatalogservice|3550|grpc|Online Boutique proto
hipster-shop|recommendationservice|8080|grpc|Online Boutique proto
hipster-shop|shippingservice|50051|grpc|Online Boutique proto
hipster-shop|frontend|80|http|Go net/http
hipster-shop|frontend-external|80|http|Go net/http (LoadBalancer)
hipster-shop|redis-cart|6379|tcp|redis wire protocol
EOF
)

patched=0; already=0; missing=0; absent=0

while IFS='|' read -r ns svc port want why; do
  [[ -z "${ns:-}" ]] && continue

  idx=$(kubectl -n "$ns" get svc "$svc" -o json 2>/dev/null \
    | python3 -c '
import json,sys
try: s=json.load(sys.stdin)
except Exception: sys.exit(1)
want=int(sys.argv[1])
for i,p in enumerate(s["spec"].get("ports",[])):
    if p.get("port")==want:
        print("%d %s" % (i, p.get("appProtocol") or ""))
        break
' "$port" 2>/dev/null)

  if [[ -z "$idx" ]]; then
    printf '  %-14s %-24s :%-6s ABSENT (service or port not found)\n' "$ns" "$svc" "$port"
    absent=$((absent+1)); continue
  fi

  i="${idx%% *}"; cur="${idx#* }"

  if [[ "$cur" == "$want" ]]; then
    already=$((already+1)); continue
  fi

  if [[ $VERIFY_ONLY -eq 1 ]]; then
    printf '  %-14s %-24s :%-6s want=%-5s got=%s\n' "$ns" "$svc" "$port" "$want" "${cur:-<none>}"
    missing=$((missing+1)); continue
  fi

  if kubectl -n "$ns" patch svc "$svc" --type=json \
       -p "[{\"op\":\"add\",\"path\":\"/spec/ports/$i/appProtocol\",\"value\":\"$want\"}]" >/dev/null 2>&1; then
    printf '  %-14s %-24s :%-6s -> %-5s (%s)\n' "$ns" "$svc" "$port" "$want" "$why"
    patched=$((patched+1))
  else
    printf '  %-14s %-24s :%-6s PATCH FAILED\n' "$ns" "$svc" "$port"
    missing=$((missing+1))
  fi
done <<< "$TABLE"

echo
if [[ $VERIFY_ONLY -eq 1 ]]; then
  echo "appProtocol verify: ok=$already wrong-or-missing=$missing absent=$absent"
  [[ $missing -eq 0 ]] || exit 1
else
  echo "appProtocol patch: patched=$patched already-correct=$already failed=$missing absent=$absent"
  [[ $missing -eq 0 ]] || exit 1
fi

# A Service port protocol change rewrites the listener; existing sidecar
# connections are not retroactively reclassified. Restart the app workloads
# after the first patch of a phase, or the first minutes of the run measure the
# old classification.
echo
echo "NOTE: restart app deployments after a protocol change, e.g."
echo "  kubectl -n otel-demo rollout restart deploy && kubectl -n hipster-shop rollout restart deploy"
