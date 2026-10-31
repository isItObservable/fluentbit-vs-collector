# KubeCon 2026 — talk-ready summary

## The one-slide takeaway

> **We re-ran the telemetry-pipeline benchmark on today's releases. The two failure modes that
> defined the last run are gone. All four modern pipelines survived a 12h production-realistic
> soak with loss under 0.01 % and flat memory.**

| Arm | Engine | Drop | Crashes/SIGSEGV | Memory | Soak |
|-----|--------|------|-----------------|--------|------|
| A | Fluent Bit 5.1.5 | 0.004 % | 0 / 0 | 38 MiB flat | ✅ 12h PASS |
| B | OTel Collector contrib 0.163.1 | 0 % | 0 / 0 | flat (queue=0) | ✅ 12h PASS |
| C | df_engine 0.61.0 (OTLP) | <0.01 % | 0 / 0 | flat | ✅ 12h PASS |
| D | df_engine 0.61.0 (OTAP) | 0.00 % | 0 / 0 | 28.2 MiB flat | ✅ 12h PASS |

## The arc of the talk

1. **Why re-run?** OTel-Arrow shipped a whole new engine (Rust `otap-dataflow`), and the last run
   showed "strange things" — crashes and suspected silent loss. You can't put a two-year-old
   benchmark on a KubeCon slide.
2. **How we kept it honest** — serial single-engine (one engine in the cluster at a time, full
   uncontended environment), same apps (otel-demo + hipster-shop), same 50 VU steady soak, newest
   stable pins frozen on one day, and measurement purity: no backend agent wraps the engine under
   test.
3. **The "strange things" guard** — the part worth stealing (below).
4. **Results** — the matrix. Everyone passes the stability bar. That *is* the story: modern
   pipelines are boring now, in the good way.
5. **Reproduce it yourself** — one command per arm from this repo, gate scripts included. (demo)

## The "strange things" resolution narrative (the heart of the talk)

"Strange things" covered three fears: engines that **crash**, engines that **silently drop
data**, and a demo app that **looks healthy but only emits errors** — which would make every
downstream number a lie. We turned each fear into an automated check that **must pass before any
run is trusted** (`validate-app.sh` + `validate-gate.sh`):

1. Census — all pods Running, engine-under-test 0-restart.
2. Demo actually working — probe the frontend, require a success-rate threshold; "generating lots
   of spans" and "working" are different things.
3. Engine receives — accepted > 0 **and refused == 0**.
4. Engine exports — sent/output > 0.
5. Backend receipt — the exported telemetry is **actually in the backend**.
6. OTAP arm — the Arrow-stream → df_engine → backend path end to end.

### The one that actually fired: the reference collector's missing OTLP endpoint
The guard earned its keep on the collector arm. The otel-demo workloads came up healthy — pods
Running, frontend serving — but **zero spans reached the collector**. The gate's receive-check
flagged `accepted == 0` immediately, before a 12h soak was wasted on a dead pipeline. Root cause:
the otel-demo Deployments were missing `OTEL_EXPORTER_OTLP_ENDPOINT`, so the apps instrumented
fine but **shipped their telemetry nowhere**. The pods looked perfect; the numbers were zero.

> **Talk line:** *"A healthy-looking demo app is the most dangerous input to a benchmark. The pods
> were green and the numbers were zero. The gate caught it in seconds. Steal the gate."*

### The two that stayed quiet (and that's the point)
- **Fluent Bit mesh crash:** the older v5.0.9 reproducibly SIGSEGV'd over the service-mesh HTTP/2
  path on multi-hour runs. We watched for it across the full 12h Arm-A soak. **It never fired.**
  v5.1.5 is clean over the mesh.
- **Arrow dictionary overflow:** the older Go Arrow engine died on soak. The Rust df_engine 0.61.0
  ran two 12h soaks (OTLP and OTAP) with **no overflow, no restart**.

## Reproduce it
```bash
git clone https://github.com/isItObservable/fluentbit-vs-collector
cd fluentbit-vs-collector/kubecon-2026
# create your backend secret from dynatrace-secret.example.yaml, then:
./deploy-arm.sh --foundation
./deploy-arm.sh collector      # or: fluentbit | arrow | otap
./validate-app.sh              # the "strange things" app-health gate
./validate-gate.sh collector   # the full pre-run gate
# ...run load, soak 12h, read KPIs...
./teardown-arm.sh collector
```
