---
title: VERSIONS — ISI-3574 E0 frozen pins (ISI-3572 extended benchmark)
status: CONFIRMED — board answered interaction 2d1e7309 (2026-09-02); pins FROZEN
frozenAt: 2026-09-02
owner: John (PM)
scopingDecisions:
  cluster: reuse-ISI-1777-observable-otelarrow
  tailsampling: collector-only-FB-no-TS-control
  versions: newest-stable-frozen
stepsCompleted:
  - research-latest-tags
  - fb-crash-revalidation-flag
  - board-confirmed-scoping-2d1e7309
---

# Frozen version pins — latest otel-collector vs Fluent Bit v5

These are the **newest stable** release tags as of **2026-09-02**, pulled from each
project's GitHub releases API. They satisfy deliverable #1 of ISI-3574 and answer
scoping question `versions` (option `newest_stable`). **Do not bump mid-benchmark** —
one pin set spans all tiers E1–E4 (ISI-1779 lesson: per-RUN/per-KIND version drift
invalidates comparisons).

| Component | Pinned tag | Released | Image ref | Notes |
|-----------|-----------|----------|-----------|-------|
| **otel-collector-contrib** | `v0.159.0` | 2026-08-17 | `otel/opentelemetry-collector-contrib:0.159.0` | Engine-under-test A. Contrib distro (needs `k8sattributes`, `prometheus`, `tailsampling`, `kepler`-scrape via prometheus receiver). |
| **Fluent Bit** | `v5.1.1` | 2026-08-16 | `fluent/fluent-bit:5.1.1` | Engine-under-test B. Newest v5.x. **⚠️ see crash-loop re-validation below.** |
| **Kepler** | `release-0.8.0` (chart `kepler/kepler` 0.6.2) | 2024 | `quay.io/sustainable_computing_io/kepler:release-0.8.0` | Power/energy metrics exporter — deliberately expensive / high-cardinality metric source. **DEPLOYED + VERIFIED 2026-09-02: 755 `kepler_*` series/pod, port 9102.** See Kepler pin reconciliation below. |

### Kepler pin reconciliation (DEPLOYED, not the original v0.11.4 pin)
Original pin was image `v0.11.4` (newest release). **Reconciled at deploy time:** the
supported Helm chart (`kepler/kepler`, now DEPRECATED) tops out at appVersion
`release-0.8.0`; Kepler 0.9+ carries breaking architecture/config changes and would
require hand-maintained standalone manifests to run the v0.11.4 image. For this
benchmark Kepler's job is to be an *expensive, high-cardinality power exporter* — the
0.8.0 line emits the full per-container/VM/node joules metric family (755 series/pod
verified live), which satisfies that purpose and is chart-supported for reproducibility.
**DECISION: deploy `release-0.8.0` via chart 0.6.2, pin it, do not chase v0.11.4.**
(ISI-1779 lesson: pin the version you actually run and hold it across all tiers.)

## ⚠️ Fluent Bit v5.1.1 — MANDATORY crash-loop re-validation gate

ISI-2093 confirmed a **reproducible SIGSEGV at `flb_http_common.c:903`** (HTTP/2 push
over the Istio ztunnel mesh, 13× over 24h) in **Fluent Bit v5.0.9**. That bug is
**mesh-transport-specific + multi-hour** (ISI-3264: NOT signal/conn-churn), so a short
smoke will *not* surface it. v5.1.1 is two releases newer and **may or may not** carry
a fix.

**E0 acceptance MUST include:** confirm whether the v5.0.9 SIGSEGV reproduces on
`v5.1.1` under the real Istio mesh path before the Tier-1 24h soak is trusted. If it
still crashes, the FB arm needs the ISI-2093 mitigation posture (documented, not
`http2:off` which is non-viable in prod) and the finding is a first-class benchmark
result, not a blocker to abandon the arm.

## Cluster-side versions (DECIDED: reuse ISI-1777 observable-otelarrow)

Board answered scoping question `cluster` = **reuse** (interaction 2d1e7309, 2026-09-02).
Rationale — ISI-3471 health check 08-31 shows headroom: etcd 7.3ms, CP io avg300 0.04%,
only 2 demo OOMKills; istio + otel-demo + hipster-shop already deployed → zero extra install.
- Istio **1.29** (native sidecars = initContainers; gate 4b needs `istiod` rollout-restart — ISI-1937 lesson).
- otel-demo + hipster-shop already deployed → traces source ready with no extra install.

(Rejected: dedicated cluster — would add ~1 setup day for no measured benefit.)

## Provenance
```
open-telemetry/opentelemetry-collector-contrib  latest → v0.159.0  (2026-08-17)
fluent/fluent-bit                                latest → v5.1.1    (2026-08-16)
sustainable-computing-io/kepler                  latest → v0.11.4   (2026-02-16)
```
Queried via GitHub releases API 2026-09-02.
