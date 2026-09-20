# fluentbit-vs-collector — E0 (setup & foundation)

Branch: `benchmark/collector-v0.159.0-vs-fluentbit-v5.1.1` (one-branch-per-benchmark).
Part of the ISI-3572 extended benchmark (follow-on to ISI-1779): **latest otel-collector
vs Fluent Bit v5**, progressive signal-stacking (logs → +metrics → +traces → +tail-sampling),
each tier a 2h-rampup gate + 24h-stable soak on both engines. This branch delivers E0 —
the foundation everything else (E1–E4) builds on.

## Pinned versions
See [`VERSIONS.md`](./VERSIONS.md). collector-contrib `v0.159.0` · Fluent Bit `v5.1.1` ·
Kepler `release-0.8.0`. Do not bump mid-benchmark.

## Layout
- `manifests/` — namespaces + both engine DaemonSets (collector, Fluent Bit), no OneAgent
  on the engine-under-test (`oneagent=false`). Logs (DaemonSet tail), metrics (istio-CP +
  Kepler scrape), traces (OTLP receivers + Services).
- `harness/` — telemetrygen stable-load (2h-rampup / 24h-stable), per-arm endpoint, with
  the ISI-1927 hard-kill backstop.
- `kpi/` — leak/validity readout scripts: census gate (run first), loss accounting,
  TAIL-flat leak check, cost-per-1M.
- `docs/` — E0 execution spec + live smoke results.

## E0 status (2026-09-02)
Both engines live on `observable-otelarrow`; all 3 signal sources flowing; harness + KPI
toolkit built and smoke-validated. See `docs/SMOKE-RESULTS.md`.

## Deploy (target cluster: observable-otelarrow / ISI-1777)
```sh
export KUBECONFIG=~/.config/capmox/observable-otelarrow.kubeconfig
kubectl apply -f manifests/00-namespaces.yaml
kubectl apply -f manifests/20-collector-daemonset.yaml
kubectl apply -f manifests/30-fluentbit-daemonset.yaml
kubectl get pods -n bench-collector -n bench-fluentbit   # expect Running, 0 restarts
./kpi/census-gate.sh                                      # validity gate — run FIRST
```
