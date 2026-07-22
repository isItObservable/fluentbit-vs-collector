# ISI-1779 B1-v2 — RUN REGISTER

**Six timed runs. Two rounds × three engine phases. One row per run, written *as the run happens*.**

Plan of record: `benchmark-plan` on ISI-1779, **rev 6**, §5 and §5a.

---

## Why this file is the deliverable

There are **no snapshots** in this campaign (board directive, 2026-07-22 — plan rev 5 §5, decision **D8**).
Dynatrace records resource consumption and data flow continuously; the comparison is read *afterwards*
from dashboard **`764f7082-0039-4f3f-ad39-47b5abc5bb73`** with the run's time window applied.

That makes this register the **only record of what window a number came from**. Nothing is captured
locally during a run. A row with a missing, guessed, or local-time timestamp does not degrade the
result — it makes a **120-minute run unreadable**, and the only remedy is to run it again.

Treat writing a timestamp as part of the run, not as paperwork after it.

---

## How to capture a timestamp — copy this exact command

Do **not** read the clock off a laptop, a screenshot, a Slack message, or a pod's `START TIME` column.
Run this on the machine driving the phase, and paste the output verbatim:

```bash
date -u +%Y-%m-%dT%H:%M:%SZ
```

Rules that make a row trustworthy:

1. **Start** is captured **immediately before load begins** — after the §4 gate is green, before the
   first VU. Write the row *then*, with `End` still `⟨UNSET⟩`.
2. **End** is captured **the moment load stops and before any teardown**. Deleting the engine first and
   reconstructing the end time later is how a window silently gets 4 minutes of idle tail baked in.
3. **UTC only, seconds precision, trailing `Z`.** `2026-07-23T09:14:07Z`. Not `09:14`, not `+02:00`,
   not a local time with a note. The dashboard timeframe picker takes exactly this.
4. **A row is written even if the run is aborted** — mark it `ABORTED` in Validation gate and say why in
   Notes. An unrecorded failed run looks identical to a run that never happened.
5. The row is **mirrored into a comment on the phase issue** (ISI-1815…ISI-1820) as it is written, so the
   timestamps survive independently of this file.

### Self-check before you leave a phase

- [ ] `Start (UTC)` and `End (UTC)` are both real values — no `⟨UNSET⟩`, no placeholder left behind.
- [ ] `End` − `Start` ≈ **120 min** (±2 min). A wildly different duration means one of them is wrong.
- [ ] Both end in `Z` and contain seconds.
- [ ] `End` > `Start`, and `Start` is *after* the gate evidence timestamp.
- [ ] Image tag recorded is the tag that actually ran (`kubectl get pod -o jsonpath='{..image}'`), not the
      tag the manifest says it wants.
- [ ] Row mirrored to the phase issue comment.
- [ ] Round 2's row for this engine does **not** reuse Round 1's window.

---

## Register

Run ID format: `R<round>-P<phase>-<engine>` — e.g. `R1-P1-collector`.
Phase order is fixed by plan §1: **P1 = OTel Collector → P2 = Fluent Bit v5 → P3 = OTel-Arrow native**.

| Run ID | Engine + image tag | Round | Start (UTC) | End (UTC) | Validation gate | Load profile | Notes |
|---|---|---|---|---|---|---|---|
| `R1-P1-collector` | otel-collector contrib `0.154.0` | 1 | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | `rampup2h` 50→100→150→200 VU, both apps | |
| `R1-P2-fluentbit` | fluent-bit `5.0.9` | 1 | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | `rampup2h` 50→100→150→200 VU, both apps | |
| `R1-P3-arrow` | `ghcr.io/isitobservable/df_engine:0.50.0` | 1 | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | `rampup2h` 50→100→150→200 VU, both apps | |
| `R2-P1-collector` | otel-collector contrib `0.154.0` | 2 | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | `rampup2h` 50→100→150→200 VU, both apps | |
| `R2-P2-fluentbit` | fluent-bit `5.0.9` | 2 | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | `rampup2h` 50→100→150→200 VU, both apps | |
| `R2-P3-arrow` | `ghcr.io/isitobservable/df_engine:0.50.0` | 2 | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | `rampup2h` 50→100→150→200 VU, both apps | |

**Owning issue per row:** R1-P1 = ISI-1815 · R1-P2 = ISI-1816 · R1-P3 = ISI-1817 ·
R2-P1 = ISI-1818 · R2-P2 = ISI-1819 · R2-P3 = ISI-1820.

### Column contract

| Column | What goes in it |
|---|---|
| **Run ID** | `R<round>-P<phase>-<engine>`, from the table above. Never invent a new one. |
| **Engine + image tag** | The image that actually ran, resolved from the running pod. |
| **Round** | `1` or `2`. Round 2 is a **fresh deploy of everything**, not a re-read of Round 1's pods. |
| **Start (UTC)** | `date -u +%Y-%m-%dT%H:%M:%SZ`, captured before the first VU. |
| **End (UTC)** | Same command, captured when load stops, before teardown. |
| **Validation gate** | `PASS 5/5` plus the §4 evidence pointer (phase-issue comment ID), or `ABORTED` + reason. |
| **Load profile** | `rampup2h`, VU ladder, and that **both** apps were driven. Any deviation invalidates cross-phase comparison — say so loudly. |
| **Notes** | Anything that could explain an outlier: restarts, OOM kills, node pressure, cluster events, export retries, a redeploy mid-run. Empty means "nothing anomalous", so do not leave it empty out of haste. |

---

## Gate evidence (per run)

`validate-phase.sh <engine>` prints one `CHECK <n> PASS|FAIL <name> <detail>` line per check. Paste the five
lines into the phase issue comment alongside the row. Summarise here as `PASS 5/5 — <comment id>`.

```
CHECK 1 PASS apps-healthy      ...
CHECK 2 PASS app-spans         ...
CHECK 3 PASS sidecars          ...
CHECK 4 PASS istio-spans       ...
CHECK 5 PASS engine-healthy    ...
```

A run started on anything other than `PASS 5/5` is not comparable to the other five and must be
recorded as such — an unvalidated phase is worse than a missing one, because it looks like data.

---

## Reading a window back in Dynatrace

1. Open dashboard `764f7082-0039-4f3f-ad39-47b5abc5bb73`
   ("Fluent Bit v5 vs OTel-Collector vs OTel-Arrow — Benchmark Comparison (ISI-1779 B1-v2,
   timeframe-driven)"). This is the *same* dashboard the plan §5 cites — it was updated in place
   rather than replaced, so every existing reference to `764f7082` still resolves.
2. Set the dashboard timeframe to the row's **Start → End**, exactly as written.
3. Every tile is sliced by `k8s.workload.name`, so the engine under test in that window reads out
   directly — CPU (millicores), memory working set, restarts/OOM, and ingest volume by signal.
4. Compare `R1-P<n>-<engine>` against `R2-P<n>-<engine>` for the same engine to see replication, and
   across engines *within a round* for the headline comparison.

### Two readout traps this campaign has already paid for

- **Absolute timeframes in DQL are a QUOTED string or nothing.** If you replay a window by hand
  instead of via the timeframe picker: `from:"2026-07-23T09:14:07Z"`. Unquoted is a `PARSE_ERROR`
  and `timestamp("...")` fails with *"has to be a long, but was a string"*. The entire no-snapshot
  design rests on being able to replay a register window long after the run ended.
- **`dt.kubernetes.container.restarts` is SPARSE** — a workload that never restarted has *no series
  at all*, so "no rows" is indistinguishable from a broken query. The stability tile (tile 4) already
  handles this: it anchors on `cpu_usage` (always present), left-joins restarts/OOM via `lookup`, and
  coalesces to `0`, so a healthy engine reads an explicit `0` instead of vanishing. Verified live
  against five never-restarted workloads. Do not "simplify" that tile into a bare restarts
  `timeseries` — you would turn every healthy run into an empty panel, and worse, **a restart resets
  memory and fakes a clean flat trend**, so a missed restart turns a leak into a passing result.

Only one engine is deployed at a time (plan §1), so a correctly-scoped window contains exactly one
engine workload. If a window shows two, the window is wrong — most likely an End timestamp captured
after the next phase started.

**Scope reminder (D1):** Istio/Envoy Prometheus metrics are excluded from every run. App-emitted OTLP
metrics **are** in scope and are measured. Istio-generated spans and access logs are in scope.
