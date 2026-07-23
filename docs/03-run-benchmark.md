# 03 — Run the benchmark

> Previous: [02 — Deploy the environment](02-deploy-environment.md) · Next: [04 — Read the results](04-read-results.md)

One phase = one engine, one round. Six phases (3 engines × 2 rounds), strictly
serial. **Deviating from this order is how a phase becomes non-comparable, which
is worse than a missing phase because it still looks like data.**

```bash
set -a && . ./.env && set +a
export ENGINE=otel-collector     # | fluentbit-v5
export RUN_ID=R1-P1-collector    # R<round>-P<phase>-<engine>
```

---

## The methodology rules

The scripts refer to these by number. They are the rules that make two windows
comparable; each one exists because breaking it produced a plausible wrong
answer at least once.

| rule | what it says |
|---|---|
| **D1** | Istio/Envoy **Prometheus** metrics are out of scope in every arm — no Prometheus receiver, no ServiceMonitor, no Envoy scrape. Istio spans and access logs are in scope; app-emitted OTLP metrics are in scope. |
| **D8** | **No snapshots and no capture loop.** Dynatrace records continuously; a poller adds load that differs between arms. Set the timeframe afterwards and read the window. |
| **D12** | A run is **void** if the pod census fails: the engine must be *one continuous pod* for the whole window, at ≥ 90% metric coverage. A pod *replacement* is invisible to restart counters. |

## 1. Gate — never start a 120-minute run on a red gate

```bash
./benchmark/validate-phase.sh $ENGINE --window 15m
```

All six checks must pass. Check 4 alone has five preflights (4a–4e), each naming
a distinct silent failure — a stripped tracing provider, an unclassifiable port
name, a split `Telemetry` CR, and so on.

Check **5b** is the one to understand. Check 5 sums accepted/exported records
across *all* signals and passes on the total; 5b asserts **per signal**. On the
Fluent Bit arm, 5b prints `metrics 100% processor failure` and turns check 5 red
— an aggregate throughput assertion cannot see one signal die.

Check **5c** is the one that would have saved a run. It asserts the engine is
*still alive* over a **disjoint forward window**, not that it has ever worked:

> A cumulative reading proves the engine **worked**. It never proves the engine
> **works**. `df_engine:0.50.0` panicked on all four pipeline cores 18–43 seconds
> after start and ran dead for nearly two hours while reporting `1/1 Running`,
> `ready: True`, `restarts: 0`. A 15-minute lookback found 31,426 spans — all
> real, all emitted before the panic. The pod census passed too, because the pod
> was never *replaced*, it just stopped working. **A window can be perfectly
> valid and contain nothing.**

And a dead engine uses almost no CPU, so the ruined run would have looked like a
spectacular efficiency win.

## 2. Attribute landing — per signal, per engine, before the run

```bash
./benchmark/attr-landing.sh $ENGINE --window 15m
```

Prints, for spans / logs / metrics **separately**, whether `k8s.cluster.name`
actually lands — i.e. whether a cluster-scoped filter is safe to read for this
arm.

**This is a diagnostic, not a gate.** An `UNSAFE` signal does not stop the run;
it tells the readout which filter to drop. Not knowing does.

`k8s.cluster.name` is stamped **by the engine**, by a different processor in
every arm, so it is a per-engine, per-signal property and must never be inherited
from the previous phase. Measured on the Fluent Bit arm: **4,820,733 of
4,820,733 spans** carry it and **0 of 2,782,904 logs** do — with zero processor
errors reported. That is why the dashboard's log tiles read **0** for that arm
while the engine was in fact delivering ten million log records: a wrong number
of the worst kind — large, directional and plausible.

> Generalises: **verify an attribute lands per signal.** "0 processor errors"
> proves nothing about whether the upsert took effect.

Corrections ship at **read** time (`benchmark/service-key.dql`,
`benchmark/readout.sh`), never as config changes — the telemetry config stays
frozen so the engine remains the only variable.

## 3. Register the START — before load

Add a row to `results/RUN-REGISTER.md`: run ID, engine + image tag, round, start
UTC to the second, **every engine pod name with its `creationTimestamp`**,
expected replica count, gate result, load profile, and **the step-2
attribute-landing verdict per signal** (`spans=… logs=… metrics=…`).

Without that verdict in the row, a readout months later cannot tell a signal the
engine *dropped* from a signal the *filter hid*.

```bash
./benchmark/pod-census.sh $RUN_ID start
```

## 4. The timed run — 120 minutes, both apps

```bash
kubectl apply -f loadtest/ramp-jobs-${ENGINE}.yaml
date -u +%Y-%m-%dT%H:%M:%SZ     # record this as Start
```

50 → 100 → 150 → 200 VU per app, four 30-minute rungs, both apps stepping at the
same wall-clock time. No snapshots, no capture loop (D8).

> **A queued rung reports `Pending`, not `Running` — that is correct.** Each rung
> parks in a `wait` **initContainer**, and a sleeping *initContainer* shows
> `Pending`. Do not read it as "the ramp never climbed"; check
> `initContainerStatuses[].state.running.startedAt`.

## 5. Register the END — the moment load stops, before any teardown

```bash
./benchmark/capture-window.sh $RUN_ID
```

End is taken from Kubernetes, not from a wall clock: `max(pod terminated
.finishedAt)` across the ramp pods — **not** `Job.status.completionTime`, which
is null on failure and lags a few seconds.

`capture-window.sh` refuses to print a window unless **every app container of
every ramp pod** has terminated. That guard exists because the first version
only caught the *zero*-pods-finished case: with 7 of 8 finished and one hung,
`max(finishedAt)` is a well-formed timestamp that lands inside 120 ± 2 minutes
and prints `PASS` — while a pod is still generating load past the End being
recorded. **"Partial" is the dangerous state, not "empty".** (`initContainers`
are excluded from that test: the ladder's `wait` initContainer terminates when
its rung *starts*, so counting it would mark a running pod finished.)

## 6. Census — a failed census voids the run

```bash
./benchmark/pod-census.sh $RUN_ID end
```

≥ 90% coverage per bucket, and the pod count must match the register's expected
replicas. Not 100%: the first and last bucket of any window are partially
covered by the metric's own cadence, so a perfectly healthy pod reads ~96.7% on a
2 h / 1-minute window. Tightening this to equality fails every valid run.

> **Coverage has two causes and they look identical.** A low census means either
> the pod was *replaced* — which is what D12 is for — or that *nobody was
> collecting*. During one valid run the engine pod read 93.10% with its name,
> `creationTimestamp` and zero restarts all unchanged, and **all 112 cluster pods
> shared the identical mid-window gap**: a collection hiccup, not a replacement.
> **Discriminator: a lifetime gap belongs to one pod; a collection gap is shared
> by all of them.** `readout.sh` never auto-passes a failed census — it tells you
> which kind you have.

A coverage figure read a minute after the window closes is also *pessimistic* —
trailing buckets have not landed yet. Replay before voiding a run over a
near-threshold number.

## 7. Read out, then tear down

```bash
./benchmark/readout.sh $RUN_ID <start-utc> <end-utc>
./benchmark/teardown.sh $RUN_ID            # DRY RUN — prints the plan, deletes nothing
./benchmark/teardown.sh $RUN_ID --confirm  # actually deletes
```

**Do not hand-type the deletes.** This step is irreversible, it runs last when a
120-minute run is already in the bank, and it sits next to two traps:

- **Teardown destroys the End timestamp.** It lives only on the ramp pods'
  `.state.terminated.finishedAt`. `teardown.sh` refuses (G1/G2) until the
  register carries a real End *and* an End census row.
- **`kubectl delete ns hipster-shop` would destroy a constant.** Anything already
  running in the app namespaces that this repo does not define contributes
  identical load to *every* arm — so it cancels. Deleting it at a phase boundary
  manufactures a difference that is not the engine. This script **never deletes
  a namespace**, re-checks mechanically that no manifest it deletes *defines* the
  protected object (G4), and verifies it survived (P1).

G3 refuses while any ramp pod is still running. P2 confirms no
`benchmark=logship` object and no run-lock annotation are left. Istio is
deliberately left up — the next phase reconfigures it in place.

> **Audit the last step of a runbook, not just the risky-looking middle.** Every
> other step here was scripted and gated long before teardown was; teardown was
> one sentence of prose, and it is the only irreversible one.

## 8. Next phase

Repeat from [02](02-deploy-environment.md) with the next `ENGINE`. Do not change
the cluster, the load profile, the app versions or the telemetry configuration
between phases. If you have to change one, the campaign restarts.

---

Next: [04 — Read the results](04-read-results.md)
