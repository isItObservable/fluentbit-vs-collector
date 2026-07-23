# B1-v2 phase runbook — run this EXACT order for every phase

One phase = one engine, one round. Six phases total (3 engines × 2 rounds), strictly
serial on `observable-otelarrow`. Deviating from this order is how a phase becomes
non-comparable, which is worse than a missing phase because it still looks like data.

`ENGINE` is one of `otel-collector` · `fluentbit-v5` · `otel-arrow-native`.

```bash
export KUBECONFIG=/tmp/otelarrow.kubeconfig     # no kube context exists on this host
export ENGINE=otel-collector
```

---

## 1. Engine

```bash
kubectl apply -f engines/${ENGINE}.yaml
```

The OTLP gRPC Service port **must** be named `grpc-otlp` with `appProtocol: grpc`.
It already is in the repo — do not "tidy" it to `otlp-grpc`. See
`engines/README-port-naming.md`; CHECK 4d enforces it.

## 2. Apps — both, pointed at this engine

```bash
helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
  --version 0.40.10 -n otel-demo --create-namespace \
  -f apps/otel-demo-values-${ENGINE}.yaml --wait

kubectl apply -f apps/hipster-shop-${ENGINE}.yaml
```

## 3. appProtocol on the app Services — MANDATORY, easy to forget

```bash
./apps/appprotocol.sh
```

**This cannot be skipped and cannot be expressed in the Helm values.** The otel-demo
chart hardcodes `name: tcp-service` on nearly every component Service, which Istio
cannot classify, so those hops fall back to plain TCP and emit **no mesh spans**.
Measured before this step existed: hipster-shop 688,747 mesh spans vs otel-demo
6,820 in the same window — and CHECK 4 was green on the sum.

`helm upgrade` recreates those Services, so **this must run after every step 2**, in
every phase, or the phases are not comparable. It is idempotent; `--verify` reports
without patching.

## 4. Namespace labels — sidecars in, Dynatrace injection out

```bash
kubectl label ns otel-demo hipster-shop istio-injection=enabled --overwrite
kubectl label ns otel-demo hipster-shop oneagent=false --overwrite
```

`oneagent=false` is what the DynaKube `metadataEnrichment.namespaceSelector` excludes
(`key: oneagent, operator: NotIn, values: ["false"]`). Without it the Dynatrace webhook
injects an init container and two volumes into every app pod — an uncontrolled variable
in a benchmark that measures resource consumption, and the hook the OneAgent codemodule
would arrive through if it were ever enabled.

## 5. Istio — this cluster only

```bash
helm upgrade istiod istio/istiod -n istio-system -f istio/values-${ENGINE}.yaml --wait
kubectl rollout restart deploy/istiod -n istio-system    # NOT optional, see below
kubectl apply -f istio/telemetry-${ENGINE}.yaml
```

`tracing` + `accessLogging` only. No metrics provider, no Prometheus scrape (D1).

- `helm upgrade --wait` prints "successfully rolled out" **without rolling istiod**,
  because meshConfig is a ConfigMap and no Deployment field changes. A control plane
  that never re-read the config looks perfectly healthy. Always restart it.
- Only **one** Telemetry resource applies per scope; extras are silently discarded.
  `tracing` and `accessLogging` stay merged in one CR.
- CAAPH on the management cluster is paused for this cluster for the duration of the
  campaign (see `CAMPAIGN-STATE.md` / **ISI-1826**). Do not un-pause mid-campaign.

## 6. Restart the apps

```bash
kubectl -n otel-demo rollout restart deploy
kubectl -n hipster-shop rollout restart deploy
```

Required after steps 3–5: sidecars pick up the new mesh config and the new port
protocol classification only on restart.

⚠️ The cluster has **no spare CPU for a full simultaneous surge**. Single-replica
deployments default to `maxSurge=1, maxUnavailable=0`, so a mass restart can deadlock —
the new pod cannot schedule until the old one frees CPU, and the old one will not go
until the new one is Ready. It resolves on its own within a few minutes; if it does not,
delete the old-generation pods rather than adding capacity.

## 7. Smoke, then gate

```bash
# each app's own loadgenerator at low volume, 5-10 min, then:
./validate-phase.sh ${ENGINE} --window 15m
```

All **six** checks must pass. CHECK 4 alone has five preflights (4a–4e), each naming a
distinct silent failure. **Never start a 120-minute run on a red gate.**

## 7b. Attribute landing — per signal, per engine, BEFORE the run

```bash
./results/attr-landing.sh ${ENGINE} --window 15m
./results/attr-landing.sh --selftest      # must reproduce R1P2: spans SAFE, logs UNSAFE
```

Prints, for spans / logs / metrics separately, whether `k8s.cluster.name` actually
lands — i.e. whether a cluster-scoped filter is safe to read for this arm.

**This is a diagnostic, not a gate.** An `UNSAFE` signal does not stop the run; it
tells the readout which filter to drop. Not knowing does.

`k8s.cluster.name` is stamped **by the engine**, by a different processor in every
arm — so it is a per-engine, per-signal property and must never be inherited from
the previous phase. Measured live on the fluentbit arm: spans 4,820,733/4,820,733
carry it, logs **0** of 2,782,904, with zero processor errors reported. That is why
the dashboard's log tiles read **0** for R1P2 while the engine was in fact delivering
millions of log records — a wrong number of the worst kind: large, directional,
plausible.

(This paragraph previously went further and said Fluent Bit delivered *more* logs
than the collector. That was wrong, and `4f85bbc` corrected it in
`results/RUN-REGISTER.md` — but the same claim was sitting here too. Over identical
89-minute windows P2 delivered **8.8% fewer** logs *and* 8.8% fewer spans; equal
movement on both signals argues upstream, not at the engine. A correction is only
finished when every copy of the wrong number is found — quote the full-window
`readout.sh` figure, never a mid-ramp slice.)

Corrections ship at **read** time (`results/service-key.dql`, `results/readout.sh`),
never as config changes — the telemetry config is frozen so the engine stays the
only variable.

**R1P3 has a predicted verdict — compare against it.** df_engine 0.50.0 was run
off-cluster with the frozen pipeline config on 2026-07-23 and pushed 50 records per
signal into a debug sink: `benchmark.engine`, `k8s.cluster.name` and `benchmark.run`
landed on **100% of spans, logs and metric data points** (evidence and method:
`engines/attr-probe/`). So step 7b **must** print
`spans=SAFE logs=SAFE metrics=SAFE` for the arrow arm — unlike fluentbit, its log
tiles need no cluster-filter correction.

If 7b reports anything else, **the deployed pipeline is not the one that was probed**.
Treat the discrepancy as a finding and investigate the deployment; do not silently
drop the filter and read on.

## 8. Register the START — before load

Record in `results/RUN-REGISTER.md`: run ID, engine + image tag, round, start UTC to the
second, **every engine pod name + `creationTimestamp`**, expected replica count, gate
result, load profile, **and the step-7b attribute-landing verdict per signal**
(`spans=… logs=… metrics=…`). Without the verdict in the row, a readout months later
cannot tell a signal the engine dropped from a signal the filter hid.

## 9. Timed run — 120 min, both apps simultaneously

`LOAD_PHASE=rampup2h`, 50→100→150→200 VU per app, `--exit-code-on-error 0`.
**No snapshots, no capture loop** (D8) — Dynatrace records continuously.

## 10. Register the END — the moment load stops, before any teardown

Take it from Kubernetes, not from a wall clock:
`max(pod terminated.finishedAt)` across the ramp pods — **not**
`Job.status.completionTime`, which is null on failure and lags ~4s. Teardown deletes the
pods that hold this value, so capture it first.

## 11. Census, then teardown

```bash
./pod-census.sh          # ≥90% coverage per bucket; a failed census VOIDS the run
./teardown.sh <run-id>            # DRY RUN — prints the plan, deletes nothing
./teardown.sh <run-id> --confirm  # actually deletes
```

**Do not hand-type the deletes.** This step is irreversible, runs last when a
120-minute run is already in the bank, and sits next to two traps:

- **Teardown destroys the End timestamp.** It lives only on the ramp pods'
  `.state.terminated.finishedAt`; nothing is captured locally. `teardown.sh`
  refuses (G1/G2) until the register carries a real End *and* an End census row.
- **`kubectl delete ns hipster-shop` would destroy a constant.**
  `hipster-shop/loadgenerator` is a pre-campaign leftover in **no** manifest that
  must survive every teardown — it contributes identical load to all six runs, so
  removing it manufactures a difference that is not the engine. The script never
  deletes a namespace, re-checks mechanically that no manifest *defines* it (G4),
  and verifies it survived (P1).

It also refuses while any ramp pod is still running (G3), and confirms afterwards
that no `benchmark=isi1779` object and no run-lock annotation is left (P2/P3).
Istio is deliberately left up — the next phase reconfigures it in place (step 6).
