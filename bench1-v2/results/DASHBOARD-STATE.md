# Dynatrace dashboard `764f7082-0039-4f3f-ad39-47b5abc5bb73` — state and why

**Current version: 7** (2026-07-23, ISI-1816).

`@BigBoss reads the Dynatrace dashboard for the recorded window and consolidates`
— so a wrong tile here becomes a wrong number on camera. This file records what
was changed and why, because the *why* is not obvious from the DQL.

## v6/v7 — the log tiles were reporting Fluent Bit as 0

Tiles **5** (*Ingest volume by signal*) and **7** (*Ingest rate over the run*)
both filtered their `fetch logs` branch with
`k8s.cluster.name == "observable-otelarrow"`.

Fluent Bit **never lands `k8s.cluster.name` on the logs signal** — null on every
record, with **zero processor errors reported**. The same upsert works fine on
spans. Measured over the R1P2 window:

| arm | logs, by `benchmark.engine` | as the tiles filtered them |
|---|---|---|
| `R1-P1-collector` | 10,656,970 | 10,656,970 — identical |
| `R1-P2-fluentbit` | **5,262,729+** | **0** |

Read as-is the dashboard said *"Collector 10.6M logs, Fluent Bit 0"* — i.e.
Fluent Bit dropped every log, when it was in fact delivering **more** logs than
the collector. This is worse than the metrics failure: that one produced a
blank, and a blank invites a question. This produced a large, directional,
entirely plausible number, and nobody queries behind a number that confirms
what they already expect.

**Fix (read-time, not config — telemetry is frozen so the engine stays the only
variable):** drop `k8s.cluster.name` from the **logs branch only**.
`benchmark.engine` is campaign-unique — verified 2026-07-23, no cluster other
than `observable-otelarrow` stamps it on logs — so it discriminates safely
alone. The **spans** branch keeps the cluster filter: the attribute lands there
and it guards the cross-cluster `k8s.workload.name` collision (D12.4).

## v6 was broken — and it is why every tile is now executed, not read

v6 placed the explanatory comment *inline after the filter*. DQL `//` runs to
end of line, and `| fieldsAdd signal = "logs"` sat on that same line — so v6
commented it out. Tile 5 silently degraded (`signal: null` instead of `logs`)
and **tile 7 became a `PARSE_ERROR`**, because the swallowed text included the
`]` closing the `append`.

v6 passed a string-match check that only asserted the cluster filter was gone.
It never ran the query. **v7 moved the comment onto its own lines before
`fetch logs`, and verification now EXECUTES all 13 queryable tiles.**

Lesson, the same one this campaign keeps re-learning: a check that inspects text
rather than behaviour will certify something that does not work.

## Verified at v7 (2026-07-23)

```
all 13 queryable tiles execute            ok
tile 5  R1P1  spans 18,499,537 · logs 10,656,970   (spans match the banked figure exactly)
tile 5  R1P2  spans 10,522,098 · logs  6,036,974   signal correctly "logs"
tile 7  R1P2  timeseries returns, signal "logs"
6 span tiles still cluster-scoped         unchanged
```
