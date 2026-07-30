#!/usr/bin/env bash
# ISI-1843 — read df_engine's internal counters and assert the arrow arm's invariants.
#
# WHY THIS EXISTS
#   ISI-1817 recorded "the admin port serves HTML, so there are no engine-side counters".
#   That is wrong. The HTML is a UI that polls
#     GET /api/v1/metrics?format=json&reset=false&keep_all_zeroes=true
#   which returns the full internal metric set, per node, per core. So the arrow arm DOES
#   have an engine-side liveness gate and does not have to rely on the sink alone.
#
# WHY ENGINE-SIDE AND NOT SINK-SIDE
#   "0 metrics at the sink" is equally satisfied by: a deliberate route, a dead engine, and
#   a generator that never sent metrics. Only signals.received.metrics > 0 AND
#   signals.routed.named.metrics == signals.received.metrics AND 0 at the sink says
#   "deliberate route". Prefer the counter that proves the MECHANISM.
#
# READING TRAP (cost me one false alarm)
#   The JSON carries one metric_set per (node, core). `mmsc` instruments expose
#   {min,max,sum,count}. min/max are NOT summable across sets — summing them made
#   flush.age.duration read as ~8s against a configured 1s. Aggregate `sum`/`count`
#   across sets; take min-of-min and max-of-max. Never add a min to a min.
#
# Usage: ./engine-counters.sh [-n NAMESPACE] [-d DEPLOY] [-o OUT.json] [--no-fetch FILE]
set -uo pipefail

NS=dfsmoke; DEPLOY=df-engine; OUT=/tmp/df-engine-counters.json; FETCH=1; LPORT=18080
while [ $# -gt 0 ]; do
  case "$1" in
    -n) NS=$2; shift 2;;
    -d) DEPLOY=$2; shift 2;;
    -o) OUT=$2; shift 2;;
    --no-fetch) FETCH=0; OUT=$2; shift 2;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac
done

if [ "$FETCH" = 1 ]; then
  kubectl -n "$NS" port-forward "deploy/$DEPLOY" ${LPORT}:8080 >/tmp/pf-engine-counters.log 2>&1 &
  PF=$!; trap 'kill $PF 2>/dev/null' EXIT
  for _ in $(seq 1 15); do sleep 1; curl -sf "http://127.0.0.1:${LPORT}/api/v1/metrics?format=json" -o /dev/null && break; done
  code=$(curl -s -o "$OUT" -w '%{http_code}' \
    "http://127.0.0.1:${LPORT}/api/v1/metrics?format=json&reset=false&keep_all_zeroes=true")
  if [ "$code" != "200" ]; then echo "FATAL: admin API returned HTTP $code (expected 200)"; exit 1; fi
fi

python3 - "$OUT" <<'PY'
import json, sys, collections
d = json.load(open(sys.argv[1]))

ctr = collections.Counter()            # (set, node, metric) -> summed counter value
mmsc = {}                              # (set, node, metric) -> {min,max,sum,count}
for s in d['metric_sets']:
    at = s.get('attributes', {}) or {}
    nid = at.get('node.id')
    node = nid.get('String') if isinstance(nid, dict) else (nid or '')
    for m in s.get('metrics', []):
        k = (s['name'], node, m['name'])
        v = m.get('value')
        if isinstance(v, dict):                    # mmsc: min/max/sum/count
            a = mmsc.setdefault(k, {'min': float('inf'), 'max': float('-inf'), 'sum': 0.0, 'count': 0})
            if v.get('count', 0):
                a['min'] = min(a['min'], v['min']); a['max'] = max(a['max'], v['max'])
            a['sum'] += v.get('sum', 0.0); a['count'] += v.get('count', 0)
        elif isinstance(v, (int, float)) and not isinstance(v, bool):
            ctr[k] += v

def c(sn, node, mn): return ctr.get((sn, node, mn), 0)
def agg(sn, node, mn): return mmsc.get((sn, node, mn))

R = 'processor.signal_type_router'
rx = {sig: c(R, 'router', f'signals.received.{sig}') for sig in ('logs', 'metrics', 'traces')}
named = {sig: c(R, 'router', f'signals.routed.named.{sig}') for sig in ('logs', 'metrics', 'traces')}
dflt = {sig: c(R, 'router', f'signals.routed.default.{sig}') for sig in ('logs', 'metrics', 'traces')}
started, completed = c('receiver.otlp', 'otlp_in', 'requests.started'), c('receiver.otlp', 'otlp_in', 'requests.completed')
exp = {s: c('exporter.pdata', 'dt_out', f'{s}.exported') for s in ('logs', 'traces', 'metrics')}

checks = []
def chk(name, ok, detail): checks.append((name, ok, detail))

# Liveness — the engine is receiving and the receiver is not stalling.
chk('receiver alive', started > 0, f'requests.started={started}')
chk('no stalled OTLP requests', started - completed <= 2,
    f'started={started} completed={completed} inflight={started-completed}')

# Routing — the whole point of the type_router change.
chk('router saw all three signals', all(v > 0 for v in rx.values()), f'received={rx}')
chk('every signal left by a NAMED port', named == rx, f'named={named} received={rx}')
chk('nothing fell through to default', sum(dflt.values()) == 0,
    f'default={dflt}  (a typo in outputs: silently falls back here and still "works")')

# The metrics drop is a route, not an absence — needs BOTH halves to be non-tautological.
chk('metrics DROP is a deliberate route', rx['metrics'] > 0 and named['metrics'] == rx['metrics'] and exp['metrics'] == 0,
    f"received.metrics={rx['metrics']} routed.named.metrics={named['metrics']} exporter.metrics.exported={exp['metrics']}")

# Parity chain actually ran on the signals that are kept.
for node, sig in (('enrich_logs', 'logs'), ('enrich_traces', 'traces')):
    up = c('processor.attributes', node, 'upserted.entries')
    chk(f'{node} enriched', up > 0, f'upserted.entries={up}')
chk('transform ran on logs', c('processor.transform', 'parity', 'msgs.transformed') > 0,
    f"msgs.transformed={c('processor.transform','parity','msgs.transformed')}")

# Batch alignment (change #3): the 1s timer must be what flushes, not the 1000-record size.
for bnode in ('batch_logs', 'batch_traces'):
    a = agg('otap.processor.batch', bnode, 'flush.age.duration')
    tim, siz = c('otap.processor.batch', bnode, 'flushes.timer'), c('otap.processor.batch', bnode, 'flushes.size')
    if a and a['count']:
        mean = a['sum'] / a['count'] / 1e9
        chk(f'{bnode} flush age ~1s', 0.95 <= mean <= 1.30,
            f"mean={mean:.3f}s min={a['min']/1e9:.3f}s max={a['max']/1e9:.3f}s n={a['count']} "
            f"timer_flushes={tim} size_flushes={siz}")
    else:
        chk(f'{bnode} flushed at all', False, 'no flush.age samples')
    chk(f'{bnode} no batching errors', c('otap.processor.batch', bnode, 'batching.errors') == 0
        and c('otap.processor.batch', bnode, 'dropped.conversion') == 0
        and c('otap.processor.batch', bnode, 'nacked.inbound.slots') == 0
        and c('otap.processor.batch', bnode, 'nacked.outbound.slots') == 0,
        f"errors={c('otap.processor.batch',bnode,'batching.errors')} "
        f"dropped.conversion={c('otap.processor.batch',bnode,'dropped.conversion')} "
        f"nacked_in={c('otap.processor.batch',bnode,'nacked.inbound.slots')} "
        f"nacked_out={c('otap.processor.batch',bnode,'nacked.outbound.slots')}")

# No metrics batch node may exist — metrics terminate at noop BEFORE any batching.
chk('no batch node on the metrics branch',
    not any(k[1].startswith('batch_metrics') for k in list(ctr) + list(mmsc)),
    'batch_metrics absent')

chk('exporter delivered', exp['logs'] > 0 and exp['traces'] > 0, f"exported={exp}")

# CONSERVATION — the only correct loss detector on this arm.
#   router.received != exporter.exported is EXPECTED here and is NOT loss: the 1s timer
#   coalesces inbound requests into outbound batches. Comparing those two directly
#   false-FAILs a healthy engine, and does it WORSE the busier the run gets.
#   The ratio MOVES WITH LOAD, so no fixed threshold can be right -- measured on the two
#   banked snapshots:
#     T+11m (~1 req/s):   1.01x logs (185->183), 1.01x traces (102->101)
#     T+26m (~4.5 req/s): 1.49x logs (2147->1440), 1.56x traces (1974->1269)
#   What must hold exactly, at any load, is the hand-off at each hop. That is the check.
for bnode, sig in (('batch_logs', 'logs'), ('batch_traces', 'traces')):
    cons = c('otap.processor.batch', bnode, f'consumed.batches.{sig}')
    prod = c('otap.processor.batch', bnode, f'produced.batches.{sig}')
    ratio = f'{cons/prod:.2f}x' if prod else 'n/a'
    chk(f'{sig}: router -> batch loses nothing', cons == rx[sig],
        f'router.received={rx[sig]} batch.consumed={cons}')
    chk(f'{sig}: batch -> exporter loses nothing', prod == exp[sig],
        f'batch.produced={prod} exporter.exported={exp[sig]}  (coalescing {ratio}, not loss)')

fails = 0
for name, ok, detail in checks:
    print(f"{'PASS' if ok else 'FAIL'}  {name:<42} {detail}")
    fails += 0 if ok else 1
print(f"\n{len(checks)-fails}/{len(checks)} PASS")
sys.exit(1 if fails else 0)
PY
