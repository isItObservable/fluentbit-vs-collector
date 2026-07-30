# #3561 correction — POSTED, and what the published body actually contains

**Closing test for ISI-1850 / ISI-1852 was: "the comment is visible on #3561 *and* I have
verified the published body — not my local copy."** That test has now been run against the
GitHub API rather than against a report that it was posted. It passes on visibility and
**fails on completeness**. Both halves are recorded here.

## Verified published (2026-07-23, GitHub API)

| | value |
|---|---|
| URL | https://github.com/open-telemetry/otel-arrow/issues/3561#issuecomment-5061029145 |
| author | `henrikrexed` |
| `created_at` / `updated_at` | `2026-07-23T16:46:50Z` (identical — not edited since) |
| issue state | `open`, `comments = 1` |
| published body | 3081 bytes, 24 lines |
| sha256 (LF-normalised) | `81500d69920c64da351df6c62fcf68747f10ea2e7444f7ab93f4ec8292b311cf` |

**The retraction landed.** The published body carries the correction in full: the
"41 minutes with zero panics" claim is publicly withdrawn, the T+26m10.5s / T+33m34.2s
comparison table is there, accumulation-driven-not-batch-size-gated is stated, traces-and-
logs-alone reachability is stated, and the second panic site at `concatenate.rs:150` is
reported with its stack. **The actively harmful state — a maintainer reading #3561 and
concluding the workaround is a fix — is resolved.**

## The delta: it is the `04decf8`-era draft, not the certified paste file

Diffed the published body against `UPSTREAM-3561-FOLLOWUP.paste.md` (4742 bytes, 47 lines).
Attribution is unambiguous: the published text contains **zero** occurrences of
`keep_all_zeroes` and of `Still present on current`, and those sections entered the draft at
`dd3e6ee`. So the paste was taken from a copy made at or before `04decf8` — most likely a
board paste block, which is exactly the staleness mode already recorded on this campaign.

Missing from the published body:

1. **The detection mechanism** — the admin API stops *serving* the pipeline metric sets when
   the cores die: 289 sets / 17 names healthy, exactly **1** / **1** dead, with
   `keep_all_zeroes=true` proving *absent* rather than zeroed. This is the most directly
   actionable content we have for a maintainer, and the only signal that does not lie while
   the process stays `Ready` with `restarts=0`.
2. **Still present on current `main`** — the check that stops a maintainer re-deriving it.
3. The closing "happy to supply the full log … or to test a patch" offer.

One deliberate human edit, not a defect: "I flagged that *we'd* changed two things at once"
was posted as "I flagged that *i had* changed two things at once". Correct — it is his
account and his original report.

## What did NOT go wrong (checked, so the record is complete rather than selective)

The published body has **no blank lines at all** — all 18 were stripped in transit. The
prediction from the campaign's own notes was that this ships both tables as literal `|` text.
**It did not.** Rendered through the GitHub markdown API (`mode=gfm`, repo context): 1
`<table>`, 2 `<h3>`, 1 `<ol>`, 1 `<pre>`, and zero paragraphs beginning with a literal pipe.
GFM lets a table, an ATX heading, a `1.`-initial ordered list and a fenced block each
interrupt a paragraph, so the only visible cost is that a few paragraphs run together.
**Recording the corrected version of our own rule: blank lines are syntax for *some* block
types, not all — verify against the renderer, not against the fear.**

## The gap-closer

`UPSTREAM-3561-ADDENDUM.paste.md` — a standalone follow-up comment carrying exactly the three
missing items. Additive, so it needs no edit to the posted comment and no second retraction.

- 1821 bytes, sha256 `affc0ccb251c17be0e1988936fc5ec5068ea923942fb3c9147f450bf2990b3d4`
- scrub: `./scrub-paste-block.sh UPSTREAM-3561-ADDENDUM.paste.md` → **CLEAN across 6 classes,
  each pattern first proven against a synthetic known-dirty control**. Valid only for that
  sha256.
- consumer-grammar check re-run on the addendum bytes: 7 blank lines present, blank line
  precedes the table, renders as 1 `<table>` + 2 `<h3>` + 0 literal-pipe paragraphs.

## The decaying claim was re-verified, not copied

"Still present on current `main`" is a statement about a moving tip, so it was re-checked
immediately before being put back in front of maintainers, rather than carried over:
`GET /compare/7502e7d...main` → `ahead_by 14`, 144 files, **zero** under
`rust/otap-dataflow/crates/pdata/src/otap/transform/`, and the only `crates/pdata/` file
touched is `README.md`. `concatenate.rs` blob is `0d8b9f39`, 107944 bytes, **identical at
`7502e7d` and at `main`**. Tip `257cceb0`, `2026-07-23T16:03:28Z`. The wording in the
addendum matches what is true now.
