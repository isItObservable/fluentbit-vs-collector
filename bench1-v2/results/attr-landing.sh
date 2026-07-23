#!/usr/bin/env bash
# ============================================================================
# ISI-1779 B1-v2 — PER-SIGNAL attribute-landing probe.
#
#   ./results/attr-landing.sh <engine> [--window 15m]
#   ./results/attr-landing.sh <engine> --from <utc> --to <utc>
#   ./results/attr-landing.sh <engine> --gate   # MANDATORY step 7b, all 3 arms
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
#
# ---------------------------------------------------------------------------
# --gate — MANDATORY BEFORE THE TIMED WINDOW, ON EVERY ARM (ISI-1844 / Q5)
# ---------------------------------------------------------------------------
# This started as a readout diagnostic for the arrow arm. The board promoted it
# to a mandatory pre-window step on all three arms, and made it a PREDICTION
# rather than a measurement: each engine's expected verdict is declared below,
# in advance, and --gate FAILS on any deviation from it.
#
# Why a declared expectation and not just a printout: a bare readout is graded
# after the fact by whoever reads it, and "logs=UNSAFE" reads as normal once you
# have seen it once. Stating the expected value in advance turns the same two
# minutes into a falsifiable check — for the arrow arm it is the ONLY thing that
# can tell you the deployed pipeline is not the one that was probed off-cluster.
#
# Why it applies to the FROZEN arms too (decision D0): a check changes no engine
# work, so it does not unfreeze anything. And the failure is measured, not
# theoretical — R1P2 delivered k8s.cluster.name on 100% of spans and 0 of
# 2,782,904 logs, which is why that arm's dashboard log tiles read ZERO for an
# engine that was in fact delivering millions of records.
#
# EXPECTATIONS — each one is a claim about a MEASUREMENT, sourced:
#   otel-arrow-native  spans=SAFE logs=SAFE metrics=SAFE
#       off-cluster probe of the frozen df_engine 0.50.0 pipeline config,
#       2026-07-23, 100% on all three signals (engines/attr-probe/FINDINGS.md).
#   fluentbit-v5       spans=SAFE logs=UNSAFE metrics=NO-DATA
#       measured live on the R1P2 arm 2026-07-23: spans 1,654,883/1,654,883,
#       logs 0/951,392. metrics=NO-DATA is the 🛑 R1P2 finding — the metrics
#       processor chain fails on 100% of batches and the datapoints are LOST,
#       not merely unlabelled (RUN-REGISTER.md). It is recorded as the EXPECTED
#       value so the run is not blocked by a known-frozen defect — but it is
#       recorded as NO-DATA, never as SAFE.
#   otel-collector     spans=SAFE logs=UNKNOWN metrics=UNKNOWN
#       spans=SAFE is implied by R1P1's CHECK 2, which counted app spans through
#       a k8s.cluster.name filter and passed. Logs and metrics have NEVER been
#       measured for this arm — attr-landing.sh postdates R1P1 — so they are
#       declared UNKNOWN rather than guessed. UNKNOWN accepts SAFE or UNSAFE and
#       still FAILS on NO-DATA (a dead signal is a dead signal whatever the
#       attribute does). R2P1's run establishes the baseline; when it does,
#       replace UNKNOWN here with what was measured.
# ============================================================================
set -euo pipefail

# engine -> expected verdict per signal. UNKNOWN = not yet measured; accepts
# SAFE or UNSAFE, never NO-DATA.
expected_for() {
  case "$1" in
    otel-arrow-native) echo "spans=SAFE logs=SAFE metrics=SAFE" ;;
    fluentbit-v5)      echo "spans=SAFE logs=UNSAFE metrics=NO-DATA" ;;
    otel-collector)    echo "spans=SAFE logs=UNKNOWN metrics=UNKNOWN" ;;
    *)                 echo "" ;;
  esac
}

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
  # The window is ABSOLUTE, and it is the banked R1-P2-fluentbit window
  # (RUN-REGISTER.md). It used to be `--window 30m`, which only worked while the
  # fluentbit arm was still live — that arm was torn down on 2026-07-23, so the
  # relative form now returns NO-DATA and the selftest fails on a probe that is
  # perfectly fine. A selftest that cannot be run is not a selftest.
  # Replay is legitimate for THIS question and not for liveness: attribute
  # landing is a property of records that already exist, so backfill cannot
  # flatter it. (5c's liveness check is the opposite case and must stay live —
  # history backfills: live 0 vs replayed 845, ISI-1817.)
  # Re-measured over this exact window 2026-07-23: spans 17,858,597/17,858,597
  # carry k8s.cluster.name, logs 0/10,263,977, metrics 0 series.
  exec "$(dirname "${BASH_SOURCE[0]}")/attr-landing.sh" fluentbit-v5 \
    --from "${SELFTEST_FROM:-2026-07-23T08:34:49Z}" \
    --to   "${SELFTEST_TO:-2026-07-23T10:35:12Z}" --selftest-assert
fi

ENGINE="${1:?engine required: otel-collector | fluentbit-v5 | otel-arrow-native}"
shift || true
WINDOW="15m"; FROM=""; TO=""; ASSERT=0; GATE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --window) WINDOW="$2"; shift 2 ;;
    --from)   FROM="$2";   shift 2 ;;
    --to)     TO="$2";     shift 2 ;;
    --gate)   GATE=1; shift ;;
    --selftest-assert) ASSERT=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

EXPECTED="$(expected_for "$ENGINE")"
if [[ $GATE -eq 1 ]]; then
  [[ -n "$EXPECTED" ]] || { echo "no declared expectation for engine '$ENGINE' — refusing to gate on nothing" >&2; exit 2; }
  # Printed BEFORE the measurement, deliberately: a prediction read after the
  # result is not a prediction.
  echo "expected (declared in advance): $EXPECTED"
fi

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

# ---------------------------------------------------------------------------
# --gate — compare against the declared expectation. Mandatory step 7b.
# ---------------------------------------------------------------------------
if [[ $GATE -eq 1 ]]; then
  echo
  gate_bad=""
  for kv in $EXPECTED; do
    sig="${kv%%=*}"; exp="${kv##*=}"
    got=""
    for a in $verdicts; do [[ "${a%%=*}" == "$sig" ]] && got="${a##*=}"; done
    if [[ "$exp" == "UNKNOWN" ]]; then
      # Never measured for this arm. Accept a real reading of either kind and
      # say so loudly enough that someone records it; NO-DATA is still a fail.
      if [[ "$got" == "NO-DATA" || -z "$got" ]]; then
        gate_bad="$gate_bad ${sig}: expected a reading, got ${got:-<none>}"
      else
        echo "  $sig: UNKNOWN -> measured $got. FIRST measurement for this arm —"
        echo "     record it in the register row AND replace UNKNOWN in expected_for()."
      fi
    elif [[ "$got" != "$exp" ]]; then
      gate_bad="$gate_bad ${sig}: expected ${exp}, got ${got:-<none>}"
    fi
  done
  echo
  if [[ -n "$gate_bad" ]]; then
    echo "ATTR-LANDING FAIL engine=$ENGINE —$gate_bad"
    echo "  This is a FINDING, not a filter to drop. The deployed pipeline is not the"
    echo "  one the expectation was measured on. Investigate the deployment before the"
    echo "  timed window opens; do not silently read on with a different filter."
    exit 4
  fi
  echo "ATTR-LANDING PASS engine=$ENGINE verdict:${verdicts} (== declared expectation)"
  echo "  Copy the verdict into the RUN-REGISTER row for this run."
  exit 0
fi

if [[ $ASSERT -eq 1 ]]; then
  # The selftest asserts the SHAPE of the known R1P2 result, not the counts.
  case "$verdicts" in
    *spans=SAFE*logs=UNSAFE*) echo "  SELFTEST PASS — reproduced R1P2: spans SAFE, logs UNSAFE"; exit 0 ;;
    *) echo "  SELFTEST FAIL — did not reproduce R1P2 (got:$verdicts). Probe is not"
       echo "     measuring what it claims; its arrow-arm verdict cannot be trusted."; exit 3 ;;
  esac
fi

exit $rc
