# ISI-1859 — OPL transform re-test: both parity gaps are KQL-surface limits, not engine limits

**Date:** 2026-07-24 · **Cluster:** `observable-agentsandbox` (scratch, not the measured cluster)
**Image:** `ghcr.io/isitobservable/df_engine:0.50.0` — the unchanged R1P3/ISI-1843 image
**Build SHA:** `7502e7dbe636b6bd14d15e0a69367fa00bc10343` (otap-df v0.50.0)
**Rig:** `engines/opl-proof/probe.yaml` · **Gate:** `engines/opl-proof/verify.sh` (9/9 PASS)
**Evidence:** `results/opl-retest/sink-evidence.log` (1274 lines, the actual emitted records)

## Verdict

> **OPL closes both disclosed parity gaps at runtime.** The conditional-severity
> gap (P-SEV, step 2) and the conditional field-read + redact gap (P-PII, step 3)
> were **KQL-surface limits, not `df_engine` capability limits.** @lquerel's
> guidance on otel-arrow#3561 — "use OPL, not KQL; KQL is Microsoft-compat only" —
> is correct, and the transform part of our disclosure is retracted.

## Step 0 — OPL shipped in our build (verified at SHA, not assumed)

The transform processor at `7502e7d` accepts `opl_query` alongside `kql_query`:
`crates/core-nodes/src/processors/transform_processor/mod.rs` deserializes a
`Query` enum with `KqlQuery` / `OplQuery` / `Ottl` arms and dispatches to
`OplParser::parse_with_options` (line ~151). The OPL grammar
(`crates/query-engine-languages/src/opl/opl.pest`, saved here as
`opl-grammar-7502e7d.pest`) and the OPL user guide
(`query-engine-languages/docs/opl-user-guide/`) both exist at that SHA. Six
`transform-opl-*.yaml` validation pipelines ship at that SHA, including
`transform-opl-conditional-set-processor.yaml` whose query
`logs | if (severity_text == "ERROR") { set attributes["is_error"] = "true" } else { ... }`
is itself a read-predicate. No rebuild was needed (ISI-1841 one-rebuild policy
not spent).

The engine confirmed this on startup: the R1P3 image loaded the OPL config across
all four cores with no parse error and no panic (a bad query crashes the pod on
boot). `urn:otel:processor:transform` is in the printed URN registry.

## The runtime proof (the validator is worthless on this engine)

`--validate-and-exit` is zero evidence here (ISI-1817/1843: it accepts
`filter {__bogus__:1}`, a router with no `outputs:`, and the KQL predicates it
then cannot evaluate). So every claim is read off the wire via a debug exporter.

**OPL under test** (`processor:transform`, logs branch):

```
logs
| if (contains(body, "error")) { set severity_text = "ERROR" } else { set severity_text = "CLEARED" }
| if (matches(body, r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9._-]+")) { set attributes["pii.email.detected"] = "true", body = concat("REDACTED:", encode(sha256(body), "hex")) }
```

**Input:** 100 logs — 50 with body `database error for user alice@example.com`
(service `opl-err`), 50 with body `request completed successfully` (service
`opl-ok`). The clean stream is the built-in control: it exercises the else-branch
and the unmatched PII predicate, so a PASS on the error stream cannot be an
unconditional write in disguise.

**Emitted off the wire:**

| Observed | Count | Proves |
|---|---:|---|
| total records delivered | 100 | conservation — nothing dropped |
| `severity_text = ERROR` (error body → if-branch) | 50 | conditional write fired on match |
| `severity_text = CLEARED` (clean body → else-branch) | 50 | **the engine READ `body` and branched** |
| `pii.email.detected = true` (error body only) | 50 | regex `matches(body,…)` read-predicate fired |
| body rewritten to `REDACTED:<sha256>` (error body only) | 50 | conditional field redact |
| original e-mail surviving in output | 0 | redaction actually removed it |
| clean body passed through untouched | 50 | control — predicate false ⇒ no change |
| CLEARED records carrying pii/redact | 0 | writes are conditional, not unconditional |
| engine panics / core deaths during run | 0 | transform path is stable |

The **ERROR vs CLEARED split** is the crux. KQL validated the identical
predicate and then wrote `severity_text` unconditionally (it could not read a
field at runtime — upstream #1634). OPL produced two different values from one
`if/else` driven by a read of `body`. That single fact retires both P-SEV and
P-PII as engine gaps.

## Precise note on what did NOT translate 1:1 (reproducible)

OPL's function library at `7502e7d` (from `docs/opl-user-guide/src/functions.md`):
`contains`, `matches`, `starts_with`, `ends_with`, `lower_case`, `upper_case`,
`concat`, `concat_ws`/`join`, `substring`, `replace` (**literal** from→to),
`ltrim`, `rtrim`, `regexp_capture`, `regexp_substr`, hashing (`sha256`, `sha512`,
`md5`, `fnv`, `murmur3`, `xxh3`, `xxh128`), `encode`, math, `format_datetime`,
`uuid`/`uuidv7`, `coalesce`.

There is **no `regexp_replace`** verb. The Collector's step-3 semantic —
`replace_pattern(body, <e-mail-regex>, "***REDACTED***")`, masking only the
matched substring in place — is therefore not a single OPL operation. This proof
redacted by hashing the whole matched field (`encode(sha256(body),"hex")`), which
is exactly what the **Fluent Bit** arm already does (whole-value SHA-256). So
step 3's redaction remains a three-way engine semantic difference (substring mask
vs whole-value hash vs whole-value hash), **not** an arrow-side inability. The
capability the disclosure called impossible — read a field, form a condition,
conditionally redact — is fully implementable.

`severity_number` stays at the emitted value (`Info(9)` here) because the query
only sets `severity_text`; `set severity_number = 17` would align it in one line.
The SNUM disclosure is thus also closable, though it was never a benchmark axis.

## Grammar note (why the regex uses character classes, not `\.`)

OPL string literals only permit the escapes `\" \\ \n \r \t \u` (see the pest
grammar). A regex `\.`/`\d` inside an `r"…"` string fails to parse. The e-mail
pattern is written with character classes (`[a-zA-Z0-9._%+-]+@[a-zA-Z0-9._-]+`)
to stay within the grammar. This is a language-surface constraint worth a docs
mention but did not block the proof.

## Consequences

- **PARITY-REGISTER.md** P-SEV and P-PII corrected: the arrow arm *can* do the
  conditional write and the conditional read; both are retracted as engine gaps.
  (Moot for the readout — the arm is DNF, ISI-1849 — but the register is a public
  correctness record and #3561 links to it.)
- **otel-arrow#3561** follow-up drafted paste-ready and header-free at
  `results/opl-retest/UPSTREAM-3561-OPL-FOLLOWUP.paste.md`, delivering exactly
  what the 2026-07-24T07:48Z comment promised. Henrik posts (runner PAT 403s on
  write).
- Upstream #1634 (KQL validate-but-can't-evaluate) stands unchanged and correct.
