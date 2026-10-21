#!/usr/bin/env python3
"""Harness-side helper for perf/guest-bench.sh. Python 3.9+, standard library only.

  hvg.py nodes                       nodes JSON on stdin -> one TSV line per node
  hvg.py meta                        run metadata from the environment -> JSON
  hvg.py imagestatus                 image JSON on stdin -> "imported retry progress sc"
  hvg.py image NAME NS URL           VirtualMachineImage manifest
  hvg.py userdata ROLE BENCH_PY [PEER_IP]
                                     cloud-config for the guest
  hvg.py vm NAME NS ROLE NODE IMAGE_NS/IMAGE IMAGE_SC DATA_SC VCPUS MEM ROOT DATA SECRET ARCH RUN_ID
                                     Harvester-style VirtualMachine manifest
  hvg.py pvc NAME NS SC SIZE [MODE]  PVC for the pod-mode data disk (Block, or Filesystem for pgbench)
  hvg.py pod NAME NS ROLE NODE IMAGE CONFIGMAP VCPUS MEM [PVC] [PEER_IP]
                                     pod-mode bench or peer: same workloads, no VM layer
  hvg.py sampler NAME NS NODE IMAGE  pod that logs the node's /proc/stat steal every 5 s
  hvg.py steal SAMPLER_LOG RESULT_JSON OUT_JSON
                                     node steal % during each test, from the sampler
  hvg.py throttle CG_LOG RESULT_JSON OUT_JSON
                                     the bench container's CPU use and quota
                                     throttling during each test
  hvg.py status CONSOLE_LOG          done | fail:<why> | ready | running:<stage> | none
  hvg.py decode CONSOLE_LOG OUT_JSON reassemble the framed payload bench.py sent
  hvg.py summary DIR [DIR...]        key figures; with several DIRs, a comparison
  hvg.py quota DIR                   CPU used and quota throttling per test, per mode
  hvg.py podmonitor NS               PodMonitor that scrapes etcd during a contention run
  hvg.py promq START SECONDS GAP     Prometheus queries for each contention phase window
  hvg.py contention DIR              contention phases: totals, per-VM spread, etcd, node disks
  hvg.py overhead DIR [DIR...]       VM overhead against the pod baseline, per cluster;
                                     with several DIRs, how each compares to the first

Manifests are emitted as JSON, which `kubectl apply -f -` accepts, so nothing is
templated through the shell.
"""

import base64
import gzip
import hashlib
import json
import math
import re
import sys
import zlib


# --- cluster facts -------------------------------------------------------------

def cmd_nodes():
    """name, arch, ready, schedulable, cpu allocatable, InternalIP, roles."""
    for n in json.load(sys.stdin)["items"]:
        meta, spec, status = n["metadata"], n.get("spec", {}), n.get("status", {})
        labels = meta.get("labels", {})
        ready = any(c["type"] == "Ready" and c["status"] == "True" for c in status.get("conditions", []))
        ip = next((a["address"] for a in status.get("addresses", []) if a["type"] == "InternalIP"), "")
        roles = ",".join(sorted(k.split("/", 1)[1] for k in labels
                                if k.startswith("node-role.kubernetes.io/"))) or "worker"
        print("\t".join([meta["name"], labels.get("kubernetes.io/arch", "?"),
                         "ready" if ready else "notready",
                         "cordoned" if spec.get("unschedulable") else "schedulable",
                         status.get("allocatable", {}).get("cpu", "?"), ip, roles]))


def cmd_meta():
    """Run metadata, taken from the environment so no value is ever quoted by a shell."""
    import os
    e = os.environ.get
    params = e("DATA_SC_PARAMS", "")
    try:
        params = json.loads(params) if params else {}
    except ValueError:
        pass
    print(json.dumps({
        "label": e("LABEL", ""), "run_id": e("RUN_ID", ""), "harvester": e("HARVESTER", ""),
        "kubernetes": e("KUBE", ""), "arch": e("ARCH", ""), "vcpus": int(e("VCPUS", "0")),
        "memory": e("MEMORY", ""), "data_size": e("DATA_SIZE", ""),
        "data_storage_class": e("DATA_SC", ""), "data_storage_class_parameters": params,
        "bench_node": e("BENCH_NODE", ""), "peer_node": e("PEER_NODE", ""),
        "same_node": e("BENCH_NODE") == e("PEER_NODE"), "image_url": e("IMAGE_URL", ""),
        "overcommit_config": e("OVERCOMMIT", ""),
        "vm_net_multiqueue": e("MULTIQUEUE", "false") == "true",
        "vm_cpu_limit": e("VM_CPU_LIMIT") or e("VCPUS", ""),
        "sustained_seconds": int(e("SUSTAINED") or 0),
        "pgbench": e("PGBENCH") == "true",
        "contention_vms": int(e("CONTENTION") or 0),
        "contention_start": float(e("CONTENTION_START") or 0),
        "contention_seconds": int(e("CONTENTION_SECONDS") or 0),
        "contention_gap": int(e("CONTENTION_GAP") or 0),
        "contention_nodes": json.loads(e("CONTENTION_NODES") or "{}"),
        "contention_prefill": e("CONTENTION_PREFILL") == "true",
    }, indent=2))


def cmd_imagestatus():
    """Four whitespace-free fields, "-" when absent, so `read` can never misalign."""
    try:
        status = json.load(sys.stdin).get("status", {})
    except ValueError:
        status = {}
    cond = {c.get("type"): c.get("status") for c in status.get("conditions", [])}
    print(cond.get("Imported") or "-", cond.get("RetryLimitExceeded") or "-",
          status.get("progress", 0), status.get("storageClassName") or "-")


# --- manifests -----------------------------------------------------------------

def cmd_image(name, ns, url):
    print(json.dumps({
        "apiVersion": "harvesterhci.io/v1beta1",
        "kind": "VirtualMachineImage",
        "metadata": {"name": name, "namespace": ns,
                     "labels": {"perf.harvester-aws/guest-bench": "true"}},
        "spec": {"displayName": name, "sourceType": "download", "url": url,
                 "backend": "backingimage", "retry": 3},
    }))


def cmd_userdata(role, bench_py, peer=""):
    import os
    with open(bench_py, "rb") as fh:
        program = base64.b64encode(fh.read()).decode()
    args = ["python3", "/opt/hvg/bench.py", role] + (["--peer", peer] if peer else [])
    if role == "bench" and int(os.environ.get("SUSTAINED") or 0) > 0:
        args += ["--sustained", os.environ["SUSTAINED"]]
    packages = ["fio", "sysbench", "stress-ng", "iperf3"]
    if role == "contend":
        e = os.environ.get
        args = ["python3", "/opt/hvg/bench.py", "contend", "--index", e("CONTEND_INDEX", "0"),
                "--vms", e("CONTEND_VMS", "1"), "--start", e("CONTEND_START", "0"),
                "--seconds", e("CONTEND_SECONDS", "120"), "--gap", e("CONTEND_GAP", "30")]
        if e("CONTEND_PREFILL") == "true":
            args.append("--prefill")
        packages = ["fio"]
    if role == "bench" and os.environ.get("PGBENCH") == "true":
        args += ["--pgbench"]
        packages.append("postgresql")
    # JSON is valid YAML, so the cloud-config body is emitted as JSON after the
    # header: no indentation rules to get wrong and no quoting of the payload.
    body = {
        "package_update": True,
        "packages": packages,
        "write_files": [{"path": "/opt/hvg/bench.py", "permissions": "0755",
                         "encoding": "b64", "content": program}],
        "runcmd": [args],
    }
    sys.stdout.write("#cloud-config\n" + json.dumps(body) + "\n")


def cmd_vm(name, ns, role, node, image_id, image_sc, data_sc, vcpus, mem, root, data,
           secret, arch, run_id):
    import os
    vcpus = int(vcpus)
    pvc = lambda disk, size, sc, ann: {  # noqa: E731
        "metadata": {"name": "%s-%s" % (name, disk), "annotations": ann},
        "spec": {"accessModes": ["ReadWriteMany"], "volumeMode": "Block",
                 "resources": {"requests": {"storage": size}}, "storageClassName": sc},
    }
    # The same shape the Harvester UI and the upstream e2e suite produce: PVCs
    # declared in harvesterhci.io/volumeClaimTemplates, which Harvester's VM
    # controller creates, rather than KubeVirt dataVolumeTemplates.
    claims = [pvc("rootdisk", root, image_sc, {"harvesterhci.io/imageId": image_id}),
              pvc("datadisk", data, data_sc, {})]
    domain = {
        "cpu": {"cores": vcpus, "sockets": 1, "threads": 1},
        # The limit covers the whole virt-launcher compute container: the vCPU
        # threads AND QEMU's emulator and vhost-net threads. VM_CPU_LIMIT above
        # the vCPU count gives those threads headroom; default is the count.
        "resources": {"limits": {"cpu": os.environ.get("VM_CPU_LIMIT") or str(vcpus), "memory": mem}},
        "features": {"acpi": {"enabled": True}},
        "devices": {
            "disks": [
                {"name": "rootdisk", "disk": {"bus": "virtio"}, "bootOrder": 1},
                # The serial gives the guest a stable /dev/disk/by-id name, so
                # fio never depends on probe order.
                {"name": "datadisk", "disk": {"bus": "virtio"}, "serial": "hvgdata"},
                {"name": "cloudinitdisk", "disk": {"bus": "virtio"}},
            ],
            "interfaces": [{"name": "default", "model": "virtio", "masquerade": {}}],
            # The results channel. Adds the guest-console-log sidecar to the
            # virt-launcher pod, whose log is the guest's serial console.
            "logSerialConsole": True,
        },
    }
    # One virtio-net queue per vCPU instead of one in total, so the guest can
    # spread streams over several vhost threads. Off by default, as in Harvester.
    if os.environ.get("MULTIQUEUE") == "true":
        domain["devices"]["networkInterfaceMultiqueue"] = True
    if arch == "arm64":
        # Harvester's own arm64 default, stated so the two architectures'
        # manifests differ only where they must.
        domain["firmware"] = {"bootloader": {"efi": {"secureBoot": False}}}
    print(json.dumps({
        "apiVersion": "kubevirt.io/v1",
        "kind": "VirtualMachine",
        "metadata": {
            "name": name, "namespace": ns,
            "labels": {"harvesterhci.io/creator": "harvester", "harvesterhci.io/os": "ubuntu",
                       "perf.harvester-aws/guest-bench": "true"},
            "annotations": {"harvesterhci.io/volumeClaimTemplates": json.dumps(claims),
                            "field.cattle.io/description": "harvester-aws guest-bench %s (%s)" % (role, run_id)},
        },
        "spec": {
            "runStrategy": "RerunOnFailure",
            "template": {
                "metadata": {"labels": {"harvesterhci.io/vmName": name,
                                        "perf.harvester-aws/role": role}},
                "spec": {
                    "hostname": name,
                    "nodeSelector": {"kubernetes.io/hostname": node},
                    "evictionStrategy": "LiveMigrateIfPossible",
                    "domain": domain,
                    "networks": [{"name": "default", "pod": {}}],
                    "volumes": [
                        {"name": "rootdisk", "persistentVolumeClaim": {"claimName": "%s-rootdisk" % name}},
                        {"name": "datadisk", "persistentVolumeClaim": {"claimName": "%s-datadisk" % name}},
                        {"name": "cloudinitdisk", "cloudInitNoCloud": {"secretRef": {"name": secret}}},
                    ],
                },
            },
        },
    }))


# Packages for the pod. The VM gets the same four from cloud-init; a container
# image also lacks python3 and ping, which the cloud image ships with.
POD_PACKAGES = "python3 fio sysbench stress-ng iperf3 iputils-ping"


def cmd_pvc(name, ns, sc, size, mode="Block"):
    print(json.dumps({
        "apiVersion": "v1", "kind": "PersistentVolumeClaim",
        "metadata": {"name": name, "namespace": ns,
                     "labels": {"perf.harvester-aws/guest-bench": "true"}},
        # Block, like the VM's data disk, so fio sees a raw Longhorn device in
        # both modes and the only difference is the virtio and QEMU layer.
        "spec": {"accessModes": ["ReadWriteOnce"], "volumeMode": mode,
                 "resources": {"requests": {"storage": size}}, "storageClassName": sc},
    }))


def cmd_pod(name, ns, role, node, image, configmap, vcpus, mem, pvc="", peer=""):
    args = ["python3", "/opt/hvg/bench.py", role, "--mode", "pod", "--vcpus", vcpus]
    if pvc:
        args += ["--disk", "/dev/hvgdata"]
    if peer:
        args += ["--peer", peer]
    import os
    if role == "bench" and int(os.environ.get("SUSTAINED") or 0) > 0:
        args += ["--sustained", os.environ["SUSTAINED"]]
    pg_pvc = os.environ.get("PG_PVC", "") if role == "bench" and os.environ.get("PGBENCH") == "true" else ""
    packages = POD_PACKAGES
    if pg_pvc:
        # The VM formats its data disk itself; a pod cannot mount a block
        # device without privileges that would skew the baseline, so its
        # database gets a filesystem-mode PVC of the same storage class, which
        # Longhorn formats ext4.
        args += ["--pgbench", "--pg-dir", "/pgdata"]
        packages += " postgresql"
    script = ("apt-get update -qq && apt-get install -y -qq --no-install-recommends %s >/dev/null"
              " && exec %s" % (packages, " ".join(args)))
    container = {
        "name": "bench", "image": image, "command": ["bash", "-c", script],
        "env": [{"name": "DEBIAN_FRONTEND", "value": "noninteractive"}],
        # Requests equal to limits: Guaranteed QoS, the same CPU quota and
        # memory a VM of this size is given.
        "resources": {"requests": {"cpu": vcpus, "memory": mem},
                      "limits": {"cpu": vcpus, "memory": mem}},
        "volumeMounts": [{"name": "program", "mountPath": "/opt/hvg", "readOnly": True}],
    }
    volumes = [{"name": "program", "configMap": {"name": configmap}}]
    if pvc:
        container["volumeDevices"] = [{"name": "data", "devicePath": "/dev/hvgdata"}]
        volumes.append({"name": "data", "persistentVolumeClaim": {"claimName": pvc}})
    if pg_pvc:
        container["volumeMounts"].append({"name": "pgdata", "mountPath": "/pgdata"})
        volumes.append({"name": "pgdata", "persistentVolumeClaim": {"claimName": pg_pvc}})
    print(json.dumps({
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": name, "namespace": ns,
                     "labels": {"perf.harvester-aws/guest-bench": "true",
                                "perf.harvester-aws/role": "pod-" + role}},
        "spec": {"nodeSelector": {"kubernetes.io/hostname": node}, "restartPolicy": "Never",
                 "terminationGracePeriodSeconds": 5, "containers": [container], "volumes": volumes},
    }))


def cmd_sampler(name, ns, node, image):
    # /proc/stat is not namespaced, so any pod reads the node's own counters.
    # Field 8 of the aggregate "cpu" line is steal: on a nested node, time the
    # node's vCPUs wanted to run but AWS's hypervisor ran something else --
    # overhead the node's own CPU accounting never shows as busy.
    loop = ('while :; do read -r _ u n s i w q sq st _ < /proc/stat; '
            'echo "HVG:S $(date +%s) $st $((u+n+s+i+w+q+sq+st))"; sleep 5; done')
    print(json.dumps({
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": name, "namespace": ns,
                     "labels": {"perf.harvester-aws/guest-bench": "true",
                                "perf.harvester-aws/role": "sampler"}},
        "spec": {"nodeSelector": {"kubernetes.io/hostname": node}, "restartPolicy": "Always",
                 "terminationGracePeriodSeconds": 1,
                 "containers": [{"name": "sampler", "image": image, "command": ["bash", "-c", loop],
                                 "resources": {"requests": {"cpu": "10m", "memory": "16Mi"}}}]},
    }))


def cmd_steal(sampler_log, result_json, out_json):
    samples = []
    for line in console_lines(sampler_log):
        m = re.search(r"HVG:S (\d+) (\d+) (\d+)", line)
        if m:
            samples.append(tuple(int(x) for x in m.groups()))
    with open(result_json) as fh:
        tests = json.load(fh).get("tests", {})
    out = {}
    for name, t in tests.items():
        if t.get("t0") is None or not samples:
            continue
        t0, t1 = t["t0"], t["t0"] + t.get("seconds", 0)
        # The last sample at or before the start and the first at or after the
        # end bracket the test; 5 s sampling against 30-70 s tests.
        before = [x for x in samples if x[0] <= t0]
        after = [x for x in samples if x[0] >= t1]
        if not before or not after:
            continue
        (_, s0, n0), (_, s1, n1) = before[-1], after[0]
        out[name] = round(100.0 * (s1 - s0) / (n1 - n0), 2) if n1 > n0 else None
    with open(out_json, "w") as fh:
        json.dump(out, fh, indent=2, sort_keys=True)


def cmd_throttle(cg_log, result_json, out_json):
    """CPU quota during each test, from the bench container's own cgroup.

    Lines are `HVG:C <epoch> <usage_usec> <nr_periods> <nr_throttled> <throttled_usec>`,
    sampled every 5 s from cpu.stat. For the VM that container is virt-launcher's
    compute container, so usage includes QEMU's emulator and vhost-net threads,
    not only the vCPUs. Same bracketing as cmd_steal.
    """
    samples = []
    for line in console_lines(cg_log):
        m = re.search(r"HVG:C (\d+) (\d+) (\d+) (\d+) (\d+)", line)
        if m:
            samples.append(tuple(int(x) for x in m.groups()))
    with open(result_json) as fh:
        tests = json.load(fh).get("tests", {})
    out = {}
    for name, t in tests.items():
        if t.get("t0") is None or not samples:
            continue
        t0, t1 = t["t0"], t["t0"] + t.get("seconds", 0)
        before = [x for x in samples if x[0] <= t0]
        after = [x for x in samples if x[0] >= t1]
        if not before or not after:
            continue
        a, b = before[-1], after[0]
        wall = b[0] - a[0]
        periods, throttled = b[2] - a[2], b[3] - a[3]
        out[name] = {
            "cores_used": round((b[1] - a[1]) / 1e6 / wall, 2) if wall > 0 else None,
            "throttled_periods_pct": round(100.0 * throttled / periods, 1) if periods > 0 else 0.0,
            "throttled_seconds": round((b[4] - a[4]) / 1e6, 2),
            "window_seconds": wall,
        }
    with open(out_json, "w") as fh:
        json.dump(out, fh, indent=2, sort_keys=True)


# --- reading the console ----------------------------------------------------------

def console_lines(path):
    with open(path, errors="replace") as fh:
        for line in fh:
            yield line.replace("\r", "").rstrip("\n")


def cmd_status(path):
    state, stage = "none", ""
    for line in console_lines(path):
        i = line.find("HVG:")
        if i < 0:
            continue
        tag = line[i:]
        if tag.startswith("HVG:DONE"):
            state = "done"
        elif tag.startswith("HVG:FAIL"):
            print("fail:" + tag[len("HVG:FAIL"):].strip())
            return
        elif tag.startswith("HVG:READY") and state != "done":
            state = "ready"
        elif tag.startswith("HVG:P "):
            stage = tag[len("HVG:P "):].strip()
            if state in ("none", "running"):
                state = "running"
    print(state if state != "running" else "running:" + stage)


CHUNK = 72  # bench.py's line width; every chunk but the last is exactly this long


def crc_ok(chunk, crc):
    return (zlib.crc32(chunk.encode()) & 0xFFFFFFFF) == crc


def repair(rest, crc, full):
    """Recover a chunk that a console message landed INSIDE.

    The intruding text is one contiguous span, and a full chunk's length is
    known, so there are only len(rest) - CHUNK places it can start. The CRC says
    which removal, if any, gives back the original.
    """
    extra = len(rest) - CHUNK
    if full and extra > 0:
        for i in range(CHUNK + 1):
            cand = rest[:i] + rest[i + extra:]
            if crc_ok(cand, crc):
                return cand
    return None


def cmd_decode(path, out_path):
    expect, chunks, damaged = None, {}, []
    for line in console_lines(path):
        m = re.search(r"HVG:BEGIN (\d+) ([0-9a-f]{64})", line)
        if m:
            expect = (int(m.group(1)), m.group(2))
            continue
        # Search, not match: a kernel or systemd message can land in front of a
        # chunk on the same line.
        m = re.search(r"HVG:D (\d+) ([0-9a-f]{8}) (.*)$", line)
        if not m:
            continue
        idx, crc, rest = int(m.group(1)), int(m.group(2), 16), m.group(3)
        clean = re.match(r"[A-Za-z0-9+/=]*", rest).group(0)
        if crc_ok(clean, crc):
            chunks.setdefault(idx, clean)
        else:
            damaged.append((idx, crc, rest))
    if not expect:
        sys.exit("no HVG:BEGIN in %s -- the guest never sent results" % path)
    n, digest = expect
    for idx, crc, rest in damaged:
        if idx not in chunks:
            fixed = repair(rest, crc, full=idx < n - 1)
            if fixed is not None:
                chunks[idx] = fixed
    missing = [i for i in range(n) if i not in chunks]
    if missing:
        sys.exit("%d of %d result lines unrecoverable (first: %d)" % (len(missing), n, missing[0]))
    blob = "".join(chunks[i] for i in range(n))
    if hashlib.sha256(blob.encode()).hexdigest() != digest:
        sys.exit("reassembled payload fails its SHA-256")
    data = json.loads(gzip.decompress(base64.b64decode(blob)))
    with open(out_path, "w") as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
    print("decoded %d lines, profile %s, %d tests" % (n, data.get("profile"), len(data.get("tests", {}))))


# --- summary and comparison --------------------------------------------------------------

# (label, test, field, unit, per-vCPU?, higher is better?)
FIGURES = [
    ("CPU, 1 thread", "cpu-1t", "events_per_sec", "events/s", False, True),
    ("CPU, all vCPUs", "cpu-all", "events_per_sec", "events/s/vCPU", True, True),
    ("Memory seq write, 1 thread", "mem-seq-1m-1t", "mib_per_sec", "MiB/s", False, True),
    ("Memory seq write, all", "mem-seq-1m-all", "mib_per_sec", "MiB/s/vCPU", True, True),
    ("Memory random 4K, 1 thread", "mem-rnd-4k-1t", "mib_per_sec", "MiB/s", False, True),
    ("Context switches", "stress-switch", "bogo_ops_per_sec_real", "ops/s/vCPU", True, True),
    ("Futex wake/wait", "stress-futex", "bogo_ops_per_sec_real", "ops/s/vCPU", True, True),
    ("Page faults", "stress-fault", "bogo_ops_per_sec_real", "ops/s/vCPU", True, True),
    ("Disk seq write 1M qd16", "fio-seq-write-1m-qd16", "bw_bytes", "MiB/s", False, True),
    ("Disk seq read 1M qd16", "fio-seq-read-1m-qd16", "bw_bytes", "MiB/s", False, True),
    ("Disk rand read 4K qd32", "fio-rand-read-4k-qd32", "iops", "IOPS", False, True),
    ("Disk rand write 4K qd32", "fio-rand-write-4k-qd32", "iops", "IOPS", False, True),
    ("Disk rand read 4K qd1, p99", "fio-rand-read-4k-qd1", "clat_p99_us", "us", False, False),
    ("Disk write 4K qd1 + fsync", "fio-rand-write-4k-qd1-fsync", "iops", "IOPS", False, True),
    ("Disk write+fsync, p99", "fio-rand-write-4k-qd1-fsync", "clat_p99_us", "us", False, False),
    ("Net TCP, 1 stream", "net-tcp-1", "gbit_per_sec", "Gbit/s", False, True),
    ("Net TCP, 4 streams", "net-tcp-4", "gbit_per_sec", "Gbit/s", False, True),
    ("Net TCP, 1 stream reverse", "net-tcp-1-reverse", "gbit_per_sec", "Gbit/s", False, True),
    ("Net RTT avg", "net-ping", "rtt_avg_ms", "ms", False, False),
    # Only when run with --sustained. Kept out of the overhead categories (see
    # overhead_of), so runs with and without it stay comparable.
    ("Net TCP, 4 streams, sustained: first 60 s", "net-tcp-4-sustained", "first_60s_gbit", "Gbit/s", False, True),
    ("Net TCP, 4 streams, sustained: last 120 s", "net-tcp-4-sustained", "last_120s_gbit", "Gbit/s", False, True),
    # Only with --pgbench. Outside the categories, like the sustained rows.
    ("pgbench, 1 client", "pg-c1", "tps", "tps", False, True),
    ("pgbench, 1 client, latency", "pg-c1", "latency_avg_ms", "ms", False, False),
    ("pgbench, 8 clients", "pg-c8", "tps", "tps", False, True),
    ("pgbench, 32 clients", "pg-c32", "tps", "tps", False, True),
    ("pgbench, 32 clients, latency", "pg-c32", "latency_avg_ms", "ms", False, False),
]


def in_categories(test):
    """The four profile-1 categories only; optional extras stay out of them."""
    return not (test.endswith("-sustained") or test.startswith("pg-"))


def figure(result, test, field, per_vcpu):
    t = result.get("tests", {}).get(test) or {}
    if t.get("error") or t.get(field) is None:
        return None
    v = float(t[field])
    if field == "bw_bytes":
        v /= 1024 * 1024
    if per_vcpu:
        v /= result.get("system", {}).get("vcpus") or 1
    return v


def load_json(path, default=None):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def load_run(d, mode="vm"):
    """A run directory holds vm/ and pod/; an older or single-mode one may hold
    result.json at the top. meta.json is always at the top."""
    import os
    sub = os.path.join(d, mode)
    base = sub if os.path.exists(os.path.join(sub, "result.json")) else d
    result = load_json(os.path.join(base, "result.json"))
    if result is None:
        sys.exit("no %s result in %s" % (mode, d))
    return result, load_json(os.path.join(d, "meta.json"), {})


def fmt(v):
    if v is None:
        return "-"
    if v == 0 or abs(v) >= 100:
        return "%.0f" % v
    return "%.3g" % v


def cmd_summary(dirs):
    runs = [load_run(d) for d in dirs]
    profiles = {r.get("profile") for r, _ in runs}
    if len(profiles) > 1:
        print("WARNING: runs use different workload profiles %s; figures are not comparable."
              % sorted(profiles, key=str))
    heads = []
    for d, (r, m) in zip(dirs, runs):
        s = r.get("system", {})
        heads.append("%s | %s %s, %s vCPU, %s" % (
            m.get("label") or d.rstrip("/").split("/")[-1], m.get("harvester", "?"),
            s.get("arch", "?"), s.get("vcpus", "?"), s.get("clocksource", "?")))
    for i, h in enumerate(heads):
        print("  [%d] %s" % (i, h))
    width = 28
    cols = "".join("%14s" % ("[%d]" % i) for i in range(len(runs)))
    ratio = "%12s" % ("[1]/[0]") if len(runs) > 1 else ""
    print("\n  %-*s %-14s%s%s" % (width, "figure", "unit", cols, ratio))
    for label, test, field, unit, per_vcpu, higher in FIGURES:
        vals = [figure(r, test, field, per_vcpu) for r, _ in runs]
        line = "  %-*s %-14s%s" % (width, label, unit, "".join("%14s" % fmt(v) for v in vals))
        if len(runs) > 1 and vals[0] and vals[1] is not None and not math.isnan(vals[0]):
            rel = vals[1] / vals[0]
            # Normalize so that below 1.0 always means [1] is worse.
            score = rel if higher else (1 / rel if rel else float("inf"))
            line += "%12s" % ("%.2f" % score)
        print(line)
    errors = [(i, t, v["error"]) for i, (r, _) in enumerate(runs)
              for t, v in sorted(r.get("tests", {}).items()) if v.get("error")]
    for i, t, e in errors:
        print("  [%d] %s failed: %s" % (i, t, e[:160]))
    if len(runs) > 1:
        print("\n  Last column: [1] relative to [0], oriented so that < 1.00 means [1] is worse")
        print("  (slower, or higher latency). Per-vCPU rows are already divided by vCPU count.")


CATEGORIES = [
    ("compute", ("cpu-", "mem-")),
    ("scheduler", ("stress-",)),
    ("disk", ("fio-",)),
    ("network", ("net-",)),
]


def category(test):
    return next(c for c, prefixes in CATEGORIES if test.startswith(prefixes))


def geomean(xs):
    xs = [x for x in xs if x and x > 0]
    return math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs else None


def pct(r):
    return None if r is None else 100.0 * (1.0 - r)


def overhead_of(d):
    """VM performance as a fraction of the pod baseline on the same node."""
    import os
    vm, meta = load_run(d, "vm")
    pod, _ = load_run(d, "pod")
    steal = load_json(os.path.join(d, "vm", "node-steal.json"), {})
    thr = {m: load_json(os.path.join(d, m, "cgroup-throttle.json"), {}) for m in ("vm", "pod")}
    rows, by_cat = [], {}
    for label, test, field, unit, per_vcpu, higher in FIGURES:
        v, p = figure(vm, test, field, per_vcpu), figure(pod, test, field, per_vcpu)
        r = None
        if v and p:
            r = v / p if higher else p / v
            if in_categories(test):
                by_cat.setdefault(category(test), []).append(r)
        rows.append({"figure": label, "test": test, "unit": unit, "pod": p, "vm": v,
                     "ratio": r, "overhead_pct": pct(r), "node_steal_pct": steal.get(test),
                     "cgroup": {m: thr[m].get(test) for m in ("vm", "pod") if thr[m].get(test)}})
    cats = {c: geomean(by_cat.get(c, [])) for c, _ in CATEGORIES}
    # Equal weight per category, not per figure: disk has seven figures and
    # would otherwise decide the headline on its own.
    overall = geomean([r for r in cats.values() if r])
    warnings = []
    cpu = next((x["ratio"] for x in rows if x["test"] == "cpu-1t"), None)
    if cpu and cpu > 1.05:
        warnings.append("VM beat the pod on single-thread CPU by %.0f%%: the pod baseline is suspect "
                        "(kernel or CPU placement), so every ratio here is too." % (100 * (cpu - 1)))
    if vm.get("profile") != pod.get("profile"):
        warnings.append("vm and pod ran different workload profiles")
    if vm.get("system", {}).get("vcpus") != pod.get("system", {}).get("vcpus"):
        warnings.append("vm and pod had different vCPU counts")
    return {
        "label": meta.get("label") or d.rstrip("/").split("/")[-1], "harvester": meta.get("harvester"),
        "vm_cpu_limit": meta.get("vm_cpu_limit"), "vm_net_multiqueue": meta.get("vm_net_multiqueue"),
        "arch": meta.get("arch"), "vcpus": vm.get("system", {}).get("vcpus"),
        "rows": rows, "categories": {c: {"ratio": r, "overhead_pct": pct(r)} for c, r in cats.items()},
        "overall": {"ratio": overall, "overhead_pct": pct(overall)}, "warnings": warnings,
    }


def fpct(x):
    return "-" if x is None else "%+.1f%%" % x


def cmd_overhead(dirs):
    import os
    results = [overhead_of(d) for d in dirs]
    for d, o in zip(dirs, results):
        with open(os.path.join(d, "overhead.json"), "w") as fh:
            json.dump(o, fh, indent=2)
    for i, o in enumerate(results):
        print("\n  [%d] %s | %s %s, %s vCPU" % (i, o["label"], o["harvester"], o["arch"], o["vcpus"]))
        print("  %-28s %-14s%12s%12s%10s%11s%8s" % ("figure", "unit", "pod", "vm", "vm/pod", "overhead", "steal"))
        for x in o["rows"]:
            print("  %-28s %-14s%12s%12s%10s%11s%8s" % (
                x["figure"], x["unit"], fmt(x["pod"]), fmt(x["vm"]),
                "-" if x["ratio"] is None else "%.3f" % x["ratio"], fpct(x["overhead_pct"]),
                "-" if x["node_steal_pct"] is None else "%.1f%%" % x["node_steal_pct"]))
        for w in o["warnings"]:
            print("  WARNING: " + w)
    print("\n  VM overhead against a pod on the same node (geometric mean of vm/pod; overall")
    print("  weights the four categories equally). Positive = the VM is slower.\n")
    head = "  %-34s" % "" + "".join("%12s" % c for c, _ in CATEGORIES) + "%12s" % "overall"
    print(head)
    for i, o in enumerate(results):
        print("  %-34s" % ("[%d] %s" % (i, o["label"]))[:36] + "".join(
            "%12s" % fpct(o["categories"][c]["overhead_pct"]) for c, _ in CATEGORIES)
            + "%12s" % fpct(o["overall"]["overhead_pct"]))
    if len(results) > 1:
        base = results[0]
        print("\n  Relative to [0]: how much of [0]'s VM performance-per-host each run keeps.")
        print("  e.g. 0.80 = a VM there gets 80% of what a VM on [0] gets from its own host.\n")
        print(head)
        for i, o in enumerate(results[1:], 1):
            cells = []
            for c, _ in CATEGORIES + [("overall", None)]:
                a = (o["overall"] if c == "overall" else o["categories"][c])["ratio"]
                b = (base["overall"] if c == "overall" else base["categories"][c])["ratio"]
                cells.append("%12s" % ("-" if not (a and b) else "%.2f" % (a / b)))
            print("  %-34s" % ("[%d] / [0]" % i) + "".join(cells))
    for o in results:
        if o["overall"]["overhead_pct"] is not None:
            print("\n  %s: a VM delivers %.0f%% of what the same work gets in a pod on the same"
                  "\n  node -- %.0f%% VM overhead (compute %s, scheduler %s, disk %s, network %s)."
                  % (o["label"], 100 * o["overall"]["ratio"], o["overall"]["overhead_pct"],
                     *[fpct(o["categories"][c]["overhead_pct"]) for c, _ in CATEGORIES]))


def cmd_quota(d):
    """Per test: cores the bench container used, and how often its quota throttled it."""
    import os
    thr = {m: load_json(os.path.join(d, m, "cgroup-throttle.json")) for m in ("vm", "pod")}
    modes = [m for m in ("vm", "pod") if thr[m]]
    if not modes:
        return
    meta = load_json(os.path.join(d, "meta.json"), {})
    limits = {"vm": meta.get("vm_cpu_limit") or meta.get("vcpus"), "pod": meta.get("vcpus")}
    print("\n  CPU quota during each test: cores used by the bench container, and the share of")
    print("  CFS periods in which its limit throttled it. VM figures include QEMU's emulator and")
    print("  vhost-net threads.  Limits: %s" % ", ".join("%s %s CPU" % (m, limits[m]) for m in modes))
    head = "  %-28s" % "test" + "".join("%14s%12s" % ("%s cores" % m, "throttled") for m in modes)
    print(head)
    tests = []
    for _, test, _, _, _, _ in FIGURES:
        if test not in tests:
            tests.append(test)
    for test in tests:
        cells = []
        for m in modes:
            t = thr[m].get(test) or {}
            cells.append("%14s%12s" % ("-" if t.get("cores_used") is None else "%.2f" % t["cores_used"],
                                       "-" if not t else "%.1f%%" % t.get("throttled_periods_pct", 0)))
        print("  %-28s" % test + "".join(cells))


# --- contention ---------------------------------------------------------------

PROM_PATH = ("/api/v1/namespaces/cattle-monitoring-system/services/"
             "rancher-monitoring-prometheus:9090/proxy/api/v1/query")


def contention_windows(start, seconds, gap):
    """(phase, window start, window end). Mirrors bench.contend_schedule, plus
    an idle window just before the first phase, for reference."""
    step = seconds + gap
    return [("idle", start - seconds, start),
            ("solo-randwrite", start, start + seconds),
            ("all-randwrite", start + step, start + step + seconds),
            ("all-seqwrite", start + 2 * step, start + 2 * step + seconds)]


def contention_queries(seconds):
    w = "%ds" % seconds
    disk = 'device=~"nvme[0-9]+n1"'
    by_node = " * on(instance) group_left(nodename) node_uname_info"
    return {
        # etcd's own histograms: only present while the PodMonitor scrapes etcd.
        "etcd_wal_fsync_p99": 'histogram_quantile(0.99, sum by (le, pod) (rate(etcd_disk_wal_fsync_duration_seconds_bucket{namespace="kube-system"}[%s])))' % w,
        "etcd_commit_p99": 'histogram_quantile(0.99, sum by (le, pod) (rate(etcd_disk_backend_commit_duration_seconds_bucket{namespace="kube-system"}[%s])))' % w,
        # What the control plane feels: the API server's own etcd request latency.
        "apiserver_etcd_p99": 'histogram_quantile(0.99, sum by (le, operation) (rate(etcd_request_duration_seconds_bucket{operation=~"create|update|get"}[%s])))' % w,
        # Each node's EBS volume, as the node's kernel sees it.
        "node_writes_per_s": "sum by (nodename) (rate(node_disk_writes_completed_total{%s}[%s])%s)" % (disk, w, by_node),
        "node_write_bytes_per_s": "sum by (nodename) (rate(node_disk_written_bytes_total{%s}[%s])%s)" % (disk, w, by_node),
        "node_write_await_s": "sum by (nodename) (rate(node_disk_write_time_seconds_total{%s}[%s])%s) / sum by (nodename) (rate(node_disk_writes_completed_total{%s}[%s])%s)" % (disk, w, by_node, disk, w, by_node),
    }


def cmd_promq(start, seconds, gap):
    """One line per query: phase, name, the API path for `kubectl get --raw`."""
    import urllib.parse
    start, seconds, gap = float(start), int(seconds), int(gap)
    for phase, _, end in contention_windows(start, seconds, gap):
        for name, q in contention_queries(seconds).items():
            print("%s\t%s\t%s?%s" % (phase, name, PROM_PATH,
                                       urllib.parse.urlencode({"query": q, "time": "%.0f" % end})))


def cmd_podmonitor(ns):
    """Scrape etcd for the length of a contention run; deleted with the namespace."""
    print(json.dumps({
        "apiVersion": "monitoring.coreos.com/v1", "kind": "PodMonitor",
        "metadata": {"name": "hvg-etcd", "namespace": ns,
                     "labels": {"perf.harvester-aws/guest-bench": "true"}},
        "spec": {"namespaceSelector": {"matchNames": ["kube-system"]},
                 "selector": {"matchLabels": {"component": "etcd", "tier": "control-plane"}},
                 "podMetricsEndpoints": [{"port": "metrics", "path": "/metrics", "scheme": "http",
                                          "interval": "10s", "scrapeTimeout": "10s"}]},
    }))


def prom_samples(path):
    data = load_json(path, {}) or {}
    out = []
    for r in (data.get("data") or {}).get("result") or []:
        try:
            v = float(r["value"][1])
        except (KeyError, IndexError, TypeError, ValueError):
            continue
        if v == v:
            out.append((r.get("metric", {}), v))
    return out


def cmd_contention(d):
    import os
    meta = load_json(os.path.join(d, "meta.json"), {})
    cdir = os.path.join(d, "contention")
    vms = sorted(x for x in os.listdir(cdir) if x.startswith("c") and os.path.isdir(os.path.join(cdir, x)))
    results = {v: load_json(os.path.join(cdir, v, "result.json")) for v in vms}
    start, seconds, gap = meta.get("contention_start"), meta.get("contention_seconds"), meta.get("contention_gap")
    phases = []
    for phase, w0, w1 in contention_windows(start, seconds, gap):
        seq = phase.endswith("seqwrite")
        per_vm = {}
        for v, r in results.items():
            t = ((r or {}).get("tests") or {}).get(phase)
            if not t:
                continue
            per_vm[v] = {"value": None if t.get("error") else (t["bw_bytes"] / 1048576.0 if seq else t["iops"]),
                         "clat_p99_ms": None if t.get("error") else t.get("clat_p99_us", 0) / 1000.0,
                         "late_s": t.get("late_s"), "error": t.get("error"),
                         "node": (meta.get("contention_nodes") or {}).get(v)}
        vals = [x["value"] for x in per_vm.values() if x["value"] is not None]
        prom = {}
        for name in contention_queries(seconds):
            prom[name] = prom_samples(os.path.join(cdir, "prom", "%s.%s.json" % (phase, name)))
        node = {}
        for name, key, scale in (("node_writes_per_s", "writes_per_s", 1), ("node_write_bytes_per_s", "mib_per_s", 1 / 1048576.0),
                                 ("node_write_await_s", "await_ms", 1000)):
            for m, v in prom[name]:
                node.setdefault(m.get("nodename", "?"), {})[key] = round(v * scale, 2)
        maxv = lambda name: max([v for _, v in prom[name]], default=None)
        phases.append({
            "phase": phase, "window": [w0, w1], "unit": "MiB/s" if seq else "IOPS",
            "vms": len(per_vm), "total": round(sum(vals), 1) if vals else None,
            "per_vm_min": round(min(vals), 1) if vals else None,
            "per_vm_mean": round(sum(vals) / len(vals), 1) if vals else None,
            "per_vm_max": round(max(vals), 1) if vals else None,
            "clat_p99_ms_max": max([x["clat_p99_ms"] for x in per_vm.values() if x["clat_p99_ms"] is not None], default=None),
            "late_s_max": max([x["late_s"] or 0 for x in per_vm.values()], default=None),
            "errors": [v + ": " + x["error"] for v, x in sorted(per_vm.items()) if x["error"]],
            "per_vm": per_vm,
            "etcd_wal_fsync_p99_ms": None if maxv("etcd_wal_fsync_p99") is None else round(maxv("etcd_wal_fsync_p99") * 1000, 2),
            "etcd_commit_p99_ms": None if maxv("etcd_commit_p99") is None else round(maxv("etcd_commit_p99") * 1000, 2),
            "apiserver_etcd_p99_ms": {m.get("operation", "?"): round(v * 1000, 2) for m, v in prom["apiserver_etcd_p99"]},
            "node_disk": node,
        })
    fills = {}
    for v, r in results.items():
        t = ((r or {}).get("tests") or {}).get("prefill")
        if t:
            fills[v] = {"mib_per_s": None if t.get("error") else round(t["bw_bytes"] / 1048576.0, 1),
                        "seconds": t.get("seconds"), "finished_before_start": t.get("finished_before_start"),
                        "error": t.get("error")}
    prefill = None
    if fills:
        rates = [x["mib_per_s"] for x in fills.values() if x["mib_per_s"] is not None]
        prefill = {"vms": len(fills), "per_vm": fills,
                   "per_vm_min_mib_s": min(rates, default=None), "per_vm_max_mib_s": max(rates, default=None),
                   "seconds_max": max([x["seconds"] or 0 for x in fills.values()], default=None),
                   "all_finished_before_start": all(x["finished_before_start"] for x in fills.values())}
    out = {"label": meta.get("label"), "harvester": meta.get("harvester"), "arch": meta.get("arch"),
           "prefill": prefill,
           "vms": len(vms), "vcpus": meta.get("vcpus"), "data_storage_class": meta.get("data_storage_class"),
           "data_storage_class_parameters": meta.get("data_storage_class_parameters"),
           "phase_seconds": seconds, "phases": phases}
    with open(os.path.join(d, "contention.json"), "w") as fh:
        json.dump(out, fh, indent=2, sort_keys=True)
    print("\n  Contention: %d VMs, %s s per phase, data disks on %s%s" % (
        len(vms), seconds, meta.get("data_storage_class"), ", disks pre-filled" if prefill else ""))
    if prefill:
        print("  pre-fill: %d VMs, %s-%s MiB/s each, slowest took %s s, all done before the schedule: %s" % (
            prefill["vms"], fmt(prefill["per_vm_min_mib_s"]), fmt(prefill["per_vm_max_mib_s"]),
            fmt(prefill["seconds_max"]), "yes" if prefill["all_finished_before_start"] else "NO"))
    print("  %-16s %4s %10s %-6s %18s %9s %9s %9s %11s" % ("phase", "VMs", "total", "unit", "per VM min/max",
                                                         "p99 ms", "etcd WAL", "API etcd", "node w/s"))
    for p in phases:
        nw = [x.get("writes_per_s") for x in p["node_disk"].values() if x.get("writes_per_s") is not None]
        api = p["apiserver_etcd_p99_ms"]
        print("  %-16s %4s %10s %-6s %18s %9s %9s %9s %11s" % (
            p["phase"], p["vms"] or "-", fmt(p["total"]), p["unit"] if p["vms"] else "",
            "-" if p["per_vm_min"] is None else "%s / %s" % (fmt(p["per_vm_min"]), fmt(p["per_vm_max"])),
            fmt(p["clat_p99_ms_max"]), fmt(p["etcd_wal_fsync_p99_ms"]), fmt(max(api.values(), default=None)),
            "-" if not nw else "%s-%s" % (fmt(min(nw)), fmt(max(nw)))))
        for e in p["errors"]:
            print("    error: " + e[:160])


def main(argv):
    cmds = {
        "nodes": (cmd_nodes, 0), "meta": (cmd_meta, 0), "imagestatus": (cmd_imagestatus, 0),
        "image": (cmd_image, 3), "userdata": (cmd_userdata, None),
        "vm": (cmd_vm, 14), "status": (cmd_status, 1), "decode": (cmd_decode, 2),
        "pvc": (cmd_pvc, 4), "sampler": (cmd_sampler, 4), "steal": (cmd_steal, 3), "throttle": (cmd_throttle, 3),
    }
    if len(argv) >= 2 and argv[1] == "summary" and len(argv) >= 3:
        return cmd_summary(argv[2:])
    if len(argv) == 3 and argv[1] == "quota":
        return cmd_quota(argv[2])
    if len(argv) == 3 and argv[1] == "contention":
        return cmd_contention(argv[2])
    if len(argv) == 5 and argv[1] == "promq":
        return cmd_promq(*argv[2:])
    if len(argv) == 3 and argv[1] == "podmonitor":
        return cmd_podmonitor(argv[2])
    if len(argv) >= 2 and argv[1] == "overhead" and len(argv) >= 3:
        return cmd_overhead(argv[2:])
    if len(argv) >= 2 and argv[1] == "pod" and len(argv) in (10, 11, 12):
        return cmd_pod(*argv[2:])
    if len(argv) < 2 or argv[1] not in cmds:
        sys.exit(__doc__)
    fn, nargs = cmds[argv[1]]
    args = argv[2:]
    if argv[1] == "userdata" and len(args) in (2, 3):
        return fn(*args)
    if argv[1] == "pvc" and len(args) == 5 and args[4] in ("Block", "Filesystem"):
        return fn(*args)
    if nargs is None or len(args) != nargs:
        sys.exit(__doc__)
    return fn(*args)


if __name__ == "__main__":
    main(sys.argv)
