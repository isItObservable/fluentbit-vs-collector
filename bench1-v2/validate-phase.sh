#!/usr/bin/env bash
# ============================================================================
# ISI-1821 / ISI-1779 B1-v2 — the phase validation gate (plan §4, +§5b check 6)
# ----------------------------------------------------------------------------
#   ./validate-phase.sh <engine>            # otel-collector | fluentbit-v5 | otel-arrow-native
#   ./validate-phase.sh <engine> --window 15m
#
# Run this after the smoke traffic and BEFORE the 120-minute timed run. Exit 0
# means all six checks passed and the phase is comparable to the other two.
# Any non-zero exit means the phase is NOT comparable — fix, re-smoke, re-run.
# Never start a 120-min run on a red gate; an unvalidated phase is worse than a
# missing one, because it looks like data.
#
# Output is a human-readable report on stdout plus a machine-readable summary
# line per check on stderr-free stdout:
#     CHECK <n> <PASS|FAIL> <name> <detail>
# so a phase issue can grep it into evidence without re-parsing prose.
#
# Requires: kubectl (KUBECONFIG -> observable-otelarrow), dtctl (context with
# Grail read on the oat05854 tenant).
# ============================================================================
set -uo pipefail

ENGINE="${1:-}"
WINDOW="15m"
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --window) WINDOW="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$ENGINE" in
  otel-collector|fluentbit-v5|otel-arrow-native) ;;
  *) echo "usage: $0 <otel-collector|fluentbit-v5|otel-arrow-native> [--window 15m]" >&2; exit 2 ;;
esac

ENGINE_NS="${ENGINE_NS:-default}"
APP_NS=(otel-demo hipster-shop)
# Every DQL query in this gate is scoped by cluster (board directive D12).
# k8s.workload.name and the k8s.* metric keys are NOT unique across the clusters
# reporting into this tenant — observable-kagent and observable-agentsandbox emit
# the same keys — so an unscoped query silently mixes in another cluster's series
# and can turn a dead phase green.
CLUSTER="${CLUSTER:-observable-otelarrow}"
EXPECTED_REPLICAS="${EXPECTED_REPLICAS:-1}"
FAILED=0
PASSED=0

# Sidecar exclusions (plan §4 check 3). otel-demo's load-generator and
# frontend-proxy are excluded by the Helm values; the ramp-job load drivers
# exclude themselves and are matched by their `ramp: isi1779` label.
EXCLUDE_RE='^(load-generator|loadgenerator|frontend-proxy|rampjob-)'

say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n=== %s ===\n' "$*"; }
ok()   { PASSED=$((PASSED+1)); printf 'CHECK %s PASS %s %s\n' "$1" "$2" "$3"; }
bad()  { FAILED=$((FAILED+1)); printf 'CHECK %s FAIL %s %s\n' "$1" "$2" "$3"; }

# dtctl -o json wraps results as {"ok":..,"result":{"records":[...]}} — the key
# is `records`, not `rows`.
#
# TIMEFRAMES: this gate runs live, immediately before the timed run, so it
# legitimately uses a relative `from:now()-N` — it is asking "is telemetry
# arriving right now". That is a choice, NOT a limitation. Absolute windows DO
# work on this tenant, but ONLY as a QUOTED string: from:"2026-07-23T09:14:07Z".
# Unquoted is a PARSE_ERROR and timestamp("...") fails with "has to be a long,
# but was a string" (ISI-1811, validated against oat05854). Do not copy the
# relative form into the post-run readout: the whole no-snapshot design (plan
# D8) depends on replaying a RUN-REGISTER window hours or days later, which a
# relative window cannot express.
dql() {
  dtctl query -f - -o json 2>/dev/null <<< "$1" \
    | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("[]"); raise SystemExit
r = d.get("result", d)
print(json.dumps(r.get("records", r if isinstance(r, list) else [])))'
}

# Grail returns numeric aggregates as JSON STRINGS ("4581", not 4581). Summing
# them without a cast silently yields 0 and a green check goes red — or worse,
# a red check goes green. Every numeric read from DQL goes through this.
dql_num() {
  # $1 = records JSON, $2 = field, $3 = optional filter field, $4 = filter value
  python3 -c '
import json, sys
rows = json.loads(sys.argv[1] or "[]")
field = sys.argv[2]
fkey = sys.argv[3] if len(sys.argv) > 3 else ""
fval = sys.argv[4] if len(sys.argv) > 4 else ""
total = 0
for r in rows:
    if fkey and str(r.get(fkey)) != fval:
        continue
    v = r.get(field) or 0
    try:
        total += float(v)
    except (TypeError, ValueError):
        pass
print(int(total))' "$1" "$2" "${3:-}" "${4:-}" 2>/dev/null || echo 0
}

say "ISI-1779 B1-v2 phase validation gate"
say "engine=$ENGINE  engine-ns=$ENGINE_NS  window=$WINDOW  $(date -u +%FT%TZ)"

# ---------------------------------------------------------------------------
# CHECK 1 — apps healthy
# ---------------------------------------------------------------------------
hdr "CHECK 1: apps healthy"
c1_detail=""
c1_fail=0
for ns in "${APP_NS[@]}"; do
  notready=$(kubectl -n "$ns" get deploy -o json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
out = []
for i in d.get("items", []):
    name = i["metadata"]["name"]
    want = i["spec"].get("replicas", 1)
    have = i.get("status", {}).get("readyReplicas", 0)
    if want and have != want:
        out.append("%s(%s/%s)" % (name, have, want))
print(",".join(out))')
  crash=$(kubectl -n "$ns" get pods -o json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
out = []
for p in d.get("items", []):
    if p.get("status", {}).get("phase") in ("Succeeded", "Failed"):
        continue
    name = p["metadata"]["name"]
    for cs in p.get("status", {}).get("containerStatuses", []) or []:
        w = (cs.get("state", {}).get("waiting") or {}).get("reason", "")
        if w in ("CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull"):
            out.append("%s:%s" % (name, w))
print(",".join(out))')
  # restarts in the last 5 min: any container whose lastState.terminated is recent
  recent=$(kubectl -n "$ns" get pods -o json 2>/dev/null | python3 -c '
import json, sys, datetime
d = json.load(sys.stdin)
now = datetime.datetime.now(datetime.timezone.utc)
out = []
for p in d.get("items", []):
    if p.get("status", {}).get("phase") in ("Succeeded", "Failed"):
        continue
    name = p["metadata"]["name"]
    for cs in p.get("status", {}).get("containerStatuses", []) or []:
        t = (cs.get("lastState", {}).get("terminated") or {}).get("finishedAt")
        if not t:
            continue
        ts = datetime.datetime.fromisoformat(t.replace("Z", "+00:00"))
        if (now - ts).total_seconds() < 300:
            out.append("%s/%s" % (name, cs["name"]))
print(",".join(out))')
  say "  $ns: notready=[${notready:-none}] crashloop=[${crash:-none}] restarts<5m=[${recent:-none}]"
  [[ -n "$notready$crash$recent" ]] && { c1_fail=1; c1_detail="$c1_detail $ns:${notready}${crash}${recent}"; }
done
if [[ $c1_fail -eq 0 ]]; then ok 1 apps-healthy "all deployments Ready in ${APP_NS[*]}"
else bad 1 apps-healthy "${c1_detail# }"; fi

# ---------------------------------------------------------------------------
# CHECK 2 — app spans in Dynatrace, from BOTH apps, non-zero each
# ---------------------------------------------------------------------------
hdr "CHECK 2: app spans in Dynatrace (both apps, window $WINDOW)"
# Spans in Grail carry service.namespace, NOT k8s.namespace.name — verified by
# sampling a real span on this tenant: `summarize by:{k8s.namespace.name}`
# returns a single null bucket for 44k spans. service.namespace is what the
# apps set via OTEL_RESOURCE_ATTRIBUTES, which is why both app manifests set it
# explicitly. Filtering on the wrong field returns zero and looks like the
# engine dropped everything.
q2="fetch spans, from:now()-${WINDOW}
| filter k8s.cluster.name == \"${CLUSTER}\"
| filter service.namespace == \"otel-demo\" or service.namespace == \"hipster-shop\"
| summarize spans = count(), by:{service.namespace}"
r2=$(dql "$q2")
say "  $r2"
c2_fail=0
for ns in "${APP_NS[@]}"; do
  n=$(dql_num "$r2" spans service.namespace "$ns")
  say "  $ns spans=$n"
  [[ "${n:-0}" -gt 0 ]] || c2_fail=1
done
if [[ $c2_fail -eq 0 ]]; then ok 2 app-spans "non-zero spans from both namespaces"
else bad 2 app-spans "one or both namespaces produced zero spans in $WINDOW"; fi

# ---------------------------------------------------------------------------
# CHECK 3 — istio-proxy sidecar everywhere except the documented exclusions
# ---------------------------------------------------------------------------
hdr "CHECK 3: istio-proxy sidecars (exclusions: load-generator, frontend-proxy, ramp jobs)"
c3_fail=0
for ns in "${APP_NS[@]}"; do
  read -r expect have missing < <(kubectl -n "$ns" get pods -o json 2>/dev/null | EXCLUDE_RE="$EXCLUDE_RE" python3 -c '
import json,os,re,sys
rx=re.compile(os.environ["EXCLUDE_RE"])
d=json.load(sys.stdin)
expect=have=0; missing=[]
for p in d.get("items",[]):
    m=p["metadata"]; name=m["name"]
    if p.get("status",{}).get("phase") in ("Succeeded","Failed"): continue
    if rx.match(name) or m.get("labels",{}).get("ramp")=="isi1779": continue
    expect+=1
    names=[c["name"] for c in p["spec"]["containers"]]
    if "istio-proxy" in names: have+=1
    else: missing.append(name)
print(expect, have, ",".join(missing) or "-")')
  say "  $ns: expected=$expect with-sidecar=$have missing=[$missing]"
  [[ "$expect" == "$have" && "$expect" -gt 0 ]] || c3_fail=1
done
if [[ $c3_fail -eq 0 ]]; then ok 3 sidecars "expected == actual in both namespaces"
else bad 3 sidecars "sidecar count mismatch (see missing list above)"; fi

# ---------------------------------------------------------------------------
# CHECK 4 — Istio-generated spans present, distinguishable from app SDK spans
# ---------------------------------------------------------------------------
hdr "CHECK 4: Istio/Envoy-generated spans (window $WINDOW)"
# Discriminated by benchmark.telemetry_source == "istio-mesh", a customTag the
# Telemetry CR sets and nothing else does. benchmark.engine CANNOT be used
# here: all three engines stamp it onto every record they touch, app spans
# included, so it is non-zero even with zero mesh spans — a false green.
q4="fetch spans, from:now()-${WINDOW}
| filter k8s.cluster.name == \"${CLUSTER}\"
| filter benchmark.telemetry_source == \"istio-mesh\"
| summarize mesh_spans = count(), by:{benchmark.engine}"
r4=$(dql "$q4")
say "  $r4"
n4=$(dql_num "$r4" mesh_spans)
say "  Istio-generated spans: $n4"
if [[ "${n4:-0}" -gt 0 ]]; then ok 4 istio-spans "$n4 mesh spans in $WINDOW"
else bad 4 istio-spans "no Istio-generated spans — check the Telemetry CR and that the namespaces are in SIDECAR mode (ztunnel/ambient emits none)"; fi

# ---------------------------------------------------------------------------
# CHECK 5 — engine healthy, non-zero accepted AND non-zero exported
# ---------------------------------------------------------------------------
hdr "CHECK 5: engine healthy with non-zero accepted + exported"
case "$ENGINE" in
  otel-collector)     SEL="app.kubernetes.io/instance=${ENGINE_NS}.bench-otel-collector" ;;
  fluentbit-v5)       SEL="app=bench-fluentbit-v5" ;;
  otel-arrow-native)  SEL="app=bench-otel-arrow-native" ;;
esac
POD=$(kubectl -n "$ENGINE_NS" get pods -l "$SEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
c5_fail=0
if [[ -z "$POD" ]]; then
  say "  no engine pod found for selector $SEL"
  c5_fail=1
else
  ready=$(kubectl -n "$ENGINE_NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[?(@.name!="istio-proxy")].ready}' 2>/dev/null)
  restarts=$(kubectl -n "$ENGINE_NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
  say "  pod=$POD ready=$ready restarts=${restarts:-?}"
  [[ "$ready" == *"true"* ]] || c5_fail=1

  # Counters. All three images are distroless — no shell, no curl inside the
  # pod — so scrape via port-forward from here rather than `kubectl exec`.
  accepted=0; exported=0
  case "$ENGINE" in
    otel-collector)
      kubectl -n "$ENGINE_NS" port-forward "pod/$POD" 18888:8888 >/dev/null 2>&1 &
      PF=$!; sleep 3
      M=$(curl -s --max-time 10 http://127.0.0.1:18888/metrics || true)
      kill $PF 2>/dev/null; wait $PF 2>/dev/null
      accepted=$(awk '/^otelcol_receiver_accepted_(spans|log_records|metric_points)/{s+=$2} END{printf "%.0f", s+0}' <<< "$M")
      exported=$(awk '/^otelcol_exporter_sent_(spans|log_records|metric_points)/{s+=$2} END{printf "%.0f", s+0}' <<< "$M")
      ;;
    fluentbit-v5)
      kubectl -n "$ENGINE_NS" port-forward "pod/$POD" 12020:2020 >/dev/null 2>&1 &
      PF=$!; sleep 3
      M=$(curl -s --max-time 10 http://127.0.0.1:12020/api/v1/metrics || true)
      kill $PF 2>/dev/null; wait $PF 2>/dev/null
      accepted=$(printf '%s' "$M" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
print(sum(v.get("records", 0) for v in d.get("input", {}).values()))' 2>/dev/null || echo 0)
      exported=$(printf '%s' "$M" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
print(sum(v.get("proc_records", 0) for v in d.get("output", {}).values()))' 2>/dev/null || echo 0)
      ;;
    otel-arrow-native)
      # df_engine's admin port serves an HTML dashboard, not a Prometheus
      # endpoint (paid for on 2026-07-21: /metrics/* is a 404). Its throughput
      # is therefore confirmed from the Dynatrace side, which is the only
      # counter that proves receive AND export in one number anyway.
      q5="fetch logs, from:now()-${WINDOW} | filter k8s.cluster.name == \"${CLUSTER}\" and benchmark.engine == \"otel-arrow-native\" | summarize n = count()"
      r5=$(dql "$q5"); say "  $r5"
      accepted=$(dql_num "$r5" n)
      exported=$accepted
      ;;
  esac
  say "  accepted=$accepted exported=$exported"
  [[ "${accepted:-0}" -gt 0 && "${exported:-0}" -gt 0 ]] || c5_fail=1

  errs=$(kubectl -n "$ENGINE_NS" logs "$POD" --since=10m 2>/dev/null | grep -ciE 'observed_error|permanent error|panic|failed to export' || true)
  say "  error-ish log lines in last 10m: ${errs:-0}"
  [[ "${errs:-0}" -eq 0 ]] || c5_fail=1
fi
if [[ $c5_fail -eq 0 ]]; then ok 5 engine-healthy "pod ready, accepted>0, exported>0, no export errors"
else bad 5 engine-healthy "see detail above"; fi

# ---------------------------------------------------------------------------
# CHECK 6 — pod census baseline (board directive D12, plan §5b)
# ---------------------------------------------------------------------------
# This check does NOT ask "did the pod restart". It cannot: a pod REPLACEMENT —
# reschedule, eviction, node drain, rollout — is invisible to
# dt.kubernetes.container.restarts, which counts in-place container restarts
# only. A replaced pod gets a new name and leaves that metric completely empty,
# while its newborn ~2 MiB working set poisons any workload-level min()/avg().
# Re-proven live on observable-otelarrow over 2026-07-20T11:00Z -> 2026-07-22T11:00Z:
# six pod names across two workloads, and zero restart datapoints.
#
# So the gate records the pod IDENTITY instead: name + creationTimestamp. That
# baseline goes into RUN-REGISTER.md at Start; the same capture at End is what
# makes "no pod was replaced during this window" falsifiable. Without it, a
# 120-minute number rests on an unprovable assumption.
hdr "CHECK 6: pod census baseline (record these in RUN-REGISTER.md)"
c6_fail=0
census=$(kubectl -n "$ENGINE_NS" get pods --no-headers \
  -o custom-columns='POD:.metadata.name,CREATED:.metadata.creationTimestamp,NODE:.spec.nodeName,PHASE:.status.phase' 2>/dev/null \
  | awk '$1 ~ /^bench-/ && $4 == "Running"' || true)
if [[ -z "$census" ]]; then
  say "  no running bench-* pod in ns $ENGINE_NS"
  c6_fail=1
else
  while read -r line; do say "  $line"; done <<< "$census"
  n6=$(printf '%s\n' "$census" | wc -l | tr -d ' ')
  say "  pods=$n6 expected-replicas=$EXPECTED_REPLICAS cluster=$CLUSTER"
  [[ "$n6" -eq "$EXPECTED_REPLICAS" ]] || c6_fail=1
fi
if [[ $c6_fail -eq 0 ]]; then
  ok 6 pod-census "$(printf '%s\n' "$census" | awk '{printf "%s@%s ", $1, $2}')pods=$EXPECTED_REPLICAS — copy into RUN-REGISTER.md and re-capture at End"
else
  bad 6 pod-census "engine pod count != expected replicas ($EXPECTED_REPLICAS) — do not start a run whose pod identity cannot be pinned"
fi

# ---------------------------------------------------------------------------
hdr "GATE RESULT"
say "passed=$PASSED failed=$FAILED engine=$ENGINE at $(date -u +%FT%TZ)"
if [[ $FAILED -gt 0 ]]; then
  say "GATE RED — do NOT start the 120-minute run. Fix, re-smoke, re-run this script."
  exit 1
fi
say "GATE GREEN — phase $ENGINE is comparable; start the timed run."
