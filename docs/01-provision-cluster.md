# 01 — Provision the cluster

> Previous: [README](../README.md) · Next: [02 — Deploy the environment](02-deploy-environment.md)

This benchmark measures **resource consumption**. That makes the cluster part of
the instrument, not part of the background. A cluster that is too small, too
busy, or too heterogeneous does not make the benchmark fail — it makes the
benchmark *lie*, because a starved arm serves fewer requests, hands its engine
less data, and therefore burns less CPU. Which looks exactly like a win.

So this page is mostly about what the cluster must guarantee, and only
secondarily about how you build one.

---

## 1. What the cluster must provide

| | requirement | why this number |
|---|---|---|
| **Schedulable nodes** | **≥ 3** | The two apps, the Istio control plane and the engine must not share a node in a way that changes between arms. |
| **Allocatable CPU** | **≥ 10 cores** total | Round 1 ran on ~12 allocatable cores and had *no* spare capacity — a mass pod restart could not surge. Below ~10 the apps throttle and the arms stop being comparable. |
| **Allocatable memory** | **≥ 24 GiB** total | otel-demo alone is ~20 pods. |
| **Kubernetes** | **≥ 1.29** | Istio 1.29.2 and the `appProtocol` behaviour the gate depends on. |
| **Node shape** | **identical across nodes** | A 3-node cluster where one node is twice the size makes scheduling a hidden variable. |
| **Egress** | to your Dynatrace tenant over HTTPS | The engine exports directly; there is no gateway to proxy through. |

Round 1 of the published results ran on **3 workers × 4 vCPU / 12 GiB**,
Kubernetes v1.35.3, Istio 1.29.2. Anything comparable or larger works.

**Do not run this on a shared cluster.** See §5.

## 2. How you provision it is up to you

Nothing in this repo depends on a particular provisioner. Any of these produce a
qualifying cluster:

- **Managed** — GKE / EKS / AKS, one node pool, 3 identical nodes ≥ 4 vCPU.
- **Cluster API** — what the published runs used: a CAPI workload cluster with
  3 identically-shaped workers.
- **kubeadm / k3s / RKE2** on 3 identical VMs or hosts.
- **kind / minikube** — only for a smoke test of the manifests. A single-host
  cluster cannot produce comparable resource numbers, because every arm shares
  one kernel's CPU accounting with the load generators.

What matters is that **the cluster is identical for every arm**. Do not resize
it, do not add or drain a node, and do not upgrade it between phases. If you
must, the campaign restarts from arm 1.

## 3. Install the prerequisites

### Istio (sidecar mode)

The benchmark reads Istio mesh spans and access logs, so the apps must run with
**sidecars**, not ambient. If your istiod was installed with `profile: ambient`,
the namespaces must be explicitly opted into sidecar injection —
`deploy/istio/namespaces-sidecar.yaml` does that, and
`deploy/deploy-arm.sh` applies the labels.

```bash
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update
kubectl create namespace istio-system
helm install istio-base istio/base -n istio-system --version 1.29.2 --wait
helm install istiod     istio/istiod -n istio-system --version 1.29.2 --wait
```

`deploy/deploy-arm.sh` will `helm upgrade` istiod with the per-arm values. It
does **not** install it.

> If a GitOps or add-on controller manages istiod on your cluster, **pause its
> reconciliation for the whole campaign** and record that you did. The benchmark
> owns `meshConfig` for its duration; a controller that re-applies its own values
> strips the benchmark's tracing provider, and istiod then silently discards a
> `Telemetry` spec whose provider it cannot resolve — no error, no event, and
> `kubectl get telemetry` still lists the CR as applied. That is failure mode 4a
> in `benchmark/validate-phase.sh`. **Un-pause it at campaign end**; while it is
> paused istiod does not self-heal from drift.

### Dynatrace

Install the Dynatrace Operator and apply `deploy/dynatrace/dynakube.yaml` after
substituting the two placeholders — see [02](02-deploy-environment.md#dynatrace).
Kubernetes CPU and memory come from `dt.kubernetes.container.*`; without the
operator there is nothing to read.

### Helm repos

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
```

## 4. Check that it qualifies

```bash
cp .env.example .env && $EDITOR .env
set -a && . ./.env && set +a
./cluster/preflight.sh
```

`preflight.sh` exits non-zero on a blocker. It checks node count and allocatable
capacity, the Istio and Dynatrace prerequisites, the ingest Secret, leftovers
from a previous run — and it looks for **other telemetry pipelines already
running on the cluster**, which is the check people skip.

## 5. Contamination — the thing that actually bites

Round 1 of the published results ran with a **parallel collector pipeline** on
the same three nodes: two DaemonSets tailing every container log plus three
gateway Collectors, 9 pods, ~932 mCores — **5–8× the engine under test**.

It did not corrupt the record counts: every query filters on `benchmark.engine`,
which that pipeline never sets. It was present for both arms, so it is a
constant and the comparison holds. But it is a real CPU competitor on nodes with
no spare capacity, and it is a plausible mechanism for the ~3.5% throughput gap
between the two arms. It is disclosed in
[results/RESULTS.md](../results/RESULTS.md) for exactly that reason.

The rule that follows:

> **Inventory what else is running on the cluster before you attribute a
> difference to the thing you changed.** Either remove the other pipeline before
> the campaign starts, or record it in `results/RUN-REGISTER.md` and leave it
> completely alone until the campaign ends. What you must not do is remove it
> *between* arms — that manufactures a difference that is not the engine.

The same rule covers anything else generating load. If something is already
sending traffic to the apps — a leftover load generator, a synthetic monitor, a
health-checker — it is a constant only for as long as nobody touches it.
`benchmark/teardown.sh` is deliberately built around this: it never deletes a
namespace, and it refuses to run if a manifest it is about to delete *defines*
the protected object.

---

Next: [02 — Deploy the environment](02-deploy-environment.md)
