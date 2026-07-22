# ISI-1779 B1-v2 — RUN REGISTER

**Six timed runs. Two rounds × three engine phases. One row per run, written *as the run happens*.**

Plan of record: `benchmark-plan` on ISI-1779, **rev 7**, §5, §5a and **§5b (pod census)**.

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

## The second thing this file has to prove: **no pod was replaced mid-window** (D12)

A timestamp pair alone does not make a window readable. **A pod replacement — reschedule, eviction,
node drain, rollout — is INVISIBLE to `dt.kubernetes.container.restarts`.** That metric counts
*in-place container restarts only*; a replaced pod gets a new name and leaves the metric completely
empty. A newborn pod also reports ~2 MiB, so a workload-level `avg()`/`min()` blends it straight into
the aggregate and the run looks clean.

Observed live on `observable-otelarrow` (ISI-1811, re-proven for this issue on 2026-07-22 over the
48-hour window `2026-07-20T11:00:00Z → 2026-07-22T11:00:00Z`): **six pod names across two workloads,
and a restarts timeseries over the same window returning zero datapoints.** A workload floor read
1.99 MiB in one bucket against ~70 MiB either side — pure artifact.

So the register carries a **pod census**: the engine's pod names, each pod's `creationTimestamp`, the
expected replica count, and the cluster. Without those four, "no pod was replaced during this run" is
an unfalsifiable claim, and a 120-minute number rests on it. **A run whose End census does not match
its Start census — same pod names, same creationTimestamps — is INVALID and must be re-run.**

The dashboard enforces the same rule from the other side: tile **POD CENSUS — VALIDITY GATE** is the
first tile under the header, groups by `k8s.pod.name`, and flags any pod alive for less than 90% of
the window. Read it before any other tile.

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

## How to capture the pod census — copy this exact command

Run it **twice**: once immediately after the Start timestamp, once immediately before the End
timestamp, *before any teardown*. Paste the output verbatim into the census table below.

```bash
kubectl get pods -A --no-headers \
  -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,CREATED:.metadata.creationTimestamp,NODE:.spec.nodeName,PHASE:.status.phase,RESTARTS:.status.containerStatuses[*].restartCount' \
  | awk '$2 ~ /^bench-/'
```

Expected replica count, from the manifest that is actually applied:

```bash
kubectl get deploy,statefulset -n default -o custom-columns='KIND:.kind,NAME:.metadata.name,DESIRED:.spec.replicas' | grep bench-
```

All three engines run **`replicas: 1`** in namespace `default` on cluster `observable-otelarrow`, so
the census must show **exactly one pod**, with an unchanged name and `creationTimestamp` at both ends
of the window. Two pod names in one run means a replacement happened — the run is invalid, regardless
of what the restarts metric says, because it will say nothing.

### Self-check before you leave a phase

- [ ] `Start (UTC)` and `End (UTC)` are both real values — no `⟨UNSET⟩`, no placeholder left behind.
- [ ] `End` − `Start` ≈ **120 min** (±2 min). A wildly different duration means one of them is wrong.
- [ ] Both end in `Z` and contain seconds.
- [ ] `End` > `Start`, and `Start` is *after* the gate evidence timestamp.
- [ ] Image tag recorded is the tag that actually ran (`kubectl get pod -o jsonpath='{..image}'`), not the
      tag the manifest says it wants.
- [ ] **Census captured twice** — at Start and at End — and both rows written below.
- [ ] **Pod names identical at Start and End**, and **`creationTimestamp` identical at Start and End**.
      A changed name *or* a changed creationTimestamp = a replacement = **RUN INVALID**.
- [ ] **Pod count == expected replicas (1)** in both censuses.
- [ ] Dashboard `POD CENSUS — VALIDITY GATE` tile is green for this window (every pod ≥ 90% coverage,
      pod count == expected replicas). Its verdict and this file's census must agree; if they disagree,
      trust neither and re-run.
- [ ] Row mirrored to the phase issue comment.
- [ ] Round 2's row for this engine does **not** reuse Round 1's window.

---

## Register

Run ID format: `R<round>-P<phase>-<engine>` — e.g. `R1-P1-collector`.
Phase order is fixed by plan §1: **P1 = OTel Collector → P2 = Fluent Bit v5 → P3 = OTel-Arrow native**.

| Run ID | Engine + image tag | Round | Cluster | Expected replicas | Start (UTC) | End (UTC) | Validation gate | Census | Load profile | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| `R1-P1-collector` | otel-collector contrib `0.154.0` | 1 | `observable-otelarrow` | 1 | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | `rampup2h` 50→100→150→200 VU, both apps | |
| `R1-P2-fluentbit` | fluent-bit `5.0.9` | 1 | `observable-otelarrow` | 1 | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | `rampup2h` 50→100→150→200 VU, both apps | |
| `R1-P3-arrow` | `ghcr.io/isitobservable/df_engine:0.50.0` | 1 | `observable-otelarrow` | 1 | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | `rampup2h` 50→100→150→200 VU, both apps | |
| `R2-P1-collector` | otel-collector contrib `0.154.0` | 2 | `observable-otelarrow` | 1 | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | `rampup2h` 50→100→150→200 VU, both apps | |
| `R2-P2-fluentbit` | fluent-bit `5.0.9` | 2 | `observable-otelarrow` | 1 | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | `rampup2h` 50→100→150→200 VU, both apps | |
| `R2-P3-arrow` | `ghcr.io/isitobservable/df_engine:0.50.0` | 2 | `observable-otelarrow` | 1 | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | `rampup2h` 50→100→150→200 VU, both apps | |

**Owning issue per row:** R1-P1 = ISI-1815 · R1-P2 = ISI-1816 · R1-P3 = ISI-1817 ·
R2-P1 = ISI-1818 · R2-P2 = ISI-1819 · R2-P3 = ISI-1820.

### Pod census — one block per run, captured at Start AND at End (D12)

The names and `creationTimestamp`s here are the **only** evidence that the window contains one
continuous pod lifetime. `Restarts` is recorded for completeness, but it is *not* the check — a
replaced pod shows no restart at all. **The check is: same pod name, same `creationTimestamp`, at both
ends, count == expected replicas.**

| Run ID | When | Pod name | `creationTimestamp` | Node | Restarts | Verdict |
|---|---|---|---|---|---|---|
| `R1-P1-collector` | Start | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ |
| `R1-P1-collector` | End | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ |
| `R1-P2-fluentbit` | Start | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ |
| `R1-P2-fluentbit` | End | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ |
| `R1-P3-arrow` | Start | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ |
| `R1-P3-arrow` | End | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ |
| `R2-P1-collector` | Start | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ |
| `R2-P1-collector` | End | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ |
| `R2-P2-fluentbit` | Start | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ |
| `R2-P2-fluentbit` | End | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ |
| `R2-P3-arrow` | Start | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ |
| `R2-P3-arrow` | End | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ |

Expected workload names, one pod each: `bench-otel-collector-collector` (P1, created by the OTel
operator — note the `-collector` suffix the operator appends), `bench-fluentbit-v5` (P2),
`bench-otel-arrow-native` (P3). If a run needs more than one row per `When`, the pod count already
exceeds the expected replica count and the run is invalid.

`Verdict` is `MATCH` (name and creationTimestamp identical to the Start row, count == 1) or
`REPLACED → RUN INVALID` plus what happened. There is no third value.

### Column contract

| Column | What goes in it |
|---|---|
| **Run ID** | `R<round>-P<phase>-<engine>`, from the table above. Never invent a new one. |
| **Engine + image tag** | The image that actually ran, resolved from the running pod. |
| **Round** | `1` or `2`. Round 2 is a **fresh deploy of everything**, not a re-read of Round 1's pods. |
| **Cluster** | `observable-otelarrow`. Recorded explicitly because `k8s.workload.name` is **not unique across the clusters on this tenant** — `observable-kagent` and `observable-agentsandbox` report the same `dt.kubernetes.container.*` metric keys. A readout that forgets to scope by cluster silently mixes in another cluster's series. |
| **Expected replicas** | `1` for all three engines. This is what the census pod count is checked against; without it, "one pod" is an assumption rather than a comparison. |
| **Start (UTC)** | `date -u +%Y-%m-%dT%H:%M:%SZ`, captured before the first VU. |
| **End (UTC)** | Same command, captured when load stops, before teardown. |
| **Validation gate** | `PASS 5/5` plus the §4 evidence pointer (phase-issue comment ID), or `ABORTED` + reason. |
| **Census** | `MATCH` (Start and End censuses identical, count == expected replicas) or `REPLACED → RUN INVALID`. The per-pod detail lives in the census block above. A `PASS 5/5` gate with a failed census is still an invalid run — the gate runs *before* the window, the census covers the whole of it. |
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
3. **Read the `POD CENSUS — VALIDITY GATE` tile first.** It is the first tile under the header. Every
   pod must show `coverage_pct ≥ 90` and the verdict `ok`, and `Pods seen per engine` must equal this
   row's **Expected replicas**. If it does not, **stop** — the window's numbers are not reportable, no
   matter how clean the charts below look. Cross-check it against this row's census block; they must
   agree.
4. Every tile is grouped by `k8s.pod.name` and scoped by `k8s.cluster.name`, so the engine under test
   in that window reads out directly — CPU (millicores), memory working set, restarts/OOM, and ingest
   volume by signal — with a replaced pod appearing as its **own row** rather than being averaged into
   the workload.
5. Compare `R1-P<n>-<engine>` against `R2-P<n>-<engine>` for the same engine to see replication, and
   across engines *within a round* for the headline comparison.

### Three readout traps this campaign has already paid for

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
- **A pod REPLACEMENT is not a restart, and nothing in the restarts metric will ever tell you it
  happened.** `dt.kubernetes.container.restarts` counts in-place container restarts only. A
  reschedule, eviction, node drain or rollout gives you a new pod name and an *empty* metric, while a
  newborn pod reporting ~2 MiB poisons any workload-level `min()`/`avg()`. Re-proven live on
  `observable-otelarrow` over `2026-07-20T11:00:00Z → 2026-07-22T11:00:00Z`: six pod names across two
  workloads, zero restart datapoints. This is why the census exists and why the dashboard groups by
  `k8s.pod.name`. The census threshold is **90% bucket coverage, not 100%** — the first and last bucket
  of any window are partially covered by the metric's own cadence, so a healthy pod reads ~96.7% on a
  2h/1-minute window and never exactly 100%; real replacements measured 27–56%.

Only one engine is deployed at a time (plan §1), so a correctly-scoped window contains exactly one
engine workload **and exactly one engine pod**. If a window shows two workloads, the window is wrong —
most likely an End timestamp captured after the next phase started. If it shows one workload but two
pod names, the pod was replaced and the run is invalid.

**Scope reminder (D1):** Istio/Envoy Prometheus metrics are excluded from every run. App-emitted OTLP
metrics **are** in scope and are measured. Istio-generated spans and access logs are in scope.
