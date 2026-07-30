#!/usr/bin/env bash
# ISI-1859 — control-proven scrub for the #3561 OPL follow-up paste file.
# Each class must first match a synthetic dirty line (proving the pattern is
# alive) before its zero-hit on the real file is trusted. See ISI-1850 lesson:
# "a green run is a claim; a measured detection rate on known-dirty input is
# evidence." Run from results/opl-retest/.
set -uo pipefail
FILE="${1:-UPSTREAM-3561-OPL-FOLLOWUP.paste.md}"
DIRTY='ISI-1859 observable-agentsandbox 10.0.0.230 oat05854.dev.dynatracelabs.com Api-Token dt0c01.ABC github_pat_11ABCDEF ghcr.io/isitobservable/df_engine henrikrexed'
declare -A P=(
 [internal-ticket]='ISI-[0-9]+'
 [cluster-name]='observable-[a-z]+'
 [lab-ip]='10\.0\.0\.[0-9]+'
 [tenant-host]='oat[0-9]+\.[a-z.]*dynatrace'
 [dt-token]='Api-Token|dt0c01\.'
 [gh-pat]='github_pat_|ghp_'
 [image-org]='ghcr\.io/isitobservable'
 [account]='henrikrexed'
)
fail=0
for name in "${!P[@]}"; do
  pat="${P[$name]}"
  echo "$DIRTY" | grep -qE "$pat" || { echo "PATTERN-DEAD $name ($pat)"; fail=1; continue; }
  hits=$(grep -nE "$pat" "$FILE" || true)
  if [[ -n "$hits" ]]; then echo "DIRTY $name:"; echo "$hits"; fail=1; else echo "CLEAN $name"; fi
done
[[ $fail -eq 0 ]] && echo "== SCRUB CLEAN: paste-ready ==" || { echo "== SCRUB FAILED =="; exit 1; }
