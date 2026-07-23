# 04 — Read the results

> Previous: [03 — Run the benchmark](03-run-benchmark.md) · Results: [results/RESULTS.md](../results/RESULTS.md)

You have a window. Turning it into a number you can defend takes four steps, and
three of them are about *not* quoting the wrong number.

```bash
set -a && . ./.env && set +a
./benchmark/readout.sh   R1-P1-collector 2026-07-22T15:58:43Z 2026-07-22T17:59:21Z
./benchmark/normalise.sh R1-P1-collector <A-start> <A-end> \
                         R1-P2-fluentbit <B-start> <B-end>
```

---

## 1. `readout.sh` — one pinned readout for every arm

It takes an **explicit start and end**, never a relative window, and it runs the
census **first**: if the census fails it exits non-zero *without printing
numbers*. D12 voids a run, it does not caveat one.

```bash
./benchmark/readout.sh --selftest     # replays a banked window; must reproduce it exactly
```

The selftest exists so that a change to the read side is provably
non-retroactive. It replays a recorded window and must reproduce 122/122 census
buckets, 190.7 mCores, 108.2 MiB and 18,499,537 spans that split into
9,340,725 + 9,158,812 — a split that conserves.

Notes that will save you an hour:

- **Pin the bucket interval.** Dynatrace picks bucket size from window *length*,
  so a 120.6-minute arm and a 120.0-minute arm otherwise yield non-comparable
  coverage percentages.
- **`interval:` is a `timeseries` parameter and a syntax error on `fetch`.** The
  DQL helper sends errors to `/dev/null`, so a broken query prints as an *empty
  section*, not as a failure. Keep two timeframe strings.
- **Absolute-window DQL takes a quoted string**, not a `timestamp()` call.
- **~2 trailing null buckets are normal ingest lag** on a window ending near
  `now`.

## 2. `normalise.sh` — because the arms did not serve the same request volume

The fairness rules give every arm an identical load *configuration*. They cannot
give it identical achieved *throughput*, and on Round 1 they did not: over equal
windows the second arm served ~3.5% fewer records.

An engine handed less data will use less CPU for that reason alone. Absolute
resource figures therefore credit an engine for work it was never asked to do.
`normalise.sh` divides by records delivered and prints **mCores per 1M records**
and **MiB per 1M records**.

> **Read both resources.** The first version of this script normalised CPU only.
> A comparison tool silently defines what gets compared — and because memory was
> not in the script, nobody noticed that memory moved the *other way*. The honest
> Round 1 headline is **"~36% less CPU per record, at ~20% more memory"**, not
> the −38.6% absolute CPU figure, and not the CPU column alone.

`istio-mesh` spans are emitted per request *hop*, so they track requests actually
served — that is the row that tells you whether the arms were handed the same
work. Do not try to *explain* a throughput gap with the engine: less CPU would
predict *more* throughput, so the obvious explanation runs backwards. State it,
normalise for it, and let the readout stand.

## 3. The three ways a number here lies to you

### Never compare across non-equivalent elapsed windows

Two published comparisons in this campaign were wrong because a 15-minute slice
of one arm was compared with a 20-minute slice of the other, taken at *different
rungs of the ramp*. Measured over the identical first 89 minutes both logs and
spans were down 8.8%, not up.

And the *symmetry* is the signal: both signals down by the same 8.8% argues
against a per-signal engine problem and points upstream at app output. A real
per-signal loss moves one and not the other.

Interim slices of a ramped run are not small versions of the result. They are a
different result.

### A self-filtered coverage ratio is a tautology

`readout.sh` originally computed span coverage as
`tagged / spans-where(k8s.cluster.name == X)` — but `k8s.cluster.name` is stamped
**by the engine under test**, so the complement is structurally zero and the
ratio can only ever print 100%. A perfect score that no failure could dent.

Two different ratios get confused here, so the script prints both, labelled:

- **arm coverage** — tagged records vs all records from *this cluster*. Comparable.
- **tenant share** — this cluster's records vs everything on the tenant. **Never
  comparable across arms**: it moves when unrelated clusters get busier.

### Verify a query by executing it, not by reading it

A one-line comment placed after a filter commented out the rest of that line —
`//` in DQL runs to end of line — which silently degraded one tile and turned
another into a parse error. It passed review because the check *string-matched*
the query instead of running it.

## 4. The Dynatrace dashboard

`results/resource-comparison.dashboard.json` is the comparison surface. Import it
into your environment, substitute `${CLUSTER_NAME}` in the tile queries, and read
a run by pasting its register Start/End into the timeframe picker. Every tile is
timeframe-driven; no tile carries its own `from:`.

Read the **pod census tile first** — it is a validity gate, not a detail tile.
The rest of its documented caveats are in [results/DASHBOARD.md](../results/DASHBOARD.md).

One that generalises beyond this repo: **Prometheus counters land in Grail as
delta, not cumulative**, and workload names collide across clusters on one
tenant — which is why every tile is scoped by `k8s.cluster.name`.

## 5. Write it down

Add the readout to `results/RUN-REGISTER.md` and, if it changes a published
figure, to `results/RESULTS.md`.

> **A correction is not finished until every copy of the wrong number is found.**
> One wrong comparison in this campaign lived in three places at once — a
> comment, the register and the runbook — and fixing two of them left the third
> to be read as current.
>
> And **a caveat is not a fix**: a warning posted next to a broken instrument
> leaves the wrong number on the instrument, which is what gets read.

---

Back to: [README](../README.md) · [results/RESULTS.md](../results/RESULTS.md)
