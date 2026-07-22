# Out-of-repo cluster state owned by this campaign — MUST be reverted at campaign end

This file tracks mutations made to clusters *outside* this repo for the duration of
the ISI-1779 B1-v2 benchmark campaign. Each one leaves a cluster in a non-default
state that no `kubectl delete -f` in this repo will undo. **Revert every row below
after the last phase (R2P3) completes**, before closing ISI-1779.

Tracked as a campaign-end issue so it cannot be lost with an individual phase issue.

---

## 1. CAAPH reconciliation paused on `istiod` for `observable-otelarrow`

| | |
|---|---|
| **Added** | 2026-07-22, ISI-1815 (R1P1) |
| **Cluster** | management cluster `capmox-mgmt-prod` (NOT the workload cluster) |
| **Object** | `HelmReleaseProxy/istiod-observable-otelarrow-x57wm` |
| **Revert owner** | last phase of the campaign (R2P3) |

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
