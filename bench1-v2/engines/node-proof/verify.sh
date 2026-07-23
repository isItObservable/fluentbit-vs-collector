#!/usr/bin/env bash
# ============================================================================
# ISI-1843 — runtime proof of every node in df-engine-config.tmpl.yaml
# ----------------------------------------------------------------------------
# Usage:  KUBECONFIG=~/.config/capmox/observable-agentsandbox.kubeconfig \
#           ./verify.sh [--deploy]
#
#   --deploy   tear down and re-apply probe.yaml first, then wait for the
#              generators. Required for a first run or after editing the
#              template, because the assertions count records in the sinks'
#              whole log and a stale sink carries a previous run's records.
#
# Runs on `observable-agentsandbox`, NOT the measured cluster.
#
# THE POINT: `--validate-and-exit` is zero evidence for this engine. It accepts
# `processor:filter` with `config: {__bogus__: 1}`; it accepts a KQL transform
# that cannot read a field at runtime; the attributes processor documents that
# unsupported actions are "accepted for forward compatibility and ignored"; and
# `processor:type_router` validates clean with no `outputs:` declared at all.
# Every assertion below is therefore made against emitted bytes or the engine's
# own counters, never against the validator.
#
# TWO SOURCES OF TRUTH, deliberately:
#   SINK SIDE   what the engine put on the wire (collector debug/detailed)
#   ENGINE SIDE the engine's internal counters, /api/v1/metrics on the admin
#               port as JSON. (An earlier note in this campaign recorded "the
#               admin port serves HTML, so there are no counters to read" —
#               that is WRONG: the HTML is a UI that polls
#               /api/v1/metrics?format=json. Corrected here.)
#
# The engine side is what makes the negative assertions worth anything. "No
# metrics arrived at the sink" is equally consistent with "the router dropped
# them", "the generator never sent them" and "the engine crashed"; only
# `signals.received.metrics > 0 AND signals.routed.named.metrics > 0 AND
# sink metrics == 0` distinguishes a deliberate route from an absence.
#
# THE CONTROL (Step C) is the other half. The identical generator invocation is
# pointed straight at a SECOND sink with the engine bypassed. If the control
# does not show metrics AND does not show `log.file.path`, then the two
# negative assertions are tautologies and this script FAILS instead of passing
# — a check that cannot fail is not a check.
#
# The control has its own sink for a reason learned the hard way: the first
# version shared one sink, the control's 50 metric datapoints and 196
# `log.file.path` records landed in the same log as the engine's output, and
# three correct PASSes were reported as FAILs. Two streams, two sinks.
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")"
NS=dfnodeproof
rc=0

if [[ "${1:-}" == "--deploy" ]]; then
  echo "== --deploy: recreating the probe from scratch"
  kubectl delete -f probe.yaml --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl apply -f probe.yaml >/dev/null
  kubectl -n $NS rollout status deploy/sink         --timeout=180s
  kubectl -n $NS rollout status deploy/sink-control --timeout=180s
  kubectl -n $NS rollout status deploy/df-engine    --timeout=180s
  echo "   waiting for the engine to bind its receivers before generating"
  sleep 15
  for j in gen-traces gen-logs gen-metrics ctl-traces ctl-logs ctl-metrics; do
    kubectl -n $NS wait --for=condition=complete job/$j --timeout=180s >/dev/null 2>&1 \
      || echo "   note: job/$j did not report complete within 180s (telemetrygen traces"\
              "often stays Active after emitting; the counters below are what decide)"
  done
  echo "   letting the 1s batchers flush"
  sleep 10
fi
ok(){   printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad(){  printf '  \033[31mFAIL\033[0m  %s\n' "$*"; rc=1; }

# ---------------------------------------------------------------- drift guard
# The probe embeds a copy of the shipping template. If they diverge by anything
# other than the two exporter lines, the proof is about a config we do not ship.
echo "== Step 0: probe config vs shipping template"
python3 - <<'PY'
import sys, yaml, difflib
tmpl = yaml.safe_load(open('../df-engine-config.tmpl.yaml'))
probe = None
for d in yaml.safe_load_all(open('probe.yaml')):
    if d and d.get('kind')=='ConfigMap' and d['metadata']['name']=='df-nodeproof-config':
        probe = yaml.safe_load(d['data']['config.yaml'])
t = tmpl['groups']['default']['pipelines']['main']
p = probe['groups']['default']['pipelines']['main']
# neutralise the two intentional differences
for cfg in (t,p):
    cfg['nodes']['dt_out']['config']['endpoint'] = '<REDACTED>'
    cfg['nodes']['dt_out']['config']['http']['headers']['Authorization'] = '<REDACTED>'
a = yaml.safe_dump(t, sort_keys=True).splitlines()
b = yaml.safe_dump(p, sort_keys=True).splitlines()
if a == b:
    print('IDENTICAL')
else:
    print('DRIFT — the probe does not test the shipping config:')
    print('\n'.join(difflib.unified_diff(a, b, 'template', 'probe', lineterm='')))
    sys.exit(1)
PY
[ $? -eq 0 ] && ok "probe config == shipping template (modulo endpoint + token)" \
             || bad "probe config has DRIFTED from the shipping template"

echo
echo "== Step A: engine side — internal counters"
POD="$(kubectl -n $NS get pod -l app=df-engine -o name | head -1)"
kubectl -n $NS port-forward "$POD" 18080:8080 >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null' EXIT
sleep 4
curl -s -m 10 "http://127.0.0.1:18080/api/v1/metrics?format=json&reset=false&keep_all_zeroes=true" \
  -o /tmp/isi1843-engine-metrics.json
python3 - <<'PY' > /tmp/isi1843-counters.txt
import json, collections
d = json.load(open('/tmp/isi1843-engine-metrics.json'))
for target in ('processor.signal_type_router','processor.attributes','processor.transform'):
    tot = collections.Counter()
    for ms in d.get('metric_sets', []):
        if ms.get('name') != target: continue
        for m in ms.get('metrics', []):
            v = m.get('value', 0)
            if isinstance(v, dict): v = list(v.values())[0]
            try: tot[m.get('name') or m.get('brief')] += int(v)
            except Exception: pass
    for k, v in sorted(tot.items()):
        print(f"{target}.{k}={v}")
PY
get(){ grep -m1 "^$1=" /tmp/isi1843-counters.txt | cut -d= -f2; }
RX_M=$(get processor.signal_type_router.signals.received.metrics)
RT_M=$(get processor.signal_type_router.signals.routed.named.metrics)
RX_L=$(get processor.signal_type_router.signals.received.logs)
RX_T=$(get processor.signal_type_router.signals.received.traces)
DEL=$(get processor.attributes.deleted.entries)
UPS=$(get processor.attributes.upserted.entries)
TRF=$(get processor.transform.msgs.transformed)
echo "  router received: logs=$RX_L metrics=$RX_M traces=$RX_T"
echo "  attributes: upserted=$UPS deleted=$DEL   transform: msgs=$TRF"
[ "${RX_M:-0}" -gt 0 ] && ok "P3a router RECEIVED metrics (drop is a route, not an absence)" \
                       || bad "P3a router never saw a metric — the negative sink assertion would be vacuous"
[ "${RT_M:-0}" -gt 0 ] && ok "P3b router ROUTED metrics out the named 'metrics' port -> exporter:noop" \
                       || bad "P3b metrics were not routed to the named port"
[ "${DEL:-0}" -gt 0 ]  && ok "P5a processor:attribute actually DELETED $DEL entries (action: delete is NOT an ignored variant)" \
                       || bad "P5a deleted.entries == 0 — 'action: delete' silently ignored, parity step 4 is a capability gap"
[ "${UPS:-0}" -gt 0 ]  && ok "P4a processor:attribute upserted $UPS entries" \
                       || bad "P4a no upserts recorded"
[ "${TRF:-0}" -gt 0 ]  && ok "P6a processor:transform ran on $TRF message(s)" \
                       || bad "P6a transform never ran"

echo
echo "== Step B: sink side — what the engine put on the wire"
kubectl -n $NS logs deploy/sink -c otelcol --tail=-1 > /tmp/isi1843-sink.log 2>&1
SPANS=$(grep -c '^Span #' /tmp/isi1843-sink.log)
LOGS=$(grep -c '^LogRecord #' /tmp/isi1843-sink.log)
MDP=$(grep -c 'NumberDataPoint' /tmp/isi1843-sink.log)
LFP=$(grep -c 'log.file.path' /tmp/isi1843-sink.log)
SEV=$(grep -c 'SeverityText: ERROR' /tmp/isi1843-sink.log)
echo "  spans=$SPANS logs=$LOGS metric-datapoints=$MDP log.file.path=$LFP severity_ERROR=$SEV"
[ "$SPANS" -gt 0 ] && ok "P1 traces branch delivers ($SPANS spans)"        || bad "P1 no spans reached the exporter"
[ "$LOGS"  -gt 0 ] && ok "P2 logs branch delivers ($LOGS records)"         || bad "P2 no logs reached the exporter"
[ "$MDP"  -eq 0 ] && ok "P3 ZERO metric datapoints on the wire"            || bad "P3 $MDP metric datapoints escaped to the exporter"
[ "$LFP"  -eq 0 ] && ok "P5 log.file.path absent from every emitted record" || bad "P5 log.file.path survived on $LFP records"
[ "$SEV"  -eq "$LOGS" ] && ok "P6 severity_text=ERROR on $SEV/$LOGS log records" \
                        || bad "P6 severity_text=ERROR on only $SEV of $LOGS"
for k in benchmark.engine k8s.cluster.name benchmark.run; do
  n=$(grep -c -- "-> $k:" /tmp/isi1843-sink.log)
  [ "$n" -eq $((SPANS+LOGS)) ] && ok "P4 $k on $n/$((SPANS+LOGS)) records" \
                               || bad "P4 $k on only $n of $((SPANS+LOGS)) records"
done
PANIC=$(kubectl -n $NS logs deploy/df-engine -c df-engine 2>&1 | grep -cE 'panic|observed_error')
[ "$PANIC" -eq 0 ] && ok "P7 no panic / observed_error in the engine log" \
                   || bad "P7 $PANIC panic/observed_error lines in the engine log"

echo
echo "== Step C: the control — same generator, engine BYPASSED"
echo "   (without this, P3 and P5 are tautologies: an input that never carried"
echo "    metrics or log.file.path would make both pass on a dead engine)"
kubectl -n $NS logs deploy/sink-control -c otelcol --tail=-1 > /tmp/isi1843-control.log 2>&1
CSPANS=$(grep -c '^Span #' /tmp/isi1843-control.log 2>/dev/null || echo 0)
CMDP=$(grep -c 'NumberDataPoint' /tmp/isi1843-control.log 2>/dev/null || echo 0)
CLFP=$(grep -c 'log.file.path' /tmp/isi1843-control.log 2>/dev/null || echo 0)
echo "  control: spans=$CSPANS metric-datapoints=$CMDP log.file.path=$CLFP"
[ "$CMDP" -gt 0 ] && ok "C1 the generator DOES emit metrics the sink accepts -> P3 is falsifiable" \
                  || bad "C1 control shows no metrics — P3 proves nothing"
[ "$CLFP" -gt 0 ] && ok "C2 the generator DOES stamp log.file.path -> P5 is falsifiable" \
                  || bad "C2 control shows no log.file.path — P5 proves nothing"

echo
[ $rc -eq 0 ] && echo "ALL NODE PROOFS PASS" || echo "NODE PROOF FAILED"
exit $rc
