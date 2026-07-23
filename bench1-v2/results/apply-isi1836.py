#!/usr/bin/env python3
"""ISI-1836 — fix the two read-time defects on dashboard 764f7082.

Defect 1: the per-app tile bucketed 54.4% of the R1-P1 window (10,070,942 of
18,499,537 spans) into "unlabelled", because the namespace lives under two
mutually exclusive attributes: app-SDK spans carry `service.namespace`, Istio
mesh spans do not.

The issue offered (a) rename the bucket, (b) coalesce in `k8s.namespace.name`,
(c) split by telemetry_source. **We take none of them — we take (d).**
`k8s.namespace.name` is written by the k8sattributes processor, i.e. by the
ENGINE UNDER TEST, so option (b) would make the per-app split partly a function
of the engine — exactly the artifact that does not cancel in an engine-vs-engine
comparison. But Istio already encodes the namespace in `service.name` as
`<service>.<namespace>` (Istio's own convention), and Istio config is frozen and
identical across all three engine arms. Parsing it there recovers the same
coverage as (b) with **zero** engine-applied attributes:

    app = coalesce(service.namespace, splitString(service.name, ".")[1], "<unattributed>")
           ^ set by the app SDK        ^ set by Istio                     ^ visible gap

Measured on R1-P1 (2026-07-22T15:58:43Z→17:59:21Z), verified before writing:
    hipster-shop  7,962,661 mesh + 5,507,966 app-sdk
    otel-demo     1,196,151 mesh + 2,920,629 app-sdk
    <unattributed>              912,130 app-sdk   (4.93%, left visible on purpose)
    total 18,499,537 = the window's benchmark-tagged span count. Coverage 95.07%.

Defect 2: the source tile mapped `if(benchmark.telemetry_source == "istio-mesh",
"istio-mesh", else: "app-sdk")`, so a NULL silently became a real category. For
P1 that is coincidentally correct, but an engine that drops the attribute would
report a clean, plausible 100% app-sdk instead of failing — the ISI-1830 lesson
that a skipped check must never render as a pass.

The fix is not only to render the null (`<not stamped>`); it is to derive the
same fact a SECOND, independent way and show both. The independent derivation
uses `telemetry.sdk.name == "envoy"` (written by the emitting proxy) plus the
dotted Istio service name — neither touched by the engine:

    stamped = if(isNull(benchmark.telemetry_source), "<not stamped>", else: ...)
    shape   = if(telemetry.sdk.name == "envoy" and isNotNull(parts[1]), "istio-mesh", else: "app-sdk")

On R1-P1 the two agree exactly — 9,158,812 istio-mesh / 9,340,725 app-sdk — which
is what makes the cross-check trustworthy as a P2/P3 gate. A disagreement row is
a dropped attribute, and it is now impossible to read as a clean result.
NOTE the derivation is not "sdk.name == envoy" alone: 422,380 otel-demo
`frontend-proxy` spans are Envoy-emitted but not Istio sidecar spans. The dotted
service name is what separates them.

Input : live dashboard, downloaded first (never rebuild from the local copy blind).
Output: <stem>.deploy.json (with id, for dtctl apply) and the stripped source export.
"""
import json
import re
import sys

DASH_ID = "764f7082-0039-4f3f-ad39-47b5abc5bb73"
CLUSTER = "observable-otelarrow"
SEL = f'fetch spans | filter k8s.cluster.name == "{CLUSTER}" and isNotNull(benchmark.engine)'

# The namespace/ingest derivation, engine-independent. Shared by every span tile so
# the dashboard cannot drift into two different definitions of "app".
DERIVE = """
| fieldsAdd svc_parts = splitString(service.name, ".")
| fieldsAdd app = coalesce(service.namespace, svc_parts[1], "<unattributed>")
| fieldsAdd ingest = if(telemetry.sdk.name == "envoy" and isNotNull(svc_parts[1]), "istio-mesh", else: "app-sdk")"""

live = json.load(open(sys.argv[1]))
assert live["id"] == DASH_ID, live["id"]
c = live["content"]
tiles, layouts = c["tiles"], c["layouts"]

# --- Defect 2: stamped vs independently derived ----------------------------
tiles["8"] = {
    "type": "data",
    "title": "App SDK vs Istio mesh — STAMPED attribute vs INDEPENDENT derivation (gate checks 2 & 4)",
    "query": f"""{SEL}
| fieldsAdd svc_parts = splitString(service.name, ".")
| fieldsAdd stamped = if(isNull(benchmark.telemetry_source), "<not stamped>", else: benchmark.telemetry_source)
| fieldsAdd shape = if(telemetry.sdk.name == "envoy" and isNotNull(svc_parts[1]), "istio-mesh", else: "app-sdk")
| summarize spans = count(), by:{{ engine = benchmark.engine, stamped, shape }}
| sort spans desc""",
    "visualization": "table",
    "visualizationSettings": {
        "chartSettings": {},
        "singleValue": {},
        "table": {},
        "thresholds": [],
    },
}

# --- Defect 1: per-app split with no engine-applied attribute --------------
tiles["9"] = {
    "type": "data",
    "title": "Spans by app x ingest path — namespace derived WITHOUT any engine-applied attribute (gate check 2)",
    "query": f"""{SEL}{DERIVE}
| summarize spans = count(), by:{{ engine = benchmark.engine, app, ingest }}
| sort spans desc""",
    "visualization": "table",
    "visualizationSettings": {
        "chartSettings": {},
        "singleValue": {},
        "table": {},
        "thresholds": [],
    },
}

# --- NEW tile 13: the known gap, kept visible instead of folded away -------
tiles["13"] = {
    "type": "data",
    "title": "KNOWN GAP — spans with no namespace on EITHER path. Must stay small and stable across engines.",
    "query": f"""{SEL}
| fieldsAdd svc_parts = splitString(service.name, ".")
| filter isNull(service.namespace) and isNull(svc_parts[1])
| summarize spans = count(), by:{{ engine = benchmark.engine, service.name }}
| sort spans desc""",
    "visualization": "table",
    "visualizationSettings": {
        "chartSettings": {},
        "singleValue": {},
        "table": {},
        "thresholds": [],
    },
}

# --- NEW tile 14: the collision-free <namespace>.<service> key -------------
# Board request (Henrik, 2026-07-23). Bare `service.name` COLLIDES: `frontend`
# is one identity holding hipster-shop 3,294,973 + otel-demo 892,424 spans, and
# the same workload also appears twice (mesh `frontend.hipster-shop`, app-SDK
# bare `frontend`). This key separates the apps and makes each workload whole:
# hipster-shop.frontend 6,591,068 / otel-demo.frontend 1,390,604 on R1-P1.
tiles["14"] = {
    "type": "data",
    "title": "Spans by <namespace>.<service> — collision-free service key (bare service.name blends the two apps)",
    "query": f"""{SEL}{DERIVE}
| fieldsAdd service_key = concat(app, ".", coalesce(svc_parts[0], service.name))
| summarize spans = count(), by:{{ engine = benchmark.engine, service_key }}
| sort spans desc""",
    "visualization": "table",
    "visualizationSettings": {
        "chartSettings": {},
        "singleValue": {},
        "table": {},
        "thresholds": [],
    },
}

# --- caveats: replace the now-wrong bullet, document the derivation --------
OLD_BULLET = "- **`app-sdk` vs `istio-mesh`** is split on `benchmark.telemetry_source`"
NEW_BULLETS = """- **`app-sdk` vs `istio-mesh` is shown TWICE on purpose** (ISI-1836 defect 2). `stamped` is `benchmark.telemetry_source`, set only by the Istio `Telemetry` CR, with NULL rendered as `<not stamped>` rather than defaulting to `app-sdk`. `shape` derives the same fact independently from `telemetry.sdk.name == "envoy"` + a dotted Istio service name. **If the two columns disagree, the engine dropped the attribute** — read that as a defect, not as a result. On R1-P1 they agree exactly (9,158,812 / 9,340,725). `benchmark.engine` cannot make this split — the engines stamp it on every record they process, app and mesh alike.
- **The per-app namespace is derived without any engine-applied attribute** (ISI-1836 defect 1, decision (d)). App-SDK spans carry `service.namespace`; Istio mesh spans carry the namespace inside `service.name` as `<service>.<namespace>`. The tile coalesces those two — both written upstream of the engine — and deliberately does **not** use `k8s.namespace.name`, which the k8sattributes processor (the engine under test) writes, and which would make the per-app split partly a function of the engine. Coverage 95.07% on R1-P1; the residual 4.93% is shown as `<unattributed>` and broken out in its own tile.
- **Bare `service.name` collides across the two apps** — `frontend` exists in both hipster-shop and otel-demo, and the same workload appears twice (mesh `frontend.hipster-shop`, app-SDK bare `frontend`). Read per-service volume from the `<namespace>.<service>` tile, never from `service.name` alone."""
md = tiles["10"]["markdown"]
lines = md.split("\n")
hit = [i for i, l in enumerate(lines) if l.startswith(OLD_BULLET)]
assert len(hit) == 1, f"caveat bullet not found exactly once: {hit}"
lines[hit[0]] = NEW_BULLETS
tiles["10"]["markdown"] = "\n".join(lines)

# --- reflow: the two span tiles grow, the two new tiles sit under them -----
NEW_LAYOUT = {
    "0":  {"x": 0,  "y": 0,  "w": 24, "h": 9},   # header
    "11": {"x": 0,  "y": 9,  "w": 16, "h": 8},   # pod census (gate)
    "12": {"x": 16, "y": 9,  "w": 8,  "h": 8},   # pods seen vs expected
    "1":  {"x": 0,  "y": 17, "w": 12, "h": 7},   # cpu per pod
    "2":  {"x": 12, "y": 17, "w": 12, "h": 7},   # mem per pod
    "3":  {"x": 0,  "y": 24, "w": 24, "h": 7},   # resource summary per pod
    "4":  {"x": 0,  "y": 31, "w": 8,  "h": 6},   # stability per pod
    "5":  {"x": 8,  "y": 31, "w": 8,  "h": 6},   # ingest volume
    "6":  {"x": 16, "y": 31, "w": 8,  "h": 6},   # metric series
    "7":  {"x": 0,  "y": 38, "w": 12, "h": 7},   # ingest rate
    "8":  {"x": 12, "y": 38, "w": 12, "h": 7},   # stamped vs derived  (ISI-1836 D2)
    "9":  {"x": 0,  "y": 45, "w": 12, "h": 9},   # spans by app x ingest (ISI-1836 D1)
    "10": {"x": 12, "y": 45, "w": 12, "h": 9},   # caveats
    "13": {"x": 0,  "y": 54, "w": 10, "h": 6},   # known gap            (ISI-1836 D1)
    "14": {"x": 10, "y": 54, "w": 14, "h": 6},   # <ns>.<svc> service key
}
c["layouts"] = NEW_LAYOUT

# --- assertions ------------------------------------------------------------
assert set(c["tiles"]) == set(c["layouts"]), (set(c["tiles"]) ^ set(c["layouts"]))
assert c["variables"] == [], c["variables"]
for tid, t in c["tiles"].items():
    q = t.get("query")
    if q is None:
        continue
    assert not re.search(r"\bfrom:", q), f"tile {tid} carries its own timeframe"
    assert f'k8s.cluster.name == "{CLUSTER}"' in q, f"tile {tid} not scoped by cluster"
for tid in ("1", "2", "3", "4", "11", "12"):
    assert "k8s.pod.name" in c["tiles"][tid]["query"], f"tid {tid} not pod-grouped"
# ISI-1836: no span tile may depend on an attribute the engine writes, and no
# span tile may map a null into a real category.
for tid in ("8", "9", "13", "14"):
    q = c["tiles"][tid]["query"]
    assert "k8s.namespace.name" not in q, f"tile {tid} uses an ENGINE-APPLIED namespace"
    assert "k8s.workload.name" not in q, f"tile {tid} uses an ENGINE-APPLIED workload"
assert '"<not stamped>"' in c["tiles"]["8"]["query"], "defect 2 not fixed: null is still absorbed"
assert '"unlabelled"' not in json.dumps(c), "defect 1 not fixed: unlabelled bucket still present"
for tid, l in c["layouts"].items():
    assert l["x"] + l["w"] <= 24, f"tile {tid} overflows the 24-column grid"

stem = "isi1779-benchmark-comparison"
json.dump(live, open(f"{stem}.deploy.json", "w"), indent=2, ensure_ascii=False)
export = {k: v for k, v in live.items() if k not in ("id", "owner", "version", "modificationInfo", "isPrivate")}
json.dump(export, open(f"{stem}.dashboard.json", "w"), indent=2, ensure_ascii=False)
print(f"OK  tiles={len(c['tiles'])} layouts={len(c['layouts'])} "
      f"stripped={sorted(set(live) - set(export))}")
