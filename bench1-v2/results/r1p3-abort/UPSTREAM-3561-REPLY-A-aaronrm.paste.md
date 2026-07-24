@AaronRM Thanks — the umbrella-tracker + child-issue split makes sense, and splitting the panic sites from the health-surface question is exactly the right cut. Happy to help verify each child against the real workload as they land.

On the readiness question: **you're right, and this one is on our deployment, not the engine.** I went back and checked what we actually ran.

The `df_engine` container in the failing runs had **no `readinessProbe`, no `livenessProbe`, and no `startupProbe` at all** — just the container with its args and the admin port. With no readiness probe, Kubernetes marks the container `Ready` as soon as it starts and never re-evaluates, which is the entire reason the pod showed `Ready` while every core was dead. That's a default-mismatch on our side, not the engine reporting healthy.

I also confirmed your point in the source at the commit we built (`7502e7d`): `crates/admin/src/health.rs` registers `/api/v1/readyz`, and it returns `503 SERVICE_UNAVAILABLE` whenever any pipeline's `Ready` condition is not `True` (and separately on hard memory pressure), `200` otherwise. `/api/v1/livez` is there too and returns `500` on a failing `Accepted` condition. So the engine already exposes exactly the signal we said was missing — we just never wired a probe to it.

Worth connecting to the one engine-side observation in my follow-up: the `metric_sets` count collapsing 289 → 1 and your `readyz` going `503` are two reads of the **same** observed-state store. So that wasn't a competing detection mechanism — it was the hard way to see what `/api/v1/readyz` reports directly. `readyz` is the right signal; my heuristic was just me not having found the probe endpoint yet.

The fix on our side, which we'll adopt:

```yaml
readinessProbe:
  httpGet: { path: /api/v1/readyz, port: 8080 }
  periodSeconds: 10
livenessProbe:
  httpGet: { path: /api/v1/livez, port: 8080 }
  periodSeconds: 10
  failureThreshold: 3
```

Two things I'd still flag as genuinely engine-side, so the concession doesn't bury them:

1. **The panics themselves are unaffected by any of this** — `readyz` going `503` correctly marks the pod `NotReady`, but the four cores are still dead and the engine still does not restart them. Wiring `livez` as a liveness probe would get Kubernetes to restart the *pod*, which is a blunt recovery at best; in-process core recovery (or a documented "this is terminal, rely on liveness" stance) is the real question, and I think that belongs in one of the child issues.
2. **The default matters for first-run users.** We're clearly not the only ones who will deploy this without knowing `readyz` exists — the admin endpoints aren't discoverable from the UI (it looks like a static page; we found the metrics route by reading its `metrics-api.js`). A one-line note in the deployment docs, or a probe stanza in any example manifest, would have saved this entire back-and-forth.

I'll get the exact probe stanza we're switching to into the report thread for the record. And to close the loop on #1634 — noted, thank you; I'll follow that one for the KQL validate-but-can't-evaluate-at-runtime item and keep it out of the panic children.
