# 02 — Deploy the environment

> Previous: [01 — Provision the cluster](01-provision-cluster.md) · Next: [03 — Run the benchmark](03-run-benchmark.md)

One arm at a time. This page deploys the engine under test, both applications,
and the Istio configuration that feeds it — in the one order that produces a
comparable run.

```bash
set -a && . ./.env && set +a
ENGINE=otel-collector ./deploy/deploy-arm.sh
```

That script *is* the procedure. The rest of this page explains what it does and
why the order is load-bearing, so you can debug it when something is off.

---

## Dynatrace

### The ingest token

Every engine reads its OTLP ingest token from a Kubernetes Secret. Nothing in
this repo contains a credential; the only matches for a token in the tree are
`${DT_API_TOKEN}`, `__DT_API_TOKEN__` and `secretKeyRef`.

Create an **API token** in your Dynatrace environment with the
`openTelemetryTrace.ingest`, `logs.ingest` and `metrics.ingest` scopes, then:

```bash
kubectl create secret generic gateway-dynatrace \
  -n "${NS_ENGINE:-default}" --from-literal=apiToken='dt0c01.XXXX...'
```

### DynaKube

`deploy/dynatrace/dynakube.yaml` carries two placeholders. Substitute and apply:

```bash
sed -e "s|__CLUSTER_NAME__|${CLUSTER_NAME}|g" \
    -e "s|__DT_ENDPOINT_HOST__|${DT_ENDPOINT_HOST}|g" \
    deploy/dynatrace/dynakube.yaml | kubectl apply -f -
```

Its `namespaceSelector` excludes namespaces labelled `oneagent=false`, and step 4
below labels both app namespaces that way **on purpose**. Without it the
Dynatrace webhook injects an init container and two volumes into every app pod —
an uncontrolled variable in a benchmark that measures resource consumption.

The `k8s.cluster.name` that Dynatrace reports must equal your `CLUSTER_NAME`.
Every DQL query in `benchmark/` is scoped by it. If it does not match, the
queries return zero rows and the readout prints a clean, believable, entirely
empty result.

## Step 1 — the engine

```bash
sed -e "s|__CLUSTER_NAME__|$CLUSTER_NAME|g" -e "s|__DT_ENDPOINT_HOST__|$DT_ENDPOINT_HOST|g" \
    deploy/engines/${ENGINE}.yaml | kubectl apply -f -
```

## Step 2 — the applications

Both apps, both pointed at this arm's engine Service:

```bash
helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
  --version 0.40.10 -n otel-demo --create-namespace \
  -f deploy/apps/otel-demo-values-${ENGINE}.yaml --wait

kubectl apply -f deploy/apps/hipster-shop-${ENGINE}.yaml
```

`deploy/apps/hipster-shop-*.yaml` is a **fully resolved** Online Boutique
manifest — rendered by `deploy/render.sh` from the kustomize overlay in
`deploy/_templates/`, so a phase never fetches from the network mid-campaign.
The overlay deliberately deletes the bundled `loadgenerator`: a second,
uncontrolled load source would corrupt the methodology.

Two things in the app values are easy to lose and expensive to lose:

- **Delta temporality.** Dynatrace rejects cumulative Sum, cumulative Histogram
  and Summary. Without the temporality override the tenant 400s every cumulative
  point and the metrics arm reads empty.
- **`ENABLE_TRACING=1`** on the five Online Boutique services that emitted
  app-SDK spans in Round 1. Online Boutique gates its OTel SDK on this variable;
  without it the Go and Python services log `"Tracing disabled."` and export
  nothing, no matter where `COLLECTOR_SERVICE_ADDR` points. It is granted to
  exactly those five and not to the other five, because granting it more widely
  would *add* load that Round 1 never had and break comparability in the other
  direction.

## Step 3 — `appProtocol` on the app Services — mandatory, and easy to forget

```bash
./deploy/apps/appprotocol.sh          # --verify reports without patching
```

**This cannot be skipped and cannot be expressed in the Helm values.** The
otel-demo chart hardcodes `name: tcp-service` on nearly every component Service.
Istio cannot classify that, so those hops fall back to plain TCP and emit **no
mesh spans at all**.

Measured before this step existed: hipster-shop 688,747 mesh spans versus
otel-demo 6,820 in the same window — and the gate's aggregate span check was
*green on the sum*. An aggregate assertion cannot see one namespace die.

`helm upgrade` recreates those Services, so **step 3 must follow step 2 every
single time**, in every arm, or the arms are not comparable. It is idempotent.

## Step 4 — namespace labels

```bash
kubectl label ns otel-demo hipster-shop istio-injection=enabled --overwrite
kubectl label ns otel-demo hipster-shop oneagent=false --overwrite
```

`istio-injection=enabled` because the benchmark needs sidecars (see
[01](01-provision-cluster.md#istio-sidecar-mode)). `oneagent=false` is what the
DynaKube `namespaceSelector` excludes — see above.

## Step 5 — Istio

```bash
helm upgrade istiod istio/istiod -n istio-system -f deploy/istio/values-${ENGINE}.yaml --wait
kubectl rollout restart deploy/istiod -n istio-system     # NOT optional
kubectl apply -f deploy/istio/telemetry-${ENGINE}.yaml
```

`tracing` + `accessLogging` only. No metrics provider and no Prometheus scrape —
Istio/Envoy Prometheus metrics are out of scope for every arm.

Two traps:

- **`helm upgrade --wait` prints "successfully rolled out" without rolling
  istiod**, because `meshConfig` is a ConfigMap and no Deployment field changes.
  A control plane that never re-read its config looks perfectly healthy. Always
  restart it.
- **Only one `Telemetry` resource applies per scope**; extras are silently
  discarded. `tracing` and `accessLogging` stay merged in one CR — do not split
  the file.

## Step 6 — restart the apps

```bash
kubectl -n otel-demo    rollout restart deploy
kubectl -n hipster-shop rollout restart deploy
```

Required after steps 3–5: sidecars pick up the new mesh config and the new port
protocol classification only on restart.

> On a cluster with no spare CPU a mass restart can appear to deadlock.
> Single-replica Deployments default to `maxSurge=1, maxUnavailable=0`, so the
> new pod cannot schedule until the old one frees CPU, and the old one will not
> go until the new one is Ready. It resolves within a few minutes; if it does
> not, delete the old-generation pods rather than adding capacity — adding
> capacity mid-campaign changes the instrument.

## Changing the configuration

`deploy/_templates/` is the source of truth. Twelve per-arm artifacts are
rendered from four templates:

```bash
./deploy/render.sh            # regenerate all of them
./deploy/render.sh --check    # fail if a committed artifact has drifted
```

**Edit the template, never the rendered file.** A hand-edit to a rendered file
survives until the next `render.sh`, and then disappears — silently, mid-campaign.
Worse, `--check` reports that drift as *the rendered file* being wrong, so the
drift detector points at the correct file and blames it. Before re-rendering
mid-campaign, diff the output against git and read every deletion.

---

Next: [03 — Run the benchmark](03-run-benchmark.md)
