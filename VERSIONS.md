# Frozen version pins — OpenTelemetry Collector vs Fluent Bit v5

These are the **newest stable** release tags used for the benchmark, pulled from each
project's GitHub releases. **Do not bump mid-benchmark** — one pin set spans all four tiers.
Version drift between tiers (or between the two engine arms) invalidates the comparison.

| Component | Pinned tag | Released | Image ref | Notes |
|-----------|-----------|----------|-----------|-------|
| **otel-collector-contrib** | `v0.159.0` | 2026-08-17 | `otel/opentelemetry-collector-contrib:0.159.0` | Engine under test A. Contrib distro (needs `k8sattributes`, `prometheus`, `tailsampling`, and the Kepler scrape via the `prometheus` receiver). |
| **Fluent Bit** | `v5.1.1` | 2026-08-16 | `fluent/fluent-bit:5.1.1` | Engine under test B. Newest v5.x. See the crash-loop re-validation note below. |
| **Kepler** | `release-0.8.0` (chart `kepler/kepler` `0.6.2`) | — | `quay.io/sustainable_computing_io/kepler:release-0.8.0` | Power/energy metrics exporter — a deliberately expensive, high-cardinality metric source (~755 `kepler_*` series/pod on port `9102`). |

## Kepler pin note (`release-0.8.0`, not the newer `v0.11.x` image)

The supported Helm chart (`kepler/kepler`, now deprecated) tops out at appVersion
`release-0.8.0`. Kepler 0.9+ carries breaking architecture/config changes and would require
hand-maintained standalone manifests to run a newer image. For this benchmark Kepler's job is
to be an *expensive, high-cardinality power exporter* — the `0.8.0` line emits the full
per-container/VM/node joules metric family (755 series/pod verified live), which satisfies
that purpose and is chart-supported for reproducibility. **Decision: deploy `release-0.8.0`
via chart `0.6.2` and hold it.** Pin the version you actually run and hold it across all tiers.

## Fluent Bit v5 — crash-loop re-validation gate

Earlier Fluent Bit v5.x builds carried a reproducible SIGSEGV on the HTTP/2 export hop over
an Istio (ztunnel) mesh — observed multiple times over a 24-hour window on **v5.0.9**. That
bug is **mesh-transport-specific and multi-hour**, so a short smoke test will *not* surface
it. `v5.1.1` is two releases newer and may or may not carry a fix.

**Acceptance requires** confirming whether that SIGSEGV reproduces on `v5.1.1` under the real
mesh path before the Tier-1 24-hour soak is trusted. If it still crashes, the Fluent Bit arm
runs with a documented mitigation posture (not `http2: off`, which is not viable in
production) and the finding is reported as a first-class benchmark result rather than a reason
to abandon the arm.

## Cluster-side versions

- **Istio 1.29** (native sidecars are init containers; a mesh-config change needs an `istiod`
  rollout-restart to take effect).
- **OpenTelemetry Demo** + **Online Boutique (hipster-shop)** as the trace/log source apps.

## Fluent Bit v5.1.1 — tail-sampling capability finding (ISI-4768 / Tier-4 re-run)

On-cluster boot smoke of `fluent/fluent-bit:5.1.1` (no pin bump needed):

- `sampling` processor `type: tail` **SHIPS** and initializes clean. Condition types validated
  live: `status_code`, `string_attribute` (regex + negative-lookahead invert), `latency`
  (`threshold_ms_low`). Also documented: `span_count`, `numeric_attribute`, `boolean_attribute`,
  `trace_state`.
- `cumulative_to_delta` processor **SHIPS** (`drop_on_reset` default `true`, plus `drop_first`,
  `initial_value`) — the fix for negative deltas on counter/histogram resets.
- **Limitation:** FB tail sampling has **no `probabilistic` condition**. Percentage sampling in
  FB is a *separate* `type: probabilistic` = **head** sampling (drops at ingest, before the tail
  decision), so it cannot be composed inside the tail decision the way the collector's
  `probabilistic` tail policy can, and a head-probabilistic would drop error traces before
  keep-errors runs. => The collector's original "keep-errors OR (non-health AND 30% probabilistic)"
  has no like-for-like FB-tail equivalent. Tier-4 re-run uses **Design A**: both engines run an
  identical condition-based tail policy — keep-errors + keep-slow-non-health (latency ≥ 250ms,
  drop /health|/ready|/live). No FB pin change; frozen pins hold.

## Provenance

```
open-telemetry/opentelemetry-collector-contrib  latest → v0.159.0  (2026-08-17)
fluent/fluent-bit                                latest → v5.1.1    (2026-08-16)
sustainable-computing-io/kepler                  chart-supported → release-0.8.0
```
