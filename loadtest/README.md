# Load harness — phased profile against two apps

Implements the load methodology specified for ISI-1779 (Henrik, 2026-07-21):
drive **otel-demo** *and* **hipster-shop** together with a controlled, phased VU
profile so the log/trace volume the three edge shippers (arrow / otlp /
fluentbit) transport is *aligned with the load* rather than a free-running
demo loadgen.

## The profile

| Phase | `LOAD_PHASE` | VU per app | Duration | Purpose |
|-------|--------------|-----------|----------|---------|
| 1 · Stable baseline | `stable30` | 50 | 30 min | steady state — throughput / CPU-mem / loss at a fixed rate |
| — recovery gate — | | 0 | apps settle | let both apps drain + RSS plateau before the next phase |
| 2 · Ramp-up | `rampup2h` | 50 → 100 → 150 → 200 (+50 / 30 min) | 2 h | scaling behaviour of each transport as volume climbs |
| — recovery gate — | | 0 | apps settle | |
| 3 · Leak soak | `leak24h` | 50 | 24 h | **memory-leak detection** — collector RSS trend over a long steady run |

50 VU hit **each** app simultaneously (two Locust drivers, one shape), so the
combined request rate exercises the full otel-demo + boutique service graphs
and produces logs **and** traces proportional to the load.

> **Ramp interpretation.** "50 users added every 30 min for 2 h" is implemented
> as a step function starting at 50, +50 at each 30-min boundary → **50, 100,
> 150, 200** (peak held through the 4th step). Every value is an env knob
> (`BASE_USERS`, `STEP_USERS`, `STEP_SECS`) — retune without editing code.

## Components

| File | Role |
|------|------|
| `loadshape.py` | Locust `LoadTestShape`; the active phase is picked by env `LOAD_PHASE`. Shared by both apps → identical VU profile at the same wall-clock time. |
| `tasks_otel_demo.py` | Locust `HttpUser` — browse / cart / checkout against the OTel-demo frontend API. |
| `tasks_hipster_shop.py` | Locust `HttpUser` — mirrors the Online Boutique flow. |
| `locust-otel-demo.yaml` | Deployment `loadgen-otel-demo` (image `locustio/locust`, headless). |
| `locust-hipster-shop.yaml` | Deployment `loadgen-hipster-shop`. |
| `hipster-shop/kustomization.yaml` | Deploys Online Boutique into ns `hipster-shop`, **removes its bundled loadgenerator** (we own the load). |
| `run-benchmark.sh` | Orchestrator — runs all three phases with recovery gates and snapshots every phase boundary + every 2 h through the leak soak. |
| `loadtest_job.yaml` | *Legacy* v4-style single Locust burst (kept for reference; superseded by the phased harness above). |

## Run

```bash
export KUBECONFIG=~/.config/capmox/observable-otelarrow.kubeconfig

# 1. add hipster-shop to the cluster (otel-demo is already live)
kubectl create namespace hipster-shop
kubectl apply -k hipster-shop/
kubectl rollout status deploy -n hipster-shop --timeout=300s

# 2. run the full phased benchmark (~27 h wall clock incl. the 24 h soak)
./run-benchmark.sh /tmp/isi1779-run          # deploys the drivers + drives all phases

# 3. per-phase tables (records/s, CPU/mem, loss) for each variant
python3 ../scripts/compute.py /tmp/isi1779-run/snap_p1_stable_t0.txt /tmp/isi1779-run/snap_p1_stable_t1.txt
# 24 h memory-leak delta: collector working-set start vs end
python3 ../scripts/compute.py /tmp/isi1779-run/snap_p3_leak_t0.txt   /tmp/isi1779-run/snap_p3_leak_end.txt
```

The `run-benchmark.sh` is designed for a **record-time** long run. It is
resumable-friendly (idempotent apply + labelled snapshots) — if the 24 h soak
is interrupted, re-run and it re-applies cleanly; already-written snapshots are
kept.

## Memory-leak read

Phase 3 snapshots collector `container_memory_working_set_bytes` every 2 h.
A leak shows as a **monotonically rising** working-set on any edge pod across
the 24 h window with a flat 50-VU input; a healthy transport plateaus. Compare
`snap_p3_leak_t0` → `snap_p3_leak_end` and eyeball the intermediate
`snap_p3_leak_<Ns>` points for the slope.
