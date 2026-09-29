#!/usr/bin/env bash
# ISI-3578 E4 — ARM2 chain-guard: auto-launch the FB no-TS control arm once ARM1 (collector+TS)
# finishes a VALID 24h soak. Detached via setsid; survives heartbeat deaths.
#   ARM1 soak readout fires at T0+26h = 2026-09-17T10:55:52Z (T0=2026-09-16T08:55:52Z).
#   Guard wakes 2026-09-17T11:20Z, polls every 10 min (3h grace), then either launches
#   tier4-arm2-driver.sh (results VALID) or posts a triage comment and exits.
# Idempotent: $OUT/arm2-launched.flag prevents double-launch.
set -uo pipefail
OUT="$HOME/.cache/fbvc-e0-branch/tiers/tier4"
ISSUE="997b27bb-1cd7-49c0-9353-a078c0be4031"   # ISI-3578
LOG="$OUT/arm2-chain.log"; exec >>"$LOG" 2>&1
[ -f "$OUT/arm2-launched.flag" ] && { echo "[chain] flag present — already launched, exit"; exit 0; }

post() { python3 - "$1" "$ISSUE" <<'PY'
import sys,json,urllib.request
req=urllib.request.Request("http://127.0.0.1:3100/api/issues/%s/comments"%sys.argv[2],
  data=json.dumps({"body":sys.argv[1]}).encode(),headers={"Content-Type":"application/json"},method="POST")
try: print("[post] HTTP",urllib.request.urlopen(req,timeout=30).status)
except Exception as e: print("[post] FAILED",e)
PY
}

echo "[chain] guard armed at $(date -u +%FT%TZ); waiting for ARM1 soak completion"
# sleep until 2026-09-17T11:20Z
python3 - <<'PY'
import time,datetime
target=datetime.datetime(2026,9,17,11,20,tzinfo=datetime.timezone.utc)
d=(target-datetime.datetime.now(datetime.timezone.utc)).total_seconds()
if d>0: time.sleep(d)
PY

for i in $(seq 1 18); do  # 18 x 10min = 3h grace
  echo "[chain] poll $i at $(date -u +%FT%TZ)"
  pgrep -f 'tier4-driver.sh' >/dev/null 2>&1 && { echo "[chain] ARM1 driver still running"; sleep 600; continue; }
  R="$OUT/tier4-collector-results.md"
  if [ -f "$R" ] && grep -q "CENSUS GATE: PASS" "$R"; then
    echo "[chain] ARM1 soak VALID — launching ARM2 (FB no-TS control)"
    touch "$OUT/arm2-launched.flag"
    setsid bash "$OUT/tier4-arm2-driver.sh" >/dev/null 2>&1 &
    post "## Tier 4 — ARM 2 auto-launched (FB v5.1.1 no-TS control)

ARM 1 (collector + tail_sampling) completed a VALID 24h soak; the chain-guard torn-down/apply sequence is now running (\`tiers/tier4/tier4-arm2-driver.sh\`): bench-collector teardown -> fluentbit-tier4.yaml -> T3-shaped load (\`--otlp-http\`) -> span-ingest pre-check -> T0. 2h gate auto-posts ~T+2h; 24h soak readout ~T+26h. No agent action needed unless a gate posts RED."
    exit 0
  elif [ -f "$R" ]; then
    post "## Tier 4 — ARM 1 soak finished but census shows INVALID — ARM 2 NOT launched

\`tier4-collector-results.md\` exists without a census PASS. bench-load/bench-collector left as-is for triage. Assignee: inspect the soak readout, decide re-run vs proceed, then launch \`tiers/tier4/tier4-arm2-driver.sh\` manually."
    exit 1
  else
    echo "[chain] ARM1 driver gone but no results file (gate RED halt or crash) — keep polling"; sleep 600
  fi
done
post "## Tier 4 — chain-guard gave up at $(date -u +%FT%TZ)

ARM1 did not produce a valid soak within the 3h grace window (driver pid gone or stalled). Assignee: check \`tiers/tier4/driver.log\` + cluster state, then launch \`tiers/tier4/tier4-arm2-driver.sh\` manually or re-run ARM1."
