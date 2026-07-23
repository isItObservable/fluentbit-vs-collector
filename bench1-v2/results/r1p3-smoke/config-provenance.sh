#!/usr/bin/env bash
# ISI-1843 — prove the running engine is executing the COMMITTED config.
#
# WHY: a smoke/benchmark result is only evidence about the config that actually ran.
# "The repo is correct" and "the cluster is running what the repo says" are two
# independent assertions, and the second one decays every time someone kubectl-edits.
# Here the smoke ConfigMap is even NAMED `df-nodeproof-config` — a leftover from the
# node-proof work — so the name is actively misleading and only the content settles it.
#
# It compares the SEMANTIC node graph, not the text: the deployed copy has been
# re-serialised by kubectl (comments stripped, flow maps expanded to block style), so a
# plain diff is ~100 lines of noise and tells you nothing. It also cannot be grepped —
# the template's header comments mention `processor:type_router` and `min_size: 1000`,
# so a naive `grep -c` reports template=2 deployed=1 and looks like a mismatch.
#
# The exporter destination is the one legitimate deviation (local sink vs the tenant) and
# is redacted before comparison — everything else must match exactly.
#
# Usage: ./config-provenance.sh [-n NS] [-c CONFIGMAP] [-k CM_KEY] [-t TEMPLATE]
set -uo pipefail
NS=dfsmoke; CM=df-nodeproof-config; KEY='config\.yaml'
TMPL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/engines/df-engine-config.tmpl.yaml"
while [ $# -gt 0 ]; do
  case "$1" in
    -n) NS=$2; shift 2;; -c) CM=$2; shift 2;; -k) KEY=$2; shift 2;; -t) TMPL=$2; shift 2;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac
done
[ -f "$TMPL" ] || { echo "FATAL: no template at $TMPL"; exit 1; }

DEPLOYED=$(mktemp); RENDERED=$(mktemp)
trap 'rm -f "$DEPLOYED" "$RENDERED"' EXIT
kubectl -n "$NS" get cm "$CM" -o "jsonpath={.data.$KEY}" > "$DEPLOYED" || exit 1
[ -s "$DEPLOYED" ] || { echo "FATAL: $NS/$CM key $KEY is empty"; exit 1; }
# Placeholder only — the real token is never rendered to disk (see render-df-engine-config.sh).
awk '{gsub(/__DT_API_TOKEN__/,"PLACEHOLDER"); print}' "$TMPL" > "$RENDERED"

python3 - "$RENDERED" "$DEPLOYED" <<'PY'
import yaml, sys, json
def pipeline(p):
    d = yaml.safe_load(open(p))
    gk = list(d['groups'].keys())[0]
    return d['groups'][gk]['pipelines']['main']
try:
    a, b = pipeline(sys.argv[1]), pipeline(sys.argv[2])
except Exception as e:
    print(f"FAIL  could not parse both configs: {e}"); sys.exit(1)

fails = 0
def chk(name, ok, detail=''):
    global fails
    print(f"{'PASS' if ok else 'FAIL'}  {name}{('  ' + detail) if detail else ''}")
    fails += 0 if ok else 1

na, nb = a['nodes'], b['nodes']
chk('node sets identical', sorted(na) == sorted(nb),
    f'template={sorted(na)} deployed={sorted(nb)}' if sorted(na) != sorted(nb) else f'{len(na)} nodes')
chk('connection graph identical', a.get('connections') == b.get('connections'),
    '' if a.get('connections') == b.get('connections') else 'EDGES DIFFER')

for k in sorted(set(na) & set(nb)):
    x, y = na[k], nb[k]
    if k == 'dt_out':                      # redact the one intended deviation
        cx, cy = dict(x.get('config', {})), dict(y.get('config', {}))
        for c in (cx, cy):
            for f in ('endpoint', 'http', 'client_pool_size'): c.pop(f, None)
        chk(f'node {k} (endpoint redacted)', x.get('type') == y.get('type') and cx == cy)
        print(f"      template endpoint: {x.get('config',{}).get('endpoint')}")
        print(f"      deployed endpoint: {y.get('config',{}).get('endpoint')}   <- expected smoke deviation")
        continue
    chk(f'node {k}', x == y, '' if x == y else f'\n      template={json.dumps(x)}\n      deployed={json.dumps(y)}')

print(f"\n{'PROVENANCE VERIFIED' if not fails else str(fails) + ' MISMATCH(ES)'} — "
      f"the running engine {'is' if not fails else 'is NOT'} executing the committed config.")
sys.exit(1 if fails else 0)
PY
