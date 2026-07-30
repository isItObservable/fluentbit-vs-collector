- Deployment: Kubernetes, 4-core pod, `gcr.io/distroless/cc-debian13:nonroot`
- Build: `cargo build --locked --release --target=x86_64-unknown-linux-gnu`,
  `RUSTFLAGS=-C target-cpu=x86-64-v2`
- `arrow-data` 58.3.0
- Load: `opentelemetry-demo` chart 0.40.10 (appVersion 2.2.0), ~20 services, traces +
  logs + metrics into one pipeline, plus mesh access-log spans and a second application
- Backend: an OTLP/HTTP endpoint that returns 400 on cumulative Sum/Histogram/Summary
  (relevant only as corroboration that the metrics payload was independently judged
  malformed at the same moment the encoder panicked)
