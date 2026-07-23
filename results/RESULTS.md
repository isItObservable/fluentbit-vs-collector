# Results

**Round 1, phases 1 and 2. One run per arm. Round 2 has not run.**

Every figure below comes from Dynatrace over an explicit, recorded window, via
`benchmark/readout.sh` and `benchmark/normalise.sh`. The windows, pod censuses
and gate results are in [RUN-REGISTER.md](RUN-REGISTER.md).

---

## Headline

> **Fluent Bit v5 spends ~36% less CPU per record than the OpenTelemetry
> Collector, and ~20% more memory per record.** Peak working set is +59%.

It is a **trade, not a win**. Two ways of quoting it that overstate the result:

- **"−38.6% CPU"** — that is the *absolute* delta, and the two arms did not serve
  the same request volume. Fluent Bit was handed 3.55% fewer records. Per record
  the figure is −36.3%.
- **"Fluent Bit uses fewer resources"** — memory moves the other way, on both the
  average and the peak.

---

## The two arms

| | **R1-P1 · otel-collector** | **R1-P2 · fluentbit-v5** |
|---|---|---|
| Image | `otel/opentelemetry-collector-contrib:0.154.0` | `fluent/fluent-bit:5.0.9` |
| Window (UTC) | `2026-07-22T15:58:43Z → 17:59:21Z` | `2026-07-23T08:34:49Z → 10:35:12Z` |
| Elapsed | 120.6 min | 120.4 min |
| Gate | 6/6 | 6/6 (see caveat 2) |
| Census | MATCH — 1 pod, 0 restarts | MATCH — 1 pod, 0 restarts |

### Throughput delivered

| | otel-collector | fluentbit-v5 | Δ |
|---|---:|---:|---:|
| Spans — Istio mesh | 9,340,725 | 8,974,246 | −3.92% |
| Spans — app SDK | 9,158,812 | 8,884,341 | −3.00% |
| **Spans total** | **18,499,537** | **17,858,584** | **−3.46%** |
| Logs | 10,656,970 | 10,263,964 | −3.69% |
| Metrics | delivered | **not delivered** — caveat 2 | — |
| **Total records** | **29,156,507** | **28,122,548** | **−3.55%** |

Both span figures conserve against their totals. Fluent Bit dropped nothing:
its own counters report `dropped_records = 0`, `errors = 0`,
`retries_failed = 0` over 10.26M log records. The −3.55% is *upstream* — the
apps served fewer requests — not engine loss. Mesh spans are emitted per request
hop, and they move with the app-SDK spans, which is what an upstream cause looks
like.

### Resource cost

| | otel-collector | fluentbit-v5 | Δ |
|---|---:|---:|---:|
| CPU avg (mCores) | 190.7 | 117.1 | **−38.6%** |
| CPU p95 / max (mCores) | — | 167.9 / 173.0 | |
| Memory avg (MiB) | 108.2 | 125.3 | **+15.8%** |
| Memory peak (MiB) | 130.7 | 207.3 | **+58.6%** |

### Normalised — the comparable figures

| | otel-collector | fluentbit-v5 | Δ |
|---|---:|---:|---:|
| **mCores / 1M records** | 6.54 | 4.16 | **−36.3%** |
| **MiB / 1M records** | 3.71 | 4.46 | **+20.1%** |

Reproduce with:

```bash
./benchmark/normalise.sh R1-P1-collector 2026-07-22T15:58:43Z 2026-07-22T17:59:21Z \
                         R1-P2-fluentbit 2026-07-23T08:34:49Z 2026-07-23T10:35:12Z
```

### The obvious objection, checked rather than assumed

*"The collector only looks lean on memory because it runs a `memory_limiter`."*
Well-founded on its face — the manifest itself calls it a known asymmetry. It is
not what happened. Container limit is **2 GiB on both**. The limiter's hard
threshold is 80% = 1638 MiB, soft = 1229 MiB. The collector peaked at **130.7
MiB = 10.6% of the soft threshold**. The limiter never engaged and could not have
capped anything. The +20% is a real behavioural difference, not a config
artefact.

> **A disclosed asymmetry is not automatically an active one** — compare the
> threshold to the observed value before you either credit or discount it.

---

## Caveats — these are the interesting part

### 1. Round 1 ran with a parallel collector pipeline on the same nodes

Two DaemonSets tailing every container log plus three gateway Collectors — **9
pods, ~932 mCores, 5–8× the engine under test** — ran on the same three nodes for
the whole of Round 1.

- **Record counts are safe.** Every query filters on `benchmark.engine`, which
  that pipeline never sets.
- **The comparison holds.** It was present, unchanged, for both arms — a
  constant, and constants cancel.
- **It is a plausible mechanism for the −3.55% throughput gap.** App log volume
  drives agent CPU, which competes with the apps on nodes with no spare capacity.
- **Tenant-share figures from Round 1 are not comparable** and are not quoted.

It is removed before Round 2. That makes Round 2 not directly comparable to
Round 1 on *absolute* CPU — compare within a round.

### 2. R1-P2 delivered no app-OTLP metrics, and it was our bug, not the engine's

Fluent Bit exported **zero** application OTLP metric datapoints for the whole
window. The cause is a missing `context:` on the metrics `content_modifier` in
our own `deploy/engines/fluentbit-v5.yaml`: logs and traces have a valid default
context, metrics has none, so the metrics chain aborted at stage 0 with a 100%
processor error rate and never reached the later stages — including the
`cumulative_to_delta` conversion that was declared all along and simply never
ran.

Proven, not inferred, on a scratch cluster with five identical OTLP payloads:

| | stage 0 | stages 1–3 | input records | output records |
|---|---|---|---|---|
| without `context:` | 5 invocations / **5 errors** | never reached | 0 | 0 |
| with `context: otel_resource_attributes` | 5 / **0 errors** | all invoked | 5 | 5 |

So **"Fluent Bit cannot do metrics" is wrong** and would have been unfair to say.
The evidence is in [probes/](probes/).

The fix is in the repo. It is **effective from Round 2** and is deliberately not
back-dated onto R1-P2's numbers: R1-P2 measured a configuration that shipped no
metrics, and that is what its row says. Round 1's metrics dimension is
asymmetric; the load, spans, logs and resource figures are unaffected.

Two things this hid, and how:

- **The gate passed.** Check 5 summed accepted/exported across *all* signals
  (dominated by logs and traces) and read 283,359/283,021. An aggregate
  throughput assertion cannot see one signal die. Check **5b** — per-signal —
  now turns the gate red on exactly this.
- **The log was silent.** At `log_level: info` a 100% processor failure logs
  nothing; `grep -i error` shows only benign idle-keepalive reaps.

### 3. Fluent Bit does not stamp `k8s.cluster.name` on logs

It lands the attribute on **100% of spans** and **0% of logs**, reporting zero
processor errors either way.

Any log query filtered on `k8s.cluster.name` therefore returns **zero** for that
arm. This is not a data loss — it is a *read* defect, and it produced the worst
single number of the campaign: the dashboard's log tiles showed **0 logs** for an
engine that had delivered 10.26 million and dropped none.

> A missing signal produces a blank, which invites a question. This produced a
> large, directional, plausible **number** — "Fluent Bit dropped every log" — and
> nobody queries behind a number that confirms an expectation.

Fixed at read time (the logs branch drops the cluster filter; `benchmark.engine`
is unique to this campaign and discriminates alone). Spans **keep** the cluster
filter — the attribute lands there, and it guards against workload-name
collisions across clusters. `benchmark/attr-landing.sh` reports this per signal
before every run.

### 4. One run per arm

Round 2 exists to replicate Round 1. Until then, treat every figure here as a
single observation. Fluent Bit's memory figure in particular includes buffering
(it is memory-backed), so confirm it reproduces before quoting it as a property
of the engine.

---

## A third engine

OTel-Arrow native (`df_engine`) is benchmarked on the
`collector-fluentbitV5-otel-arrow` branch, using this same harness. It has not
produced a valid run yet, so there is no third column to compare against here.

## Reproducing these numbers

Everything above is derivable from the recorded windows:

```bash
./benchmark/readout.sh R1-P1-collector 2026-07-22T15:58:43Z 2026-07-22T17:59:21Z
./benchmark/readout.sh R1-P2-fluentbit 2026-07-23T08:34:49Z 2026-07-23T10:35:12Z
```

You will not reproduce them *exactly* on your own cluster — different hardware,
different node contention, a different Dynatrace tenant. What should reproduce is
the **shape**: Fluent Bit cheaper on CPU per record, dearer on memory per record,
and neither engine losing data.
