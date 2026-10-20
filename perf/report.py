#!/usr/bin/env python3
"""Render one perf/run-perf.sh results directory as a single markdown report.

  python3 perf/report.py perf/results/<stamp>            # writes <stamp>/summary.md
  python3 perf/report.py perf/results/<stamp> --stdout   # print instead

The same idea as harvester-perf's poc/lib/report.sh summary.md: one file, a
status table, then a section per suite. Everything is read from the files the
run left behind (cluster.txt, <suite>.json, guest/), so an old directory can be
re-rendered at any time. Standard library only; Python 3.9+.
"""

import json
import os
import re
import sys
from datetime import datetime

# Thresholds the upstream poc judges etcd against (ETCD_*_THRESHOLD defaults in
# poc/suites/etcd-benchmark.sh): etcd's own commonly cited 10 ms for the WAL,
# and 25 ms for the backend commit.
WAL_FSYNC_P99_S = 0.010
BACKEND_COMMIT_P99_S = 0.025

HVPERF_SUITES = ["node-capacity", "resource-footprint", "etcd-benchmark", "density"]


# --- helpers -------------------------------------------------------------------

def load_json(path, default=None):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def read_cluster(d):
    """cluster.txt is `key: value` lines; `warning:` may repeat."""
    info, warnings = {}, []
    try:
        with open(os.path.join(d, "cluster.txt")) as fh:
            for line in fh:
                k, sep, v = line.partition(":")
                if not sep:
                    continue
                k, v = k.strip(), v.strip()
                if k == "warning":
                    warnings.append(v)
                else:
                    info[k] = v
    except OSError:
        pass
    return info, warnings


def ts(s):
    """hvperf writes RFC 3339 with nanoseconds, which fromisoformat rejects."""
    if not s:
        return None
    m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)?", s)
    if not m:
        return None
    frac = (m.group(2) or ".0")[:7]
    tz = m.group(3) or "Z"
    return datetime.fromisoformat(m.group(1) + frac + ("+00:00" if tz == "Z" else tz))


def dur(seconds):
    if seconds is None:
        return "-"
    if seconds < 1:
        return "<1s"
    seconds = int(round(seconds))
    return "%dm %02ds" % divmod(seconds, 60) if seconds >= 60 else "%ds" % seconds


def num(v, digits=3):
    if v is None:
        return "-"
    if v == 0 or abs(v) >= 100:
        return "{:,.0f}".format(v)
    return "%.*g" % (digits, v)


def ms(seconds):
    return "-" if seconds is None else "%.2f ms" % (seconds * 1000)


def gib(b):
    return "-" if b is None else "%.1f GiB" % (b / 2**30)


def mib(b):
    return "-" if b is None else "%.0f MiB" % (b / 2**20)


def short_node(name):
    return name or "-"


def samples(metric):
    """[(labels, float value)] from one MetricResult; NaN dropped."""
    out = []
    for s in (metric or {}).get("Samples") or []:
        try:
            v = float(s["value"][1])
        except (KeyError, IndexError, TypeError, ValueError):
            continue
        if v == v:
            out.append((s.get("metric", {}), v))
    return out


def find_metric(case, needle):
    for m in (case or {}).get("MetricResults") or []:
        if needle in m.get("Query", ""):
            return m
    return None


def cases(result):
    return result.get("Results") or []


def case_named(result, name):
    return next((c for c in cases(result) if c.get("CaseName") == name), None)


def suite_span(result):
    starts = [ts(c.get("DateTimeStart")) for c in cases(result)]
    ends = [ts(c.get("DateTimeEnd")) for c in cases(result)]
    starts, ends = [s for s in starts if s], [e for e in ends if e]
    if not starts or not ends:
        return None
    return (max(ends) - min(starts)).total_seconds()


def table(head, rows):
    out = ["| " + " | ".join(head) + " |", "|" + "|".join(" --- " for _ in head) + "|"]
    for r in rows:
        out.append("| " + " | ".join(str(c).replace("|", "\\|").replace("\n", " ") for c in r) + " |")
    return out


# --- per-suite sections --------------------------------------------------------

def sec_node_capacity(r):
    out = ["## Node capacity", ""]
    info = case_named(r, "node os info")
    rows = []
    for k in (info or {}).get("K8sResourceResults") or []:
        d = k.get("Data") or {}
        mem = d.get("memory.allocatable", "")
        mem_b = None
        m = re.match(r"(\d+)Ki$", mem)
        if m:
            mem_b = int(m.group(1)) * 1024
        rows.append([short_node(k.get("Subject")), d.get("architecture", "-"),
                     d.get("cpu.allocatable", "-"), gib(mem_b) if mem_b else (mem or "-"),
                     "%s / %s" % (d.get("pods.running", "-"), d.get("pods.capacity", "-")),
                     d.get("kubelet.version", "-"), d.get("kernel.version", "-")])
    if rows:
        out += table(["Node", "Arch", "CPU allocatable", "Memory allocatable", "Pods running / max",
                      "Kubelet", "Kernel"], rows)
        out.append("")
    disks = case_named(r, "node disk info")
    drows = []
    for c in (disks or {}).get("CmdResults") or []:
        top = [ln.split() for ln in (c.get("Stdout") or "").splitlines()[1:]]
        whole = [f for f in top if len(f) >= 3 and f[-1] == "disk" and not f[0].startswith("sd")]
        drows.append([short_node(c.get("Node")),
                      ", ".join("%s %s" % (f[0], f[2]) for f in whole) or "-",
                      c.get("Err") or "-"])
    if drows:
        out += ["Root disks (from `lsblk` on each node; Longhorn's attached `sd*` volumes omitted):", ""]
        out += table(["Node", "Disk", "Error"], sorted(drows))
        out.append("")
    return out


def sec_footprint(r):
    out = ["## Resource footprint", "",
           "Harvester's own namespaces, from Prometheus: actual use over the last 5 minutes, "
           "and what their pods reserve.", ""]
    usage, reqs = case_named(r, "per-namespace resource usage"), case_named(r, "per-namespace resource requests")
    ns = {}

    def add(case, needle, key):
        for labels, v in samples(find_metric(case, needle)):
            n = labels.get("namespace", "?")
            ns.setdefault(n, {}).setdefault(key, 0.0)
            ns[n][key] += v

    add(usage, "container_cpu_usage_seconds_total", "cpu")
    add(usage, "container_memory_working_set_bytes", "mem")
    add(reqs, 'resource="cpu"', "cpu_req")
    add(reqs, 'resource="memory"', "mem_req")
    if ns:
        rows = []
        for n, v in sorted(ns.items(), key=lambda kv: -kv[1].get("cpu", 0)):
            rows.append([n, num(v.get("cpu")), mib(v.get("mem")), num(v.get("cpu_req", 0)), mib(v.get("mem_req", 0))])
        tot = {k: sum(v.get(k, 0) for v in ns.values()) for k in ("cpu", "mem", "cpu_req", "mem_req")}
        rows.append(["**total**", "**%s**" % num(tot["cpu"]), "**%s**" % mib(tot["mem"]),
                     "**%s**" % num(tot["cpu_req"]), "**%s**" % mib(tot["mem_req"])])
        out += table(["Namespace", "CPU used (cores)", "Memory used", "CPU requested (cores)", "Memory requested"], rows)
        out.append("")
    host = case_named(r, "host memory")
    alloc = case_named(r, "node allocatable resources")
    nodes = {}
    for labels, v in samples(find_metric(host, "MemTotal")):
        nodes.setdefault(labels.get("nodename", "?"), {})["total"] = v
    for labels, v in samples(find_metric(host, "MemAvailable")):
        nodes.setdefault(labels.get("nodename", "?"), {})["avail"] = v
    for labels, v in samples(find_metric(alloc, 'resource="cpu"')):
        nodes.setdefault(labels.get("node", "?"), {})["cpu"] = v
    for labels, v in samples(find_metric(alloc, 'resource="memory"')):
        nodes.setdefault(labels.get("node", "?"), {})["mem"] = v
    if nodes:
        rows = [[n, gib(v.get("total")), gib(v.get("avail")), num(v.get("cpu")), gib(v.get("mem"))]
                for n, v in sorted(nodes.items())]
        out += table(["Node", "Host memory", "Host memory available", "Allocatable CPU", "Allocatable memory"], rows)
        out.append("")
    return out


BENCH_RE = {k: re.compile(p) for k, p in {
    "total": r"Total:\s+([\d.]+) secs", "slowest": r"Slowest:\s+([\d.]+) secs",
    "avg": r"Average:\s+([\d.]+) secs", "rps": r"Requests/sec:\s+([\d.]+)",
    "p99": r"99% in ([\d.]+) secs", "p50": r"50% in ([\d.]+) secs"}.items()}


def bench_row(label, cmd):
    out = cmd.get("Stdout") or ""
    v = {k: (float(m.group(1)) if m else None) for k, rx in BENCH_RE.items() for m in [rx.search(out)]}
    if cmd.get("Err") or v["rps"] is None:
        return [label, "FAILED", "-", "-", "-", "-"]
    return [label, num(v["rps"]), ms(v["avg"]), ms(v["p50"]), ms(v["p99"]), ms(v["slowest"])]


def bench_label(cmd, concurrent):
    c = cmd.get("Cmd", "")
    kind = "write" if " put " in c else ("read, linearizable" if "consistency l" in c else "read, serializable")
    return "%s %s" % ("concurrent" if concurrent else "serial", kind)


def sec_etcd(r):
    out = ["## etcd benchmark", ""]
    health = case_named(r, "etcd healthcheck")
    for c in (health or {}).get("CmdResults") or []:
        if "endpoint health" in c.get("Cmd", "") and c.get("Stdout"):
            out += ["- Health: `%s`" % c["Stdout"].strip().splitlines()[0]]
        if "endpoint status" in c.get("Cmd", "") and c.get("Stdout"):
            out += ["- Status: `%s`" % c["Stdout"].strip().splitlines()[0]]
    perf = case_named(r, "etcd check perf")
    for c in (perf or {}).get("CmdResults") or []:
        lines = [ln.strip() for ln in (c.get("Stdout") or "").splitlines() if ln.strip()]
        verdict = lines[-1] if lines else "unknown"
        detail = "; ".join(ln for ln in lines if ln.startswith(("PASS:", "FAIL:")))
        out += ["- `etcdctl check perf` (small load): **%s** %s" % (verdict, "(%s)" % detail if detail else "")]
    out.append("")
    rows = []
    for name, conc in (("etcd benchmark (serial)", False), ("etcd benchmark (concurrent)", True)):
        for c in (case_named(r, name) or {}).get("CmdResults") or []:
            rows.append(bench_row(bench_label(c, conc), c))
    if rows:
        out += ["Serial is 1 client on 1 connection; concurrent is 500 clients on 100 connections. "
                "The job pod runs on the node named in `hvperf.yaml` and talks to etcd on 127.0.0.1.", ""]
        out += table(["Scenario", "Requests/s", "Average", "p50", "p99", "Slowest"], rows)
        out.append("")
    mon = case_named(r, "etcd monitoring (promql)")
    if mon is None:
        return out
    if mon.get("State") == "SKIP":
        out += ["Disk and peer metrics: **skipped**: %s" % (mon.get("Err") or "no reason given"), ""]
        return out

    def worst(needle):
        vals = [v for _, v in samples(find_metric(mon, needle))]
        return max(vals) if vals else None

    wal, commit = worst("etcd_disk_wal_fsync"), worst("etcd_disk_backend_commit")
    rtt = worst("peer_round_trip_time")
    sent = worst("peer_sent_failures")
    verdict = lambda v, t: "-" if v is None else ("ok" if v <= t else "**slow disk**")
    out += ["### Disk and peer metrics (etcd's own histograms, worst member)", ""]
    rtt_note = "-"
    if rtt is None and find_metric(mon, "peer_round_trip_time"):
        rtt_note = ("no data: hvperf's query filters on a `ConnectionType` label etcd 3.6 "
                    "does not have (see perf/README.md, Upstream findings)")
    out += table(["Metric", "Value", "Threshold", "Verdict"], [
        ["WAL fsync p99", ms(wal), ms(WAL_FSYNC_P99_S), verdict(wal, WAL_FSYNC_P99_S)],
        ["Backend commit p99", ms(commit), ms(BACKEND_COMMIT_P99_S), verdict(commit, BACKEND_COMMIT_P99_S)],
        ["Peer round-trip p99", ms(rtt) if rtt is not None else rtt_note, "-", "-"],
        ["Peer send failures/s", num(sent) if sent is not None else "-", "0", "-" if sent is None else ("ok" if sent == 0 else "**failures**")],
    ])
    out += ["", "Histogram quantiles are interpolated within buckets that double in width, "
            "so read them as an upper bound, not a precise value.", ""]
    return out


def sec_density(r):
    out = ["## VM density", ""]
    create = case_named(r, "vmi-create")
    if create is None:
        out += ["Did not run: **%s**" % (r.get("Err") or "no case results"), ""]
        return out
    cap = ((create.get("CapacityResults") or [{}])[0]) or {}
    span = None
    s, e = ts(create.get("DateTimeStart")), ts(create.get("DateTimeEnd"))
    if s and e:
        span = (e - s).total_seconds()
    out += ["- VMIs confirmed Running and healthy: **%s**" % cap.get("Max", "-"),
            "- Stopped because: %s" % (cap.get("Err") or "reached `maxVMs` (see `hvperf.yaml`)"),
            "- Ramp duration: %s" % dur(span)]
    if cap.get("CleanupErr"):
        out.append("- **Cleanup failed:** %s" % cap["CleanupErr"])
    out.append("")
    met = case_named(r, "density metrics")
    if met and met.get("MetricResults"):
        def one(needle):
            v = [x for _, x in samples(find_metric(met, needle))]
            return v[0] if v else None
        lat = [(q, one("histogram_quantile(%s" % q)) for q in ("0.50", "0.95", "0.99")]
        out += ["VMI creation to `Running` (KubeVirt's histogram; `Running` means QEMU started, not that the guest booted):", ""]
        out += table(["p50", "p95", "p99"], [["%.1f s" % v if v is not None else "-" for _, v in lat]])
        out.append("")
        comp = []
        for name, pod in (("virt-api", "virt-api"), ("virt-controller", "virt-controller")):
            cpu = one('pod=~"%s-.*",container!=""}[2m]' % pod)
            mems = [x for _, x in samples(find_metric(met, 'avg_over_time((sum(container_memory_working_set_bytes{namespace="harvester-system",pod=~"%s' % pod))]
            mx = [x for _, x in samples(find_metric(met, 'max_over_time((sum(container_memory_working_set_bytes{namespace="harvester-system",pod=~"%s' % pod))]
            comp.append([name, num(cpu), mib(mems[0] if mems else None), mib(mx[0] if mx else None)])
        out += table(["Component", "CPU (cores, avg)", "Memory (avg)", "Memory (max)"], comp)
        out.append("")
    elif met:
        out += ["Metrics: **%s** %s" % (met.get("State"), met.get("Err") or ""), ""]
    return out


def sec_guest(d):
    g = os.path.join(d, "guest")
    o = load_json(os.path.join(g, "overhead.json"))
    meta = load_json(os.path.join(g, "meta.json"), {})
    out = ["## In-guest workloads: VM against a pod on the same node", ""]
    if not o:
        single = sec_guest_single(g, meta)
        if single:
            return out[:1] + ["", "No pod baseline in this run (`--guest-mode vm` or `pod`), so no "
                              "overhead figure; the workloads' own results follow."] + single
        log = os.path.join(d, "guest.log")
        reason = "no `guest/overhead.json`"
        try:
            errs = [ln.strip() for ln in open(log) if re.search(r"ERROR|Error from server|failed", ln)]
            if errs:
                reason = errs[0][:300]
        except OSError:
            pass
        out += ["Did not complete: %s" % reason, ""]
        if os.path.exists(os.path.join(d, "guest-console.txt")):
            out += ["The suite's printed output was kept in `guest-console.txt`.", ""]
        return out
    out += ["- Label: %s" % (o.get("label") or "-"),
            "- %s vCPU / %s per VM and pod; bench on `%s`, network peer on `%s`" % (
                meta.get("vcpus", "-"), meta.get("memory", "-"), meta.get("bench_node", "-"), meta.get("peer_node", "-")),
            "- VM network multiqueue: %s" % ("on" if meta.get("vm_net_multiqueue") else "off (one virtio-net queue)"),
            "- VM CPU limit: %s (vCPUs: %s)" % (meta.get("vm_cpu_limit") or meta.get("vcpus", "-"), meta.get("vcpus", "-")),
            "- Data disk: %s on `%s`" % (meta.get("data_size", "-"), meta.get("data_storage_class", "-")), ""]
    cats = o.get("categories") or {}
    pc = lambda x: "-" if x is None else "%+.1f%%" % x
    out += table(["Compute", "Scheduler", "Disk", "Network", "**Overall**"],
                 [[pc((cats.get(c) or {}).get("overhead_pct")) for c in ("compute", "scheduler", "disk", "network")]
                  + ["**%s**" % pc((o.get("overall") or {}).get("overhead_pct"))]])
    out += ["", "Overhead is the VM's shortfall against the pod: the geometric mean of vm/pod per category, "
            "with the four categories weighted equally. Positive means the VM is slower.", ""]
    rows = [[x["figure"], x["unit"], num(x.get("pod")), num(x.get("vm")),
             "-" if x.get("ratio") is None else "%.3f" % x["ratio"], pc(x.get("overhead_pct")),
             "-" if x.get("node_steal_pct") is None else "%.1f%%" % x["node_steal_pct"]]
            for x in o.get("rows") or []]
    out += table(["Figure", "Unit", "Pod", "VM", "VM/pod", "Overhead", "Node steal"], rows)
    out.append("")
    qrows = []
    for x in o.get("rows") or []:
        cg = x.get("cgroup") or {}
        if not cg:
            continue
        cell = lambda m, k, f: "-" if not cg.get(m) or cg[m].get(k) is None else f % cg[m][k]
        qrows.append([x["figure"], cell("pod", "cores_used", "%.2f"), cell("pod", "throttled_periods_pct", "%.1f%%"),
                      cell("vm", "cores_used", "%.2f"), cell("vm", "throttled_periods_pct", "%.1f%%")])
    if qrows:
        out += ["CPU quota during each test: cores the bench container used, and the share of CFS periods "
                "in which its limit throttled it. The VM's container also runs QEMU's emulator and "
                "vhost-net threads, so its usage can exceed its vCPU count when the limit allows.", ""]
        out += table(["Figure", "Pod cores", "Pod throttled", "VM cores", "VM throttled"], qrows)
        out.append("")
    for w in o.get("warnings") or []:
        out.append("> **Warning:** %s" % w)
    if o.get("warnings"):
        out.append("")
    return out


def sec_sustained(d, info):
    g = os.path.join(d, "guest")
    runs = {}
    for mode in ("vm", "pod"):
        t = (load_json(os.path.join(g, mode, "result.json"), {}).get("tests") or {}).get("net-tcp-4-sustained")
        if t and not t.get("error") and t.get("series_gbit"):
            runs[mode] = t
    if not runs:
        return []
    any_t = next(iter(runs.values()))
    out = ["### Sustained network: %d streams for %s, sampled every %s s" % (
        any_t.get("streams", 4), dur(any_t.get("duration_s")), any_t.get("interval_s", 10)), ""]
    if info.get("instance_network"):
        out += ["Instance network (baseline / burst): %s." % info["instance_network"], ""]
    drop = lambda t: "no drop within the run" if t.get("drop_at_s") is None else "after %s" % dur(t["drop_at_s"])
    rows = [[m.upper(), num(t.get("gbit_per_sec")), num(t.get("first_60s_gbit")), num(t.get("last_120s_gbit")),
             num(t.get("min_interval_gbit")), num(t.get("max_interval_gbit")), drop(t)] for m, t in runs.items()]
    out += table(["Mode", "Overall Gbit/s", "First 60 s", "Last 120 s", "Min 10 s", "Max 10 s",
                  "Fell below 80% of the first minute"], rows)
    out.append("")
    step = max(1, 60 // int(any_t.get("interval_s", 10)))
    longest = max(len(t["series_gbit"]) for t in runs.values())
    mrows = []
    for i in range(0, longest, step):
        row = ["%d" % (i // step + 1)]
        for m in ("vm", "pod"):
            if m in runs:
                chunk = runs[m]["series_gbit"][i:i + step]
                row.append(num(sum(chunk) / len(chunk)) if chunk else "-")
        mrows.append(row)
    out += ["Minute by minute (mean Gbit/s):", ""]
    out += table(["Minute"] + [m.upper() for m in ("vm", "pod") if m in runs], mrows)
    out.append("")
    return out


def hvg_module():
    """perf/guest/hvg.py, for its FIGURES table and figure(), so the two never disagree."""
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "guest", "hvg.py")
    spec = importlib.util.spec_from_file_location("hvg", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def sec_guest_single(g, meta):
    hvg = hvg_module()
    out = []
    for mode in ("vm", "pod"):
        result = load_json(os.path.join(g, mode, "result.json"))
        if not result:
            continue
        thr = load_json(os.path.join(g, mode, "cgroup-throttle.json"), {})
        limit = meta.get("vm_cpu_limit") if mode == "vm" else meta.get("vcpus")
        out += ["", "### %s mode (%s vCPU, CPU limit %s, multiqueue %s)" % (
            mode.upper(), meta.get("vcpus", "-"), limit or "-",
            "on" if meta.get("vm_net_multiqueue") and mode == "vm" else "off"), ""]
        rows = []
        for label, test, field, unit, per_vcpu, _ in hvg.FIGURES:
            t = thr.get(test) or {}
            rows.append([label, unit, num(hvg.figure(result, test, field, per_vcpu)),
                         "-" if t.get("cores_used") is None else "%.2f" % t["cores_used"],
                         "-" if not t else "%.1f%%" % t.get("throttled_periods_pct", 0)])
        out += table(["Figure", "Unit", mode.upper(), "Cores used", "Throttled"], rows)
    return out + [""] if out else []


def sec_limits(info):
    keys = [("instance_network", "Instance network (baseline / burst)"),
            ("instance_ebs", "Instance EBS (baseline / burst)"),
            ("node_volume", "Node root volume (Longhorn, etcd and the OS share it)")]
    have = [(label, info[k]) for k, label in keys if info.get(k)]
    if not have:
        return []
    out = ["## AWS limits in play", "",
           "A figure that sits at one of these is measuring AWS, not Harvester. "
           "See perf/README.md, \"Which AWS limit a result is hitting\".", ""]
    out += table(["Limit", "Value"], have)
    out.append("")
    return out


# --- report --------------------------------------------------------------------

def render(d):
    info, warnings = read_cluster(d)
    present = [s for s in HVPERF_SUITES if os.path.exists(os.path.join(d, s + ".json"))]
    results = {}
    for s in present:
        data = load_json(os.path.join(d, s + ".json"))
        results[s] = (data or [{}])[0] if isinstance(data, list) else {}
    has_guest = os.path.isdir(os.path.join(d, "guest")) or os.path.exists(os.path.join(d, "guest.log"))

    out = ["# Harvester performance report", ""]
    out += ["- **Run**: `%s`" % os.path.basename(os.path.abspath(d))]
    for key, label in (("harvester", "Harvester"), ("architecture", "Architecture"), ("nodes", "Nodes"),
                       ("control_plane", "Control plane"), ("monitoring", "Monitoring addon"),
                       ("etcd_metrics", "etcd metrics"), ("harvester_perf", "harvester-perf commit"),
                       ("suites", "Suites requested")):
        if info.get(key):
            out.append("- **%s**: %s" % (label, info[key]))
    out.append("")
    if warnings:
        out += ["Preflight warnings:", ""] + ["- %s" % w for w in warnings] + [""]

    rows = []
    order = [s.strip() for s in info.get("suites", "").split(",") if s.strip()] or present + (["guest"] if has_guest else [])
    for s in order:
        if s == "guest":
            o = load_json(os.path.join(d, "guest", "overhead.json"))
            rows.append(["guest", "PASS" if o else "**FAILED**", "-",
                         "%+.1f%% overall VM overhead" % o["overall"]["overhead_pct"] if o and o.get("overall", {}).get("overhead_pct") is not None else "-"])
            continue
        r = results.get(s)
        if r is None:
            rows.append([s, "**not produced**", "-", "-"])
            continue
        states = [c.get("State") for c in cases(r)]
        if r.get("Err") and not states:
            status = "**ERROR**"
        elif any(x == "ERROR" for x in states) or r.get("Err"):
            status = "**ERROR**"
        elif states and all(x == "SKIP" for x in states):
            status = "SKIP"
        else:
            status = "PASS"
        tally = ", ".join("%d %s" % (states.count(x), x) for x in ("PASS", "SKIP", "ERROR") if states.count(x))
        note = r.get("Err") or "; ".join("%s: %s" % (c.get("CaseName"), (c.get("Err") or "")[:120])
                                         for c in cases(r) if c.get("State") in ("SKIP", "ERROR"))
        rows.append([s, status, dur(suite_span(r)) if states else "-", tally + (" (%s)" % note if note else "") if tally else (note or "-")])
    out += table(["Suite", "Status", "Duration", "Cases"], rows)
    out.append("")

    out += sec_limits(info)
    sections = {"node-capacity": sec_node_capacity, "resource-footprint": sec_footprint,
                "etcd-benchmark": sec_etcd, "density": sec_density}
    for s in order:
        if s == "guest":
            out += sec_guest(d)
        elif s in results:
            out += sections[s](results[s])
        if s == "guest":
            out += sec_sustained(d, info)

    raw = sorted(f for f in os.listdir(d) if f.endswith((".json", ".log", ".yaml", ".txt")) and f != "summary.md")
    out += ["---", "", "Raw results in this directory: %s%s." % (
        ", ".join("`%s`" % f for f in raw), ", and `guest/`" if has_guest else "")]
    return "\n".join(out) + "\n"


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    if len(args) != 1 or not os.path.isdir(args[0]):
        sys.exit("usage: report.py RESULTS_DIR [--stdout]")
    md = render(args[0])
    if "--stdout" in argv:
        sys.stdout.write(md)
    else:
        path = os.path.join(args[0], "summary.md")
        with open(path, "w") as fh:
            fh.write(md)
        print(path)


if __name__ == "__main__":
    main(sys.argv)
