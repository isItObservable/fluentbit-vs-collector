1. Build `otap-df` at 7502e7dbe636b6bd14d15e0a69367fa00bc10343 (submodules recursive,
   upstream Dockerfile unmodified):
   `cargo build --locked --release --target=x86_64-unknown-linux-gnu`
   with `RUSTFLAGS=-C target-cpu=x86-64-v2`; runtime `gcr.io/distroless/cc-debian13:nonroot`.
2. Run it with 4 pipeline cores and the config in the Configuration field — one shared
   chain for all three signals, so a metrics panic takes traces and logs with it.
3. Point sustained OTLP traffic at it. We used the `opentelemetry-demo` Helm chart
   0.40.10 (appVersion 2.2.0, ~20 services) with every service's
   `OTEL_EXPORTER_OTLP_ENDPOINT` set to the engine, plus a service mesh emitting
   access-log spans and a second demo application. Ordinary smoke-test volume was
   enough — we never reached our intended load level.
4. Watch the engine log for `panicked at` and watch the pod's readiness.

Deterministic: reproduced on two independent pods. Time-to-death **shortens** with
backlog, because upstream SDKs queue telemetry and retry it as a burst — run 1 survived
3m08s, run 2 survived ~48s. That rules out periodic restarts as a mitigation, since each
restart meets a larger backlog than the last.
