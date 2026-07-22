#!/usr/bin/env python3
"""ISI-1822 / D12 follow-up — make the pod-count tile state its EXPECTATION.

Tile 12 previously reported `pods_in_window` and nothing else. A bare "3" is
exactly the silent failure D12 exists to remove: the reader has to already know
the engines run replicas:1 to see that 3 is wrong. The tile now carries the
expected replica count and a PASS/FAIL verdict, matching pod-census.sh (which
exits 1 on the same condition) and the RUN-REGISTER census table.

Download-first (never rebuild from the local copy blind): a sibling run edited
this dashboard minutes ago, so the live document is the only safe input.
"""
import json, re, sys

DASH_ID = "764f7082-0039-4f3f-ad39-47b5abc5bb73"
CLUSTER = "observable-otelarrow"
ENGINE_SEL = f'k8s.cluster.name == "{CLUSTER}" and startsWith(k8s.workload.name, "bench-")'

live = json.load(open(sys.argv[1]))
assert live["id"] == DASH_ID, live["id"]
c = live["content"]

c["tiles"]["12"]["title"] = (
    "Pod count vs expected replicas — FAIL here means the window covers more than one pod lifetime"
)
c["tiles"]["12"]["query"] = (
    f'timeseries mem = avg(dt.kubernetes.container.memory_working_set), '
    f'by:{{k8s.workload.name, k8s.pod.name}}, filter: {ENGINE_SEL}\n'
    '| summarize pods_in_window = countDistinctExact(k8s.pod.name), by:{engine = k8s.workload.name}\n'
    '| fieldsAdd expected_replicas = 1\n'
    '| fieldsAdd census = if(pods_in_window == 1, "PASS - one continuous pod for the whole window", '
    'else:"FAIL - pod count != expected replicas -> RUN INVALID")\n'
    '| fields engine, census, pods_in_window, expected_replicas\n'
    '| sort census desc, engine asc'
)

# --- same invariants apply-d12.py asserts; re-checked so this cannot regress them
assert set(c["tiles"]) == set(c["layouts"]), set(c["tiles"]) ^ set(c["layouts"])
assert c["variables"] == []
for tid, t in c["tiles"].items():
    q = t.get("query")
    if q is None:
        continue
    assert not re.search(r"\bfrom:", q), f"tile {tid} carries its own timeframe"
    assert f'k8s.cluster.name == "{CLUSTER}"' in q, f"tile {tid} not scoped by cluster"
for tid in ("1", "2", "3", "4", "11", "12"):
    assert "k8s.pod.name" in c["tiles"][tid]["query"], f"tile {tid} not pod-grouped"
for tid, l in c["layouts"].items():
    assert l["x"] + l["w"] <= 24, f"tile {tid} overflows the 24-column grid"

stem = "isi1779-benchmark-comparison"
json.dump(live, open(f"{stem}.deploy.json", "w"), indent=2, ensure_ascii=False)
export = {k: v for k, v in live.items()
          if k not in ("id", "owner", "version", "modificationInfo", "isPrivate")}
json.dump(export, open(f"{stem}.dashboard.json", "w"), indent=2, ensure_ascii=False)
print(f"OK tiles={len(c['tiles'])} stripped={sorted(set(live) - set(export))}")
