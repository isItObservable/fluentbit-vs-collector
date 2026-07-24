#!/usr/bin/env bash
# ============================================================================
# ISI-1859 — OPL runtime node-proof assertions for df_engine 0.50.0 @ 7502e7d
# ----------------------------------------------------------------------------
# Reproduces the proof that OPL closes the two disclosed parity gaps that KQL
# could not (P-SEV conditional severity, P-PII conditional field-read + redact).
#
#   ./verify.sh --deploy    # apply probe.yaml, run generators, then assert
#   ./verify.sh             # assert against whatever is already deployed
#
# The decisive assertion is the ERROR/CLEARED split: the OPL `if/else` reads
# `body` at runtime and drives TWO DIFFERENT writes. KQL validated the same
# predicate and then wrote unconditionally — see ISI-1817/1843.
# ============================================================================
set -euo pipefail
NS=dfopl
HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ "${1:-}" == "--deploy" ]]; then
  awk 'BEGIN{RS="\n---\n"} !/kind: Job/{print $0"\n---"}' "$HERE/probe.yaml" | kubectl apply -f -
  kubectl -n "$NS" rollout status deploy/df-engine --timeout=120s
  kubectl -n "$NS" rollout status deploy/sink       --timeout=120s
  awk 'BEGIN{RS="\n---\n"} /kind: Job/{print $0"\n---"}'  "$HERE/probe.yaml" | kubectl apply -f -
  kubectl -n "$NS" wait --for=condition=complete job/gen-err job/gen-ok --timeout=120s
  sleep 5
fi

LOG="$(mktemp)"
kubectl -n "$NS" logs deploy/sink --tail=100000 > "$LOG"

fail=0
check(){ local name="$1" got="$2" want="$3"; if [[ "$got" == "$want" ]]; then echo "PASS $name ($got)"; else echo "FAIL $name (got $got want $want)"; fail=1; fi; }

check "total records"              "$(grep -c 'LogRecord #' "$LOG")"                 100
check "P-SEV if-branch  ERROR"     "$(grep -c 'SeverityText: ERROR' "$LOG")"          50
check "P-SEV else-branch CLEARED"  "$(grep -c 'SeverityText: CLEARED' "$LOG")"        50
check "P-PII flag on err only"     "$(grep -c 'pii.email.detected: Str(true)' "$LOG")" 50
check "P-PII body redacted"        "$(grep -c 'Body: Str(REDACTED:' "$LOG")"          50
check "P-PII email removed"        "$(grep -c 'alice@example.com' "$LOG")"             0
check "control body untouched"     "$(grep -c 'Body: Str(request completed successfully)' "$LOG")" 50

# Per-stream cross-check: no CLEARED record may carry pii/REDACTED (else-branch
# and unmatched PII predicate must not fire — proves the writes are conditional,
# not unconditional).
python3 - "$LOG" <<'PY'
import re,sys
blocks=re.split(r'LogRecord #',open(sys.argv[1]).read())[1:]
bad=0
for b in blocks:
    if 'SeverityText: CLEARED' in b and ('pii.email.detected: Str(true)' in b or 'Body: Str(REDACTED:' in b):
        bad+=1
print(("PASS" if bad==0 else "FAIL")+f" conditional-not-unconditional (CLEARED records with pii/redact = {bad}, want 0)")
sys.exit(1 if bad else 0)
PY

# engine health: no panic / core death during the run
if kubectl -n "$NS" logs deploy/df-engine --since=15m 2>/dev/null | grep -iE "panicked at|core.*died|observed_error" | grep -qv 'exporter:error'; then
  echo "FAIL engine clean (panic/core death found)"; fail=1
else
  echo "PASS engine clean (no panic / core death)"
fi

rm -f "$LOG"
if [[ $fail -eq 0 ]]; then echo "== ALL PASS =="; else echo "== FAILURES =="; exit 1; fi
