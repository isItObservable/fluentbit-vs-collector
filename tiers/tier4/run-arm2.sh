#!/bin/bash
D=$HOME/.cache/fbvc-e0-branch/tiers/tier4
cd "$D" || exit 1
export PATH="$HOME/.local/bin:$PATH"
if pgrep -f "tier4-arm2-drive[r]" >/dev/null; then echo "GUARDED_ALREADY_RUNNING: $(pgrep -f "tier4-arm2-drive[r]" | tr "\n" " ")"; exit 1; fi
setsid bash ./tier4-arm2-driver.sh >/dev/null 2>&1 < /dev/null &
sleep 3
echo "LAUNCHED: $(pgrep -f "tier4-arm2-drive[r]" | tr "\n" " ")"
