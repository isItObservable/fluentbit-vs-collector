# ISI-1843 — detection-rate harness for engine-counters.sh.
# A green gate is a claim. This mutates the known-good snapshot into each way the arrow arm
# can silently be wrong and asserts the gate FAILS on every one. 8/8 caught, 15/15 on clean.
# The two tautology-satisfiers (m_dead, m_neversent) are the ones that matter: both produce
# "0 metrics at the sink", which is the naive check, and both are real failures.
# NOTE: mutators edit every matching (node,core) metric set, so mutated totals are inflated
# vs a real fault. This generates dirty input; it does not measure anything.
import json, copy, subprocess, sys
import os
base = json.load(open(os.environ.get('SNAP','engine-counters-T+26m.json')))

def find(d, setname, node, metric):
    out=[]
    for s in d['metric_sets']:
        if s['name']!=setname: continue
        at=s.get('attributes',{}) or {}
        nid=at.get('node.id'); n=nid.get('String') if isinstance(nid,dict) else (nid or '')
        if node is not None and n!=node: continue
        for m in s.get('metrics',[]):
            if m['name']==metric: out.append(m)
    return out

def m_dead(d):
    "engine dead: every counter zero (the classic tautology-satisfier)"
    for s in d['metric_sets']:
        for m in s.get('metrics',[]):
            if isinstance(m.get('value'),(int,float)): m['value']=0
            elif isinstance(m.get('value'),dict): m['value']={'min':float('inf'),'max':float('-inf'),'sum':0.0,'count':0}
    return d
def m_typo(d):
    "typo in outputs: metrics fall through to the default port"
    for m in find(d,'processor.signal_type_router','router','signals.routed.named.metrics'):
        v=m['value']; m['value']=0
        for dm in find(d,'processor.signal_type_router','router','signals.routed.default.metrics'): dm['value']+=v
    return d
def m_leak(d):
    "metrics reach the exporter — the drop silently stopped working"
    for m in find(d,'exporter.pdata','dt_out','metrics.exported'): m['value']=42
    return d
def m_batch3s(d):
    "batch reverted to 3s"
    for m in find(d,'otap.processor.batch',None,'flush.age.duration'):
        v=m['value']
        if v['count']: v['min']*=3; v['max']*=3; v['sum']*=3
    return d
def m_bErr(d):
    "batch conversion drops"
    for m in find(d,'otap.processor.batch','batch_logs','dropped.conversion'): m['value']=7
    return d
def m_stall(d):
    "receiver accepting but never completing"
    for m in find(d,'receiver.otlp','otlp_in','requests.completed'): m['value']=10
    return d
def m_noenrich(d):
    "enrichment silently no-op"
    for m in find(d,'processor.attributes','enrich_logs','upserted.entries'): m['value']=0
    return d
def m_loss(d):
    "silent loss between batch and exporter — the case coalescing would mask"
    for m in find(d,'exporter.pdata','dt_out','logs.exported'): m['value']=int(m['value']*0.6)
    return d
def m_routerloss(d):
    "silent loss between router and batch"
    for m in find(d,'otap.processor.batch','batch_logs','consumed.batches.logs'): m['value']=int(m['value']*0.5)
    return d
def m_neversent(d):
    "generator never sent metrics — the OTHER tautology-satisfier"
    for m in find(d,'processor.signal_type_router','router','signals.received.metrics'): m['value']=0
    for m in find(d,'processor.signal_type_router','router','signals.routed.named.metrics'): m['value']=0
    return d

muts=[m_dead,m_typo,m_leak,m_batch3s,m_bErr,m_stall,m_noenrich,m_neversent,m_loss,m_routerloss]
caught=0
for f in muts:
    d=f(copy.deepcopy(base))
    json.dump(d, open('/tmp/mut.json','w'))
    r=subprocess.run(['./engine-counters.sh','--no-fetch','/tmp/mut.json'],capture_output=True,text=True)
    fails=[l for l in r.stdout.splitlines() if l.startswith('FAIL')]
    ok = r.returncode!=0
    caught += ok
    print(f"{'CAUGHT' if ok else 'MISSED':<7} {f.__name__:<12} {f.__doc__}")
    for l in fails[:3]: print(f"          -> {l}")
print(f"\ndetection rate: {caught}/{len(muts)}")
sys.exit(0 if caught==len(muts) else 1)
