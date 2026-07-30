#!/usr/bin/env python3
"""compute.py snap_t0 snap_t1 -> A/B/C benchmark table (handles sci-notation,
picks pod-total cgroup series, sums DaemonSet pods)."""
import re, sys

def load(path):
    ts=None; self_tel=[]; cadv=[]
    for ln in open(path):
        ln=ln.rstrip("\n")
        if ln.startswith("TS="): ts=int(ln.split("=")[1].split()[0]); continue
        m=re.match(r"(ARROW|OTLP|FLB)(.*)", ln)
        if m:
            body=m.group(2)
            val=float(body.split()[-2]); pod=body.split("POD=")[-1].strip()
            self_tel.append((m.group(1), body, val, pod)); continue
        if ln.startswith("container_"):
            name=ln.split("{")[0]; labels=ln[len(name)+1:].split("}")[0]
            val=float(ln.split("}")[1].split()[0])
            lab=dict(re.findall(r'(\w+)="([^"]*)"', labels))
            cadv.append((name, lab, val))
    return ts, self_tel, cadv

t0=load(sys.argv[1]); t1=load(sys.argv[2])
W=t1[0]-t0[0]
print(f"window = {W}s ({W/3600:.2f}h)\n")

VAR=[("ARROW","otel-agent-collector","otelcol_exporter_sent_log_records"),
     ("OTLP","otel-agent-otlp","otelcol_exporter_sent_log_records"),
     ("FLB","fluent-bit-v5","fluentbit_output_proc_records_total")]

def sum_self(snap, pfx, metric, extra=None):
    tot={}
    for p,body,val,pod in snap[1]:
        if p!=pfx: continue
        if metric not in body: continue
        if extra and extra not in body: continue
        tot[pod]=val
    return tot

def podtotal_cpu(snap, sub):
    # container="" and id ending pod<uid>.slice (no nested cri-containerd scope)
    tot={}
    for name,lab,val in snap[2]:
        if name!="container_cpu_usage_seconds_total": continue
        if lab.get("container")!="" or "cri-containerd" in lab.get("id",""): continue
        pod=lab.get("pod","")
        if sub in pod: tot[pod]=val
    return tot

def podtotal_mem(snap, sub):
    tot={}
    for name,lab,val in snap[2]:
        if name!="container_memory_working_set_bytes": continue
        if lab.get("container")!="" or "cri-containerd" in lab.get("id",""): continue
        pod=lab.get("pod","")
        if sub in pod: tot[pod]=val
    return tot

def net_tx(snap, sub):
    tot={}
    for name,lab,val in snap[2]:
        if name!="container_network_transmit_bytes_total": continue
        pod=lab.get("pod","")
        if sub in pod: tot[pod]=tot.get(pod,0)+val   # sum interfaces
    return tot

print(f"{'VARIANT':<12}{'recs/s':>12}{'net B/rec':>12}{'OTAP wireB/rec':>16}{'CPU cores':>11}{'mem MiB/pod':>13}{'loss':>8}")
for pfx,sub,metric in VAR:
    r0=sum_self(t0,pfx,metric); r1=sum_self(t1,pfx,metric)
    drec=sum(r1.get(p,0)-r0.get(p,0) for p in r1)
    rps=drec/W
    n0=net_tx(t0,sub); n1=net_tx(t1,sub)
    dnet=sum(n1.get(p,0)-n0.get(p,0) for p in n1)
    bpr=dnet/drec if drec else 0
    c0=podtotal_cpu(t0,sub); c1=podtotal_cpu(t1,sub)
    dcpu=sum(c1.get(p,0)-c0.get(p,0) for p in c1); cores=dcpu/W
    m1=podtotal_mem(t1,sub); memavg=(sum(m1.values())/len(m1)/1048576) if m1 else 0
    # OTAP native wire (logs) only for ARROW
    owire=""
    if pfx=="ARROW":
        w0=sum_self(t0,"ARROW","otelcol_exporter_sent_wire","ArrowLogs")
        w1=sum_self(t1,"ARROW","otelcol_exporter_sent_wire","ArrowLogs")
        dw=sum(w1.get(p,0)-w0.get(p,0) for p in w1)
        owire=f"{dw/drec:.1f}" if drec else "0"
    # loss
    if pfx in ("ARROW","OTLP"):
        a1=sum_self(t1,pfx,"otelcol_receiver_accepted_log_records")
        s1=sum_self(t1,pfx,"otelcol_exporter_sent_log_records")
        loss=sum(a1.values())-sum(s1.values())
    else:
        d1=sum_self(t1,"FLB","fluentbit_output_dropped_records_total")
        f1=sum_self(t1,"FLB","fluentbit_output_retries_failed_total")
        loss=sum(d1.values())+sum(f1.values())
    print(f"{pfx:<12}{rps:>12,.1f}{bpr:>12.1f}{owire:>16}{cores:>11.3f}{memavg:>13.1f}{loss:>8,.0f}")
