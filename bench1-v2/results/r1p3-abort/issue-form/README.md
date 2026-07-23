# Upstream issue form — one file per field

`https://github.com/open-telemetry/otel-arrow/issues/new?template=bug_report.yaml`

**Each file is exactly one form field and nothing else.** No headings, no commentary, no
markers — open it, select all, paste into the matching field. That is the whole design:
anything I added for readability would have to be deleted by hand at paste time.

| file | form field | notes |
|---|---|---|
| `01-pre-filing-checklist.md` | Pre-filing checklist |  |
| `02-components.md` | Component(s) | dropdown, pick exactly this |
| `03-version.md` | OTel-Arrow Version | single-line input |
| `04-bug-description.md` | Bug Description |  |
| `05-steps-to-reproduce.md` | Steps to Reproduce |  |
| `06-expected-behavior.md` | Expected Behavior |  |
| `07-actual-behavior.md` | Actual Behavior |  |
| `08-environment.md` | Environment |  |
| `09-configuration.yaml` | Configuration | ⚠️ `render: yaml — paste RAW, do NOT add a ``` fence` — paste RAW, GitHub fences it for you |
| `10-log-output.log` | Log Output | ⚠️ `render: shell — paste RAW, do NOT add a ``` fence` — paste RAW, GitHub fences it for you |
| `11-additional-context.md` | Additional Context |  |

## Title (not a form field — the box above the form)

```
df_engine: all pipeline cores die under real OTLP load (boo panic in metrics record encoder + arrow DictionaryKeyOverflowError), process stays alive and reports healthy
```

## Two things that will bite if skipped

- **`09-configuration.yaml` and `10-log-output.log` are `render:` fields.** GitHub wraps
  them in a code fence itself. They are stored here with no fence for that reason — adding
  one double-fences the field and renders broken. The file extensions are deliberate: they
  are not markdown and must not be treated as such.
- **`03-version.md` is a single-line input.** Only the commit SHA line goes there; build
  flags and runtime live in `08-environment.md`.

## The pre-filing checkbox is a claim, and checking it changed this report

`01-pre-filing-checklist.md` records what was actually searched. The result was not a
formality: the `boo` panic is **already known** — draft PR #2984 root-causes it and is
open/unmerged, so absent from our build SHA — while `DictionaryKeyOverflowError` returned
**zero** hits and was 3 of 4 cores. The report therefore corroborates #2984 rather than
re-reporting it, and leads with the overflow. Re-run the search before filing if time has
passed; a duplicate-search result decays like any other cited evidence.
