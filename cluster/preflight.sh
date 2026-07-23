#!/usr/bin/env bash
# ============================================================================
# Does this cluster qualify to host a VALID run?
# ----------------------------------------------------------------------------
#   ./cluster/preflight.sh
#
# This runs before anything is deployed. It is not a health check — it is a
# comparability check. A cluster that is too small does not fail the benchmark,
# it produces numbers: the apps serve fewer requests, the engine is handed less
# data, and the arm that happened to run when the node was busiest looks
# efficient. That is the single most expensive failure mode in this repo, and
# it is invisible in the results.
#
# Exit 0 = qualified. Exit 1 = one or more BLOCKERS. Warnings do not block.
# ============================================================================
set -uo pipefail

: "${KUBECONFIG:?set KUBECONFIG to the benchmark cluster (see .env.example)}"

RC=0
pass()  { printf '  ok    %s\n' "$*"; }
warn()  { printf '  warn  %s\n' "$*"; }
block() { printf '  BLOCK %s\n' "$*"; RC=1; }
hdr()   { printf '\n== %s\n' "$*"; }

# ---------------------------------------------------------------- environment
hdr "environment"
for v in CLUSTER_NAME DT_ENDPOINT_HOST; do
  if [[ -n "${!v:-}" ]]; then pass "$v = ${!v}"; else block "$v is unset — see .env.example"; fi
done
for b in kubectl helm python3; do
  command -v "$b" >/dev/null && pass "$b present" || block "$b not on PATH"
done
command -v dtctl >/dev/null && pass "dtctl present" \
  || warn "dtctl not on PATH — you can deploy and run, but not read results"
python3 -c 'import yaml' 2>/dev/null && pass "python3 pyyaml present" \
  || block "python3 pyyaml missing (teardown.sh G4 needs it): pip install pyyaml"

# ---------------------------------------------------------------- reachability
hdr "cluster"
if ! kubectl version -o json >/dev/null 2>&1; then
  block "cannot reach the cluster with this KUBECONFIG"
  echo; echo "PREFLIGHT FAILED"; exit 1
fi
SERVER="$(kubectl version -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null)"
pass "server ${SERVER:-unknown}"

# Reported cluster name must match CLUSTER_NAME, or every DQL query in
# benchmark/ silently returns nothing and the readout prints zeros.
if [[ -n "${CLUSTER_NAME:-}" ]]; then
  CTX="$(kubectl config current-context 2>/dev/null)"
  [[ "$CTX" == *"$CLUSTER_NAME"* ]] \
    && pass "current context '$CTX' mentions CLUSTER_NAME" \
    || warn "current context '$CTX' does not mention CLUSTER_NAME='$CLUSTER_NAME'.
        That is fine IF Dynatrace reports this cluster as '$CLUSTER_NAME'.
        If it does not, every benchmark/ query returns zero rows and the
        readout prints a clean, believable, entirely empty result."
fi

# ---------------------------------------------------------------- capacity
hdr "capacity"
read -r NODES CPU MEMGI SCHED < <(kubectl get nodes -o json | python3 - <<'PY'
import json,sys,re
d=json.load(sys.stdin)
def q(v):
    if v.endswith('m'): return float(v[:-1])/1000
    return float(v)
def mem(v):
    m=re.match(r'(\d+)([KMGT]i)?',v); n=float(m.group(1)); u=m.group(2) or ''
    return n*{'':1,'Ki':1024,'Mi':1024**2,'Gi':1024**3,'Ti':1024**4}[u]/1024**3
ns=d['items']
sched=[n for n in ns if not any(t.get('effect')=='NoSchedule' for t in (n['spec'].get('taints') or []))]
print(len(ns), round(sum(q(n['status']['allocatable']['cpu']) for n in sched),1),
      round(sum(mem(n['status']['allocatable']['memory']) for n in sched),1), len(sched))
PY
)
pass "$NODES node(s), $SCHED schedulable"
(( SCHED >= 3 )) && pass "schedulable nodes: $SCHED (>= 3)" \
  || block "only $SCHED schedulable node(s). The two apps plus Istio plus one
        engine do not fit on fewer than 3 without the engine competing with the
        load it is supposed to be measuring."
python3 -c "import sys; sys.exit(0 if float('$CPU') >= 10 else 1)" \
  && pass "allocatable CPU ${CPU} cores (>= 10)" \
  || block "allocatable CPU ${CPU} cores. Round 1 ran on 12 allocatable cores and
        had NO spare capacity; below ~10 the apps throttle and the arms stop
        being comparable."
python3 -c "import sys; sys.exit(0 if float('$MEMGI') >= 24 else 1)" \
  && pass "allocatable memory ${MEMGI} GiB (>= 24)" \
  || warn "allocatable memory ${MEMGI} GiB is below the 24 GiB Round 1 had."

# ---------------------------------------------------------------- prerequisites
hdr "prerequisites"
kubectl get ns istio-system >/dev/null 2>&1 \
  && pass "namespace istio-system exists" \
  || block "Istio is not installed — see docs/01-provision-cluster.md"
kubectl get deploy -n istio-system istiod >/dev/null 2>&1 \
  && pass "istiod present" || block "istiod not found in istio-system"
kubectl get crd telemetries.telemetry.istio.io >/dev/null 2>&1 \
  && pass "Istio Telemetry CRD present" || block "Telemetry CRD missing"
kubectl get ns dynatrace >/dev/null 2>&1 \
  && pass "namespace dynatrace exists" \
  || warn "namespace dynatrace not found — Kubernetes CPU/memory metrics come
        from the Dynatrace operator; without it there is nothing to read"
if kubectl -n "${NS_ENGINE:-default}" get secret "${DT_SECRET:-gateway-dynatrace}" >/dev/null 2>&1; then
  pass "Secret ${NS_ENGINE:-default}/${DT_SECRET:-gateway-dynatrace} present"
else
  block "Secret ${NS_ENGINE:-default}/${DT_SECRET:-gateway-dynatrace} (key apiToken) missing.
        Every engine reads its ingest token from it. See docs/02."
fi

# ---------------------------------------------------------------- contamination
hdr "contamination — anything else shipping telemetry from this cluster"
OTHER="$(kubectl get pods -A -o json 2>/dev/null | python3 - <<'PY'
import json,sys
d=json.load(sys.stdin)
pat=('otel','collector','fluent','vector','fluentd','datadog','logstash','filebeat')
out=[]
for p in d['items']:
    ns=p['metadata']['namespace']; n=p['metadata']['name']
    if ns in ('otel-demo','hipster-shop'): continue
    if n.startswith('bench-'): continue
    if any(k in n.lower() for k in pat): out.append(f"{ns}/{n}")
print("\n".join(sorted(out)))
PY
)"
if [[ -z "$OTHER" ]]; then
  pass "no other telemetry pipeline found"
else
  warn "other telemetry pods are running on this cluster:"
  sed 's/^/          /' <<<"$OTHER"
  cat <<'EOF'
        This does NOT invalidate a run, but it must be DISCLOSED and it must be
        constant across every arm. Round 1 of this benchmark ran with a parallel
        collector pipeline burning ~932 mCores — 5-8x the engine under test — on
        the same nodes. It was constant across both arms, so the comparison
        holds, but it is a plausible mechanism for the ~3.5% throughput gap
        between them. Either remove it before you start, or record it in
        results/RUN-REGISTER.md and leave it alone for the whole campaign.
EOF
fi

# ---------------------------------------------------------------- leftovers
hdr "leftovers from a previous run"
LEFT="$(kubectl get all -A -l benchmark=logship --no-headers 2>/dev/null | grep -c .)"
(( LEFT == 0 )) && pass "no benchmark=logship objects left over" \
  || block "$LEFT benchmark=logship object(s) still present — run benchmark/teardown.sh"
for ns in default otel-demo hipster-shop; do
  a="$(kubectl get ns "$ns" -o jsonpath='{.metadata.annotations.logship\.benchmark/run-lock}' 2>/dev/null)"
  [[ -z "$a" ]] || block "run-lock annotation still on ns/$ns: $a"
done

echo
if (( RC == 0 )); then echo "PREFLIGHT OK — this cluster can host a valid run."
else echo "PREFLIGHT FAILED — fix the BLOCK lines above before deploying."; fi
exit $RC
