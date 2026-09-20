---
title: ISI-3574 E0 — live deploy + smoke results
date: 2026-09-02
cluster: observable-otelarrow (ISI-1777, REUSED per board decision 2d1e7309)
owner: John (PM)
status: E0 COMPLETE except branch push (#8, BigBoss PAT) — both engines live; logs+metrics+traces verified; harness+KPI toolkit built+validated
---

## UPDATE — 2026-09-02 pt2 (heartbeat 3): E0 finished except branch push

All remaining deploy/harness/KPI work completed and verified this heartbeat:
- **DiskPressure on lz9mb CLEARED** — all 4 nodes now `DiskPressure=False` (image-pull
  churn settled, kubelet image GC reclaimed). lz9mb hosting bench pods again. Census gate PASS.
- **FB Kepler truncation FIXED + verified** — `buffer_max_size 1M` on both `prometheus_scrape`
  inputs. Kepler input now ingests **446,522 bytes** (2×223KB scrapes) vs the old 32,000-byte
  ceiling; no `cannot increase buffer` errors. **New finding:** FB v5.1.1 `prometheus_scrape`
  rejects `buffer_chunk_size` (only `buffer_max_size` valid) — removed it.
- **Traces (#5) receiver side wired + verified on BOTH engines:**
  - Collector: added `otlp` receiver (gRPC :4317 + HTTP :4318) + `traces` pipeline + Service
    `bench-collector-otlp`. Smoke: telemetrygen → Service → **261 spans exported** (debug, sampled).
  - FB: added `opentelemetry` OTLP/HTTP input :4318 + Service `bench-fluentbit-otlp`. Smoke:
    OTLP/HTTP `POST /v1/traces` → **HTTP 200**. **Finding:** FB has no gRPC OTLP trace ingress
    (collector does) → protocol asymmetry; FB arm apps export OTLP/HTTP. **Finding:** v0.159.0
    deprecates `k8sattributes` → `k8s_attributes` (warn only).
  - App repoint (otel-demo/hipster-shop → engine Service) is a per-arm runtime step at each
    traces-tier run (ISI-1779 per-RUN methodology), not baked in now.
- **Harness (#6) authored** — `harness/telemetrygen-load.yaml` + `run-profile.sh` (2h-rampup /
  24h-stable, per-arm endpoint, ISI-1927 hard-kill backstop, ISI-3264 standard framing). Syntax-validated.
- **KPI/leak toolkit (#7) built + validated live** — `kpi/{census-gate,loss-accounting,leak-readout,cost-per-1m}.sh`
  + README. census-gate → PASS (10 pods, 0 restarts); loss-accounting collector → NO LOSS
  (refused=0, send_failed=0, fan-out 1.891).

**Only remaining:** #8 branch push to `isItObservable/fluentbit-vs-collector` — needs BigBoss PAT + branch name.


# E0 smoke results — 2026-09-02

Scoping unblocked by board answering interaction `2d1e7309` on ISI-3572 (12:43 UTC):
**reuse ISI-1777** · **TS collector-only, FB no-TS control** · **newest-stable versions**.

## Deployed & verified this heartbeat

| Component | State | Verification |
|-----------|-------|-------------|
| Namespaces `bench-collector`, `bench-fluentbit` | ✅ applied | Both labeled `oneagent=false` → OneAgent injection suppressed (deliverable #2, ISI-1927). Confirmed DynaKube selector is `oneagent NotIn [false]`. |
| Kepler `release-0.8.0` (chart 0.6.2) | ✅ 4/4 nodes | **755 `kepler_*` series/pod** on :9102 (AMD Ryzen 9 9955HX, AbsPower regressor). Pin reconciled from v0.11.4 — see VERSIONS.md. |
| **Collector `v0.159.0`** daemonset | ✅ 2/3 workers¹ | **Logs**: filelog accepted 90 / refused 0 / sent 89 (≈accepted==sent). **Metrics**: prometheus accepted 43,888 / sent 43,888 (exact). Self-telemetry :8888. |
| **Fluent Bit `v5.1.1`** daemonset | ✅ 2/3 workers¹ | **Logs**: tail 19 rec, 0 err / 0 dropped. **Metrics**: istiod scrape 23KB + Kepler scrape 223KB. Metrics endpoint :2020. No crash in smoke. |

¹ Both daemonsets are 2/3 because worker **lz9mb** is under DiskPressure (see risks).

## Signal-source status vs deliverables
- **#3 Logs (DaemonSet)** — ✅ BOTH engines tailing node logs, clean accounting.
- **#4 Metrics (istio-CP + Kepler)** — ✅ BOTH engines scraping; Kepler power metrics flowing.
- **#5 Traces (otel-demo + hipster-shop → both engines)** — ⬜ NOT yet wired. Apps present in cluster; need OTLP receivers on both bench engines + app export tee.
- **#6 Harness (2h rampup + 24h soak)** — ⬜ profiles not authored yet.
- **#7 KPI dashboards + leak scripts** — ⬜ reuse ISI-1779 toolkit, not ported yet.
- **#8 Repo branch push** — 🔒 BLOCKED on BigBoss PAT/branch (Blocker 2).

## Config findings (real, fixed/flagged)
1. **Collector v0.159.0 telemetry schema change** — `service.telemetry.metrics.address`
   was REMOVED; the collector crashes with `'migration.MetricsConfigV030' has invalid
   keys: address`. FIXED → use `readers:[{pull:{exporter:{prometheus:{host,port}}}}]`.
   (Manifest `20-collector-daemonset.yaml` updated.)
2. **FB prometheus_scrape buffer too small for Kepler** — `[http_client] cannot increase
   buffer: current=32000 requested=64768 max=32000`. Kepler's 223KB high-card payload
   exceeds FB's default scrape buffer → **FB truncates Kepler metrics**. FIX PENDING:
   raise `buffer_max_size`/`buffer_size` on the `prometheus_scrape` INPUT before Tier-2.

## Risks / cluster-health
- **DiskPressure=True on worker `lz9mb`** (isolated; other 2 workers + CP are False).
  Appeared during image-pull churn (collector+kepler+FB images). Evicts pods →
  **would invalidate a 24h soak** (ISI-1779 pod-census validity gate). MUST resolve
  before tier soaks: kubelet image GC should reclaim, else cordon/clean that node.
- **FB v5.1.1 mesh SIGSEGV re-validation** (ISI-2093) — NOT covered by this smoke;
  it's mesh-HTTP/2 + multi-hour. Tier-1 24h soak over real Istio egress is the gate.

## Next concrete steps (live continuation path)
1. Resolve/observe DiskPressure on lz9mb (image GC or cordon).
2. Bump FB prometheus_scrape buffer; re-smoke Kepler scrape completeness.
3. Wire traces: OTLP receivers on both engines + point otel-demo/hipster-shop (or a
   tee) at them (deliverable #5).
4. Author harness profiles: telemetrygen/locust 2h-rampup + 24h-stable (deliverable #6,
   with LOCUST_RUN_TIME hard-kill + telemetrygen-not-slowloris lessons).
5. Port ISI-1779 KPI/leak toolkit (deliverable #7).
6. On BigBoss PAT: create branch on isItObservable/fluentbit-vs-collector, push
   manifests + VERSIONS + smoke results (deliverable #8).
