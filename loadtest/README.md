# Load harness — the 120-minute ramp

The timed run drives **otel-demo** *and* **hipster-shop** simultaneously with a
controlled, phased VU profile, so the telemetry volume the engine ingests is
aligned with the load rather than left to a free-running demo loadgen.

```bash
kubectl apply -f loadtest/ramp-jobs-${ENGINE}.yaml
```

## The profile

Four 30-minute rungs, both apps stepping at the same wall-clock time:

| minutes | VU per app | combined |
|---|---:|---:|
| 0 – 30 | 50 | 100 |
| 30 – 60 | 100 | 200 |
| 60 – 90 | 150 | 300 |
| 90 – 120 | 200 | 400 |

Each rung is a separate Kubernetes `Job` per app, so there are eight Jobs. A
rung is scheduled immediately but parks in a `wait` **initContainer** until its
turn, then runs `locust --headless` for exactly the remaining wall-clock time.

## Three details that are load-bearing

**A queued rung reports `Pending`, not `Running`.** The `sleep` is an
*initContainer*, and a sleeping initContainer leaves the pod `Pending`. A
sleeping *container* would show `Running`. Do not read `Pending` as "the ramp
never climbed" — that would look like a flat-VU comparability defect where there
is none. Check `initContainerStatuses[].state.running.startedAt`.

**`--exit-code-on-error 0` is required.** Without it Locust exits non-zero on a
single HTTP 5xx from the app and the Job pod is marked `Error`. It happened once
on an earlier revision of this ramp: 13 × `POST /cart/checkout` returning 500 out
of 78,258 requests marked the rung failed, on load that was otherwise perfectly
healthy. The benchmark measures the engine, not the demo app's error budget.

**`ttlSecondsAfterFinished` is deliberately unset**, along with
`backoffLimit: 0` and `restartPolicy: Never`. Completed ramp pods must persist
until teardown, because the run's **End** timestamp lives only on
`.state.terminated.finishedAt` and nothing captures it locally. A TTL inside the
gap between "load stops" and "you run `capture-window.sh`" would garbage-collect
the pods holding the deliverable.

## Files

| file | what |
|---|---|
| `ramp-jobs-otel-collector.yaml` | the eight ramp Jobs, labelled for the collector arm |
| `ramp-jobs-fluentbit-v5.yaml` | same, Fluent Bit arm |
| `ramp-jobs-otel-arrow-native.yaml` | same, OTel-Arrow arm |

The three files are **identical apart from the engine name** — verify it:

```bash
for e in otel-collector fluentbit-v5 otel-arrow-native; do
  sed "s/$e/@@E@@/g" loadtest/ramp-jobs-$e.yaml | md5sum
done   # three identical checksums
```

That is the point of rendering rather than hand-maintaining them: "the arms got
identical load" becomes something you can prove instead of something you assert.

## Teardown

`benchmark/teardown.sh` deletes these Jobs — but only after the register carries
a real End *and* an End census row. Do not delete them by hand; see
[docs/03](../docs/03-run-benchmark.md).
