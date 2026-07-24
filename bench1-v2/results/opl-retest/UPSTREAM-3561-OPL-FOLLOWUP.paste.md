Follow-up on the OPL re-test I promised above.

**Result: OPL closes both gaps. I'm retracting the conditional-write and field-read part of the disclosure.** @lquerel was right — this was a KQL-surface limit, not an engine limit.

Same method as the rest of the report: real logs through the real `df_engine` binary (build `7502e7d`, `processor:transform` with `opl_query`), reading what actually comes off the wire via a debug exporter — not `--validate-and-exit`, which on this engine validates predicates it then cannot evaluate (the KQL item, #1634).

The two parity steps, rewritten from KQL to OPL:

```
logs
| if (contains(body, "error")) { set severity_text = "ERROR" } else { set severity_text = "CLEARED" }
| if (matches(body, r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9._-]+")) { set attributes["pii.email.detected"] = "true", body = concat("REDACTED:", encode(sha256(body), "hex")) }
```

I fed 100 logs through one engine — 50 with `database error for user alice@example.com` in the body, 50 with a clean body — and read the emitted records:

| observed off the wire | count |
|---|---|
| `severity_text = ERROR` (error body → if-branch) | 50 |
| `severity_text = CLEARED` (clean body → else-branch) | 50 |
| `pii.email.detected = true` (error body only) | 50 |
| body rewritten to `REDACTED:<sha256>` (error body only) | 50 |
| original e-mail surviving in output | 0 |
| clean body passed through untouched | 50 |
| engine panics / core deaths during the run | 0 |

The `ERROR`/`CLEARED` split is the whole point: the `if` predicate **read** `body` at runtime and drove two different writes. That is exactly what the KQL surface would not do — it validated the predicate and then wrote `severity_text` unconditionally. So both the conditional-severity gap and the "can't read a field to redact" gap were KQL-surface limits. Retracting that part of the disclosure.

One precise note on what did **not** translate 1:1, so it's on record and reproducible:

- OPL's function set at `7502e7d` has `contains`, `matches`, `starts_with`, `ends_with`, `substring`, `replace` (literal from→to), `regexp_capture`, `regexp_substr`, the hashing functions and `encode` — but **no `regexp_replace`**. So a substring mask like the Collector's `replace_pattern(body, <e-mail-regex>, "***REDACTED***")` isn't a single OPL verb. I redacted by hashing the whole matched field (`encode(sha256(body), "hex")`), which is what a whole-value hash processor would do anyway. That's a semantic difference, not an inability — the read-predicate + conditional redact that I'd reported as impossible works fine.
- Minor grammar snag worth a docs line: OPL string literals only allow the escapes `\" \\ \n \r \t \u`, so a regex with `\.` or `\d` inside an `r"…"` literal fails to parse. I used character classes (`[a-zA-Z0-9._%+-]+@[a-zA-Z0-9._-]+`) to stay inside the grammar.
- `severity_number` stays at the emitted value since the query only sets `severity_text`; `set severity_number = 17` aligns it in one line if wanted.

Happy to share the full manifest and queries if they're useful as a transform-processor docs example — reaching for KQL because it was the documented example is exactly the trap a "recommended surface = OPL" note would prevent.
