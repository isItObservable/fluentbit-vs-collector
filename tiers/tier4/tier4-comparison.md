# Tier 4 — Comparison: collector v0.159.0 (+tail sampling) vs Fluent Bit v5.1.1 (control)
## Signal set: LOGS + METRICS + TRACES + TAIL SAMPLING (collector-only stage)

Tier 4 adds the **`tail_sampling` processor** to the collector's Tier-3 trace pipeline.
Fluent Bit has no in-pipeline tail-sampling stage, so its Tier-4 arm runs the **same shape as
Tier 3** and serves as the **no-tail-sampling control** — the Tier 3 → Tier 4 tail-sampling
cost is therefore read on the collector arm.

---

## Run parameters

| Parameter | ARM 1 — collector v0.159.0 (+tail sampling) | ARM 2 — Fluent Bit v5.1.1 (no-TS control) |
|---|---|---|
| Duration | 2h gate + 24h soak | 2h gate + 24h soak |
| Log source | DaemonSet (filelog receiver) | DaemonSet (tail input) |
| Metrics source | StatefulSet (Prometheus receiver: istiod + Kepler) | StatefulSet (Prometheus input: istiod + Kepler) |
| Traces source | Deployment (OTLP gRPC :4317) | Deployment (OTLP HTTP :4318) |
| Traces load | telemetrygen @200 span/s | telemetrygen @200 span/s (HTTP) |
| Tail sampling | keep-errors OR (NOT healthcheck AND 30% probabilistic); `decision_wait=10s`, `num_traces=100000` | n/a (no stage) |

---

## Validity + soak gates

| Gate | collector | Fluent Bit (control) |
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

## Resource comparison at T+24h (working-set memory / CPU)

### Collector v0.159.0 (+tail sampling)

| Component | CPU | Memory |
|---|---|---|
| logs DaemonSet ×3 | 50m / 30m / 47m | 62 / 59 / 60 MiB |
| metrics StatefulSet ×1 | 11m | 81 MiB |
| **traces Deployment ×1 (tail sampling)** | 27m | **152 MiB** |
| **Total (5 pods)** | **~165m** | **~413 MiB** |

### Fluent Bit v5.1.1 (control)

| Component | CPU | Memory |
|---|---|---|
| logs DaemonSet ×3 | 66m / 19m / 16m | 17 / 14 / 8 MiB |
| metrics StatefulSet ×1 | 3m | 9 MiB |
| traces Deployment ×1 | 39m | 150 MiB |
| **Total (5 pods)** | **~143m** | **~198 MiB** |

---

## The tail-sampling premium (collector-only)

| | Tier 3 (no TS) | Tier 4 (TS on) | Delta |
|---|---|---|---|
| Collector traces-pod memory | 53 MiB | **152 MiB** | **~2.9× (+~99 MiB)** |
| Collector 5-pod aggregate memory | ~337 MiB | ~413 MiB | +76 MiB (~+23%) |

Tail-sampling processor stats over the soak: **37,491,952** new trace IDs received;
**11,246,417 sampled** / 26,241,185 not-sampled under the 30% probabilistic policy;
37,487,602 not-sampled under keep-errors. The decision buffer rode its
`num_traces=100000` cap the whole soak (`sampling_traces_on_memory=100000`) — sized *at* the
limit, not beyond it — with 0 policy-evaluation errors and 0 traces dropped too early, and
still the flattest memory run of the whole benchmark (+0.00%).

---

## Verdict

| Dimension | collector v0.159.0 | Fluent Bit v5.1.1 (control) | Winner |
|---|---|---|---|
| Soak validity (census 0-restart) | ✅ VALID | ✅ VALID | tie |
| Data loss | ⚠️ refused 35,616 / failed 10,460 (≤0.005%) | ✅ 0 dropped | **FB** |
| Memory at 24h (5-pod) | ~413 MiB | ~198 MiB | **FB** (~2.1× lighter) |
| CPU at 24h | ~165m | ~143m | **FB** |
| In-pipeline tail sampling | ✅ available | ❌ not available | **collector** |

**Summary:** Fluent Bit stays the lighter engine even at the full signal set (~2.1× lighter
memory) with zero loss. **But Tier 4 is the capability tier:** only the collector can
tail-sample in-pipeline, and that capability costs ~2.9× the traces-pod memory (53 → 152 MiB,
~+76 MiB on the 5-pod aggregate). If you need in-pipeline tail sampling, that premium is what
you pay; if you do not, Fluent Bit ships the same three signals for roughly half the memory.
