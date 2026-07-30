1. Encoding a batch of ordinary OTLP telemetry should not panic.
2. If a pipeline core does panic, `pipeline_runtime_failed` should be recoverable —
   restart the core or start a new generation — rather than terminal.
3. An engine whose cores have all died should FAIL its health/readiness surface. Reporting
   `Running`/`Ready` while processing nothing is the failure mode that costs downstream
   users the most.

On (3) there may be an easy win: the admin server already has the data. `GET
/api/v1/metrics?format=json&keep_all_zeroes=true` returns the internal metric set **per
node per core**, so a dead core shows as its `receiver.otlp` / `processor.*` counters
going flat while sibling cores advance — no log grepping needed. This is not discoverable
from the admin UI, which looks like a static HTML page; we only found the endpoint by
reading the UI's own `metrics-api.js`. Documenting it would help, and surfacing the same
signal on a readiness endpoint would help more.
