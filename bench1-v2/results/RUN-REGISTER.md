# ISI-1779 B1-v2 — RUN REGISTER

**Six timed runs. Two rounds × three engine phases. One row per run, written *as the run happens*.**

Plan of record: `benchmark-plan` on ISI-1779, **rev 7**, §5, §5a and **§5b (pod census)**.

---

## Why this file is the deliverable

There are **no snapshots** in this campaign (board directive, 2026-07-22 — plan rev 5 §5, decision **D8**).
Dynatrace records resource consumption and data flow continuously; the comparison is read *afterwards*
from dashboard **`764f7082-0039-4f3f-ad39-47b5abc5bb73`** with the run's time window applied.

That makes this register the **only record of what window a number came from**. Nothing is captured
locally during a run. A row with a missing, guessed, or local-time timestamp does not degrade the
result — it makes a **120-minute run unreadable**, and the only remedy is to run it again.

Treat writing a timestamp as part of the run, not as paperwork after it.

---

## The second thing this file has to prove: **no pod was replaced mid-window** (D12)

A timestamp pair alone does not make a window readable. **A pod replacement — reschedule, eviction,
node drain, rollout — is INVISIBLE to `dt.kubernetes.container.restarts`.** That metric counts
*in-place container restarts only*; a replaced pod gets a new name and leaves the metric completely
empty. A newborn pod also reports ~2 MiB, so a workload-level `avg()`/`min()` blends it straight into
the aggregate and the run looks clean.

Observed live on `observable-otelarrow` (ISI-1811, re-proven for this issue on 2026-07-22 over the
48-hour window `2026-07-20T11:00:00Z → 2026-07-22T11:00:00Z`): **six pod names across two workloads,
and a restarts timeseries over the same window returning zero datapoints.** A workload floor read
1.99 MiB in one bucket against ~70 MiB either side — pure artifact.

So the register carries a **pod census**: the engine's pod names, each pod's `creationTimestamp`, the
expected replica count, and the cluster. Without those four, "no pod was replaced during this run" is
an unfalsifiable claim, and a 120-minute number rests on it. **A run whose End census does not match
its Start census — same pod names, same creationTimestamps — is INVALID and must be re-run.**

The dashboard enforces the same rule from the other side: tile **POD CENSUS — VALIDITY GATE** is the
first tile under the header, groups by `k8s.pod.name`, and flags any pod alive for less than 90% of
the window. Read it before any other tile.

---

## How to capture a timestamp — copy this exact command

Do **not** read the clock off a laptop, a screenshot, a Slack message, or a pod's `START TIME` column.
Run this on the machine driving the phase, and paste the output verbatim:

```bash
date -u +%Y-%m-%dT%H:%M:%SZ
```

Rules that make a row trustworthy:

1. **Start** is captured **immediately before load begins** — after the §4 gate is green, before the
   first VU. Write the row *then*, with `End` still `⟨UNSET⟩`.
2. **End** is captured **the moment load stops and before any teardown**. Deleting the engine first and
   reconstructing the end time later is how a window silently gets 4 minutes of idle tail baked in.
3. **UTC only, seconds precision, trailing `Z`.** `2026-07-23T09:14:07Z`. Not `09:14`, not `+02:00`,
   not a local time with a note. The dashboard timeframe picker takes exactly this.
4. **A row is written even if the run is aborted** — mark it `ABORTED` in Validation gate and say why in
   Notes. An unrecorded failed run looks identical to a run that never happened.
5. The row is **mirrored into a comment on the phase issue** (ISI-1815…ISI-1820) as it is written, so the
   timestamps survive independently of this file.

## Recovering the window if the End was not captured live (`capture-window.sh`)

The timed run is 120 minutes; an agent heartbeat is 30. **The heartbeat that starts a
run is never the heartbeat that ends it.** Reconstructing `End` from "when I next woke
up" bakes idle tail into the window — the exact failure rule 2 above calls out.

You do not need a capture loop for this (D8 forbids one, and a loop perturbs what it
measures). **Kubernetes already records the instant every ramp pod stopped**, to the
second. `./capture-window.sh <run-id>` reads it back.

Measured live on `observable-otelarrow`, 2026-07-22T14:40Z, with two throwaway Jobs —
one exiting 0, one exiting 1:

| Field | exit 0 | exit 1 |
|---|---|---|
| `Job.status.completionTime` | `14:40:41Z` | **`None`** |
| pod `.state.terminated.finishedAt` | `14:40:37Z` | `14:40:46Z` |

So **End comes from the pod, not the Job**:

1. **`Job.status.completionTime` is only set on success.** `--exit-code-on-error 0` is
   supposed to stop Locust failing a run over a stray 500 (ISI-1822: 13 × HTTP 500 out
   of 78,258 requests marked a healthy ramp `Failed`). If that flag is ever missing or
   ineffective, the Job field is null and the window becomes unrecoverable — silently.
2. It also **lags the pod** by the controller's observation delay: 4 s here, on an idle
   cluster.

`End` = **max** `finishedAt` across all ramp pods in both namespaces — the four staggered
steps stop at the same wall-clock, and load is over when the last one does.

> ⚠️ **Teardown order.** Step 9 deletes both apps, and that deletes the ramp pods —
> which are the only place the End timestamp lives. **Run `capture-window.sh` and
> `pod-census.sh <run-id> end` BEFORE any teardown.** Once those pods are gone the
> window is unrecoverable and the 120 minutes are void. `capture-window.sh` exits `2`
> with an explicit message when no ramp pods exist, so this failure is loud rather than
> a plausible-looking blank.

---

## How to capture the pod census — copy this exact command

Run it **twice**: once immediately after the Start timestamp, once immediately before the End
timestamp, *before any teardown*. Paste the output verbatim into the census table below.

```bash
kubectl get pods -A --no-headers \
  -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,CREATED:.metadata.creationTimestamp,NODE:.spec.nodeName,PHASE:.status.phase,RESTARTS:.status.containerStatuses[*].restartCount' \
  | awk '$2 ~ /^bench-/'
```

Expected replica count, from the manifest that is actually applied:

```bash
kubectl get deploy,statefulset -n default -o custom-columns='KIND:.kind,NAME:.metadata.name,DESIRED:.spec.replicas' | grep bench-
```

All three engines run **`replicas: 1`** in namespace `default` on cluster `observable-otelarrow`, so
the census must show **exactly one pod**, with an unchanged name and `creationTimestamp` at both ends
of the window. Two pod names in one run means a replacement happened — the run is invalid, regardless
of what the restarts metric says, because it will say nothing.

### Self-check before you leave a phase

- [ ] `Start (UTC)` and `End (UTC)` are both real values — no `⟨UNSET⟩`, no placeholder left behind.
- [ ] `End` − `Start` ≈ **120 min** (±2 min). A wildly different duration means one of them is wrong.
- [ ] Both end in `Z` and contain seconds.
- [ ] `End` > `Start`, and `Start` is *after* the gate evidence timestamp.
- [ ] Image tag recorded is the tag that actually ran (`kubectl get pod -o jsonpath='{..image}'`), not the
      tag the manifest says it wants.
- [ ] **Census captured twice** — at Start and at End — and both rows written below.
- [ ] **Pod names identical at Start and End**, and **`creationTimestamp` identical at Start and End**.
      A changed name *or* a changed creationTimestamp = a replacement = **RUN INVALID**.
- [ ] **Pod count == expected replicas (1)** in both censuses.
- [ ] Dashboard `POD CENSUS — VALIDITY GATE` tile is green for this window (every pod ≥ 90% coverage,
      pod count == expected replicas). Its verdict and this file's census must agree; if they disagree,
      trust neither and re-run.
- [ ] **`Attr-landing (7b)` carries a per-signal verdict** — `spans=… logs=… metrics=…`,
      copied verbatim from `./results/attr-landing.sh ${ENGINE} --gate` (CHECK 7). Mandatory
      on **all three arms** (ISI-1844 / board Q5). `NO-DATA` is written as `NO-DATA`, never as
      `SAFE`; a blank cell means the readout months later cannot tell a signal the engine
      dropped from a signal the filter hid.
- [ ] Row mirrored to the phase issue comment.
- [ ] Round 2's row for this engine does **not** reuse Round 1's window.

---

## Register

Run ID format: `R<round>-P<phase>-<engine>` — e.g. `R1-P1-collector`.
Phase order is fixed by plan §1: **P1 = OTel Collector → P2 = Fluent Bit v5 → P3 = OTel-Arrow native**.

| Run ID | Engine + image tag | Round | Cluster | Expected replicas | Start (UTC) | End (UTC) | Validation gate | Census | Attr-landing (7b) | Load profile | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `R1-P1-collector` | otel-collector contrib `0.154.0` | 1 | `observable-otelarrow` | 1 | `2026-07-22T15:58:43Z` | `2026-07-22T17:59:21Z` | `PASS 6/6 @ 2026-07-22T15:57:12Z` | `MATCH` | `not run` — the probe postdates this run (`attr-landing.sh` was written 2026-07-23). **Not** a pass: nothing was measured. Establish the collector baseline at R2P1. | `rampup2h` 50→100→150→200 VU, both apps | `cumulativetodelta` added to the metrics pipeline before this run (CHECK 5 fix). CAAPH reconciliation for istiod is PAUSED for the campaign (ISI-1826). Built-in app loadgenerators run alongside the ramp, identically in every phase — see the ⚠️ note below on `hipster-shop/loadgenerator`, which is a pre-campaign leftover that **must be left running**. Duration 120.6 min (End−Start), within the ±2 min self-check. End recovered with `capture-window.sh` from `max(pod .state.terminated.finishedAt)` across all 8 ramp pods (`otel-demo` 4 + `hipster-shop` 4), captured **before** teardown; the two namespaces' last pods stopped 17:59:21Z and 17:59:07Z. Nothing anomalous: engine pod never replaced, 0 restarts, node under no pressure. |
| `R1-P2-fluentbit` | fluent-bit `5.0.9` | 1 | `observable-otelarrow` | 1 | `2026-07-23T08:34:49Z` | `2026-07-23T10:35:12Z` | `PASS 6/6 @ 2026-07-23T08:34:35Z` ⚠️ *(gate was SIGNAL-BLIND — re-running it after the CHECK 5b fix added the same day yields **FAIL**: `metrics 100% processor failure`. Load/spans/resource remain valid; the metrics signal was never delivered.)* | `MATCH` | `spans=SAFE logs=UNSAFE metrics=NO-DATA` — measured over **this exact window** on 2026-07-23 (ISI-1844): spans 17,858,597/17,858,597 carry `k8s.cluster.name`, logs **0**/10,263,977, metrics 0 series. This is the declared expectation for every fluentbit arm; `NO-DATA` is the 🛑 metrics finding, recorded as itself and never as SAFE. | `rampup2h` 50→100→150→200 VU, both apps | **Duration 120.4 min** (End−Start), within ±2. End recovered with `capture-window.sh` from `max(pod .state.terminated.finishedAt)` across all 8 ramp pods, captured **before** teardown; 8/8 finished. Census **MATCH** — same pod name and `creationTimestamp` at both ends. Census coverage 96.72% (118/122 buckets); the shortfall is a **cluster-wide Dynatrace collection gap shared by all 109 pods**, not a pod-lifetime gap — see the discriminator note. **Readout: CPU avg 117.1 mCores / p95 167.9 / max 173.0; memory avg 124.3 MiB / peak 207.1. Spans 17,858,584 (mesh 8,974,246 + app-sdk 8,884,341). Logs 10,263,964. Metrics: NONE — see the 🛑 note.** Normalised vs R1P1: total records −3.55%, engine CPU −38.34% absolute, **−36.08% per 1M records — quote the normalised figure.** Engine pod `bench-fluentbit-v5-67978b69d8-h8st4` created `2026-07-23T08:16:26Z`, expected replicas 1. **The gate went RED on the first attempt** (CHECK 2, hipster-shop app spans = 0) and was fixed before any load ran — see the two R1P1 carry-over mutations in commit `d4a0d29`: `ENABLE_TRACING` was never committed anywhere, and `render.sh` would have deleted the ISI-1815 delta-temporality override. Both are now in `_templates/`, so R1P3 and Round 2 render correctly with no hand-patching. 🛑 **NO app-OTLP metrics are delivered by this arm** — the metrics processor chain errors 100% and aborts before export, so the datapoints are LOST, not merely unlabelled (corrected 2026-07-23; the first wording said "drops resource attributes", which was too weak). The failure is silent in the log and CHECK 5 is signal-blind, which is why the gate passed. Spans, load and the `dt.kubernetes.container.*` resource readout are unaffected and fully comparable. **Logs ARE delivered and NOTHING is dropped** (engine counters: `dropped_records=0`, `errors=0`) **but the dashboard's log tiles read ZERO for this arm** — separate read-time defect, see the note below. **The metrics dimension of Round 1 is asymmetric — open decision for @BigBoss.** See the note below. |
| `R1-P3-arrow` | `ghcr.io/isitobservable/df_engine:0.50.0` | 1 | `observable-otelarrow` | 1 | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | `rampup2h` 50→100→150→200 VU, both apps | |
| `R2-P1-collector` | otel-collector contrib `0.154.0` | 2 | `observable-otelarrow` | 1 | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | `rampup2h` 50→100→150→200 VU, both apps | |
| `R2-P2-fluentbit` | fluent-bit `5.0.9` | 2 | `observable-otelarrow` | 1 | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | `rampup2h` 50→100→150→200 VU, both apps | |
| `R2-P3-arrow` | `ghcr.io/isitobservable/df_engine:0.50.0` | 2 | `observable-otelarrow` | 1 | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | `rampup2h` 50→100→150→200 VU, both apps | |

**Owning issue per row:** R1-P1 = ISI-1815 · R1-P2 = ISI-1816 · R1-P3 = ISI-1817 ·
R2-P1 = ISI-1818 · R2-P2 = ISI-1819 · R2-P3 = ISI-1820.

> ⚠️ **`hipster-shop/loadgenerator` — a second load source exists. LEAVE IT RUNNING.**
> Found during R1-P1 teardown (2026-07-22T18:1xZ). The hipster-shop overlay deliberately
> **deletes** the bundled loadgenerator — its own comment says *"a second, uncontrolled load
> source would corrupt the methodology"* — and none of `hipster-shop-{otel-collector,
> fluentbit-v5,otel-arrow-native}.yaml` contains one (`grep -c 'name: loadgenerator'` = 0 on
> all three). But a `loadgenerator` Deployment applied **before the campaign** (deployment
> created `2026-07-21T15:59:35Z`, 10 VU against `frontend:80`) is live in the namespace, and
> its `last-applied-configuration` carries none of the overlay's kustomize labels — so it is
> not ours. Its pod (`…-g7pxd`, created `2026-07-22T14:54:47Z`, 0 restarts) was up
> continuously **before and through the whole R1-P1 window**.
>
> **Do not delete it as part of any teardown.** Because it is in no phase manifest, teardown
> never removes it and redeploy never recreates it — it therefore persists **identically
> across all six runs**, which is exactly the condition cross-phase comparison needs. Removing
> it now would give P1 more hipster-shop load than P2/P3 and *create* the asymmetry the
> overlay comment warns about. It is a constant, not a variable.
>
> Two things it is honest to record rather than wave away: it drives ~10 VU of hipster-shop
> traffic that the ramp ladder does not account for, and **unlike otel-demo's `load-generator`
> it has an Istio sidecar** (`2/2`), so its traffic does produce mesh spans and access logs —
> otel-demo's is sidecar-excluded precisely so the load driver is not measured. So absolute
> hipster-shop volumes carry a constant offset. **Engine-vs-engine comparison is unaffected**;
> any *absolute* hipster-shop ingest figure should be read with this in mind.

> 🛑 **R1P2 DELIVERS NO APP-OTLP METRICS AT ALL. The metrics signal is not comparable to R1P1.**
> *(2026-07-23. This CORRECTS the first version of this note, which said Fluent Bit "drops
> resource attributes on metrics". That was too weak and wrongly shaped — the datapoints are not
> stripped, they are **lost in the processor stage and never exported**.)*
>
> Same query on both arms, `timeseries avg(system.cpu.utilization), by:{benchmark.engine,
> k8s.cluster.name, service.name}`:
>
> | arm | rows | detail |
> |---|---|---|
> | `R1-P1-collector` (16:30–16:45Z) | **5** | `otel-collector` / `observable-otelarrow` / `load-generator`, `loadgen-otel-demo`, `product-reviews`, `recommendation` (+1 null row) |
> | `R1-P2-fluentbit` (live) | **1** | every field `null`; by `host.name` the only emitter is `paperclip`, an unrelated off-cluster source present in BOTH windows |
>
> So it is not that our app metrics arrive unlabelled — **the bucket that held them is gone.**
>
> **Mechanism, from Fluent Bit's own counters.** The metrics pipeline fails on every batch and
> aborts at the first processor:
>
> | signal | stages with counters | invocations | errors |
> |---|---|---|---|
> | metrics | stage 6 **only** | 1,732 | **1,732 (100%)** |
> | traces | stages 10–13 | 443,941 | 0 |
> | logs | stages 0–5 | (clean) | 0 |
>
> Stages 7, 8 and `cumulative_to_delta` have **no counters at all** — they are never reached.
> `fluentbit_output_dropped_records_total` stays **0** because the records die in the processor,
> upstream of the output plugin that counts drops.
>
> ⚠️ **The failure is completely SILENT in the log.** At `log_level: info` there is not one line
> about it — `grep -i error` returns only benign idle-keepalive `[downstream]` reaps. The single
> piece of evidence anywhere is `fluentbit_processor_errors_total{signal="metrics"}` on the
> engine's own `:2020` endpoint.
>
> ⚠️ **This is why CHECK 5 passed: the gate is SIGNAL-BLIND.** It asserts non-zero accepted AND
> exported *in aggregate* (283,359 / 283,021 — overwhelmingly logs and traces) plus "0 error-ish
> log lines", and both stayed green while an entire signal was 100% dead. **Add a per-signal
> assertion before R1P3** — an aggregate throughput check cannot see one signal fail, exactly as
> an aggregate span check could not see one namespace die (ISI-1815).
>
> **Likely cause — NOT yet confirmed, and deliberately not tested on the live engine.** The same
> `content_modifier` verbs succeed on logs and traces and fail only on metrics, which points at a
> missing metrics-specific `context:` on the processor rather than at Fluent Bit being unable to
> enrich metrics. If that is right, this is a CONFIG defect in `engines/fluentbit-v5.yaml`, not an
> engine limitation, and saying "Fluent Bit can't do metrics" on camera would be **wrong and
> unfair**. Confirm on a scratch instance **after teardown** — adding a pod mid-run would perturb
> a measured window on a cluster with no spare CPU, and restarting the engine would replace the
> pod and VOID the run outright.
>
> **What survives, and why the run is still worth finishing.** Load, spans and resource are all
> unaffected and fully comparable:
> - *load* — the ramp ladder, untouched.
> - *spans* — 443,941 trace-processor invocations at 0 errors; both apps confirmed in Grail.
> - *resource* — `dt.kubernetes.container.*`, which **Dynatrace collects itself and Fluent Bit
>   never handles**. Seeing healthy pod/CPU/memory numbers for the engine therefore says nothing
>   about whether the metrics *pipeline* works; the two are independent paths and it is easy to
>   read the first as reassurance about the second.
>
> **Open decision for @BigBoss — the metrics dimension of Round 1 is asymmetric.** P1 delivered
> app metrics, P2 delivers none, so that one dimension cannot be compared within Round 1 whatever
> the cause. Options: (a) report the metrics signal for R1P2 as *not delivered by this
> configuration* and fix the `context:` for **all three** arms in Round 2, keeping parity within
> each round; or (b) re-run R1P2 after the fix. Spans/resource/load are unaffected either way.
> **Do not patch the pipeline mid-run** — it would replace the engine pod and void the window.

> 🛑 **THE DASHBOARD'S LOG TILES READ ZERO FOR R1P2 — AND FLUENT BIT IS DELIVERING MORE LOGS
> THAN THE COLLECTOR. Do not read them until they are fixed. (2026-07-23, ISI-1816.)**
>
> Both log tiles — *Ingest volume by signal* and *Ingest rate over the run* — filter with
> `k8s.cluster.name == "observable-otelarrow" and isNotNull(benchmark.engine)`.
>
> | arm | logs, filtered by `benchmark.engine` | logs, **as the dashboard filters them** |
> |---|---|---|
> | `R1-P1-collector` | 10,656,970 | 10,656,970 — identical |
> | `R1-P2-fluentbit` | **5,262,729** | **0** |
>
> Fluent Bit's logs `content_modifier` reports **zero errors**, yet its `k8s.cluster.name`
> upsert does not land: every one of those 5.26M records has `k8s.cluster.name` **null**, while
> `benchmark.engine` is present on all of them. The same upsert works fine on **spans**, which
> carry `observable-otelarrow` normally. So this is the logs path specifically — and unlike the
> metrics failure it is **completely invisible in the engine's own counters**: 0 processor
> errors, records exported, everything green.
>
> **Why this one is the most dangerous defect in the campaign so far.** The metrics failure at
> least *looked* like nothing (an empty tile invites a question). This produces a large,
> directional, entirely plausible number: *"Collector 1.2M logs, Fluent Bit 0"* — read as
> **Fluent Bit dropped every log**, when it in fact dropped **nothing at all** — engine counters show
> `dropped_records = 0`, `errors = 0`, `retries_failed = 0`.
>
> ⚠️ **CORRECTION (2026-07-23).** An earlier version of this note said Fluent Bit delivered *more*
> logs than the collector. **That was wrong** — it compared a 15-minute P1 slice against a
> 20-minute P2 slice taken at *different rungs of the ramp*. Measured over the **identical first
> 89 minutes** of each run, P2 delivers slightly FEWER records:
>
> | signal | P1 collector | P2 fluentbit | delta |
> |---|---|---|---|
> | logs | 7,032,793 | 6,413,886 | −8.80% |
> | spans | 12,257,408 | 11,175,723 | −8.82% |
>
> Logs and spans are down by the *same* 8.8%, which argues against a per-signal engine problem
> and points upstream at how much telemetry the apps produced. Do not conclude from a partial
> mid-ramp window — the full-window figure from `readout.sh` is the one to quote.
>
> **The general lesson: never quote a cross-arm comparison until both sides come from equivalent
> elapsed windows.** `readout.sh` takes explicit start/end for exactly this reason.
> Nobody would query behind a number that confirms an expectation.
>
> **Read-time fix, not a config change** — telemetry config is frozen (same principle as
> `results/service-key.dql`). Drop `k8s.cluster.name` from the **logs** branch only and filter on
> `isNotNull(benchmark.engine)`. That is safe on its own: `benchmark.engine` is campaign-unique —
> the only non-null values anywhere on the tenant are the three engine names. **Keep** the cluster
> filter on spans, where the attribute does land and guards against the cross-cluster
> `k8s.workload.name` collision.
>
> `results/readout.sh` already reports logs the correct way and prints the cluster-filtered
> cross-check next to it, so the discrepancy is visible rather than assumed. ⚠️ **The dashboard
> `764f7082` itself still needs the same edit before the logs tiles are shown to anyone.**

### Pod census — one block per run, captured at Start AND at End (D12)

The names and `creationTimestamp`s here are the **only** evidence that the window contains one
continuous pod lifetime. `Restarts` is recorded for completeness, but it is *not* the check — a
replaced pod shows no restart at all. **The check is: same pod name, same `creationTimestamp`, at both
ends, count == expected replicas.**

| Run ID | When | Pod name | `creationTimestamp` | Node | Restarts | Verdict |
|---|---|---|---|---|---|---|
| `R1-P1-collector` | Start | `bench-otel-collector-collector-cbd58d94c-rz424` | `2026-07-22T15:45:23Z` | `observable-otelarrow-workers-k5hgq-9r662` | 0 | baseline |
| `R1-P1-collector` | End | `bench-otel-collector-collector-cbd58d94c-rz424` | `2026-07-22T15:45:23Z` | `observable-otelarrow-workers-k5hgq-9r662` | 0 | `MATCH` |
| `R1-P2-fluentbit` | Start | `bench-fluentbit-v5-67978b69d8-h8st4` | `2026-07-23T08:16:26Z` | `observable-otelarrow-workers-k5hgq-lz9mb` | 0 | baseline |
| `R1-P2-fluentbit` | End | `bench-fluentbit-v5-67978b69d8-h8st4` | `2026-07-23T08:16:26Z` | `observable-otelarrow-workers-k5hgq-lz9mb` | 0 | `MATCH` |
| `R1-P3-arrow` | Start | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ |
| `R1-P3-arrow` | End | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ |
| `R2-P1-collector` | Start | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ |
| `R2-P1-collector` | End | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ |
| `R2-P2-fluentbit` | Start | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ |
| `R2-P2-fluentbit` | End | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ |
| `R2-P3-arrow` | Start | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ |
| `R2-P3-arrow` | End | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ | ⟨UNSET⟩ |

Expected workload names, one pod each: `bench-otel-collector-collector` (P1, created by the OTel
operator — note the `-collector` suffix the operator appends), `bench-fluentbit-v5` (P2),
`bench-otel-arrow-native` (P3). If a run needs more than one row per `When`, the pod count already
exceeds the expected replica count and the run is invalid.

`Verdict` is `MATCH` (name and creationTimestamp identical to the Start row, count == 1) or
`REPLACED → RUN INVALID` plus what happened. There is no third value.

### Worked example — what a filled-in run looks like

A valid run. Note that the register row and the census rows agree, and that the `creationTimestamp`
is *older* than the Start timestamp — the pod was already up when the window opened, which is the
point:

| Run ID | Engine + image tag | Round | Cluster | Expected replicas | Start (UTC) | End (UTC) | Validation gate | Census | Attr-landing (7b) | Load profile | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `R1-P1-collector` | otel-collector contrib `0.154.0` | 1 | `observable-otelarrow` | 1 | `2026-07-23T09:14:07Z` | `2026-07-23T11:14:31Z` | `PASS 6/6 — comment a1b2c3d4` | `MATCH` | `not run` — the probe postdates this run (`attr-landing.sh` was written 2026-07-23). **Not** a pass: nothing was measured. Establish the collector baseline at R2P1. | `rampup2h` 50→100→150→200 VU, both apps | node `…-k5hgq-9r662` under no pressure |

| Run ID | When | Pod name | `creationTimestamp` | Node | Restarts | Verdict |
|---|---|---|---|---|---|---|
| `R1-P1-collector` | Start | `bench-otel-collector-collector-7d9f8b6c5-x4kqp` | `2026-07-23T08:51:44Z` | `observable-otelarrow-workers-k5hgq-9r662` | 0 | baseline |
| `R1-P1-collector` | End | `bench-otel-collector-collector-7d9f8b6c5-x4kqp` | `2026-07-23T08:51:44Z` | `observable-otelarrow-workers-k5hgq-9r662` | 0 | `MATCH` |

And an invalid one. The restart count is still `0` at both ends — **it always will be**, because a
replacement never increments it. The pod name and `creationTimestamp` are what give it away:

| Run ID | When | Pod name | `creationTimestamp` | Node | Restarts | Verdict |
|---|---|---|---|---|---|---|
| `R1-P2-fluentbit` | Start | `bench-fluentbit-v5-6c8d47f9b-2mhpq` | `2026-07-23T12:02:11Z` | `…-k5hgq-9r662` | 0 | baseline |
| `R1-P2-fluentbit` | End | `bench-fluentbit-v5-6c8d47f9b-tw7vl` | `2026-07-23T13:19:08Z` | `…-k5hgq-lz9mb` | 0 | `REPLACED → RUN INVALID` — rescheduled to another node at ~13:19Z, memory series restarts from ~2 MiB mid-window |

`validate-phase.sh` check 6 prints the Start baseline for you in exactly this shape, and
`./pod-census.sh <run-id> start|end` emits paste-ready rows for both captures.

### Column contract

| Column | What goes in it |
|---|---|
| **Run ID** | `R<round>-P<phase>-<engine>`, from the table above. Never invent a new one. |
| **Engine + image tag** | The image that actually ran, resolved from the running pod. |
| **Round** | `1` or `2`. Round 2 is a **fresh deploy of everything**, not a re-read of Round 1's pods. |
| **Cluster** | `observable-otelarrow`. Recorded explicitly because `k8s.workload.name` is **not unique across the clusters on this tenant** — `observable-kagent` and `observable-agentsandbox` report the same `dt.kubernetes.container.*` metric keys. A readout that forgets to scope by cluster silently mixes in another cluster's series. |
| **Expected replicas** | `1` for all three engines. This is what the census pod count is checked against; without it, "one pod" is an assumption rather than a comparison. |
| **Start (UTC)** | `date -u +%Y-%m-%dT%H:%M:%SZ`, captured before the first VU. |
| **End (UTC)** | Same command, captured when load stops, before teardown. |
| **Validation gate** | `PASS 6/6` plus the §4/§5b evidence pointer (phase-issue comment ID), or `ABORTED` + reason. |
| **Census** | `MATCH` (Start and End censuses identical, count == expected replicas) or `REPLACED → RUN INVALID`. The per-pod detail lives in the census block above. A `PASS 6/6` gate with a failed census is still an invalid run — the gate runs *before* the window, the census covers the whole of it. |
| **Load profile** | `rampup2h`, VU ladder, and that **both** apps were driven. Any deviation invalidates cross-phase comparison — say so loudly. |
| **Notes** | Anything that could explain an outlier: restarts, OOM kills, node pressure, cluster events, export retries, a redeploy mid-run. Empty means "nothing anomalous", so do not leave it empty out of haste. |

---

## Gate evidence (per run)

`validate-phase.sh <engine>` prints one `CHECK <n> PASS|FAIL <name> <detail>` line per check. Paste the six
lines into the phase issue comment alongside the row. Summarise here as `PASS 6/6 — <comment id>`.

```
CHECK 1 PASS apps-healthy      ...
CHECK 2 PASS app-spans         ...
CHECK 3 PASS sidecars          ...
CHECK 4 PASS istio-spans       ...
CHECK 5 PASS engine-healthy    ...
CHECK 6 PASS pod-census        bench-otel-collector-collector-7d9f8b6c5-x4kqp@2026-07-23T08:51:44Z pods=1 ...
```

Check 6 is the pod-census baseline (plan §5b). It prints the engine pod's name and
`creationTimestamp` in exactly the shape the census table above wants — capture it again at End and
compare. Every DQL query in the gate is scoped by `k8s.cluster.name`, for the same reason the
dashboard tiles are.

A run started on anything other than `PASS 6/6` is not comparable to the other five and must be
recorded as such — an unvalidated phase is worse than a missing one, because it looks like data.

---

## Reading a window back in Dynatrace

1. Open dashboard `764f7082-0039-4f3f-ad39-47b5abc5bb73`
   ("Fluent Bit v5 vs OTel-Collector vs OTel-Arrow — Benchmark Comparison (ISI-1779 B1-v2,
   timeframe-driven)"). This is the *same* dashboard the plan §5 cites — it was updated in place
   rather than replaced, so every existing reference to `764f7082` still resolves.
2. Set the dashboard timeframe to the row's **Start → End**, exactly as written.
3. **Read the `POD CENSUS — VALIDITY GATE` tile first.** It is the first tile under the header. Every
   pod must show `coverage_pct ≥ 90` and the verdict `ok`, and `Pods seen per engine` must equal this
   row's **Expected replicas**. If it does not, **stop** — the window's numbers are not reportable, no
   matter how clean the charts below look. Cross-check it against this row's census block; they must
   agree.
4. Every tile is grouped by `k8s.pod.name` and scoped by `k8s.cluster.name`, so the engine under test
   in that window reads out directly — CPU (millicores), memory working set, restarts/OOM, and ingest
   volume by signal — with a replaced pod appearing as its **own row** rather than being averaged into
   the workload.
5. Compare `R1-P<n>-<engine>` against `R2-P<n>-<engine>` for the same engine to see replication, and
   across engines *within a round* for the headline comparison.

### How the per-app / per-service split is keyed — ISI-1836 decision, 2026-07-23

The namespace of a span lives under **two mutually exclusive attributes**: app-SDK spans carry
`service.namespace`, Istio mesh spans do not. The original per-app tile coalesced only
`service.namespace`, so it dropped **10,070,942 of 18,499,537 R1-P1 spans (54.4%)** into an
`unlabelled` bucket that reads exactly like data loss.

ISI-1836 offered three fixes — (a) rename the bucket, (b) coalesce in `k8s.namespace.name`,
(c) split by `benchmark.telemetry_source`. **We took none of them. The recorded decision is (d):**

```
app = coalesce(service.namespace, splitString(service.name, ".")[1], "<unattributed>")
       ^ written by the app SDK    ^ written by Istio (`<service>.<namespace>`)  ^ visible gap
```

**Why not (b), which was the obvious fix.** `k8s.namespace.name` is written by the
k8sattributes processor — that is, by **the engine under test**. Folding it in would make the
per-app split partly a function of the engine, which is precisely the class of artifact that does
*not* cancel in an engine-vs-engine comparison. Istio already encodes the namespace in
`service.name`, Istio config is frozen and identical across all three arms, so parsing it there
buys the **same coverage as (b) with zero engine-applied attributes**.

Measured on R1-P1 `2026-07-22T15:58:43Z → 17:59:21Z`, verified live before the dashboard was
deployed: hipster-shop 7,962,661 mesh + 5,507,966 app-sdk; otel-demo 1,196,151 mesh + 2,920,629
app-sdk; `<unattributed>` 912,130. Total **18,499,537 — the window's exact benchmark-tagged span
count**, so the key neither drops nor double-counts a span. Coverage **95.07%**.

The residual **4.93% is left visible on purpose** and has its own tile: hipster-shop
`currencyservice` (900,146) and `paymentservice` (11,984) are app-SDK services that never set
`service.namespace`. They render as `<unattributed>.<service>` rather than being folded into a
real namespace — a gap must read as a gap, never as a clean result.

**Read per-service volume from `<namespace>.<service>`, never from `service.name` alone**
(`results/service-key.dql`, dashboard tile 14). Bare `service.name` **collides**: `frontend` is a
single identity holding hipster-shop 3,294,973 + otel-demo 892,424 = 4,187,397 spans (22.6% of the
run), and the same workload also appears twice — mesh `frontend.hipster-shop` and app-SDK bare
`frontend` — so its real volume is never visible in one place. Normalised:
`hipster-shop.frontend` 6,591,068 and `otel-demo.frontend` 1,390,604, each whole and separate.
This is a **read-time** key: it needs no config change, so it applies retroactively to the banked
R1-P1 and identically to every later arm. **Do not do the rename at source mid-campaign** — the
grouping key would then differ per arm and the read path would need per-arm logic. Telemetry
config stays frozen; the engine is the only variable.

### `benchmark.telemetry_source` is now cross-checked, not trusted — ISI-1836 defect 2

The source tile used to map `if(benchmark.telemetry_source == "istio-mesh", "istio-mesh", else:
"app-sdk")`. That attribute is **null on 50.5% of R1-P1 spans**, and for P1 the output was
*coincidentally* correct — only Istio sets it, so null really did mean app-sdk. But the mapping was
`null → app-sdk`, so **an engine that dropped the attribute would report a clean, plausible 100%
app-sdk instead of failing.** Same class as the ISI-1830 lesson: a skipped check must never render
as a pass.

Tile 8 now shows two columns. `stamped` renders null as `<not stamped>`. `shape` derives the same
fact **independently** — `telemetry.sdk.name == "envoy"` (written by the emitting proxy) plus a
dotted Istio service name — touching nothing the engine writes. **If the two columns disagree, the
engine dropped the attribute; read that as a defect, not a result.**

> `envoy` alone is not sufficient: otel-demo's own `frontend-proxy` emits 422,380 Envoy spans that
> are not Istio sidecar spans. The dotted service name is what separates them.

**P2 pre-read check (ISI-1836 AC3), confirmed both ways on 2026-07-23:** statically, all three
`istio/telemetry-*.yaml` stamp `benchmark.telemetry_source: istio-mesh` identically; empirically,
live fluent-bit v5 spans read **115,009 stamped `istio-mesh` / 19,237 `<not stamped>` app-sdk with
zero disagreement rows**. The P2 source split is meaningful.

### Three readout traps this campaign has already paid for

- **Absolute timeframes in DQL are a QUOTED string or nothing.** If you replay a window by hand
  instead of via the timeframe picker: `from:"2026-07-23T09:14:07Z"`. Unquoted is a `PARSE_ERROR`
  and `timestamp("...")` fails with *"has to be a long, but was a string"*. The entire no-snapshot
  design rests on being able to replay a register window long after the run ended.
- **`dt.kubernetes.container.restarts` is SPARSE** — a workload that never restarted has *no series
  at all*, so "no rows" is indistinguishable from a broken query. The stability tile (tile 4) already
  handles this: it anchors on `cpu_usage` (always present), left-joins restarts/OOM via `lookup`, and
  coalesces to `0`, so a healthy engine reads an explicit `0` instead of vanishing. Verified live
  against five never-restarted workloads. Do not "simplify" that tile into a bare restarts
  `timeseries` — you would turn every healthy run into an empty panel, and worse, **a restart resets
  memory and fakes a clean flat trend**, so a missed restart turns a leak into a passing result.
- **A pod REPLACEMENT is not a restart, and nothing in the restarts metric will ever tell you it
  happened.** `dt.kubernetes.container.restarts` counts in-place container restarts only. A
  reschedule, eviction, node drain or rollout gives you a new pod name and an *empty* metric, while a
  newborn pod reporting ~2 MiB poisons any workload-level `min()`/`avg()`. Re-proven live on
  `observable-otelarrow` over `2026-07-20T11:00:00Z → 2026-07-22T11:00:00Z`: six pod names across two
  workloads, zero restart datapoints. This is why the census exists and why the dashboard groups by
  `k8s.pod.name`. The census threshold is **90% bucket coverage, not 100%** — the first and last bucket
  of any window are partially covered by the metric's own cadence, so a healthy pod reads ~96.7% on a
  2h/1-minute window and never exactly 100%; real replacements measured 27–56%.

Only one engine is deployed at a time (plan §1), so a correctly-scoped window contains exactly one
engine workload **and exactly one engine pod**. If a window shows two workloads, the window is wrong —
most likely an End timestamp captured after the next phase started. If it shows one workload but two
pod names, the pod was replaced and the run is invalid.

**Scope reminder (D1):** Istio/Envoy Prometheus metrics are excluded from every run. App-emitted OTLP
metrics **are** in scope and are measured. Istio-generated spans and access logs are in scope.
