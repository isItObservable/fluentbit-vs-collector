# ISI-1843 — runtime proof of the corrected df_engine 0.50.0 pipeline

**Date:** 2026-07-23 · **Cluster:** `observable-agentsandbox` — *not* the measured cluster
**Image:** `ghcr.io/isitobservable/df_engine:0.50.0` (the R1P3 image, unchanged)
**Config under test:** `engines/df-engine-config.tmpl.yaml` after the ISI-1843 corrections
**Manifest:** `probe.yaml` · **Assertions:** `verify.sh` · run with `--deploy` for a clean run

## Why a runtime proof and not `--validate-and-exit`

A green validate is **zero evidence** for this engine. Four independent demonstrations:

| # | Evidence |
|---|----------|
| 1 | `processor:filter` accepts `config: {__bogus__: 1}` and the binary prints *"Configuration is valid"* (ISI-1817) |
| 2 | The KQL transform validates clean and then cannot **read** a field at runtime (ISI-1817) |
| 3 | The attributes processor's own docs: *"Unsupported action variants are accepted for forward compatibility and ignored"* — so a green validate on `action: delete` is equally consistent with delete doing **nothing** |
| 4 | **New here:** `processor:type_router` with `config: {}` and **no `outputs:` declared at all** validates clean. Nothing would be routed, and the validator is happy |

So every node is proven against emitted bytes and the engine's own counters.

## Correction to a standing campaign note

Earlier work recorded *"df_engine's admin port serves HTML, so there are no engine-side
counters to read"* (ISI-1817). **That is wrong.** The HTML is a UI that polls
`GET /api/v1/metrics?format=json&reset=false&keep_all_zeroes=true` on the same admin port,
which returns the full internal metric set — per node, per core, including
`processor.signal_type_router`, `processor.attributes` and `processor.transform`.

This matters well beyond this issue: it means the arrow arm **does** have engine-side
counters for the run-day gate, so its liveness check no longer has to be purely sink-side.

## Design decisions proven

### The router receives metrics and *routes* them — it does not merely lack them

This is the whole point of board decision Q2. "Metrics tiles are empty" must be a
**countable route**, not an inferred absence:

```
processor.signal_type_router / node.id=router
  signals.received.logs        1     signals.routed.named.logs        1
  signals.received.metrics     1     signals.routed.named.metrics     1
  signals.received.traces     50     signals.routed.named.traces     50
  signals.routed.default.*     0     signals.dropped.*                0
  signals.nacked.*             0     signals.rejected.route.*         0
```

`signals.routed.default.* == 0` matters on its own: it proves all three named ports are
genuinely wired. The router falls back to a node's default output when a named port is
*not connected at all*, so a typo in `outputs:` would still "work" — quietly, down the
wrong path — and only this counter distinguishes the two.

**Sink side: zero metric datapoints reached the exporter.** Combined with
`received.metrics > 0`, the metrics drop is deliberate, located at a named node, and
countable on run day.

### Parity step 4 is implemented — `action: delete` is NOT an ignored variant

`processor.attributes.deleted.entries = 150` — exactly one deletion per delivered record
(100 spans + 50 log records). `upserted.entries = 450` = 150 records × 3 upserts.

**This closes the question the brief flagged as a possible capability gap.** df_engine
0.50.0 really does delete `log.file.path`; there is nothing to hand ISI-1845 as a
*missing* capability for step 4. The deletion is also visible negatively at the sink
(`log.file.path` appears **0** times in emitted output) and, critically, positively in
the control (below).

Step 4 is applied to **both** the logs and the traces branch. The ISI-1843 brief said
"the logs branch", but both frozen arms delete on both signals — the Collector runs
`delete_key(attributes, "log.file.path")` in `log_statements` *and* `trace_statements`,
and Fluent Bit runs `content_modifier action: delete` in both its `logs:` and `traces:`
lists. Applying it to logs only would have **left** a parity gap while appearing to close
one.

### The control — why the two negative assertions are not tautologies

"No metrics at the sink" and "no `log.file.path` at the sink" are both satisfied by a
**dead engine**, and by a generator that never sent either thing. So the identical
`telemetrygen` invocation is also pointed straight at a second sink with the engine
bypassed:

| | via engine | control (engine bypassed) |
|---|---|---|
| spans | delivered | delivered |
| log records | delivered | delivered |
| **metric datapoints** | **0** | **50** |
| **`log.file.path` occurrences** | **0** | **200** |
| `probe.marker` occurrences | on every record | on every record |

Same generator, same flags, same sink image. The only variable is the engine. `probe.marker`
surviving is the second guard: an attribute processor that deleted *everything* would also
pass a naive "`log.file.path` is gone" check.

⚠️ **The first run of this probe pointed the control at the *same* sink.** Both streams
landed in one log, the control's 50 datapoints and 200 `log.file.path` records were counted
as if the engine had emitted them, and three correct PASSes were reported as FAILs. Two
streams, two sinks — a negative assertion is only meaningful over a stream containing
nothing but the output under test.

## Full assertion set

| ID | Assertion | Source |
|----|-----------|--------|
| 0  | probe config == shipping template (modulo endpoint + dummy token) | `yaml` diff in `verify.sh` |
| P1 | traces branch delivers | sink |
| P2 | logs branch delivers | sink |
| P3 | zero metric datapoints on the wire | sink |
| P3a| router **received** metrics | engine counters |
| P3b| router **routed** metrics out the named port | engine counters |
| P4 | `benchmark.engine` / `k8s.cluster.name` / `benchmark.run` on 100% of delivered records | sink |
| P4a| `upserted.entries > 0` | engine counters |
| P5 | `log.file.path` absent from every emitted record | sink |
| P5a| `deleted.entries > 0` | engine counters |
| P6 | `severity_text = ERROR` on 100% of log records | sink |
| P6a| transform ran | engine counters |
| P7 | no `panic` / `observed_error` in the engine log | engine log |
| C1 | control **does** show metrics → P3 is falsifiable | control sink |
| C2 | control **does** show `log.file.path` → P5 is falsifiable | control sink |

## Carried forward unchanged from ISI-1817

`severity_number` still disagrees with `severity_text`: the KQL write sets
`SeverityText: ERROR` and leaves `SeverityNumber: Info(9)`. Not a benchmark-integrity
problem (severity is not a measured quantity, and the write itself *is* the timed parity
work) but a read-time note for the dashboard and the disclosure register.

## Consequence the readout must absorb

`results/attr-landing.sh` step 7b previously predicted `metrics=SAFE` for this arm, from
the ISI-1817 probe of the **old single-chain** config in which metrics still reached the
exporter. The corrected config routes metrics to `exporter:noop`, so the prediction is now
**`metrics=NO-DATA`** (updated in this commit).

Leaving it at `SAFE` would have made step 7b report an anomaly against a healthy,
correctly-configured engine on run day — the exact false-FAIL failure mode that file
exists to prevent. Note that this arm's `NO-DATA` means *"deliberately not shipped"*,
which is a different fact from Fluent Bit's `NO-DATA` (*"lost in a broken processor
chain"*). Both are recorded as `NO-DATA` because both mean the tiles are empty, and
neither may ever read as `SAFE`.
