# Tier 4 — Comparison: collector v0.159.0 vs Fluent Bit v5.1.1 (+ tail sampling)
## Signal set: LOGS + METRICS + TRACES + TAIL SAMPLING

> ⚠️ **ERRATUM / SUPERSEDED — re-run in progress.** An earlier version of this page framed
> Tier 4 as *collector-only* tail sampling and ran Fluent Bit as a "no-tail-sampling control."
> **That framing is wrong:** Fluent Bit v5 ships a
> [`sampling` processor](https://docs.fluentbit.io/manual/data-pipeline/processors/sampling)
> that supports **tail sampling** (`type: tail`). In this first pass only the collector arm was
> configured with a sampling stage, so the **cross-engine numbers below are not like-for-like**
> and are being **re-run with both engines tail-sampling**. Tiers 1–3 are final; the Tier-4
> verdict here is provisional pending that re-run.

Tier 4 adds an in-pipeline **tail-sampling** stage on top of the Tier-3 trace pipeline. Both
engines can do this — the collector with its `tail_sampling` processor, Fluent Bit v5 with its
`sampling` (`type: tail`) processor. The comparison below reflects the first pass, in which the
Fluent Bit arm was mistakenly run **without** its sampling stage; treat its numbers as a
no-sampling baseline, not the tail-sampling comparison.

---

## Run parameters (first pass)

| Parameter | ARM 1 — collector v0.159.0 (+tail sampling) | ARM 2 — Fluent Bit v5.1.1 (ran without sampling — provisional) |
|---|---|---|
| Duration | 2h gate + 24h soak | 2h gate + 24h soak |
| Log source | DaemonSet (filelog receiver) | DaemonSet (tail input) |
| Metrics source | StatefulSet (Prometheus receiver: istiod + Kepler) | StatefulSet (Prometheus input: istiod + Kepler) |
| Traces source | Deployment (OTLP gRPC :4317) | Deployment (OTLP HTTP :4318) |
| Traces load | telemetrygen @200 span/s | telemetrygen @200 span/s (HTTP) |
| Tail sampling | `tail_sampling`: keep-errors OR (NOT healthcheck AND 30% probabilistic); `decision_wait=10s`, `num_traces=100000` | **not configured this pass** (Fluent Bit v5 supports `sampling` `type: tail`; enabled in the re-run) |

---

## Validity + soak gates (both arms valid as run)

| Gate | collector | Fluent Bit (no sampling this pass) |
|---|---|---|
| Census (engine STRICT, 0-restart) | ✅ PASS (5 pods) | ✅ PASS (5 pods) |
| Load reaching app | ✅ PASS | ✅ PASS |
| Received at backend | ✅ 126,653,903 sent / 0 send_failed | ✅ 71,058,095 proc / 0 dropped |
| Memory verdict (24h) | ✅ TAIL-FLAT (+0.00%, 413.5 MiB) | ✅ TAIL-FLAT (+1.81%, 197.2 MiB) |
| Overall validity | ✅ VALID | ✅ VALID |

---

## Loss accounting (collector, cumulative)

| Metric | Value | % of accepted |
|---|---|---|
| accepted | 784,007,483 | — |
| refused | 35,616 | 0.005% |
| sent | 1,478,167,009 | 1.885× (multi-exporter fan-out, expected) |
| send_failed | 10,460 | 0.0013% of accepted |

Fluent Bit equivalent: **0 dropped** (output proc_records = 71,058,095).

---

## Resource snapshot at T+24h (working-set memory / CPU)

### Collector v0.159.0 (+tail sampling)

| Component | CPU | Memory |
|---|---|---|
| logs DaemonSet ×3 | 50m / 30m / 47m | 62 / 59 / 60 MiB |
| metrics StatefulSet ×1 | 11m | 81 MiB |
| **traces Deployment ×1 (tail sampling)** | 27m | **152 MiB** |
| **Total (5 pods)** | **~165m** | **~413 MiB** |

### Fluent Bit v5.1.1 (no sampling this pass — provisional)

| Component | CPU | Memory |
|---|---|---|
| logs DaemonSet ×3 | 66m / 19m / 16m | 17 / 14 / 8 MiB |
| metrics StatefulSet ×1 | 3m | 9 MiB |
| traces Deployment ×1 | 39m | 150 MiB |
| **Total (5 pods)** | **~143m** | **~198 MiB** |

> The Fluent Bit total above is a **no-sampling** figure — its trace pod was not running a
> sampling stage — so it is not comparable to the collector's tail-sampling total. The
> like-for-like comparison lands in the re-run.

---

## What turning on the collector's tail sampling cost (valid collector self-measurement)

| | Tier 3 (no TS) | Tier 4 (TS on) | Delta |
|---|---|---|---|
| Collector traces-pod memory | 53 MiB | **152 MiB** | **~2.9× (+~99 MiB)** |
| Collector 5-pod aggregate memory | ~337 MiB | ~413 MiB | +76 MiB (~+23%) |

Tail-sampling processor stats over the soak: **37,491,952** new trace IDs received;
**11,246,417 sampled** / 26,241,185 not-sampled under the 30% probabilistic policy. The
decision buffer rode its `num_traces=100000` cap the whole soak
(`sampling_traces_on_memory=100000`) — sized *at* the limit, not beyond it — with 0
policy-evaluation errors and 0 traces dropped too early, and still the flattest memory run of
the whole benchmark (+0.00%). This is a measure of the **collector's** tail-sampling cost;
Fluent Bit's tail-sampling cost is measured in the re-run.

---

## Verdict (provisional — pending the both-engines-sampling re-run)

| Dimension | collector v0.159.0 | Fluent Bit v5.1.1 (no sampling this pass) | Note |
|---|---|---|---|
| Soak validity (census 0-restart) | ✅ VALID | ✅ VALID | tie |
| Data loss | ⚠️ refused 35,616 / failed 10,460 (≤0.005%) | ✅ 0 dropped | FB, but see caveat below |
| Memory at 24h (5-pod) | ~413 MiB (with sampling) | ~198 MiB (**without** sampling) | not comparable this pass |
| In-pipeline tail sampling | ✅ `tail_sampling` | ✅ supported via `sampling` `type: tail` (enabled in re-run) | both engines |

**Summary (provisional):** both arms soaked census-clean and tail-flat. The valid finding this
pass is the **collector's** own Tier-3 → Tier-4 tail-sampling cost (~2.9× its trace-pod memory,
53 → 152 MiB). The cross-engine memory/CPU comparison is **not** like-for-like here because the
Fluent Bit arm ran without a sampling stage — that comparison is deferred to the re-run in which
both engines tail-sample. The Tiers 1–3 findings (Fluent Bit consistently lighter, zero loss)
are unaffected.
