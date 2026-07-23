# Out-of-repo cluster state owned by this campaign — MUST be reverted at campaign end

This file tracks mutations made to clusters *outside* this repo for the duration of
the ISI-1779 B1-v2 benchmark campaign. Each one leaves a cluster in a non-default
state that no `kubectl delete -f` in this repo will undo. **Revert every row below
once every measurement phase has reached a terminal state** (the gate is spelled out
in full below — it is a named list of issue ids, not "the last phase"), before
closing ISI-1779.

Tracked as **ISI-1826** (backlog, do-not-self-start) so it cannot be lost with an
individual phase issue.

> ⚠️ **R2P3 is cancelled and can no longer own a revert.** Updated 2026-07-23 under
> ISI-1820. The OTel-Arrow arm is DNF (ISI-1849) and all three of its phases are
> cancelled — R1P3/ISI-1817, R2P3/ISI-1820 and soak S3/ISI-1824. Every "R2P3" that
> appeared in this file as a *revert owner* has been repointed, because a cancelled
> phase tears nothing down: leaving the owner as R2P3 would have orphaned the CAAPH
> un-pause and the leftover-loadgenerator cleanup with no phase left to run them.
>
> 🛑 **The repoint to "R2P2 (last)" was WRONG — R2P2 is not the last phase.** Resolved
> 2026-07-23 under ISI-1826. The ISI-1824 note below flagged that *nothing in this repo*
> recorded where the two 24h soaks sit relative to Round 2. That was true of the repo,
> but the order **is** on record — in the parked soak issues' own descriptions:
>
> - **Soak S1 / ISI-1811:** *"Serial — do not start until ISI-1820 (R2P3) reports clean
>   teardown and @BigBoss promotes."*
> - **Soak S2 / ISI-1823:** *"Serial — do not start until Soak S1 reports clean teardown."*
>
> So the campaign order is `R1P1 → R1P2 → R2P1 → R2P2 → [R2P3 ✗] → S1 → S2`: **both
> soaks run after Round 2.** Firing these reverts at R2P2 would therefore have done
> exactly what the guard feared —
>
> - resume CAAPH reconciliation of `istiod` **during a 24h measurement window**, and
> - delete the standing `hipster-shop/loadgenerator` (10 VU, §3) **before** the soaks,
>   so the soaks would run against a different load baseline than every rampup arm they
>   are read against — the exact asymmetry §3 exists to prevent.
>
> ## The gate — absolute, no relative pointers
>
> **Execute no revert in this file until every measurement-phase issue below is in a
> terminal state (`done` or `cancelled`). Re-check the board; do not trust this table.**
>
> | Phase | Issue | Status when this note was written (2026-07-23) |
> |---|---|---|
> | R1P1 OTel Collector | ISI-1815 | ✅ `done` |
> | R1P2 Fluent Bit v5 | ISI-1816 | ✅ `done` |
> | R1P3 OTel-Arrow | ISI-1817 | ✅ `cancelled` |
> | R2P1 OTel Collector | ISI-1818 | ⏳ `in_progress` |
> | R2P2 Fluent Bit v5 | ISI-1819 | ⏳ `backlog` |
> | R2P3 OTel-Arrow | ISI-1820 | ✅ `cancelled` |
> | Soak S1 OTel Collector | ISI-1811 | ⏳ `backlog` |
> | Soak S2 Fluent Bit v5 | ISI-1823 | ⏳ `backlog` |
> | Soak S3 OTel-Arrow | ISI-1824 | ✅ `cancelled` |
>
> 4 of 9 were still open when this was written, so **the gate was NOT met.** On the
> ordering above the last phase to run is **Soak S2 / ISI-1823**, but that is stated
> only as context — *the gate is the table, not the name of the last phase*, precisely
> so that cancelling or inserting a phase cannot invalidate it again. Re-ordering
> remains ISI-1779's decision; any re-order changes which row runs last but not the gate.
>
> ⚠️ **One dangling pointer is left and it is not ours to fix:** ISI-1811's own start
> gate still names cancelled `ISI-1820 (R2P3)`. It fails safe (a cancelled phase never
> reports clean teardown, and @BigBoss promotion is required regardless), but it should
> be repointed at **ISI-1819 (R2P2)** by whoever owns the ordering. Raised on ISI-1779.
>
> ⭐ Root cause of this whole family of bugs: "last phase" is a **relative** pointer. The
> ISI-1820 repoint corrected *which id* it named without re-checking whether the referent
> was still the true end of the campaign, so it landed on another relative pointer.
> Cancelling a phase invalidates relative owners twice over. The fix is not a better
> relative pointer — it is the absolute table above.

---

## 1. CAAPH reconciliation paused on `istiod` for `observable-otelarrow`

| | |
|---|---|
| **Added** | 2026-07-22, ISI-1815 (R1P1) |
| **Cluster** | management cluster `capmox-mgmt-prod` (NOT the workload cluster) |
| **Object** | `HelmReleaseProxy/istiod-observable-otelarrow-x57wm` |
| **Revert owner** | **ISI-1826** — fires only when all 9 phase issues in the gate table at the top are terminal (`done`/`cancelled`). **Not** R2P2: the soaks run after Round 2. |

### What was done

```bash
# on capmox-mgmt-prod
kubectl annotate helmreleaseproxy istiod-observable-otelarrow-x57wm \
  cluster.x-k8s.io/paused=true \
  isi1779.benchmark/reason="ISI-1815 R1P1: benchmark owns istiod meshConfig for the campaign; REMOVE at campaign end"
```

### Why

`cluster-api-addon-provider-helm` (CAAPH) on the management cluster reconciles
`HelmChartProxy/istio-istiod`, whose `valuesTemplate` still carries the stale ISI-837
`otelp` extensionProvider verbatim. After every `helm upgrade` this phase ran, CAAPH
re-applied the older values within 0.6–6.3 minutes, stripping the benchmark's
providers. istiod then silently drops a tracing spec whose provider it cannot
resolve — no error, no event, and `kubectl get telemetry` still lists the CR as
applied. That is failure mode 4a in `validate-phase.sh`.

### Why *this* fix and not the obvious ones

The `addons.observable=true` selector on `HelmChartProxy/istio-istiod` matches exactly
**two** clusters: `observable-kagent` (istiod untouched, helm revision 1) and
`observable-otelarrow`. Pausing the per-cluster **HelmReleaseProxy** leaves
observable-kagent byte-identical and is non-destructive — nothing is uninstalled, CAAPH
just stops re-applying.

**Do NOT** narrow the `clusterSelector` and **do NOT** drop the `addons.observable`
label. Either makes CAAPH delete the HelmReleaseProxy, which can uninstall istiod from
a live cluster — and via the same label, cilium and metallb too.

### Risk while it is in place

istiod on `observable-otelarrow` no longer self-heals from configuration drift. This is
acceptable and in fact required for the campaign, because the benchmark owns
`meshConfig` for its duration. It is **not** acceptable to leave behind afterwards.

### Revert

```bash
# on capmox-mgmt-prod
kubectl annotate helmreleaseproxy istiod-observable-otelarrow-x57wm \
  cluster.x-k8s.io/paused- isi1779.benchmark/reason-
```

Then confirm CAAPH reconciles: the `HelmReleaseProxy` `status.revision` should advance
and the workload cluster's `istio` ConfigMap should return to the `otelp` provider.

---

## 2. Sidecar stats-inclusion annotation — ALREADY REVERTED

| | |
|---|---|
| **Added / removed** | 2026-07-22, ISI-1815 (R1P1), same session |
| **Object** | one `hipster-shop` pod, `sidecar.istio.io/statsInclusionPrefixes: tracing` |

Used to expose `tracing.opentelemetry.spans_sent`, which Istio's default stats matcher
hides — that is how the CHECK 4 root cause was found (see
`engines/README-port-naming.md`). It is a per-pod parity deviation under plan §2, so it
was removed immediately after the diagnosis. **No action needed**; recorded here only
so the parity audit has a complete list.

---

## 3. `hipster-shop/loadgenerator` — pre-campaign leftover, **DO NOT DELETE MID-CAMPAIGN**

| | |
|---|---|
| **Found** | 2026-07-22, ISI-1815 (R1P1) teardown — it survived `kubectl delete -f apps/hipster-shop-otel-collector.yaml` |
| **Cluster** | workload cluster `observable-otelarrow`, namespace `hipster-shop` |
| **Object** | `Deployment/loadgenerator`, created `2026-07-21T15:59:35Z`, 10 VU → `frontend:80` |
| **Revert owner** | campaign end — **not** any phase teardown. Fires only when all 9 phase issues in the gate table at the top are terminal (`done`/`cancelled`). **Not** R2P2: the soaks run after Round 2 and read this loadgenerator as a constant. |

### What it is

Not ours. The hipster-shop overlay *deliberately deletes* the bundled loadgenerator, and
its own comment gives the reason: **"a second, uncontrolled load source would corrupt the
methodology."** `grep -c 'name: loadgenerator'` returns `0` on all three phase manifests,
and this object's `last-applied-configuration` carries none of the overlay's kustomize
labels. It was applied by hand before the campaign started.

### Why it must be left alone until every measurement phase is terminal

Because it is in no phase manifest, **teardown never removes it and redeploy never
recreates it** — so it is present, unchanged, for every run in the campaign: **six runs,
not nine** — R1P1, R1P2, R2P1, R2P2 and Soaks S1, S2, with the three OTel-Arrow phases
(R1P3, R2P3, S3) cancelled. **The soaks are in that six**, which is why deleting this at
R2P2 would break them. That makes it a constant,
and constants cancel in an engine-vs-engine comparison. Deleting it at a phase boundary is
the harmful move: R1P1 would have run with ~10 extra VU of hipster-shop load and every
later phase without, manufacturing exactly the asymmetry the overlay comment warns about.

Its pod (`loadgenerator-d9d8bf757-g7pxd`, created `2026-07-22T14:54:47Z`, 0 restarts) was
up before and throughout the entire R1P1 window, so R1P1 itself is internally consistent.

### The caveat to carry into the readout

Unlike otel-demo's `load-generator`, which is **sidecar-excluded** specifically so the load
driver is not itself measured, this one runs `2/2` **with** an Istio sidecar — its traffic
therefore emits mesh spans and access logs into the engine under test. **Absolute**
hipster-shop ingest volumes carry a constant offset because of it. Relative engine
comparison is unaffected.
