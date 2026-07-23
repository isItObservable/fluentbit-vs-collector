#!/usr/bin/env bash
# ============================================================================
# ISI-1779 B1-v2 — PER-SIGNAL attribute-landing probe.
#
#   ./results/attr-landing.sh <engine> [--window 15m]
#   ./results/attr-landing.sh <engine> --from <utc> --to <utc>
#   ./results/attr-landing.sh --selftest        # replay the R1P2 finding
#
# Answers one question, separately for spans / logs / metrics:
#
#   "Does k8s.cluster.name actually land on THIS signal from THIS engine —
#    i.e. is a cluster-scoped filter safe to read for this arm?"
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS (ISI-1817 pre-flight, 2026-07-23)
# ---------------------------------------------------------------------------
# R1P2 found that Fluent Bit lands k8s.cluster.name on spans but NOT on logs —
# 1,813,982 log records tagged benchmark.engine=fluentbit-v5, every one with
# k8s.cluster.name null, with zero processor errors reported. The dashboard's
# log tiles therefore read 0 for an arm that was delivering MORE logs than the
# collector.
#
# The lesson was then written down as "spans are fine, logs are not". That is
# the Fluent-Bit-specific FINDING, not the generalisable one. k8s.cluster.name
# is stamped BY THE ENGINE, and each engine stamps it with a different
# processor. What R1P2 actually proved is that a single engine can land an
# attribute on one signal and silently drop it on another — so the property has
# to be MEASURED per signal per engine, never inherited from the previous arm.
#
# df_engine's attribute processor is a completely different implementation and
# is unproven on every signal. Hence this probe runs at GATE time, before the
# 120-minute run, and its verdict goes in the register row — so the readout is
# known-trustworthy in advance instead of being reinterpreted afterwards.
#
# This is a READ-TIME diagnostic. It never proposes a config change: the
# telemetry config is frozen for the campaign (corrections ship in
# results/service-key.dql), or the engine stops being the only variable.
#
# ---------------------------------------------------------------------------
# WHAT THE VERDICTS MEAN
# ---------------------------------------------------------------------------
#   SAFE    — attribute present on ~all tagged records. A cluster-scoped filter
#             reads correctly for this signal. Keep the filter: it is the only
#             guard against k8s.workload.name colliding across clusters on this
#             shared tenant.
#   UNSAFE  — attribute missing on some or all tagged records. A cluster-scoped
#             filter UNDER-COUNTS or zeroes this signal. Read it filtered on
#             benchmark.engine alone (campaign-unique; nothing outside this
#             benchmark ever sets it) and correct the dashboard tile before
#             anyone reads it.
#   NO DATA — signal absent for this engine in this window. NOT a pass. This is
#             the CHECK 5b condition, and it is reported as its own state
#             rather than being collapsed into SAFE — "did not run" must never
#             render as "passed" (ISI-1830).
# ============================================================================
set -euo pipefail

CLUSTER="${CLUSTER:-observable-otelarrow}"
# Fraction of tagged records that must carry the attribute to call it SAFE.
# Not 100%: a handful of records can be in flight across the boundary of the
# window. 0% vs ~100% is the discrimination that matters and it is not subtle —
# measured live 2026-07-23 on the fluentbit arm: spans 1,654,883/1,654,883,
# logs 0/951,392.
SAFE_PCT="${SAFE_PCT:-95}"

if [[ "${1:-}" == "--selftest" ]]; then
  # Replay the R1P2 finding against the live/most-recent fluentbit arm. If this
  # does not reproduce spans=SAFE + logs=UNSAFE, the probe is not measuring what
  # it claims and its verdict for the arrow arm cannot be trusted either.
  echo "SELFTEST — expecting spans SAFE and logs UNSAFE for fluentbit-v5"
  exec "$(dirname "${BASH_SOURCE[0]}")/attr-landing.sh" fluentbit-v5 --window 30m --selftest-assert
fi

ENGINE="${1:?engine required: otel-collector | fluentbit-v5 | otel-arrow-native}"
shift || true
WINDOW="15m"; FROM=""; TO=""; ASSERT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --window) WINDOW="$2"; shift 2 ;;
    --from)   FROM="$2";   shift 2 ;;
    --to)     TO="$2";     shift 2 ;;
    --selftest-assert) ASSERT=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Absolute windows are quoted strings — unquoted is a PARSE_ERROR and
# timestamp("...") fails outright (ISI-1811).
if [[ -n "$FROM" && -n "$TO" ]]; then
  TF="from:\"$FROM\", to:\"$TO\""
  echo "window $FROM -> $TO"
else
  TF="from:now()-${WINDOW}"
  echo "window last $WINDOW"
fi
echo "engine $ENGINE   cluster $CLUSTER   safe-threshold ${SAFE_PCT}%"

dql() {
  dtctl query -f - -o json 2>/dev/null <<< "$1" \
    | python3 -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: print("[]"); raise SystemExit
r = d.get("result", d)
print(json.dumps(r.get("records", r if isinstance(r, list) else [])))'
}

printf '\n  %-8s %14s %14s %8s   %s\n' SIGNAL TAGGED WITH-CLUSTER PCT VERDICT
rc=0
verdicts=""

for sig in spans logs; do
  rows=$(dql "fetch $sig, $TF
| filter benchmark.engine == \"$ENGINE\"
| summarize tagged = count(), with_cluster = countIf(isNotNull(k8s.cluster.name))")
  read -r v <<<"$(SIG="$sig" ROWS="$rows" PCT="$SAFE_PCT" python3 -c '
import json, os
rows = json.loads(os.environ["ROWS"] or "[]")
sig  = os.environ["SIG"]
tagged = int(float(rows[0].get("tagged") or 0)) if rows else 0
withc  = int(float(rows[0].get("with_cluster") or 0)) if rows else 0
pct    = (100.0*withc/tagged) if tagged else 0.0
verdict = "NO-DATA" if tagged == 0 else ("SAFE" if pct >= float(os.environ["PCT"]) else "UNSAFE")
print("%s|%s|%s|%s|%s" % (verdict, sig, format(tagged, ","), format(withc, ","),
                          ("--" if tagged == 0 else "%.2f%%" % pct)))
')"
  IFS='|' read -r verdict s t w p <<<"$v"
  printf '  %-8s %14s %14s %8s   %s\n' "$s" "$t" "$w" "$p" "$verdict"
  verdicts="$verdicts $sig=$verdict"
done

# METRICS are dimensional, not countable: an OTLP metric arrives as a SERIES,
# so count() on it is meaningless (dashboard caveat, ISI-1836). The equivalent
# question is whether the series carries the dimension at all — ask for the
# series split BY k8s.cluster.name and see whether a non-null group comes back.
mrows=$(dql "timeseries v = avg(system.cpu.utilization), by:{k8s.cluster.name}, $TF, filter: benchmark.engine == \"$ENGINE\"")
mv=$(MR="$mrows" python3 -c '
import json, os
rows = json.loads(os.environ["MR"] or "[]")
total = len(rows)
named = sum(1 for r in rows if r.get("k8s.cluster.name"))
if total == 0:
    print("NO-DATA|0|0|--")
else:
    print("%s|%d|%d|%s" % ("SAFE" if named == total else "UNSAFE", total, named,
                           "%.2f%%" % (100.0*named/total)))
')
IFS='|' read -r mverdict mt mn mp <<<"$mv"
printf '  %-8s %14s %14s %8s   %s\n' metrics "$mt series" "$mn series" "$mp" "$mverdict"
verdicts="$verdicts metrics=$mverdict"

echo
echo "  register-row verdict:${verdicts}"

# Guidance, per signal, in the words the readout needs.
for kv in $verdicts; do
  sig="${kv%%=*}"; verdict="${kv##*=}"
  case "$verdict" in
    UNSAFE)
      echo "  ⚠️  $sig: do NOT filter $sig by k8s.cluster.name for this arm — it under-counts."
      echo "      Read $sig on benchmark.engine == \"$ENGINE\" alone, and correct the"
      echo "      dashboard tile before anyone reads it. This is the R1P2 log-tile defect."
      rc=1 ;;
    NO-DATA)
      echo "  ⚠️  $sig: NO records for this engine in this window. This is a CHECK 5b"
      echo "      condition, not an attribute problem — the signal is not arriving at all."
      rc=2 ;;
  esac
done

if [[ $ASSERT -eq 1 ]]; then
  # The selftest asserts the SHAPE of the known R1P2 result, not the counts.
  case "$verdicts" in
    *spans=SAFE*logs=UNSAFE*) echo "  SELFTEST PASS — reproduced R1P2: spans SAFE, logs UNSAFE"; exit 0 ;;
    *) echo "  SELFTEST FAIL — did not reproduce R1P2 (got:$verdicts). Probe is not"
       echo "     measuring what it claims; its arrow-arm verdict cannot be trusted."; exit 3 ;;
  esac
fi

exit $rc
