#!/usr/bin/env bash
# ============================================================================
# publication-scrub.sh — the gate that keeps this branch publishable.
# ----------------------------------------------------------------------------
#   ./publication-scrub.sh                    # tree + all commits on this branch
#   ./publication-scrub.sh --range main..HEAD # tree + an explicit commit range
#   ./publication-scrub.sh --tree-only        # tree only (commit range NOT RUN)
#   ./publication-scrub.sh --selftest         # prove every class still FIRES
#
#   exit 0  CLEAN     — every class ran, on every surface, and found nothing
#   exit 1  DIRTY     — at least one class has hits (all classes still run)
#   exit 2  INCOMPLETE— a class could not run. NOT a pass. See below.
#
# THIS IS A GATE, NOT A REVIEW. Three design rules, each of which exists because
# breaking it produced a false "clean" on a sibling repo:
#
#  1. IT CHECKS TWO SURFACES: the file tree AND the commit messages in the range.
#     Files are an edit; commit messages are immutable. A tree can be scrubbed
#     perfectly and the history stay permanently dirty — and clean files do not
#     make a repo publishable. That is why this branch was BUILT clean (fresh
#     commits) rather than cleaned in place.
#
#  2. A CLASS THAT DID NOT RUN IS REPORTED AS "NOT RUN", NEVER AS CLEAN, and it
#     makes the whole gate exit 2. A skipped check that renders as a pass is the
#     single failure mode this file exists to prevent.
#
#  3. FAIL CLOSED. Any error inside a class is a failure of the class, not an
#     absence of hits. The allowlist SUBTRACTS allowed tokens from the line and
#     re-tests the remainder — it never discards a whole line, because one line
#     can carry an allowed token and a real leak at the same time.
#
# Adding a leak class is the only way to fix a miss. Do not widen a regex inside
# a class to cover a leak of a different kind.
# ============================================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2

RANGE=""
TREE_ONLY=0
SELFTEST=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --range) RANGE="${2:?--range needs a git range}"; shift 2 ;;
    --tree-only) TREE_ONLY=1; shift ;;
    --selftest)  SELFTEST=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

FAIL=0
NOTRUN=0
# Which classes exist, and which of them actually produced a hit. --selftest
# compares the two: a class that stayed silent on a file built to trip it is
# broken, and must fail the run rather than rely on someone reading the output.
ALL_CLASSES=()
FIRED_CLASSES=()
# Line numbers of the selftest fixture that some class actually reported. Every
# line in that file is a known leak, so any line NOT here is a leak the gate
# walked past -- a sharper assertion than "each class fired at least once",
# which one matching variant can satisfy while its siblings stay invisible.
FIRED_LINES=()

# ---------------------------------------------------------------- surfaces
IS_GIT=0
git rev-parse --git-dir >/dev/null 2>&1 && IS_GIT=1

TREE_SRC=""
if (( IS_GIT )); then
  mapfile -t TARGETS < <(git ls-files)
  TREE_SRC="tracked files"
else
  mapfile -t TARGETS < <(find . -type f -not -path './.git/*')
  TREE_SRC="filesystem walk (NOT a git repo)"
fi
# This script necessarily CONTAINS every pattern it searches for, so it would
# flag itself on almost every class. It is the one file excluded from the tree
# surface — announced here rather than filtered silently, because a silent
# exclusion is indistinguishable from a check that did not run.
SELF="$(basename "${BASH_SOURCE[0]}")"
mapfile -t TARGETS < <(printf '%s\n' "${TARGETS[@]}" | grep -vx "$SELF")
(( ${#TARGETS[@]} > 0 )) || { echo "ERROR no files to scan — refusing to report clean"; exit 2; }

# The commit surface. Default: every commit reachable from HEAD that is not on
# the upstream default branch, i.e. everything this branch introduces. On an
# orphan branch that is all of its commits, which is the point.
COMMITS_AVAILABLE=0
COMMIT_TEXT=""
COMMIT_DESC=""
if (( TREE_ONLY )); then
  COMMIT_DESC="--tree-only requested"
elif (( ! IS_GIT )); then
  COMMIT_DESC="not a git repository"
else
  if ! git rev-parse --verify -q HEAD >/dev/null; then
    COMMIT_DESC="HEAD is unborn — nothing is committed yet"
  elif [[ -z "$RANGE" ]]; then
    for base in origin/master origin/main master main; do
      if git rev-parse --verify -q "$base" >/dev/null && \
         ! git merge-base --is-ancestor HEAD "$base" 2>/dev/null; then
        RANGE="${base}..HEAD"; break
      fi
    done
    [[ -z "$RANGE" ]] && RANGE="HEAD"
  fi
  if [[ -n "$RANGE" ]]; then
  if COMMIT_TEXT="$(git log --format='%H %an <%ae>%n%s%n%b' "$RANGE" 2>&1)"; then
    COMMITS_AVAILABLE=1
    COMMIT_DESC="$RANGE ($(git rev-list --count "$RANGE" 2>/dev/null) commit(s))"
  else
    COMMIT_DESC="git log '$RANGE' failed: $COMMIT_TEXT"
    COMMIT_TEXT=""
  fi
  fi
fi

# ---------------------------------------------------------------- class runner
# class <name> <regex> <allowlist|-> <why>
class() {
  local name="$1" rx="$2" alw="$3" why="$4" case_mode="${5:-ci}"
  local tree_hits commit_hits rc_t rc_c
  ALL_CLASSES+=("$name")

  # Case sensitivity is a property OF THE CLASS, not of the runner. Most classes
  # want -i: a ticket is a ticket whether it is written ISI-1817 or isi1817.
  # Two do not, and forcing -i on them produced false positives immediately --
  # `HACK` is a work marker but "a hack" is English prose, and `secret` as a key
  # name is a leak while `DT_SECRET` naming a variable is documentation. A gate
  # that cries wolf on its own README gets switched off, so the distinction has
  # to live in the class rather than in a global flag.
  local -a gopt=(-rnEI) copt=(-nE)
  if [[ "$case_mode" == "ci" ]]; then gopt+=(-i); copt+=(-i); fi

  # grep exits 1 for "no matches" and >=2 for a real error. Only the latter is
  # a failure of the class. Conflating them would report every clean class as
  # NOT RUN -- and, worse, a genuinely broken grep as clean.
  # -i on BOTH greps. The greps only select candidate lines; `filter` is the
  # authority and has always matched case-insensitively (re.I). While the greps
  # were case-sensitive they silently narrowed the candidate set below what the
  # filter would accept, so a lower-case class regex could never see an
  # upper-case leak: `isi[-_ ]?[0-9]{3,4}` never matched `ISI-1817`, the actual
  # commit convention. 53 of 55 ticket-bearing commit lines were invisible.
  local raw
  raw="$(grep "${gopt[@]}" "$rx" "${TARGETS[@]}" 2>/dev/null)"; rc_t=$?
  (( rc_t <= 1 )) && { tree_hits="$(printf '%s\n' "$raw" | filter "$rx" "$alw" "$case_mode")"; rc_t=$?; }

  rc_c=0; commit_hits=""
  if (( COMMITS_AVAILABLE )); then
    raw="$(printf '%s\n' "$COMMIT_TEXT" | grep "${copt[@]}" "$rx" 2>/dev/null)"; rc_c=$?
    (( rc_c <= 1 )) && { commit_hits="$(printf '%s\n' "$raw" | filter "$rx" "$alw" "$case_mode")"; rc_c=$?; }
  fi

  if (( rc_t != 0 || rc_c != 0 )); then
    NOTRUN=1
    printf 'NOT RUN  %-22s the filter itself failed — this is NOT a pass\n' "$name"
    return
  fi

  if [[ -n "$tree_hits" || -n "$commit_hits" ]]; then
    FAIL=1
    if [[ -n "$tree_hits" ]]; then
      FIRED_CLASSES+=("$name")
      if (( SELFTEST )); then
        while IFS= read -r hit; do
          [[ "$hit" =~ ^([0-9]+): ]] && FIRED_LINES+=("${BASH_REMATCH[1]}")
        done <<<"$tree_hits"
      fi
    fi
    printf '\n=== LEAK CLASS: %s ===\n' "$name"
    [[ -n "$tree_hits"   ]] && printf -- '--- in the file tree:\n%s\n' "$tree_hits"
    [[ -n "$commit_hits" ]] && printf -- '--- in COMMIT MESSAGES (%s) — these cannot be edited in place:\n%s\n' "$COMMIT_DESC" "$commit_hits"
    printf -- '--- fix: %s\n' "$why"
  else
    if (( COMMITS_AVAILABLE )); then
      printf 'ok       %-22s tree + commits\n' "$name"
    else
      printf 'PARTIAL  %-22s tree only — COMMIT SURFACE NOT RUN (%s)\n' "$name" "$COMMIT_DESC"
      NOTRUN=1
    fi
  fi
}

# Subtract the allowlist from the line body, then re-test. Matching is done on
# the text only, never on the `file:lineno:` prefix, so a path can neither raise
# nor suppress a hit.
#
# The prefix is parsed with an anchored regex, NOT split(":", 2). grep emits two
# different shapes -- `file:lineno:body` when it has a filename, and `lineno:body`
# when it is reading a stream (the commit surface, and any single-file target).
# A blind 2-way split on the second shape eats everything up to the body's first
# colon, which is exactly where a commit subject puts its ticket: given
# `12:ISI-1817: close the hole`, the body became ` close the hole` and the class
# reported CLEAN. Measured against this repo's own dirty history that discarded
# 53 of 55 ticket-bearing lines -- the gate said DIRTY only because two refs
# happened to sit late in their line. A branch following the ordinary
# `ISI-####: subject` convention would have passed with a fully dirty history.
# If the prefix does not parse, the WHOLE line is tested. A parse that is unsure
# must widen the match, never silently drop text from it.
#
# The filename part is `[^:]+`, not `.+?`. A non-greedy `.+?:` backtracks until
# the rest of the pattern fits, so on
#   111:ISI-1816 R1-P2 COMPLETE: End 2026-07-23T10:35:12Z
# it happily treated everything up to the timestamp's `10:35:` as the prefix and
# threw the ticket away. The first fix for this bug reproduced the bug.
filter() {
  RX="$1" ALW="$2" CASE="${3:-ci}" python3 -c '
import os, re, sys
# Must agree with the grep that selected these lines. When they disagree the
# stricter one wins silently, which is how the greps ended up narrowing the
# candidate set below what this filter would have accepted.
flags = re.I if os.environ.get("CASE", "ci") == "ci" else 0
rx  = re.compile(os.environ["RX"], flags)
raw = os.environ.get("ALW", "")
alw = re.compile(raw, flags) if raw and raw != "-" else None
pfx = re.compile(r"^(?:[^:]+:)?\d+:")
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    m    = pfx.match(line)
    body = line[m.end():] if m else line
    if rx.search(alw.sub("", body) if alw else body):
        print(line)
' || return 1
}

# ---------------------------------------------------------------- selftest
# A gate that has never failed is not a proven gate. --selftest replaces the
# tree surface with one synthetic file carrying a known leak per class and
# asserts that every class FIRES. It found a real defect the first time it ran:
# the tree and commit greps were case-SENSITIVE while the python filter was not,
# so `ISI-1842` in upper case passed a class whose regex is lower case. Reading
# the code did not find that. Making it fail did.
if (( SELFTEST )); then
  SELFDIR="$(mktemp -d)"
  trap 'rm -rf "$SELFDIR"' EXIT
  # ONE spelling per line. The previous fixture put `ISI-1842`, `isi_1779` and
  # `isi1779` on a single line; the lower-case pair matched, the class reported
  # a hit, and the fact that the upper-case form -- the only form this project
  # actually writes -- was invisible stayed hidden behind it. A fixture that
  # ORs variants together tests the OR, not the variants.
  cat > "$SELFDIR/synthetic-leaks.txt" <<'LEAKS'
credentials        token: dt0c01.ABCDEFGHIJKLMNOPQRSTUVWX
ticket-ids         see ISI-1842
ticket-ids         see isi_1779
ticket-ids         benchmark=isi1779
ticket-ids         subject-line shape ISI-1817: close the hole
lab-ip-addresses   node at 10.0.0.176
lab-ip-addresses   node at 192.168.1.5
tenant-hostnames   ABC12345.dev.dynatracelabs.com
internal-infra-names   cluster observable-otelarrow
internal-infra-names   provisioned on capmox
internal-vocabulary    @BigBoss said so
internal-vocabulary    the board directive
internal-vocabulary    good on camera
local-paths        /home/someone/.config/capmox/x
local-paths        /mnt/nas/projects
work-markers       TODO: fix before publishing
LEAKS
  TARGETS=("$SELFDIR/synthetic-leaks.txt")
  COMMITS_AVAILABLE=0
  COMMIT_DESC="selftest — commit surface deliberately not used"
  echo "publication scrub — SELFTEST"
  echo "  every class below MUST report a hit. An 'ok' here is a BROKEN CLASS."
  echo
fi

echo "publication scrub"
if (( ! SELFTEST )); then
  echo "  tree surface   : ${#TARGETS[@]} file(s) — $TREE_SRC (excluding $SELF itself)"
  echo "  commit surface : $COMMIT_DESC"
  echo
fi

# ---------------------------------------------------------------- the classes

# 1. CREDENTIALS. A NAME is documentation; a VALUE is a leak. Dynatrace tokens
#    have a recognisable shape (dt0c01./dt0s01.) and are matched on their own so
#    a token pasted with no assignment syntax is still caught.
class "credentials" \
  '(dt0[cs]0[0-9]\.[A-Z0-9]{24}|(api[_-]?key|apitoken|token|password|passwd|secret)["'"'"']?\s*[:=]\s*["'"'"']?[A-Za-z0-9_/+=-]{16,})' \
  '\$\{[A-Z_]+\}|__[A-Z_]+__|secretKeyRef|EDIT|CHANGE|REPLACE|XXXX|example|<[A-Za-z]|apiToken["'"'"']?\s*$|from-literal' \
  'never commit a value. Read it from a Secret, or ship a .example file with a marker.' \
  cs

# 2. TICKET IDS. Separator-agnostic on purpose: ISI-1842, isi1842 and isi_1842
#    are the same leak and only the first matches the obvious pattern. Label
#    VALUES are the ones people forget — `benchmark=isi1779` is a ticket
#    reference stamped onto live Kubernetes objects and into telemetry.
class "ticket-ids" \
  'isi[-_ ]?[0-9]{3,5}' '-' \
  'strip it. Never put a ticket ID in a branch name, a label value or a resource attribute either.'

# 3. LAB IP ADDRESSES. RFC1918, so the exposure is low — but they are simply
#    wrong for anyone copying the manifests. The `\\?\.` matcher is deliberate:
#    an address inside a shell sed pattern is written 10\.0\.0\.189, and a
#    plain-dot regex walks straight past it.
class "lab-ip-addresses" \
  '\b(10|192\\?\.168|172\\?\.(1[6-9]|2[0-9]|3[01]))\\?\.[0-9]{1,3}\\?\.([0-9]{1,3}|x)\b' \
  '10\.0\.0\.0/8|172\.16\.0\.0/12|192\.168\.0\.0/16|10\.96\.0\.[0-9]+|127\.0\.0\.1|0\.0\.0\.0|10\.20\.30\.' \
  'use 10.20.30.0/24 as the documented example range, or template the value.'

# 4. OBSERVABILITY TENANT HOSTNAMES. A tenant ID is not a credential, but it
#    names our environment and is useless to a reader — every one of them must
#    be __DT_ENDPOINT_HOST__ or ${DT_ENDPOINT_HOST}.
class "tenant-hostnames" \
  '\b[a-z]{3}[0-9]{4,6}\.(dev|sprint|live|apps)\.(dynatrace|dynatracelabs)\.com\b|\bdynatracelabs\.com\b' '-' \
  'template it: __DT_ENDPOINT_HOST__ in manifests, ${DT_ENDPOINT_HOST} in scripts and docs.'

# 5. INTERNAL INFRASTRUCTURE NAMES. Cluster names, hypervisor, control plane.
#    These name the lab, not the product.
class "internal-infra-names" \
  'observable-(agentsandbox|otelarrow|kagent|llm)|capmox|proxmox|paperclip|homelab|capi-mgmt|mgmt-prod' '-' \
  'template the cluster name (${CLUSTER_NAME}) and describe the provisioner generically.'

# 6. INTERNAL PROCESS VOCABULARY. Reads as nonsense to a public reader and
#    silently implies an authority they cannot consult. Includes the video-shoot
#    vocabulary, because this repo backs a recorded episode.
class "internal-vocabulary" \
  '@BigBoss|\bthe board (said|asked|decided|directive)|board directive|\bplan rev [0-9]|\bplan §|\bHenrik\b|off.camera|on camera|before recording|hit record|teleprompter|storyboard|shoot day' '-' \
  'rewrite as a stated methodology rule that the reader can evaluate on its own terms.'

# 7. LOCAL FILESYSTEM PATHS. They leak the operator and the machine layout, and
#    they are broken for everyone else.
class "local-paths" \
  '/home/[a-z][a-z0-9_-]*|/mnt/nas|/Users/[a-z]|~/\.config/(capmox|proxmox)' \
  '/home/node|/home/nonroot|\$HOME|/home/<' \
  'use a relative path, $HOME, or an environment variable.'

# 8. UNRESOLVED WORK MARKERS. A published tree should not carry a note to itself.
class "work-markers" \
  '\b(TODO|FIXME|XXX|HACK|DO NOT PUBLISH|WIP)\b' \
  'TODO in the upstream|TODOs' \
  'resolve it or delete it before publishing.' \
  cs

# ---------------------------------------------------------------- commit-only classes
# These have no file-tree equivalent: they are about how the history READS.
if (( COMMITS_AVAILABLE )); then
  scrubby="$(printf '%s\n' "$COMMIT_TEXT" \
    | grep -inE '\bscrub\b|\bredact|\bsanitiz|remove (the )?internal|the lab.?s|drop a (production|internal) reference')"
  if [[ -n "$scrubby" ]]; then
    FAIL=1
    printf '\n=== LEAK CLASS: self-describing-history ===\n%s\n' "$scrubby"
    printf -- '--- fix: a commit that says what it removed announces what used to be there.\n'
    printf -- '         Write the subject for a reader who never saw the internal work.\n'
  else
    printf 'ok       %-22s commits only\n' "self-describing-history"
  fi
else
  printf 'NOT RUN  %-22s %s\n' "self-describing-history" "$COMMIT_DESC"
  NOTRUN=1
fi

# ---------------------------------------------------------------- verdict
echo
if (( SELFTEST )); then
  # Every tree class is SUPPOSED to fire here. Decide that in code: the earlier
  # version printed "scroll up and check" and exited 0, which is the same
  # did-not-run-rendered-as-passed failure the gate exists to prevent -- and it
  # is how a genuinely broken class survived its own selftest.
  MISSED=()
  for c in "${ALL_CLASSES[@]}"; do
    hit=0
    for f in "${FIRED_CLASSES[@]}"; do [[ "$f" == "$c" ]] && { hit=1; break; }; done
    (( hit )) || MISSED+=("$c")
  done
  if (( ${#MISSED[@]} )); then
    echo "SELFTEST FAILED — these classes did NOT detect their own known leak:"
    printf '  BROKEN  %s\n' "${MISSED[@]}"
    echo
    echo "A clean run from this gate is not trustworthy until they are fixed."
    exit 2
  fi
  # Per-LINE assertion. Every fixture line is a planted leak, so a line nobody
  # reported is a leak that got past all 8 classes.
  FIXTURE_LINES="$(grep -c . "$SELFDIR/synthetic-leaks.txt")"
  UNCAUGHT=()
  for (( n = 1; n <= FIXTURE_LINES; n++ )); do
    seen=0
    for f in "${FIRED_LINES[@]}"; do [[ "$f" == "$n" ]] && { seen=1; break; }; done
    (( seen )) || UNCAUGHT+=("$n: $(sed -n "${n}p" "$SELFDIR/synthetic-leaks.txt")")
  done
  if (( ${#UNCAUGHT[@]} )); then
    echo "SELFTEST FAILED — planted leaks that NO class reported:"
    printf '  MISSED  %s\n' "${UNCAUGHT[@]}"
    exit 2
  fi
  echo "SELFTEST PASSED — all ${#ALL_CLASSES[@]} tree classes fired on a file"
  echo "built to trip every one of them. (self-describing-history is"
  echo "commit-only and is exercised by a real --range run, not by this.)"
  exit 0
fi
if (( FAIL )); then
  echo "DIRTY — see the classes above. Do not publish this branch."
  exit 1
elif (( NOTRUN )); then
  cat <<EOF
INCOMPLETE — nothing was found, but at least one class DID NOT RUN.

That is not a pass. A check that never executed must never render as clean;
that is exactly how four successive scrubs on a sibling repo "passed".

  * commit surface not checked?  run without --tree-only, inside a git repo,
    or pass --range explicitly.
EOF
  exit 2
else
  echo "CLEAN — 9 classes, tree + commit range ($COMMIT_DESC)."
  exit 0
fi
