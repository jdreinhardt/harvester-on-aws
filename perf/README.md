# Running harvester-perf against this deployment

[harvester/harvester-perf](https://github.com/harvester/harvester-perf)'s
`hvperf` CLI, pointed at a cluster built by this repository.

| File | What it is |
| --- | --- |
| `run-perf.sh` | Discovers the cluster, launches a runner, checks the cluster's readiness for each suite, provisions the runner, runs the suites one at a time, and collects results into `results/<timestamp>/`. |
| `runner-provision.sh` | Runs *on* the runner. Builds `hvperf`, and cross-compiles `etcdctl`, `benchmark` and `promtool` for the **cluster's** architecture. Installs a cluster-matched `kubectl` when the guest suite runs. |
| `guest-bench.sh` | The `guest` suite: workloads run **inside** two Harvester VMs. Needs only `kubectl` and `python3`, so it also runs on its own against an on-prem cluster. See [The guest suite](#the-guest-suite-what-a-vm-actually-gets). |
| `guest/bench.py` | The program that runs inside the benchmark VM. |
| `guest/hvg.py` | The harness side: manifests, reading results off the guest console, summaries and comparisons. |

```bash
./perf/run-perf.sh --key-name harvester-e2e-rsa
```

That runs `node-capacity`, `resource-footprint`, `guest`, `etcd-benchmark` and
`density`, in that order, with density capped at 50 VMIs. Budget about 90 minutes:
the runner build, about 45 minutes for the guest suite's two modes, and the etcd suite's
Prometheus wait.

## Why a runner, and why not the upstream image

hvperf itself needs only a kubeconfig. The runner exists for three other
reasons:

* **The kubeconfig has to come from a node.** Node SSH is key-only on the
  private address. The runner is used as a jump host, so the cluster key stays on
  your machine, and `rke2.yaml` is piped from node 1 to the runner without
  touching your disk.
* **The API endpoint should be a node, not the VIP or the NLB.** The kubeconfig
  points at node 1's private address. The VIP goes dark if kube-vip re-elects
  (see the [README](../README.md#the-vip-does-not-fail-over)), which a hard etcd
  benchmark can provoke. An internet-facing NLB drops idle TCP after 350 s,
  which is too short for the suites' long exec and watch streams.
* **The etcd tools must match the nodes.** `etcd-benchmark` copies
  `/usr/local/bin/{etcdctl,benchmark,promtool}` from wherever hvperf runs into a
  pod on a node. The upstream image bakes in one architecture (default
  `linux/amd64`), which fails with `exec format error` on Graviton.
  `runner-provision.sh` builds them with `GOARCH` set to the cluster's
  architecture, at the versions pinned in harvester-perf's own `Dockerfile`, and
  then verifies the architecture of each binary.

The runner sits in the nodes' subnet and security group, as the e2e runner does.
It has no IAM role. It is tagged `harvester-perf-runner`, separate from the e2e
runner, so the two never reuse or terminate each other.

## Before you run

`run-perf.sh` inspects node 1 before it provisions anything and warns about
each of these. Only the arm64 case below is fatal.

| Need | For | If missing |
| --- | --- | --- |
| `rancher-monitoring` addon enabled, and running for 10+ minutes | `resource-footprint`, every metrics case | footprint and etcd metrics **skip**; density's metrics case **errors**. The e2e addon tests can leave it disabled. |
| `etcd_expose_metrics = true` on the Terraform module (there is no CloudFormation equivalent; see below) | `etcd-benchmark`'s metrics case | It waits ~10 minutes for Prometheus targets that never go healthy, then **skips**. The benchmarks themselves still run. |
| An AMI built from a current `02-customize-instance.sh` | the above | Older AMIs ignore `aws.etcd_expose_metrics`. This needs a rebuild (about two hours), in the same way the `tls-san` drop-in did. |
| Package egress from guest VMs and pods (Ubuntu's archive, Docker Hub), and two schedulable nodes | `guest` | Without egress, the tools cannot be installed and every workload reports "not installed". With one node, the network figures measure the node-local path, and `meta.json` says `same_node: true`. |
| No cordoned nodes | `density` | Density's capacity figure comes out understated. `e2e/clean-cluster.py` releases maintenance mode. |
| A cluster that has not just run e2e | `resource-footprint` | Its 5-minute windows measure the tail of whatever ran before. |

### Exposing etcd metrics, deliberately

RKE2's etcd static pod declares a `metrics` port on 2381, and hvperf's
PodMonitor scrapes that port on the pod's address. etcd host-networks, so that
address is the node's IP. By default, though, etcd listens on 2381 only on
`127.0.0.1`, so the scrape is refused. RKE2's `etcd-expose-metrics` adds the
node address. harvester-installer never sets it.

The image supports it but never turns it on by itself. `configure.sh` writes
`/etc/rancher/rke2/config.yaml.d/95-aws-etcd-metrics.yaml` only when user-data
carries `aws.etcd_expose_metrics: true`. It does that on **every** node at first
boot, because joined nodes start as agents and are promoted to servers later.
Of the deployment paths, only the Terraform module can set it, and it is meant
to be hard to enable by accident:

* `etcd_expose_metrics` defaults to `false` and appears in no README table or
  example. This file is the only place it is documented.
* Every `plan` and `apply` prints a `Check block assertion failed` warning
  while it is `true`.
* The CloudFormation template has no parameter for it. The console cannot hide
  a parameter, and that is the path where an accidental click is most likely.
  A comment there says not to add one.
* It is user-data, so changing it on an existing cluster **replaces every
  node**. It is a decision made when a test cluster is created, never a toggle.

```hcl
module "harvester" {
  source = "./terraform"
  # ...
  etcd_expose_metrics = true   # perf test cluster only
}
```

#### What it exposes

etcd's metrics listener serves `/metrics` and `/health` over plain HTTP with no
authentication. It does **not** serve the etcd client API, keys or values. What
it does reveal is cluster internals: database size, key counts, request and
gRPC method rates, raft term and leader changes, disk latencies, and the etcd
version. That is reconnaissance material, and a cheap endpoint for anyone who
wants to hammer it. It is not a credential leak.

| Who can reach `<node>:2381` | When enabled |
| --- | --- |
| The internet, and the admin prefix list | No. The admin rules cover only 22, 80, 443 and 6443. |
| Anything in the nodes' security group (nodes, e2e and perf runners) | Yes |
| `overlay_client_cidr`, if set | **Yes.** That rule opens all protocols. |
| Every pod on the cluster | Yes |
| Every guest VM that has a route to node addresses (pod-network masquerade, or the overlay with `natOutgoing`) | **Yes.** On Harvester, VMs are the tenants, so this row is the one that matters. |

Having the code in the image grants nothing new. Anyone who controls user-data
can already write any file as root through Harvester's own `os.write_files` and
`os.after_install_chroot_commands`, so the key only spares a test cluster from a
hand-written `write_files` entry. That is why it lives in the normal image
rather than in a separate test build. A separate image would cost a two-hour
build per architecture and version, and would need keeping away from
`/harvester/ami/<arch>/latest`, all to remove a capability that user-data has
anyway.

The drop-in persists on the node across reboots and upgrades, as the `tls-san`
one does. To turn it off on a running node, delete the file and restart
`rke2-server`, one management node at a time. To turn it on for a cluster
that is already running, write `etcd-expose-metrics: true` to that path and
restart in the same way. In both cases, wait for etcd to report healthy before
moving to the next node, and do node 1, which holds the VIP, last: a restart
can make kube-vip re-elect, and on EC2 a re-elected VIP goes dark. Neither
procedure has been tried yet, so the script does not do either.

## What each suite does here, and what to expect

| Suite | What it does | Expected on this deployment |
| --- | --- | --- |
| `node-capacity` | Node info from the API, plus `lsblk` on every node from a privileged `hostPID` daemonset. | Should pass. Pulls `registry.suse.com/bci/bci-base:latest`. Its `pods.capacity` figure is what bounds density (see below). |
| `resource-footprint` | Read-only PromQL: per-namespace CPU and memory, requests, host memory, allocatable. | Passes when monitoring is on. The figure that matters most is the one for Harvester's own namespaces, measured on an idle cluster. |
| `etcd-benchmark` | `etcdctl endpoint`/`check perf`, then serial and concurrent `benchmark put/range` from a host-network job pod on node 1, then etcd's own fsync, commit and peer-RTT histograms. | The benchmarks should pass. `check perf` uses the small profile, which gp3's baseline of 3000 IOPS covers. The interesting output is the WAL fsync p99 on gp3, which etcd, Longhorn and the OS all share on one volume. |
| `guest` | Not an hvperf suite. CPU, memory, scheduler, disk and network workloads, run inside two Harvester VMs and then in two plain pods on the same nodes. | Should pass on amd64 and on arm64 v1.8.2. This suite is the one that gives the VM overhead, and with it what nested virtualization costs. [Its own section](#the-guest-suite-what-a-vm-actually-gets) covers it. |
| `density` | Creates batches of cirros containerDisk VMIs (100m CPU, 90Mi) until `maxVMs` is reached or a health check trips, recording VMI boot latency at p50/p95/p99. | Expect the pod limit to stop it before CPU or memory does, at roughly (max-pods − system pods) per node. On amd64, boot latency includes nested virtualization, so do not compare it with bare-metal baselines. |

### arm64 on v1.9.x: density is refused

Density waits only for the VMI to reach phase `Running`, and QEMU gets there
whether or not the guest boots. On arm64 v1.9.0, every guest dead-loops in its
firmware ([README](../README.md#what-has-been-tested)), so density would report
a healthy ramp and plausible latencies that measure nothing. The script refuses
that combination unless you pass `--allow-arm64-density`. Use v1.8.2 for arm64
density.

### State the suites leave behind

* **etcd keys.** `benchmark put` writes about 60,000 keys of 256 bytes at the
  root of the cluster's etcd and never deletes them. They are outside
  `/registry`, so Kubernetes ignores them, but the database grows. Run the
  benchmark on a cluster you are about to retire.
* **etcd load.** The concurrent case uses 500 clients over 100 connections. The
  thing to watch on EC2 is a kube-vip lease flap: check that the VIP still
  answers afterwards.
* **Guest.** Its namespace, `harvester-perf-guest`, holds the VMs, pods,
  volumes and image, and is deleted at the end unless `guest-bench.sh` gets
  `--keep`. The fio jobs write the whole 10 GiB data disk once per mode, and
  Longhorn replicates every write.
* **Density.** With `--max-vms 0` it deliberately drives the cluster to the
  point where something fails. Its cleanup deletes the VMIs (stripping stuck
  finalizers after 30 s), and the script deletes `harvester-perf-system` after
  each suite unless you pass `--keep-namespace`.

## The guest suite: what a VM actually gets

Everything hvperf measures happens outside a guest. Its "boot latency" stops at
VMI phase `Running`, which QEMU reaches before the guest kernel has run at all.
Nested virtualization costs nothing there. Its cost shows up inside the guest,
so that is where `guest-bench.sh` measures.

It runs one fixed set of workloads **twice on the same nodes**: once inside a
Harvester VM, and once in a plain pod with the same CPUs, memory, Longhorn
volume type and network. The ratio between the two is what the VM layer costs
on that cluster. That makes it possible to say "VMs carry X% overhead on bare
metal and Y% on nested virtualization": see [VM overhead](#vm-overhead-the-x-and-y-figures).

### How it runs

`guest-bench.sh` creates one namespace, which it owns and deletes afterwards.
In it go a `VirtualMachineImage` (Ubuntu 24.04, cloud image serial
`20260926`, for the cluster's architecture) and two VMs on two different nodes.
The VMs are built the way the Harvester UI builds them: PVCs declared in
`harvesterhci.io/volumeClaimTemplates`, a root disk from the image, a blank
Longhorn data disk, and the management network (pod networking, masquerade).

* **bench** (4 vCPU, 8 GiB) runs every workload in turn, never two at once.
* **peer** is the far end of the network tests, and is otherwise idle.

The VMs are then deleted, and the same pair runs again as **pods** on the same
two nodes. The pods run `ubuntu:noble-20260917` with the same four tools
installed from the same archive. The bench pod gets a Guaranteed 4-CPU, 8 GiB
allocation and a raw-block Longhorn volume from the same storage class, and pins
itself to 4 CPUs. A small sampler pod on the bench node logs the node's own
steal counter every 5 seconds through both runs.

cloud-init installs `fio`, `sysbench`, `stress-ng` and `iperf3` from Ubuntu's
archive, which has the same versions on both architectures. It then starts
`guest/bench.py`. Results leave the guest on its **serial console**, which the
harness reads with `kubectl logs <virt-launcher> -c guest-console-log`. That
means no SSH, no guest credentials, and no route from the harness into the pod
network. The console is shared with the kernel and systemd, so the payload is
framed: gzipped, base64-encoded, sent in numbered lines with a CRC on each,
three times over, and checked against a SHA-256 when reassembled. The decoder
also repairs a line that a console message landed in the middle of. Tested
against randomly corrupted consoles, every run decoded intact at 15% of lines
damaged, and 86% did at 50%.

```bash
# On AWS: part of the default run-perf.sh suites, or on its own
./perf/run-perf.sh --suites guest

# Anywhere with a kubeconfig: on-prem, a lab cluster, the runner itself
./perf/guest-bench.sh --label "on-prem r650 v1.8.2"

# The VM overhead on each cluster, and how the second compares to the first
python3 perf/guest/hvg.py overhead perf/results/guest-<onprem> perf/results/<aws>/guest

# Raw VM figures side by side
python3 perf/guest/hvg.py summary perf/results/guest-<onprem> perf/results/<aws>/guest
```

### The workloads, and why each is there

`PROFILE` in `guest/bench.py` names this parameter set. Results compare only
within one profile, and the summary warns if you mix them.

| Figure | Workload | Why it is in the set |
| --- | --- | --- |
| CPU, 1 thread and all vCPUs | `sysbench cpu`, primes to 20000, 30 s | Pure compute. Hardware virtualization runs it natively, so nested and metal should be close. It is the control: a big gap here points at the CPU or clock, not at virtualization. |
| Memory seq write, 1 thread and all; random 4K | `sysbench memory`, 30 s | Bandwidth, and a TLB-heavy random pattern. Nested guests walk two levels of page tables on a TLB miss, which the random case exposes. |
| Context switches | `stress-ng --switch`, one per vCPU, 30 s | Cross-vCPU wake-ups mean IPIs and HLT exits, and every exit a nested guest takes goes through L0 *and* L1. Expect the largest nested penalty here or in futex. |
| Futex wake/wait | `stress-ng --futex` | The same exits from the synchronisation path that databases and runtimes hit. |
| Page faults | `stress-ng --fault` | Minor faults take the shadowed-EPT path an L2 guest pays for. |
| Disk, sequential 1M qd16 | `fio`, libaio, direct, on the raw data disk | Throughput. The first job writes the whole disk, which preconditions it: Longhorn volumes are thin, and reading blocks never written returns zeroes without touching a replica. |
| Disk, random 4K qd32 / qd1 | `fio` | IOPS under load, and single-request latency (p99), where virtualization exits add up per I/O. |
| Disk, write 4K qd1 + fsync | `fio --fsync=1` | A flush after every write, which is how etcd's WAL and most databases write. Usually the most storage-sensitive figure. |
| Net TCP, 1 and 4 streams, reverse | `iperf3`, 30 s, to the peer on another node | VM-to-VM throughput over pod networking: KubeVirt masquerade, then canal. |
| Net RTT | `ping`, 100 at 0.2 s | Round-trip latency over the same path. |

Each VM also records its kernel, CPU model and flags, clocksource,
`systemd-analyze time` and package versions, so a surprising number can be
traced to its environment.

### VM overhead: the X and Y figures

For every figure, `hvg.py overhead` takes the VM's result over the pod's, on the
same node. For latencies it takes the pod's over the VM's, so a ratio below 1
always means the VM did worse:

```
ratio     = VM / pod         (latency: pod / VM)
overhead  = 1 - ratio        e.g. ratio 0.70 -> 30% overhead
category  = geometric mean of its figures' ratios    (compute, scheduler, disk, network)
overall   = geometric mean of the four category ratios
```

Run on each kind of cluster, the result is the statement:

| Cluster | What the VM/pod ratio isolates | The statement |
| --- | --- | --- |
| On-prem x86, or AWS `c7g.metal` (Graviton) | One layer of KVM over bare metal | "VMs carry **X%** overhead on bare metal" |
| AWS `m8i.4xlarge` | One layer of KVM nested on Nitro: Harvester's KVM running inside an AWS VM | "VMs carry **Y%** overhead under nested virtualization" |

Because both sides of each ratio ran on the same node, the hardware cancels out:
a faster or slower host moves the pod and the VM together. That is what lets
an on-prem X and an AWS Y be quoted side by side. Read across two runs, the
comparison table gives Y relative to X directly, for example "a nested VM keeps
76% of the performance a bare-metal VM gets from its host".

Quote the four categories rather than only the overall figure. Nested
virtualization is expected to cost little in compute and a great deal in the
scheduler workloads, and the overall number depends on an equal-weight
convention: disk contributes one category, not seven figures. The `steal`
column shows how much CPU time AWS's hypervisor took from the node during each
VM test. That part of the nested cost is invisible to the node's own CPU
accounting.

**What the pod baseline is, and is not:**

* **It is the node without a VM layer, not hardware without Harvester.** On
  AWS the node is itself a Nitro VM, so Y is the cost of the *extra* layer.
  Relative to raw hardware there is also Nitro's own, small cost. To measure
  it, run the pod mode with plain Linux on an `m8i.metal` size (or any metal
  size from the same family) and compare it with the `m8i.4xlarge` pod run.
  That's a one-off calibration, not automated.
* **The kernels differ.** The pod runs on the node's kernel (Harvester's), the
  VM on Ubuntu 24.04's. Part of every ratio is that kernel difference, and it is
  the same on every cluster running the same Harvester version and guest image.
  It cancels when Y is compared with X, but sits inside each one alone. Compare
  X and Y only from the same Harvester version.
* **CPU placement differs slightly.** The pod pins itself to N CPUs (skipping
  CPU 0, and choosing distinct cores before any SMT sibling). The VM's vCPU
  threads float under a CPU quota of N. That favours the pod a little on cache
  locality.
* **Disk and network keep everything but the VM layer.** Both modes use a raw
  block volume from the same Longhorn storage class, and pod networking across
  the same two nodes. The difference is virtio-blk plus QEMU on the disk side,
  and virtio-net plus KubeVirt's masquerade NAT on the network side. Those are
  exactly the VM layer.
* **A sanity check is built in.** If the VM *beats* the pod on single-thread
  CPU by more than 5%, the report warns that the baseline is suspect.

Confounders to hold constant across the clusters you compare:

* **vCPU count.** Every run uses 4 (`--vcpus`), for both the VM and the pod.
  An `m8i.4xlarge`'s 16 vCPUs are 8 cores with SMT, and Graviton has no SMT.
  That affects absolute numbers, but not the VM/pod ratio, since both modes run
  on the same CPUs.
* **CPU overcommit.** Harvester derives a VM's CPU request from
  `overcommit-config` (default 1600%), so 4 vCPUs request 250m. On an idle
  cluster this does not matter; on a busy one it does. The value is recorded
  in `meta.json`. The e2e suite's overcommit teardown bug can leave a
  non-default value behind.
* **Longhorn replica count.** Recorded from the storage class. It sets how many
  network round trips each write takes, in both modes, so it affects how much
  the virtio layer's share of disk latency shows. Keep it the same everywhere.
* **Network path.** `same_node` in `meta.json` must be false for the network
  figures to mean cross-node.
* **Run-to-run variance.** Run each cluster at least three times and quote the
  median. EC2 virtualized instances have neighbours; metal does not. In the e2e
  campaign, two runs of one version differed by more than two versions did.

For absolute performance (what a cluster delivers, rather than what the VM
layer costs), `hvg.py summary` shows the raw VM figures, and the hvperf suites
cover the platform. Across architectures, the CPU figures are not comparable
in absolute terms, because sysbench and stress-ng count different instructions
on each ISA. The overhead ratios are comparable, because each is taken within
one architecture.

### Limits

* **The guests and pods need package egress.** Both install the tools from
  Ubuntu's archive, and the pods pull their image from Docker Hub. An air-gapped on-prem cluster would need an image with the
  tools baked in; pass it with `--image-url`, and keep in mind it then differs
  from what the AWS runs used.
* **Results arrive only through the serial console log** (KubeVirt's
  `logSerialConsole`). A KubeVirt without it fails fast with "no console log".
* **VMs are not CPU-pinned.** `dedicatedCpuPlacement` needs the CPU manager on
  every node, which Harvester does not enable by default. The pod pins itself;
  the VM cannot. Pinning both would cut variance, and is worth adding once a
  baseline exists.
* **Not run against a live cluster yet.** The harness was verified end to end
  in both modes against a stub `kubectl`. The VM manifests were strictly decoded
  against KubeVirt v1.9.0's API types, and the parsers and the overhead
  arithmetic were exercised on synthetic results. A first real run may still
  find a difference in tool output or in a cluster API.

## Options worth knowing

```bash
./perf/run-perf.sh --suites node-capacity,resource-footprint     # read mostly, no load
./perf/run-perf.sh --suites density --max-vms 0 --batch-size 20  # the real ramp
./perf/run-perf.sh --suites guest --guest-label "m8i run 2"      # only the VM-overhead measurement
./perf/run-perf.sh --suites guest --guest-mode vm                # VM figures only, no pod baseline
./perf/run-perf.sh --suites guest --guest-multiqueue             # VMs get one virtio-net queue per vCPU
./perf/run-perf.sh --perf-ref 6858e2c --keep                     # pin hvperf, keep the runner
./perf/run-perf.sh --down
```

Suites run in the order you give them. `hvperf run all` is not used, because it
runs suites **alphabetically**. That would put density first and the
idle-footprint measurement last, so the footprint would measure the aftermath of
density. The script warns if density is not last.

Pin `--perf-ref` when comparing runs. harvester-perf commits most days, and
`results/<stamp>/cluster.txt` records the commit that ran.

Measured results, configuration by configuration, are collected in [FINDINGS.md](FINDINGS.md).

## Which AWS limit a result is hitting

Several figures from the first `m8i.4xlarge` run, on v1.8.2 (2026-10-16), are
set by an AWS limit rather than by Harvester. Check these before reading
anything into them:

| Limit | Value | Where it shows up |
| --- | --- | --- |
| gp3 volume, as deployed | 3,000 IOPS, 125 MiB/s (the gp3 baseline; the module sets neither) | Seq write is 126 MiB/s and 4K random write is 2,941 IOPS, in **both** the VM and the pod, so both sit at the volume cap. 4K random read is 8,840 IOPS, about 3 × 3,000, because Longhorn serves reads from any of its three replicas, each on a different node's volume. |
| `m8i.4xlarge` EBS bandwidth | 5,000 Mbps / 20,000 IOPS baseline, 10,000 / 40,000 burst | Not reached: the volume caps first, at under a fifth of it. |
| `m8i.4xlarge` network | 7.5 Gbit/s baseline, 15 burst | Pod-to-pod with 4 streams held 13.9 Gbit/s for a full 15-minute `--guest-sustained 900` run, with no drop toward the baseline (2026-10-16). So the instance sustains at least that for this long, and 7.5 is not what limits these tests. |
| The VM network path | ≈7.4 Gbit/s, one stream or four | VM to VM holds 7.3-7.5 Gbit/s flat for 15 minutes while pods hold 13.9, and retransmits about 10× as much. That is a VM-path limit, not AWS. What has been ruled out is in [FINDINGS.md](FINDINGS.md), issue 1. |

CPU quota does not explain the scheduler overhead either. At limit 4 the VM's
container was throttled in 77-99% of CFS periods during the CPU-bound tests,
because QEMU's own threads share the 4-CPU limit with the vCPUs. But those
throttles totalled under a second per 30-second test, and at limit 8 every
CPU-bound figure was within 1-6% of the limit-4 result. The context-switch and
futex costs are nesting, not quota.

The VM and the pod also differ in QoS class. The pod is Guaranteed
(requests = limits). Harvester sets the VM's CPU request to its limit divided
by the CPU overcommit, which defaults to 1000%. That makes the VM Burstable,
with a tenth of the pod's CPU weight. On an idle node that changes nothing; on
a busy one, the VM would lose CPU contention that the pod wins.

All of etcd, Longhorn and the OS share one gp3 volume and its 3,000 IOPS, so
VM disk load and etcd's write-ahead log compete. The results are worth
comparing with on-prem only after the volume is provisioned above its baseline.
Otherwise the disk figures describe gp3, not Harvester.

The VM/pod overhead figures are not affected by any of this: both modes run on
the same node, so they hit the same caps and the caps cancel out. The exception
is network, where only the VM has the single-queue limit.

## Results

```
perf/results/<stamp>/
  summary.md         the whole run as one markdown report (perf/report.py)
  cluster.txt        version, arch, node count/type, monitoring, etcd metrics, hvperf commit,
                     the AWS limits in play, and any preflight warnings
  hvperf.yaml        the config the run used
  <suite>.json       hvperf -o json, one file per suite
  <suite>.log        that suite's progress log (stderr)
  guest.log          the guest suite's progress log
  guest/             the guest suite's own results (below)
```

The guest suite's directory:

```
guest/
  meta.json          label, Harvester and Kubernetes versions, nodes, storage class and replicas, overcommit
  overhead.json      per-figure VM/pod ratios, the four categories and the overall figure
  node-sampler.log   the bench node's steal counter, every 5 s, through both runs
  vm/
    result.json      every workload's figures, plus the guest's own system facts
    bench.log        the bench VM's whole serial console (boot, cloud-init, results)
    peer.log         the peer VM's
    node-steal.json  node steal % during each VM test
    vmi.json         both VMIs as KubeVirt saw them (node, QoS, actual requests)
  pod/               the same for the pod run (pods.json in place of vmi.json)
  nodes.tsv          node name, arch, readiness, allocatable CPU, address, roles
  manifests/         every object exactly as applied
```

`summary.md` follows the upstream poc's `summary.md`: run facts, a suite status
table, the AWS limits that apply, then one section per suite with its key
figures. etcd is judged against the poc's thresholds, 10 ms WAL fsync p99 and
25 ms backend commit p99. The report is rendered from the files above, so any
results directory can be re-rendered, including one from before the report
existed:

```bash
python3 perf/report.py perf/results/<stamp>
```

The script prints a per-case summary at the end. Case states are hvperf's own:
`PASS`, `ERROR`, `SKIP`. For density, `max=` is the last batch count that was
confirmed healthy, and `stopped:` says why the ramp ended.

## Upstream findings

These came out of reading the code, at harvester-perf `6858e2c`. Each one is
worked around here.

| Finding | Workaround here |
| --- | --- |
| `run all` orders suites alphabetically, so the idle footprint is measured after density. | Suites are run one at a time, in a chosen order. |
| The README says `--config` defaults to `./hvperf.yaml`, but the flag defaults to empty. | `--config` is always passed. |
| A global duration overridden in the config file fails to decode (`cannot unmarshal string ... of type time.Duration`), because options round-trip through JSON. Verified. | Only `JobPodNode`, a string, is set at the top level. |
| The etcd job pod is not pinned to a node that runs etcd. On a cluster with workers, it can land where `127.0.0.1:2379` has nothing listening. | `JobPodNode` is set to node 1. |
| The local tool paths for the etcd suite are hardcoded, and the image is single-arch. | The tools are cross-compiled into `/usr/local/bin` on the runner. |
| Density treats VMI `Running` as booted. | arm64 v1.9.x is refused. |
| The etcd peer round-trip query filters on `ConnectionType='ROUND_TRIPPER_RAFT_MESSAGE'`. etcd 3.6 labels that histogram with `To` only (`rafthttp/metrics.go`), so the query always returns nothing. Verified against node metrics and Prometheus, 2026-10-16. | None. Query Prometheus without the filter. With it removed, the v1.8.2 run shows p99 under 3.2 ms. |
