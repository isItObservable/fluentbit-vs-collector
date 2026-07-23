# Out-of-repo cluster state owned by this campaign — MUST be reverted at campaign end

This file tracks mutations made to clusters *outside* this repo for the duration of
the ISI-1779 B1-v2 benchmark campaign. Each one leaves a cluster in a non-default
state that no `kubectl delete -f` in this repo will undo. **Revert every row below
after the last phase completes**, before closing ISI-1779.

Tracked as **ISI-1826** (backlog, do-not-self-start) so it cannot be lost with an
individual phase issue.

> ⚠️ **R2P3 is cancelled and can no longer own a revert.** Updated 2026-07-23 under
> ISI-1820. The OTel-Arrow arm is DNF (ISI-1849) and all three of its phases are
> cancelled — R1P3/ISI-1817, R2P3/ISI-1820 and soak S3/ISI-1824. Every "R2P3" that
> appeared in this file as a *revert owner* has been repointed, because a cancelled
> phase tears nothing down: leaving the owner as R2P3 would have orphaned the CAAPH
> un-pause and the leftover-loadgenerator cleanup with no phase left to run them.
>
> 🛑 **The repoint to "R2P2 (last)" is NOT yet safe to act on — the soaks are missing
> from this file's model of the campaign.** Rampup order is
> `R1P1 → R1P2 → R2P1 → R2P2`, but **Soak S1 (ISI-1811) and Soak S2 (ISI-1823) are
> still scheduled and unchanged** (only S3 was cancelled), and *nothing in this repo
> records where the two 24h soaks sit relative to Round 2*. If R2P2 is genuinely last
> the repoint is correct; if either soak runs after it, then firing these reverts at
> R2P2 would:
>
> - resume CAAPH reconciliation of `istiod` **during a 24h measurement window**, and
> - delete the standing `hipster-shop/loadgenerator` (10 VU, §3) **before** the soaks,
>   so the soaks would run against a different load baseline than every rampup arm they
>   are read against — the exact asymmetry §3 exists to prevent.
>
> **Operational rule until the order is pinned: do not execute any revert in this file
> while any soak issue (ISI-1811, ISI-1823) is not yet `done`.** Ordering decision is
> tracked separately — see the campaign issue ISI-1779. Raised 2026-07-23 under ISI-1824.
>
> ⭐ Root cause of this gap: "last phase" is a **relative** pointer. The ISI-1820 repoint
> corrected *which id* it named without re-checking whether the referent was still the
> true end of the campaign. Cancelling a phase invalidates relative owners twice over.

---

## 1. CAAPH reconciliation paused on `istiod` for `observable-otelarrow`

| | |
|---|---|
| **Added** | 2026-07-22, ISI-1815 (R1P1) |
| **Cluster** | management cluster `capmox-mgmt-prod` (NOT the workload cluster) |
| **Object** | `HelmReleaseProxy/istiod-observable-otelarrow-x57wm` |
| **Revert owner** | last run of the campaign — **provisionally R2P2 (ISI-1819)** since ISI-1820 cancelled R2P3, **but not before Soak S1 (ISI-1811) and Soak S2 (ISI-1823) are `done`** — see the 🛑 note at the top |

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
| **Revert owner** | campaign end — **provisionally R2P2 (ISI-1819)** since ISI-1820 cancelled R2P3 — **not** any phase teardown, and **not before Soak S1 (ISI-1811) / Soak S2 (ISI-1823) are `done`** — see the 🛑 note at the top |

### What it is

Not ours. The hipster-shop overlay *deliberately deletes* the bundled loadgenerator, and
its own comment gives the reason: **"a second, uncontrolled load source would corrupt the
methodology."** `grep -c 'name: loadgenerator'` returns `0` on all three phase manifests,
and this object's `last-applied-configuration` carries none of the overlay's kustomize
labels. It was applied by hand before the campaign started.

### Why it must be left alone until the campaign's last phase (R2P2)

Because it is in no phase manifest, **teardown never removes it and redeploy never
recreates it** — so it is present, unchanged, for every run in the campaign (four, not
six: the two OTel-Arrow phases are cancelled). That makes it a constant,
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
