# df_engine 0.50.0 attribute-landing probe

**Date:** 2026-07-23, 10:09–10:12 UTC
**Cluster:** a scratch cluster — deliberately **not** the measured one.
**Image:** `ghcr.io/isitobservable/df_engine:0.50.0` (the R1P3 image, unchanged)
**Manifest:** `attribute-landing-probe.yaml`

## Why this ran

A later revision rewrote CHECK 5b's arrow branch to assert span and log liveness on
`benchmark.engine` alone. That attribute is written by df_engine's **own**
`processor:attribute`. R1P2 proved an engine can land an attribute on one
signal and silently drop it on another (Fluent Bit: `k8s.cluster.name` on
spans yes, on logs no). Nothing proved df_engine free of the same fault — so
the gate I had just "fixed" still rested on an untested assumption, one that
would surface as a **false FAIL on a healthy engine** two hours into run day.

The measured cluster was mid-R1P2 and its config is frozen, so the question
was answered on a different cluster instead of on the benchmark's clock.

## Method

`telemetrygen` → **df_engine (frozen config)** → OTLP/HTTP → collector with a
`debug/detailed` exporter. Reading what the engine *emits* off the wire, rather
than inferring it from a backend query, removes Grail's ingest mapping as a
confounder. 50 records per signal.

Only two lines differ from the frozen `df-engine-config.tmpl.yaml`: the
exporter `endpoint` (local sink instead of Dynatrace) and a dummy `Authorization`
value. Both sit **downstream** of the processor under test.

## Result — all three signals, 100%

| Signal  | Records | `benchmark.engine` | `k8s.cluster.name` | `benchmark.run` | Verdict |
|---------|---------|--------------------|--------------------|-----------------|---------|
| traces  | 62      | 62 (100%)          | 62 (100%)          | 62 (100%)       | SAFE    |
| logs    | 50      | 50 (100%)          | 50 (100%)          | 50 (100%)       | SAFE    |
| metrics | 50 dp   | 60 (100% + descriptor metadata) | 60 | 60             | SAFE    |

No `observed_error`, no drops, no restarts. 15 span batches, 1 log batch, 1
metric batch all arrived at the sink.

### What this retires

1. **The false-FAIL risk in CHECK 5b is gone.** df_engine upserts
   `benchmark.engine` on spans and logs at 100%. The `c4fe469` gate is sound
   for this engine.
2. **`k8s.cluster.name` is SAFE on all three signals for the arrow arm** —
   unlike Fluent Bit. D12 *requires* every readout query be scoped by
   `k8s.cluster.name`; for R1P2 that was impossible on logs. For R1P3 it works.
   `attr-landing.sh` at step 7b should therefore print `spans=SAFE logs=SAFE
   metrics=SAFE`.

**That prediction is itself the check.** If step 7b reports anything other than
all-SAFE on run day, the deployed pipeline is not the one probed here, and that
discrepancy is a finding — not a filter to quietly drop.

### Where the attributes land — record level, not resource level

- spans → **span** attributes
- logs → **log record** attributes
- metrics → **data point** attributes *and* metric descriptor metadata

Resource attributes were untouched (`service.name` only). This does not affect
Grail filtering — record attributes become fields — but it is worth stating,
because it is not the level a Collector `resource` processor would write to,
and "the attribute is present" and "the attribute is present *at the level your
query assumes*" are different claims.

## Secondary finding — severity_text/severity_number now disagree

The parity KQL write (`logs | extend severity_text = 'ERROR'`) sets
`SeverityText: ERROR` on 50/50 records — and leaves `SeverityNumber: Info(9)`
on 50/50. The transform writes the text field only; the numeric field keeps its
original value, so every R1P3 log record ships **internally inconsistent
severity**.

This is not a benchmark-integrity problem — severity is not a measured
quantity; throughput, CPU and memory are — and the write itself is the parity
work being timed, which is what matters. But whichever field Dynatrace derives
log level from, R1P3's log levels will not be comparable with R1P1/R1P2's.
**Flagged for the maintainers's consolidation, not fixed:** the config is frozen, and
this is a read-time interpretation note, not an engine defect.

## Scope and limits — what this does NOT prove

- Payloads were `telemetrygen`, not real otel-demo / hipster-shop / Istio
  traffic. It proves the processor's behaviour, not the apps' attribute sets.
- The sink was a collector, not Dynatrace. Grail ingest mapping is unproven
  here — which is exactly why `attr-landing.sh` still runs at step 7b against
  the real sink.
- A different cluster, so nothing is claimed about df_engine's behaviour under
  the benchmark's load profile.

## Teardown

Namespace `dfprobe` deleted; the sandbox cluster is left as found. The measured
cluster `the benchmark cluster` was never contacted during this work.
