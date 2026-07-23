#!/usr/bin/env bash
# ISI-1850 — generate the paste-ready body for the upstream #3561 follow-up comment.
#
# WHY THIS EXISTS: UPSTREAM-3561-FOLLOWUP.md carries an internal HTML header that must
# never reach a public issue (invisible when rendered, fully readable in the source).
# Relying on the poster to "start at the marker" makes a footgun out of a human step.
# This derives a header-free file instead, so the whole file IS the paste.
#
#   ./make-paste-block.sh          regenerate UPSTREAM-3561-FOLLOWUP.paste.md
#   ./make-paste-block.sh --check  fail if the generated file has drifted from the source
#
# The generated file is committed on purpose: it is what gets scrubbed, and a scrub
# certification is only valid for the exact bytes it ran against.
set -euo pipefail

cd "$(dirname "$0")"
SRC=UPSTREAM-3561-FOLLOWUP.md
OUT=UPSTREAM-3561-FOLLOWUP.paste.md
MARKER='---8<--- paste from here ---8<---'

# `--` is required: the marker starts with "---" and grep would parse it as options.
grep -qF -- "$MARKER" "$SRC" || { echo "FAIL: marker not found in $SRC" >&2; exit 1; }

# Everything after the marker, with leading blank lines stripped. Interior blank lines
# are load-bearing (GitHub needs them to close a paragraph before a table), so nothing
# else is touched.
gen() {
  awk -v m="$MARKER" '
    !on { if (index($0, m)) on = 1; next }
    on && !started && $0 ~ /^[[:space:]]*$/ { next }
    on { started = 1; print }
  ' "$SRC"
}

if [[ "${1:-}" == "--check" ]]; then
  tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
  gen > "$tmp"
  if diff -q "$tmp" "$OUT" >/dev/null 2>&1; then
    echo "OK: $OUT matches $SRC below the marker"
  else
    echo "DRIFT: $OUT no longer matches $SRC — re-run without --check, then RE-SCRUB." >&2
    diff "$OUT" "$tmp" >&2 || true
    exit 1
  fi
else
  gen > "$OUT"
  echo "wrote $OUT ($(wc -c < "$OUT") bytes, $(wc -l < "$OUT") lines)"
  echo "sha256 $(sha256sum "$OUT" | cut -d' ' -f1)"
  echo "REMINDER: new bytes need a new scrub certification before posting."
fi
