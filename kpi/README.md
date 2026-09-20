# ISI-3574 E0 — KPI / leak-readout toolkit (deliverable #7)

Ported from the ISI-1779 benchmark tooling. **Run `census-gate.sh` FIRST** — every other
readout is invalid if the census gate fails.

| Script | Purpose | Key lesson baked in |
|--------|---------|---------------------|
| `census-gate.sh [ns...]` | Validity gate: per-ns, per-pod `phase==Running && restarts==0`. Exit≠0 on any violation. | ISI-1937/1822: aggregate PASS hides a dead/restarted entity → assert per-pod. |
| `loss-accounting.sh <collector\|fluentbit>` | accepted vs sent; verdict = `refused==0 && send_failed==0`. | ISI-1843: sent>accepted is fan-out, not negative loss — don't use 1−sent/accepted. |
| `leak-readout.sh <arm> [samples] [iv]` | Memory trend; verdict = **TAIL-flat** (last-third vs mid-third drift), not first-vs-last. | ISI-1811: warm-up floor-creep to plateau is normal. ISI-3477: bounded encode creep ≠ leak. |
| `cost-per-1m.sh <arm> [window_s]` | Headline metric: millicores / (records/1e6). | ISI-1779 headline unit (mc/1M). |

## Validated live at E0 (2026-09-02)
- `census-gate.sh` → **PASS** (3 collector + 3 FB + 4 Kepler pods, 0 restarts).
- `loss-accounting.sh collector` → **NO LOSS** (refused=0, send_failed=0; fan-out 1.891).

## For the real soaks (E1–E4)
These are the **live oracles**. For the 24h sustained averages read Grail (dtctl) history —
KPIs survive cluster death and are readable up to 24h post-run (ISI-1881). Env:
`KUBECONFIG` defaults to `~/.config/capmox/observable-otelarrow.kubeconfig`.
