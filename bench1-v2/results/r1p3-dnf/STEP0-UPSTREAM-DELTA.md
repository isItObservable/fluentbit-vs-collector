# ISI-1849 step 0 — does a newer upstream commit change anything we depend on?

**Verdict: NO. Step 0 came up empty ⇒ no rebuild, arm is DNF (pre-authorised).**

Everything below was read on **2026-07-23, between 16:20Z and 16:35Z**. A search result and a
branch tip both decay; the SHAs and counts here are what those refs contained at that time.

## What was checked, and against what

| | ref | date |
|---|---|---|
| our build | `otel-arrow` main @ `7502e7dbe636b6bd14d15e0a69367fa00bc10343` | 2026-07-20 22:13:43Z |
| newest upstream | `otel-arrow` main @ `51b864b9de72c8f5a111c085c6cf617a523b201e` | 2026-07-23 15:08:39Z |

`git merge-base --is-ancestor 7502e7d origin/main` → true, so the range below is a real
fast-forward delta and not two divergent lines.

`git rev-list --count 7502e7d..origin/main` = **13 commits**.

```
51b864b9 2026-07-23 chore: Rename ctl title bar to say Otel-Arrow instead of OpenTelemetry Arrow (#3528)
7987c8b5 2026-07-22 feat(wasm-host): introduce experimental WASM host-kernel processor plugin (#3478)
47e33df9 2026-07-22 [azure_identity_auth] update azure sdk to bleeding edge for Arc identity support (#3549)
481f3e18 2026-07-22 chore(repo): Promote lalitb to Maintainer (#3550)
93e7bef5 2026-07-22 feat(engine): Add per-signal produced/consumed metrics for all nodes (#3437)
3c22c5bb 2026-07-22 chore(deps): update all patch versions (#3546)
e9d8f977 2026-07-22 fix(deps): update module google.golang.org/grpc to v1.82.1 [security] (#3545)
c79986e5 2026-07-22 Remove Rust OTel metrics SDK (#3523)
d25a5680 2026-07-21 chore: Fix flaky quiver WAL replay tests by disabling time-based segment finalization (#3533)
63cc7e5b 2026-07-21 feat(metrics): Use enum attributes for OTLP receiver and shared exporter outcomes (#3532)
6dd7894e 2026-07-21 feat(engine): add BearerTokenAuthorizer capability (#3494)
3b1e9ab6 2026-07-21 chore(deps): update all patch versions (#3536)
5b4e62a3 2026-07-21 feat(core-nodes): migrate debug_processor to new metric attributes (#3522)
```

## The three questions the board asked, answered

### 1. `crates/pdata/src/otap/transform/` — has anything changed?

**No.** `git log 7502e7d..origin/main -- rust/otap-dataflow/crates/pdata/src/otap/transform/`
returns **zero commits**. The only file that changed anywhere in the `pdata` crate across all
13 commits is `crates/pdata/README.md`.

`concatenate.rs` is **byte-identical** between the two commits (`git diff --stat` on the file:
empty). Line 150, the panic site from the retry, is still:

```rust
batcher.push_batch(converted).expect("Compatible schemas");
```

— an unconditional `.expect()` on `arrow::compute::BatchCoalescer::push_batch`, whose error
type includes `DictionaryKeyOverflowError`. That is not a schema failure, so the `.expect()`
message is also wrong about what it is asserting. Unchanged on the newest main.

`crates/pdata/src/encode/record/metrics.rs` (the `boo` site) is likewise untouched in the
range. It does not matter for us — we route metrics to `exporter:noop` and got 0 occurrences —
but it is recorded so the "nothing moved" claim is complete rather than selective.

### 2. Has the dictionary key type changed?

**No.** It could only have changed in the paths above, and no file in those paths changed.

### 3. Has `arrow-data` been bumped past 58.3.0?

**Yes — and it makes no difference.** This is the one thing in the range that touches us, so
it was followed to the end rather than stopped at the version number.

`rust/otap-dataflow/Cargo.toml` pins are **unchanged** — all seven `arrow-*` entries still read
`"58.3"`, which is a caret range. `Cargo.lock` moved (via `chore(deps): update all patch
versions` #3546):

| crate | our build | newest main |
|---|---|---|
| `arrow`, `arrow-array`, `arrow-buffer`, `arrow-cast`, `arrow-data`, `arrow-ipc`, `arrow-schema`, `arrow-select` | 58.3.0 | **58.4.0** |

So: does arrow-rs 58.4.0 change the overflow? Checked directly in `apache/arrow-rs`.
`git rev-list --count 58.3.0..58.4.0` = **7 commits**:

```
0ff81c12 [58_maintenance] Update changelog for #10371 (#10372)
95d72312 [58_maintenance] Add test for parquet-testing/bad_data/ARROW-GH-47662.parquet (#10371)
4544deaa Prepare for 58.4.0 release (#10367)
32e8c180 chore: Ignore py03 vulnerabilities until upgrade (#10370)
c12030f2 [58_maintenance] Backport cargo audit fixes (#10369)
01046eed [58_maintenance] [parquet] Allow more encryption algorithms (#10351)
adb77a16 [58_maintenance] Fix MSRV CI check (pin tonic to 0.14.5, install cargo-msrv --locked) (#10365)
```

Files changed across the whole release: `Cargo.toml`, `CHANGELOG*.md`,
`dev/release/update_change_log.sh`, two GitHub workflow files, `parquet/src/encryption/ciphers.rs`,
`parquet-testing`, and three parquet test files. **Nothing else.**

- `git log 58.3.0..58.4.0 -- arrow-data/src/transform/` → **zero commits**
- `git log 58.3.0..58.4.0 -- arrow-select/src/coalesce` → **zero commits**
- `git log 58.3.0..58.4.0 --grep=dictionary` → **zero commits**

58.4.0 is a parquet-encryption / CI maintenance release. `arrow-data/src/transform/mod.rs:680`
— the second panic site — is unchanged, and `BatchCoalescer` (in `arrow-select`) is unchanged.
The version number moved; not one line under either panic site did.

## Duplicate search, re-run 2026-07-23T16:28:04Z

Re-run because the previous one decays, and because the upstream report needs it fresh.

| query | scope | result |
|---|---|---|
| `DictionaryKeyOverflowError` | `open-telemetry/otel-arrow` | 1 hit — **our own issue #3561**, no other |
| `"Compatible schemas"` | `open-telemetry/otel-arrow` | 1 hit, unrelated (#863, closed) |
| `is:pr is:open concatenate` | `open-telemetry/otel-arrow` | **0** |
| `DictionaryKeyOverflow` | `apache/arrow-rs` | **0** |

Related but not duplicates:

- **#3561** — filed by Henrik **2026-07-23T16:17:29Z**, open, labelled `bug` /
  `triage:deciding`, 0 comments. This is our report. It still carries the pre-retry text,
  including the now-falsified "ran 41 minutes with zero panics" line ⇒ the correction in
  `../r1p3-abort/UPSTREAM-3561-FOLLOWUP.md` is still owed and is now the only outstanding
  upstream action.
- **#2984** "fix: stop metrics otap encode panic" — still **open and draft**, last updated
  2026-07-22. Addresses the `boo` site only, is not merged into main, and is therefore not in
  the 13-commit range. Irrelevant to us regardless: we already removed that site by routing.
- **#3181** "pdata: handle nanosecond duration/timestamp cardinality in concatenate" — merged
  **2026-06-08**, so already in our build. Worth noting as precedent: `concatenate.rs` has had
  a cardinality-driven panic fixed before, in `estimate_cardinality`. Ours is a different
  cardinality panic in the same file, one function later.

## Conclusion

Every path the failure runs through — `concatenate.rs:150`, `arrow-data/src/transform/mod.rs:680`,
`BatchCoalescer`, the dictionary key type — is **bit-identical or behaviourally unchanged** on
the newest upstream main as of 2026-07-23 15:08Z. There is no reported upstream bug for the
overflow other than the one we filed 11 minutes before this check, and no open PR touching the
file.

A rebuild would produce a different image ID and the same binary behaviour on the code that
kills us. **Step 0 is empty ⇒ go straight to DNF**, per the board's step-2 authorisation.

## Reproducing this check

```bash
git clone --filter=blob:none --no-checkout https://github.com/open-telemetry/otel-arrow.git
cd otel-arrow
git log --oneline 7502e7dbe636b6bd14d15e0a69367fa00bc10343..origin/main
git log --oneline 7502e7d..origin/main -- rust/otap-dataflow/crates/pdata/src/otap/transform/
git diff 7502e7d origin/main -- rust/otap-dataflow/crates/pdata/src/otap/transform/concatenate.rs
for c in 7502e7d origin/main; do git show $c:rust/otap-dataflow/Cargo.lock \
  | grep -A1 '^name = "arrow-data"'; done

git clone --filter=blob:none --no-checkout https://github.com/apache/arrow-rs.git
cd arrow-rs
git log --oneline 58.3.0..58.4.0
git log --oneline 58.3.0..58.4.0 -- arrow-data/src/transform/ arrow-select/src/coalesce
```
