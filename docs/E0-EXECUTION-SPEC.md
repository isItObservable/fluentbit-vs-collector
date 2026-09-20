---
title: E0 Execution Spec — Setup & Foundation (ISI-3574)
parent: ISI-3572 extended benchmark
status: READY-TO-EXECUTE on 2 unblocks (see §0)
owner: John (PM) — spec; execution owner = infra/SRE agent
frozenAt: 2026-09-02
stepsCompleted:
  - topology
  - signal-wiring
  - harness-profiles
  - kpi-reuse
  - acceptance
---

# E0 — Setup & Foundation execution spec

Deliver both engines live, all 3 signal sources flowing, harness+KPIs validated with a
short smoke, branch pushed. This spec makes E0 executable the moment §0 unblocks land.

## §0 Blockers (must clear before deploy)
1. **Scoping decisions** — interaction `2d1e7309` on **ISI-3572** (owner: board/Henrik):
   - `cluster` → **recommend REUSE ISI-1777** (headroom confirmed, ISI-3471 08-31).
   - `tailsampling` → **recommend collector_only** (FB has no TS; FB runs full-stack no-TS control in Tier 4).
   - `versions` → **recommend newest_stable** → already frozen in [VERSIONS.md](./VERSIONS.md).
2. **Repo branch + PAT** — new branch on `isItObservable/fluentbit-vs-collector`
   (one-branch-per-benchmark). Owner: **BigBoss** (PAT/PR coordination, deliverable #8).

## §1 Deployment topology (ISI-1927 lesson: NO OneAgent/sidecar on engine-under-test)
- Namespace `bench-collector` — otel-collector-contrib `v0.159.0` (engine A).
- Namespace `bench-fluentbit` — Fluent Bit `v5.1.1` (engine B).
- Both engines run **side-by-side, isolated** (separate ns; pin to separate node pools
  if headroom allows). Neither engine-under-test is wrapped by Dynatrace OneAgent/sidecar —
  the OneAgent observes the NODE, not injected into the collector pod (invalidates CPU/mem).
- Shared app/signal namespaces (istio-system, otel-demo, hipster-shop, kepler) feed BOTH.

## §2 Signal wiring (all 3 sources → both engines)
- **Logs (DAEMONSET)** — node-level tail. Collector: `filelog` receiver as DaemonSet.
  Fluent Bit: native DaemonSet `tail` input. Both scrape `/var/log/pods/**`.
- **Metrics** — (a) scrape **istio control-plane** (`istiod` `:15014/metrics`);
  (b) **Kepler** `v0.11.4` DaemonSet, scrape `:9102/metrics` (expensive/high-card, by design).
  Collector: `prometheus` receiver. Fluent Bit: `prometheus_scrape` input + **metric
  conversion** path (FB deliverable #4).
- **Traces** — otel-demo + hipster-shop → OTLP to each engine's `:4317`. On REUSE these
  apps already exist; only repoint (or fan-out) their OTLP exporter endpoints.

## §3 Load harness (reuse ISI-1779 tooling)
- Fixed-rate generator (locust for app traffic + telemetrygen for raw signal rate).
- **Profile A — 2h rampup gate**; **Profile B — 24h stable soak**. Both engines, per tier.
- ⭐ ISI-1927: `LOCUST_RUN_TIME` was NOT honoured on 1/8 pods → add hard `kill` at T+7200s.
- ⭐ ISI-3264: for FB crash repro use **standard telemetrygen framing over the real Istio
  mesh** (slowloris framing trips the Opus `[cyber]` guard AND isn't the real failure path).

## §4 KPI / leak-readout (reuse ISI-1779 scripts)
- **Leak check = TAIL-flat, not first-vs-last** (ISI-1811: warm-up floor-creep to plateau
  is normal; assert the tail is flat). For OTAP-style bounded creep see ISI-3477.
- **Pod-census validity gate FIRST** — read `restartCount` per-namespace; a PASS with
  restarts is INVALID (ISI-1937). Aggregate checks hide dead entities (ISI-1822).
- **Loss accounting: accepted == sent** (received != exported = coalescing, ISI-1843).
- **Cost-per-1M** (millicores/1M records) as the headline comparison metric.
- KPIs land in Grail; readable up to 24h post-run (survive cluster death — ISI-1881).

## §5 Smoke (E0 done-gate)
Short smoke proving: both engines Running (0 restarts), all 3 signal types arriving at
both, Kepler emitting, harness hits target rate, leak-readout + census scripts execute
clean, branch pushed. **Plus** the FB v5.1.1 crash re-validation flag from VERSIONS.md
is scheduled (not necessarily complete — the 24h mesh soak is Tier-1 E1, but the smoke
must confirm FB stays up over the mesh path for the smoke window).

## §6 Handoff
On smoke-pass: E1 (ISI-3575, logs-only) unblocks. E1→E4 sequential; E5 (ISI-3579)
consolidates + opens the GitHub PR on the new branch.
