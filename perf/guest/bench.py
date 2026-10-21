#!/usr/bin/env python3
"""In-guest workload benchmark. Runs INSIDE a Harvester VM, from cloud-init.

Shipped into the guest by perf/guest-bench.sh through cloud-init write_files,
and run as root by runcmd once the packages are installed. Standard library
only: Ubuntu's cloud image guarantees python3 (cloud-init is written in it) and
nothing else.

Two roles:

  peer   Start an iperf3 server and exit. It is the far end of the network
         tests, on another node, and otherwise stays idle so that it does not
         compete with the bench VM.
  bench  Run every workload in sequence -- never two at once -- and report.

Two modes, the same workloads:

  vm     Inside a Harvester VM (the default). Results go to the serial console.
  pod    In a plain pod on the same node, with no virtualization layer of its
         own -- the baseline the VM is measured against. Results go to stdout,
         i.e. the pod log. The pod sees every host CPU, so the program pins
         itself to --vcpus of them: without that, multi-threaded work would
         spread across the whole node under a CFS quota, which is not what 4
         vCPUs look like.

  bench.py bench [--peer IP] [--mode vm|pod] [--vcpus N] [--disk PATH] [--sustained SECONDS]
                 [--pgbench [--pg-dir DIR]]
  bench.py contend --index I --vms N --start EPOCH --seconds S --gap G [--prefill]
  bench.py peer  [--mode vm|pod]

Results leave the guest on its SERIAL CONSOLE, which the harness reads with
`kubectl logs <virt-launcher> -c guest-console-log`. That needs no SSH, no
guest credentials and no route into the pod network, so the same harness works
against any Harvester cluster from nothing but a kubeconfig. The console is
shared with the kernel and systemd, whose messages can land in the middle of a
line, so the payload is gzipped, base64'd, cut into numbered lines that each
carry a CRC, and sent three times, a couple of seconds apart. The harness
keeps any copy of each line whose CRC matches, repairs a line a message landed
inside, and checks the whole payload against a SHA-256.

PROFILE identifies the workload parameters. Change any parameter below and
bump it: results are only comparable within one profile.
"""

import base64
import glob
import gzip
import hashlib
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import time
import zlib

PROFILE = 1
DATA_DISK = "/dev/disk/by-id/virtio-hvgdata"
MODE = "vm"
VCPUS = os.cpu_count() or 1
IPERF_PORT = 5201

# Fixed workload parameters. Short enough that a run finishes in ~15 minutes,
# long enough that a single noisy second does not move the figure.
CPU_SECONDS = 30
MEM_SECONDS = 30
STRESS_SECONDS = 30
FIO_SECONDS = 60
FIO_RAMP = 5
NET_SECONDS = 30
PING_COUNT = 100
# Optional, outside PROFILE: a long 4-stream run sampled every NET_INTERVAL s.
# The 30 s tests above fit inside an EC2 instance's network burst; this one is
# long enough to drain it and show the sustained rate. 0 = not run.
SUSTAINED_SECONDS = 0
NET_INTERVAL = 10
# Optional, outside PROFILE: PostgreSQL's pgbench (its TPC-B-like default) with
# the database on the Longhorn data disk, run after fio has finished with the
# raw device. Client on the same machine over a Unix socket, so the network is
# not in it. Same distro build in both modes: Ubuntu 24.04's PostgreSQL 16.
PGBENCH = False
PG_DIR = ""            # pod: a filesystem PVC mounted here; VM: "" = format DATA_DISK
PG_SCALE = 100         # about 1.5 GB: larger than shared_buffers, smaller than RAM
PG_SECONDS = 120
PG_CLIENTS = (1, 8, 32)
PG_PORT = 5433         # not 5432, which the distro's own cluster may hold
PG_SETTINGS = {"shared_buffers": "1GB", "max_connections": "100", "max_wal_size": "4GB",
               "listen_addresses": "''", "unix_socket_directories": "/tmp", "port": str(PG_PORT)}
PG_STATE = {}


# --- console output ----------------------------------------------------------

def console_path():
    # x86 guests get a 16550 at ttyS0. aarch64 `virt` machines get a PL011 at
    # ttyAMA0 -- the same split this repo's image build hits.
    for dev in ("/dev/ttyAMA0", "/dev/ttyS0") if platform.machine() == "aarch64" else ("/dev/ttyS0",):
        if os.path.exists(dev):
            return dev
    return None


CONSOLE = None


def emit(line):
    """Write one line to the serial console, or to stdout if there is none.

    Not both: cloud-init's stdout also reaches the console, so writing to each
    would put every line on it twice.
    """
    global CONSOLE
    try:
        if CONSOLE is None:
            dev = console_path() if MODE == "vm" else None
            CONSOLE = open(dev, "w", buffering=1) if dev else False
        if CONSOLE:
            CONSOLE.write(line + "\n")
            CONSOLE.flush()
            return
    except OSError:
        CONSOLE = False
    print(line, flush=True)


def progress(stage):
    emit("HVG:P %s %s" % (time.strftime("%H:%M:%SZ", time.gmtime()), stage))


def send_payload(obj):
    raw = json.dumps(obj, sort_keys=True).encode()
    blob = base64.b64encode(gzip.compress(raw, 9)).decode()
    chunks = [blob[i:i + 72] for i in range(0, len(blob), 72)]
    digest = hashlib.sha256(blob.encode()).hexdigest()
    for copy in range(3):
        if copy:
            # Console noise comes in bursts (a unit starting, a kernel warning),
            # so spacing the copies out matters more than adding more of them.
            time.sleep(2)
        emit("HVG:BEGIN %d %s" % (len(chunks), digest))
        for i, chunk in enumerate(chunks):
            emit("HVG:D %d %08x %s" % (i, zlib.crc32(chunk.encode()) & 0xFFFFFFFF, chunk))
        emit("HVG:END")


# --- helpers -------------------------------------------------------------------

def run(cmd, timeout=None):
    """Run a command; return (rc, stdout, stderr). Never raises for the command,
    including when it does not exist (a pod has no systemd-analyze)."""
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=timeout)
    except FileNotFoundError:
        return 127, "", "%s: not found" % cmd[0]
    return p.returncode, p.stdout, p.stderr


def cpu_ticks():
    """(steal, total) jiffies summed over all CPUs, from /proc/stat.

    In a VM this is the guest's own view: time its vCPUs were runnable but the
    node ran something else. In a pod it is the NODE's view, because /proc/stat
    is not namespaced -- on a nested node, that is time AWS's hypervisor took.
    """
    fields = read("/proc/stat").split("\n", 1)[0].split()[1:]
    vals = [int(x) for x in fields[:8]] + [0] * (8 - len(fields[:8]))
    return vals[7], sum(vals)


def read(path, default=""):
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return default


def test(results, name, fn):
    """Run one workload, recording its result or its error -- never both lost."""
    progress("start " + name)
    t0 = time.time()
    # Wall-clock start, so the harness can line the test up with the node's
    # own steal samples (taken outside the guest, on the same NTP time).
    steal0, total0 = cpu_ticks()
    try:
        out = fn()
        out["error"] = None
    except Exception as exc:  # noqa: BLE001 -- one failed workload must not lose the rest
        out = {"error": "%s: %s" % (type(exc).__name__, exc)}
    out["t0"] = round(t0, 1)
    out["seconds"] = round(time.time() - t0, 1)
    steal1, total1 = cpu_ticks()
    out["steal_pct"] = round(100.0 * (steal1 - steal0) / (total1 - total0), 2) if total1 > total0 else None
    results[name] = out
    progress("done %s%s" % (name, " (error)" if out["error"] else ""))


def need(tool):
    if not shutil.which(tool):
        raise RuntimeError("%s is not installed (no package egress from the guest?)" % tool)


# --- system facts ----------------------------------------------------------------

def system_facts():
    facts = {
        "arch": platform.machine(),
        "kernel": platform.release(),
        "mode": MODE,
        "vcpus": VCPUS,
        "cpus_visible": os.cpu_count(),
        "cpus_pinned": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
        "mem_total_kib": int(re.search(r"MemTotal:\s+(\d+)", read("/proc/meminfo")).group(1)),
        "virt": run(["systemd-detect-virt"])[1].strip(),
        # Under nested virtualization the clocksource is a real confounder:
        # kvm-clock vs tsc changes the cost of every timestamp.
        "clocksource": read("/sys/devices/system/clocksource/clocksource0/current_clocksource"),
        "os_release": dict(re.findall(r'^(\w+)="?([^"\n]*)"?$', read("/etc/os-release"), re.M)),
        "uptime_at_start_s": float(read("/proc/uptime", "0 0").split()[0]),
        "packages": {},
    }
    rc, out, _ = run(["lscpu", "-J"])
    if rc == 0:
        # util-linux 2.38+ nests related fields under "children"; flatten.
        flat, stack = {}, list(json.loads(out).get("lscpu", []))
        while stack:
            f = stack.pop()
            stack.extend(f.get("children", []))
            if f.get("field"):
                flat[f["field"].rstrip(":")] = f.get("data")
        facts["lscpu"] = flat
    cpuinfo = read("/proc/cpuinfo")
    flags = re.search(r"^(?:flags|Features)\s*:\s*(.*)$", cpuinfo, re.M)
    facts["cpu_flags"] = flags.group(1).split() if flags else []
    rc, out, _ = run(["systemd-analyze", "time"])
    facts["systemd_analyze"] = out.strip() if rc == 0 else None
    for pkg in ("fio", "sysbench", "stress-ng", "iperf3"):
        rc, out, _ = run(["dpkg-query", "-W", "-f=${Version}", pkg])
        facts["packages"][pkg] = out if rc == 0 else None
    return facts


# --- workloads -----------------------------------------------------------------------

def sysbench_cpu(threads):
    def fn():
        need("sysbench")
        rc, out, err = run(["sysbench", "cpu", "--cpu-max-prime=20000",
                            "--threads=%d" % threads, "--time=%d" % CPU_SECONDS, "run"])
        if rc != 0:
            raise RuntimeError(err.strip() or out.strip())
        eps = float(re.search(r"events per second:\s*([\d.]+)", out).group(1))
        return {"threads": threads, "events_per_sec": eps}
    return fn


def sysbench_memory(block, mode, threads):
    def fn():
        need("sysbench")
        rc, out, err = run(["sysbench", "memory", "--memory-block-size=%s" % block,
                            "--memory-total-size=10000G", "--memory-oper=write",
                            "--memory-access-mode=%s" % mode, "--threads=%d" % threads,
                            "--time=%d" % MEM_SECONDS, "run"])
        if rc != 0:
            raise RuntimeError(err.strip() or out.strip())
        mibs = float(re.search(r"MiB transferred \(([\d.]+) MiB/sec\)", out).group(1))
        return {"block": block, "mode": mode, "threads": threads, "mib_per_sec": mibs}
    return fn


def stress(stressor, instances):
    # Chosen for what nested virtualization makes expensive, not for raw
    # compute: context switches and futex wake-ups cross vCPUs (IPIs, HLT
    # exits), and page faults take the shadowed-EPT path an L2 guest pays for.
    def fn():
        need("stress-ng")
        path = "/tmp/hvg-stress-%s.yaml" % stressor
        rc, out, err = run(["stress-ng", "--%s" % stressor, str(instances),
                            "--timeout", "%ds" % STRESS_SECONDS, "--metrics", "--yaml", path])
        if rc != 0:
            raise RuntimeError((err or out).strip()[-500:])
        text = read(path)
        # stress-ng's YAML is flat enough to read without a YAML parser:
        #   - stressor: switch
        #     bogo-ops: 123
        #     bogo-ops-per-second-real-time: 456.7
        block = re.search(r"-\s*stressor:\s*%s\s*\n((?:\s+[\w-]+:.*\n?)*)" % re.escape(stressor), text)
        if not block:
            raise RuntimeError("no metrics for %s in %s" % (stressor, path))
        metrics = dict(re.findall(r"^\s+([\w-]+):\s*(\S+)", block.group(1), re.M))
        real = next((v for k, v in metrics.items() if k.endswith("per-second-real-time")), None)
        return {"stressor": stressor, "instances": instances,
                "bogo_ops": float(metrics.get("bogo-ops", "nan")),
                "bogo_ops_per_sec_real": float(real) if real else None}
    return fn


FIO_JOBS = [
    # The first job writes the whole device. Longhorn volumes are thin, so
    # reading never-written blocks returns zeroes without touching a replica;
    # every later read job would otherwise measure nothing.
    ("seq-write-1m-qd16", ["--rw=write", "--bs=1m", "--iodepth=16", "--size=100%"]),
    ("seq-read-1m-qd16", ["--rw=read", "--bs=1m", "--iodepth=16"]),
    ("rand-read-4k-qd32", ["--rw=randread", "--bs=4k", "--iodepth=32"]),
    ("rand-write-4k-qd32", ["--rw=randwrite", "--bs=4k", "--iodepth=32"]),
    ("rand-read-4k-qd1", ["--rw=randread", "--bs=4k", "--iodepth=1"]),
    # A flush after every write: the pattern etcd's WAL and most databases use.
    ("rand-write-4k-qd1-fsync", ["--rw=randwrite", "--bs=4k", "--iodepth=1", "--fsync=1"]),
]


def fio_job(name, args, seconds=None):
    """seconds: run exactly this long with no ramp (contention phases must line
    up across VMs); None: the profile's FIO_SECONDS after FIO_RAMP."""
    def fn():
        need("fio")
        if not os.path.exists(DATA_DISK):
            raise RuntimeError("data disk %s not present" % DATA_DISK)
        dev = os.path.realpath(DATA_DISK)
        if seconds is not None:
            timed = ["--time_based", "--runtime=%d" % seconds]
        elif "--size=100%" in args:
            timed = []
        else:
            timed = ["--time_based", "--runtime=%d" % FIO_SECONDS, "--ramp_time=%d" % FIO_RAMP]
        rc, out, err = run(["fio", "--name=" + name, "--filename=" + dev,
                            "--ioengine=libaio", "--direct=1", "--numjobs=1",
                            "--group_reporting", "--output-format=json"] + args + timed)
        if rc != 0:
            raise RuntimeError(err.strip() or out.strip()[-500:])
        job = json.loads(out[out.index("{"):])["jobs"][0]
        side = job["write"] if "write" in args[0] else job["read"]
        pct = side.get("clat_ns", {}).get("percentile", {})
        return {
            "args": args,
            "iops": side["iops"],
            "bw_bytes": side["bw_bytes"],
            "lat_mean_us": side["lat_ns"]["mean"] / 1000.0,
            "clat_p50_us": pct.get("50.000000", 0) / 1000.0,
            "clat_p99_us": pct.get("99.000000", 0) / 1000.0,
            "clat_p999_us": pct.get("99.900000", 0) / 1000.0,
            "sync_p99_us": job.get("sync", {}).get("lat_ns", {}).get("percentile", {}).get("99.000000", 0) / 1000.0,
        }
    return fn


def pg_bin(name):
    found = sorted(glob.glob("/usr/lib/postgresql/*/bin/" + name))
    if not found:
        raise RuntimeError("%s not found under /usr/lib/postgresql (postgresql not installed?)" % name)
    return found[-1]


def as_postgres(cmd, timeout=None):
    # PostgreSQL refuses to run as root, and this program runs as root.
    return run(["runuser", "-u", "postgres", "--"] + cmd, timeout=timeout)


def pg_sql(query):
    rc, out, err = as_postgres([pg_bin("psql"), "-h", "/tmp", "-p", str(PG_PORT), "-d", "bench",
                                "-At", "-c", query])
    return out.strip() if rc == 0 else None


def pg_setup():
    """A fresh cluster on the data disk, initialized to PG_SCALE."""
    def fn():
        os.chdir("/")
        # The distro's own cluster, if its package started one: not ours, and
        # it would compete for the same CPUs.
        for conf in glob.glob("/etc/postgresql/*/main"):
            run(["pg_ctlcluster", conf.split("/")[3], "main", "stop"])
        mount = PG_DIR or "/pgdata"
        if not PG_DIR:
            # VM: the raw data disk fio used becomes an ext4 filesystem.
            dev = os.path.realpath(DATA_DISK)
            rc, _, err = run(["mkfs.ext4", "-F", "-q", dev], timeout=600)
            if rc != 0:
                raise RuntimeError("mkfs.ext4: " + err.strip())
            os.makedirs(mount, exist_ok=True)
            rc, _, err = run(["mount", dev, mount])
            if rc != 0:
                raise RuntimeError("mount: " + err.strip())
            PG_STATE["mounted"] = mount
        data = os.path.join(mount, "pg")
        if os.path.exists(data):
            shutil.rmtree(data)
        os.makedirs(data)
        shutil.chown(data, "postgres", "postgres")
        os.chmod(data, 0o700)
        rc, out, err = as_postgres([pg_bin("initdb"), "-D", data, "-U", "postgres",
                                    "--auth=trust", "-E", "UTF8"], timeout=300)
        if rc != 0:
            raise RuntimeError("initdb: " + (err or out).strip()[-300:])
        opts = " ".join("-c %s=%s" % kv for kv in PG_SETTINGS.items())
        # The log goes inside the data directory: the mount's root belongs to
        # root, and the server runs as postgres.
        rc, out, err = as_postgres([pg_bin("pg_ctl"), "-D", data, "-l", os.path.join(data, "server.log"),
                                    "-w", "-t", "120", "-o", opts, "start"], timeout=180)
        if rc != 0:
            raise RuntimeError("pg_ctl start: " + (err or out).strip()[-300:])
        PG_STATE["data"] = data
        rc, out, err = as_postgres([pg_bin("createdb"), "-h", "/tmp", "-p", str(PG_PORT), "bench"])
        if rc != 0:
            raise RuntimeError("createdb: " + (err or out).strip()[-300:])
        t0 = time.time()
        rc, out, err = as_postgres([pg_bin("pgbench"), "-h", "/tmp", "-p", str(PG_PORT), "-i",
                                    "-s", str(PG_SCALE), "-q", "bench"], timeout=1800)
        if rc != 0:
            raise RuntimeError("pgbench -i: " + (err or out).strip()[-300:])
        size = pg_sql("select pg_database_size('bench')")
        return {"version": pg_sql("show server_version"), "scale": PG_SCALE,
                "settings": PG_SETTINGS, "init_seconds": round(time.time() - t0, 1),
                "db_bytes": int(size) if size and size.isdigit() else None,
                "wal_sync_method": pg_sql("show wal_sync_method"),
                "filesystem": "ext4, guest-formatted data disk" if not PG_DIR else "ext4 PVC at " + PG_DIR}
    return fn


def pgbench_run(clients):
    def fn():
        if "data" not in PG_STATE:
            raise RuntimeError("no database: pg-init failed")
        threads = min(clients, VCPUS)
        rc, out, err = as_postgres([pg_bin("pgbench"), "-h", "/tmp", "-p", str(PG_PORT),
                                    "-c", str(clients), "-j", str(threads),
                                    "-T", str(PG_SECONDS), "bench"], timeout=PG_SECONDS + 600)
        text = out + "\n" + err
        m = re.search(r"tps = ([\d.]+) \((?:without initial connection time|excluding connections establishing)\)", text)
        if rc != 0 or not m:
            raise RuntimeError((err or out).strip()[-300:] or "pgbench rc=%d" % rc)
        lat = re.search(r"latency average = ([\d.]+) ms", text)
        txn = re.search(r"number of transactions actually processed: (\d+)", text)
        failed = re.search(r"number of failed transactions: (\d+)", text)
        return {"clients": clients, "threads": threads, "seconds": PG_SECONDS,
                "tps": float(m.group(1)),
                "latency_avg_ms": float(lat.group(1)) if lat else None,
                "transactions": int(txn.group(1)) if txn else None,
                "failed": int(failed.group(1)) if failed else 0}
    return fn


def pg_teardown():
    if "data" in PG_STATE:
        as_postgres([pg_bin("pg_ctl"), "-D", PG_STATE["data"], "-m", "fast", "-w", "stop"], timeout=120)
    if "mounted" in PG_STATE:
        run(["umount", PG_STATE["mounted"]])


def wait_for_peer(peer, timeout=600):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection((peer, IPERF_PORT), timeout=5):
                return
        except OSError:
            time.sleep(5)
    raise RuntimeError("peer %s:%d never accepted a connection" % (peer, IPERF_PORT))


def iperf(peer, streams, reverse):
    def fn():
        need("iperf3")
        wait_for_peer(peer)
        cmd = ["iperf3", "-c", peer, "-p", str(IPERF_PORT), "-t", str(NET_SECONDS),
               "-P", str(streams), "-J"]
        if reverse:
            cmd.append("-R")
        rc, out, err = run(cmd, timeout=NET_SECONDS + 120)
        data = json.loads(out) if out.strip().startswith("{") else {}
        if rc != 0 or "error" in data:
            raise RuntimeError(data.get("error") or err.strip() or "iperf3 rc=%d" % rc)
        end = data["end"]
        return {"streams": streams, "reverse": reverse,
                "gbit_per_sec": end["sum_received"]["bits_per_second"] / 1e9,
                "retransmits": end.get("sum_sent", {}).get("retransmits"),
                "tcp_mss": data.get("start", {}).get("tcp_mss_default")}
    return fn


def mean(xs):
    return sum(xs) / len(xs) if xs else None


def iperf_sustained(peer, streams, seconds):
    """Throughput every NET_INTERVAL s for `seconds`, plus where it settled.

    drop_at_s is the start of the first interval from which every remaining
    interval stays below 80% of the first minute's mean: the point a burst
    allowance ran out, if it did.
    """
    def fn():
        need("iperf3")
        wait_for_peer(peer)
        cmd = ["iperf3", "-c", peer, "-p", str(IPERF_PORT), "-t", str(seconds),
               "-P", str(streams), "-i", str(NET_INTERVAL), "-J"]
        rc, out, err = run(cmd, timeout=seconds + 180)
        data = json.loads(out) if out.strip().startswith("{") else {}
        if rc != 0 or "error" in data:
            raise RuntimeError(data.get("error") or err.strip() or "iperf3 rc=%d" % rc)
        series = [round(iv["sum"]["bits_per_second"] / 1e9, 3) for iv in data.get("intervals", [])
                  if iv.get("sum", {}).get("seconds", 0) >= NET_INTERVAL / 2]
        per_min = max(1, 60 // NET_INTERVAL)
        first = mean(series[:per_min])
        last = mean(series[-2 * per_min:])
        drop_at = None
        if first:
            for i in range(len(series)):
                if all(x < 0.8 * first for x in series[i:]):
                    drop_at = i * NET_INTERVAL
                    break
        end = data["end"]
        return {"streams": streams, "duration_s": seconds, "interval_s": NET_INTERVAL,
                "gbit_per_sec": end["sum_received"]["bits_per_second"] / 1e9,
                "first_60s_gbit": first, "last_120s_gbit": last,
                "min_interval_gbit": min(series) if series else None,
                "max_interval_gbit": max(series) if series else None,
                "drop_at_s": drop_at, "series_gbit": series,
                "retransmits": end.get("sum_sent", {}).get("retransmits")}
    return fn


def ping(peer):
    def fn():
        rc, out, err = run(["ping", "-c", str(PING_COUNT), "-i", "0.2", "-q", peer],
                           timeout=PING_COUNT + 60)
        m = re.search(r"= ([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+) ms", out)
        if rc != 0 or not m:
            raise RuntimeError(err.strip() or out.strip()[-300:])
        lo, avg, hi, mdev = (float(x) for x in m.groups())
        return {"count": PING_COUNT, "rtt_min_ms": lo, "rtt_avg_ms": avg,
                "rtt_max_ms": hi, "rtt_mdev_ms": mdev}
    return fn


# --- roles ---------------------------------------------------------------------------

def role_peer():
    progress("peer starting iperf3")
    need("iperf3")
    if MODE == "pod":
        # A pod lives as long as its process, so the server stays in the
        # foreground. READY goes out first; iperf3 binds within milliseconds,
        # and the bench side retries its connection for ten minutes anyway.
        emit("HVG:READY")
        os.execvp("iperf3", ["iperf3", "-s", "-p", str(IPERF_PORT)])
    rc, _, err = run(["iperf3", "-s", "-D", "-p", str(IPERF_PORT)])
    if rc != 0:
        emit("HVG:FAIL iperf3 server: %s" % err.strip())
        return 1
    emit("HVG:READY")
    return 0


def pin_cpus(n):
    """Restrict this process, and everything it starts, to n CPUs.

    Skips CPU 0, which takes most of a node's housekeeping interrupts, when
    there are enough CPUs. Linux numbers the first hardware thread of every
    core before any SMT sibling, so the lowest numbers are distinct cores.
    """
    allowed = sorted(os.sched_getaffinity(0))
    if len(allowed) <= n:
        return allowed
    chosen = allowed[1:n + 1] if len(allowed) > n + 1 else allowed[:n]
    os.sched_setaffinity(0, chosen)
    return chosen


def role_bench(peer):
    if MODE == "vm":
        # Keep kernel messages off the console while the payload is on it.
        run(["dmesg", "-n", "1"])
    else:
        pin_cpus(VCPUS)
    started = time.time()
    progress("bench starting, profile %d, mode %s, %d vCPU" % (PROFILE, MODE, VCPUS))
    results = {}
    payload = {"schema": 1, "profile": PROFILE, "role": "bench", "mode": MODE, "peer": peer,
               "sustained_seconds": SUSTAINED_SECONDS, "pgbench": PGBENCH,
               "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started))}
    try:
        payload["system"] = system_facts()
    except Exception as exc:  # noqa: BLE001
        payload["system"] = {"error": str(exc), "vcpus": VCPUS, "mode": MODE}
    n = VCPUS

    test(results, "cpu-1t", sysbench_cpu(1))
    test(results, "cpu-all", sysbench_cpu(n))
    test(results, "mem-seq-1m-1t", sysbench_memory("1M", "seq", 1))
    test(results, "mem-seq-1m-all", sysbench_memory("1M", "seq", n))
    test(results, "mem-rnd-4k-1t", sysbench_memory("4K", "rnd", 1))
    for stressor in ("switch", "futex", "fault"):
        test(results, "stress-%s" % stressor, stress(stressor, n))
    for name, args in FIO_JOBS:
        test(results, "fio-" + name, fio_job(name, args))
    if PGBENCH:
        test(results, "pg-init", pg_setup())
        for c in PG_CLIENTS:
            test(results, "pg-c%d" % c, pgbench_run(c))
        pg_teardown()
    if peer:
        test(results, "net-tcp-1", iperf(peer, 1, False))
        test(results, "net-tcp-4", iperf(peer, 4, False))
        test(results, "net-tcp-1-reverse", iperf(peer, 1, True))
        test(results, "net-ping", ping(peer))
        if SUSTAINED_SECONDS > 0:
            test(results, "net-tcp-4-sustained", iperf_sustained(peer, 4, SUSTAINED_SECONDS))

    payload["tests"] = results
    payload["finished"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    payload["seconds"] = round(time.time() - started, 1)
    progress("sending results")
    send_payload(payload)
    emit("HVG:DONE")
    # A copy for anyone who logs in later. After the send, and best-effort:
    # nothing on the guest's own disk may stand between the run and its results.
    try:
        with open("/root/hvg-results.json", "w") as fh:
            json.dump(payload, fh, indent=2, sort_keys=True)
    except OSError:
        pass
    return 0


# --- contention -----------------------------------------------------------------
# Several VMs, each with its own Longhorn data disk, writing on one wall-clock
# schedule. Every VM gets the same absolute start time from the harness, so the
# phases line up across guests to within clock skew (kvm-clock, NTP).
CONTEND_RANDW = ["--rw=randwrite", "--bs=4k", "--iodepth=32"]
CONTEND_SEQW = ["--rw=write", "--bs=1m", "--iodepth=16"]
# Every block written once before the schedule, so the phases measure
# overwrites, not the first write to a thin Longhorn volume's unallocated space.
CONTEND_FILL = ["--rw=write", "--bs=1m", "--iodepth=16", "--size=100%"]


def contend_schedule(start, seconds, gap):
    """(phase, planned start, which VMs run it, fio args). VM 0 alone first, as
    the same-run reference; then every VM together."""
    step = seconds + gap
    return [("solo-randwrite", start, "first", CONTEND_RANDW),
            ("all-randwrite", start + step, "all", CONTEND_RANDW),
            ("all-seqwrite", start + 2 * step, "all", CONTEND_SEQW)]


def role_contend(index, vms, start, seconds, gap, prefill=False):
    if MODE == "vm":
        run(["dmesg", "-n", "1"])
    payload = {"schema": 1, "profile": PROFILE, "role": "contend", "mode": MODE, "index": index,
               "vms": vms, "start": start, "phase_seconds": seconds, "gap": gap, "prefill": prefill,
               "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    try:
        payload["system"] = system_facts()
    except Exception as exc:  # noqa: BLE001
        payload["system"] = {"error": str(exc), "vcpus": VCPUS, "mode": MODE}
    progress("contend %d of %d ready, first phase in %ds" % (index, vms, int(start - time.time())))
    results = {}
    if prefill:
        # Starts as soon as this VM is up, not on the schedule: VMs boot at
        # different times, and the fill only has to finish before the first phase.
        test(results, "prefill", fio_job("prefill", CONTEND_FILL))
        results["prefill"]["finished_before_start"] = time.time() <= start
    for name, t0, who, args in contend_schedule(start, seconds, gap):
        if who == "first" and index != 0:
            continue
        wait = t0 - time.time()
        if wait > 0:
            time.sleep(wait)
        late = round(max(0.0, time.time() - t0), 1)
        test(results, name, fio_job(name, args, seconds))
        results[name]["planned_t0"] = t0
        results[name]["late_s"] = late
    payload["tests"] = results
    payload["finished"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    progress("sending results")
    send_payload(payload)
    emit("HVG:DONE")
    return 0


def opt(argv, name, default):
    return argv[argv.index(name) + 1] if name in argv[:-1] else default


def main(argv):
    global MODE, VCPUS, DATA_DISK, SUSTAINED_SECONDS, PGBENCH, PG_DIR
    if len(argv) < 2 or argv[1] not in ("bench", "peer", "contend"):
        print("usage: bench.py bench [--peer IP] [--mode vm|pod] [--vcpus N] [--disk PATH] [--sustained SECONDS]\n"
              "                      [--pgbench [--pg-dir DIR]]\n"
              "       bench.py contend --index I --vms N --start EPOCH --seconds S --gap G [--prefill]\n"
              "       bench.py peer [--mode vm|pod]", file=sys.stderr)
        return 2
    MODE = opt(argv, "--mode", "vm")
    if MODE not in ("vm", "pod"):
        print("--mode must be vm or pod", file=sys.stderr)
        return 2
    # Thread counts and per-vCPU figures use this, never os.cpu_count(): a pod
    # sees every CPU on the node.
    VCPUS = int(opt(argv, "--vcpus", os.cpu_count() or 1))
    DATA_DISK = opt(argv, "--disk", DATA_DISK)
    SUSTAINED_SECONDS = int(opt(argv, "--sustained", "0"))
    PGBENCH = "--pgbench" in argv
    PG_DIR = opt(argv, "--pg-dir", "")
    if argv[1] == "peer":
        return role_peer()
    if argv[1] == "contend":
        try:
            return role_contend(int(opt(argv, "--index", "0")), int(opt(argv, "--vms", "1")),
                                float(opt(argv, "--start", "0")), int(opt(argv, "--seconds", "120")),
                                int(opt(argv, "--gap", "30")), "--prefill" in argv)
        except Exception as exc:  # noqa: BLE001
            emit("HVG:FAIL %s: %s" % (type(exc).__name__, exc))
            return 1
    peer = opt(argv, "--peer", "")
    try:
        return role_bench(peer)
    except Exception as exc:  # noqa: BLE001 -- say so on the console, or the harness waits out its timeout
        emit("HVG:FAIL %s: %s" % (type(exc).__name__, exc))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
