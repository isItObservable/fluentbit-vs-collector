#!/usr/bin/env bash
# ISI-1850 — scrub certification for the bytes that go into the public upstream comment.
#
# Runs against UPSTREAM-3561-FOLLOWUP.paste.md (the header-free generated file), NOT
# against the source: a certification is only valid for the exact bytes it ran against.
#
# Every class asserts TWICE:
#   1. the pattern matches a synthetic positive  -> proves the pattern is live
#   2. the target file has zero matches          -> the actual finding
# Without step 1 a typo'd pattern reports CLEAN. That has happened here before: a
# `dt0[a-z0-9]{2}` pattern passed a real `dt0c01...` token as clean.
set -uo pipefail

cd "$(dirname "$0")"
TARGET=${1:-UPSTREAM-3561-FOLLOWUP.paste.md}
fail=0

check() { # name, egrep pattern, synthetic positive
  local name=$1 pat=$2 pos=$3
  if ! printf '%s\n' "$pos" | grep -qEi -- "$pat"; then
    printf '  %-22s PATTERN DEAD — does not match its own positive control (%s)\n' "$name" "$pos"
    fail=1; return
  fi
  local hits
  hits=$(grep -nEi -- "$pat" "$TARGET" || true)
  if [[ -n $hits ]]; then
    printf '  %-22s DIRTY\n%s\n' "$name" "$hits"
    fail=1
  else
    printf '  %-22s clean (control ok)\n' "$name"
  fi
}

echo "scrubbing $TARGET  ($(wc -c < "$TARGET") bytes, sha256 $(sha256sum "$TARGET" | cut -d' ' -f1))"

check "1 dynatrace/tenant"  'dt0[a-z]{1}[0-9]{2}\.[a-z0-9]|[a-z0-9]{8}\.(live|apps|sprint)\.dynatrace\.com|dynatrace\.com/e/' \
                            'DT_TOKEN=dt0c01.ABC123 https://abc12345.live.dynatrace.com'
check "2 cluster names"     'observable-[a-z0-9]+|homelab[0-9]?|capmox|proxmox|kind-[a-z]+' \
                            'cluster observable-otelarrow on homelab5 via capmox'
check "3 internal ticket"   '\bISI-[0-9]{3,}\b|\bPARA-[0-9]+\b|paperclip' \
                            'tracked as ISI-1850 in paperclip'
check "4 lab IPs"           '\b(10|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b' \
                            'control plane at 10.0.0.160 and 192.168.1.5'
check "5 account/app names" 'isitobservable|perfbytes|henrik|fluentbit-vs-collector|hipster-shop|mac ?studio|nas/projects' \
                            'repo isItObservable/fluentbit-vs-collector, henrik@perfbytes.com'
check "6 credentials"       'ghp_[A-Za-z0-9]{10,}|github_pat_[A-Za-z0-9_]{10,}|x-access-token|BEGIN [A-Z ]*PRIVATE KEY|kubeconfig|(api|secret|access)[-_ ]?(key|token)[=:"]' \
                            'used ghp_abcdefghij1234567890 and x-access-token in the kubeconfig'

echo
if (( fail )); then
  echo "RESULT: NOT CLEAN — do not post."
  exit 1
fi
echo "RESULT: CLEAN across 6 classes, each control-proven. Valid ONLY for the sha256 above."
