# Harvester on AWS: measured performance

What a workload can expect from Harvester on EC2, configuration by
configuration. Each figure here comes from a run in `perf/results/`, and that
run's `summary.md` has the detail. [README.md](README.md) explains how the
tests work. This file is only what they found. [SIZING.md](SIZING.md) turns it
into deployment advice.

The method: every guest workload runs twice on the same node, first inside a
Harvester VM and then in a plain pod with the same CPU limit, Longhorn volume
type and network. **VM overhead** is the VM's shortfall against the pod.
Because both modes share the hardware, the instance type, the EBS volume and
the network all cancel out. What is left is the cost of the VM layer on that
platform: nested KVM on x86, plain KVM on Graviton metal.

Status: six configurations measured (x86 nested at gp3 baseline, gp3
16,000 / 1,000 and io2; Graviton bare metal at gp3 baseline, provisioned gp3,
and io2), with pgbench and multi-VM contention on both platforms, all on
v1.8.2. [v1.9.0](#harvester-v190-on-configuration-5s-platform) is measured on
one x86 configuration. See [the matrix](#test-matrix) for what is next.

## What to expect on AWS, so far

> **gp3's baseline of 3,000 IOPS / 125 MiB/s is not enough, and is likely to
> cause cluster instability.** Each node's single root volume holds etcd, the
> OS and every Longhorn replica, and each VM write lands on all three nodes'
> volumes. At baseline, that leaves the whole cluster 3,000 write IOPS and
> 125 MiB/s, shared by every VM *and by etcd*. What that did in testing:
>
> - **One VM** writing to its disk saturated all three volumes and pushed
>   etcd's fsync p99 to 31 ms, three times etcd's 10 ms guideline.
> - **Six VMs** writing sequentially pushed it to 933 ms on Graviton, at
>   etcd's 1 s election timeout. API servers on two of the three nodes then
>   **failed their liveness and readiness probes** and returned HTTP 500s, for
>   about three minutes (see [Contention](#the-same-test-with-every-disk-pre-filled)).
> - **On x86 the same test caused a control-plane outage.** etcd's fsync p99
>   reached 1,964 ms. etcd **changed leader**, the kubelet **restarted all three
>   API servers**, the controller-manager and scheduler, a **node went
>   NotReady**, and the cluster VIP moved five times. About 30 system
>   containers restarted, and the API returned 139 HTTP 500s and 22 429s
>   (see [x86 at baseline](#configuration-5b-x86-nested-gp3-baseline)).
>
> A second run reproduced it. Both times the cluster recovered within a minute
> of the load stopping, with no data loss seen, but for three minutes it had
> no reliable control plane. **Do not run a cluster that
> hosts write-active VMs at gp3's baseline.** Set `volume_iops` and
> `volume_throughput` above it at deploy time.
>
> **Provisioning fixes the failures, but not the sharing.** The same six VMs
> at **16,000 IOPS / 1,000 MiB/s** caused no API errors, probe failures or
> restarts, and one busy VM no longer moved etcd at all. Six VMs saturating
> the faster volumes still pushed etcd's fsync p99 to 31 ms (random) and
> 123 ms (sequential), and the API server's etcd p99 to 952 ms. So size the
> volumes for the cluster's combined VM write load, and plan for etcd to have
> its own volume ([matrix 2b](#remaining-in-priority-order)).
>
> **io2 does not change that.** At 16,000 IOPS, six VMs saturating it pushed
> etcd's fsync p99 to 31 ms, the same as gp3
> ([configuration 4](#configuration-4-graviton-io2-at-16000-iops)). Across
> every tier tested, **etcd stays healthy while VM writes stay below the
> volume's IOPS and MiB/s limits, and the instance's EBS bandwidth, and
> degrades once they reach any of them**, whatever the volume type.

Preliminary: x86 has six consistent guest runs (three of them pgbench) and
three contention runs. Graviton has six guest runs (three
of them pgbench) and five contention runs: gp3 at baseline (fresh and
pre-filled), gp3 at 16,000 / 1,000 and 16,000 / 2,000, and io2 at 16,000.

| | x86, nested (`m8i.4xlarge`) | Graviton, bare metal (`c7g.metal`) |
| --- | --- | --- |
| **Overall VM overhead** against a pod on the same node | **18.5–20.9%** over six runs | **8.5–15.1%** over six runs (the spread is the noisy scheduler figure) |
| Compute (CPU, memory) | 1–5% | under 1% |
| Exit-heavy work (context switches, futex) | 31% / 56% slower | the category varies from about 0 to 28% run to run |
| Disk, on top of what the volume allows | about 4% | about 3% |
| Network round trip, VM to VM | 0.75 ms (2.5× a pod) | 0.35 ms (1.9× a pod) |
| One VM's network throughput, sustained | **≈7.4 Gbit/s** (pods: 13.9) | **≈6.0 Gbit/s** (pods: 12.9) |
| One VM on the kube-ovn overlay, to and from a VPC host, 4 streams, 30 s | **12.2–12.6 Gbit/s in, 14.2–14.3 out**; the node itself: 14.35 | not measured |
| Disk, gp3 at baseline (3,000 IOPS / 125 MiB/s) | writes capped at 2,950 IOPS / 126 MiB/s | same |
| Disk, gp3 at 16,000 IOPS / 1,000 MiB/s | 11,800 IOPS 4K write; **298 MiB/s** seq write; **143 MiB/s seq read, unchanged from baseline** | 14,100 IOPS 4K write; 452 MiB/s seq write (Longhorn's per-volume cap); 1,060 MiB/s seq read |
| Disk, single-threaded fsync (qd1), gp3 | 650 IOPS, p99 2.0 ms, **unchanged by provisioning** | 790 IOPS, p99 1.4 ms, **unchanged by provisioning** |
| Disk, io2 at 16,000 IOPS | 16,000 IOPS 4K write; **584 MiB/s** seq write; **fsync 1,060 IOPS, p99 1.35 ms (+66%)**; seq read still 131 MiB/s | 15,900 IOPS 4K write; 518 MiB/s seq write; **fsync 1,400 IOPS, p99 1.06 ms (+74%)** |
| **PostgreSQL (pgbench), gp3 16,000 / 1,000** | **441 / 2,096 / 4,988 transactions/s**; 15–19% below a pod | **565 / 2,600 / 4,605 transactions/s** at 1 / 8 / 32 clients; 10–18% below a pod |
| **PostgreSQL (pgbench), io2 16,000** | **640 / 3,374 / 7,107 transactions/s**: +45% / +61% / +42% over gp3 16,000 | **844 / 4,219 / 5,473 transactions/s**: +49% / +62% / +19% over gp3 16,000. 32 clients are CPU-bound in a 4-vCPU VM |
| **PostgreSQL (pgbench), gp3 baseline** | **447 / 2,060 / 4,365 transactions/s**: +1% / −2% / −12% against gp3 16,000 | **564 / 2,449 / 4,135 transactions/s**: 0–10% below provisioned, although the volume lost about 80% of its write IOPS |
| **One VM on EFS: fsync and PostgreSQL** | **106 fsync/s (p99 17 ms); pgbench 114 / 452 / 1,179 tps**, about a quarter of Longhorn. Seq read 1,009 MiB/s | not measured |
| **6 VMs writing at once, data disks on EFS, nodes at gp3 baseline** | **11,200 IOPS / 1,037 MiB/s**; node volumes idle and **etcd at its idle 3.9 ms throughout**. One VM alone: 2,898 IOPS at qd32 (about 11 ms per write) |
| **6 VMs writing at once, gp3 baseline** | **2,964 IOPS / 125 MiB/s**, one volume's capacity. Filled disks: etcd fsync p99 **1,964 ms**, an etcd leader change, all three API servers restarted, a node NotReady: **a control-plane outage** | **2,960 IOPS / 125 MiB/s in total, the same as one VM**: the whole cluster shares one volume's write capacity. With filled disks, etcd WAL fsync p99 reached 933 ms and two API servers **failed their health probes** |
| **6 VMs writing at once, gp3 16,000 / 1,000** | **16,033 IOPS / 1,006 MiB/s**, the volume's capacity. No failures; etcd p99 31 ms (random) and **216 ms** (sequential) | **16,031 IOPS / 1,011 MiB/s in total**, still one volume's capacity. No failures, but etcd WAL fsync p99 reached 31–123 ms under saturating load |
| **6 VMs writing at once, gp3 16,000 / 2,000** | not measured | **16,031 IOPS / 2,045 MiB/s**, both at the volume's limits. etcd p99 31 ms in both phases, against 123 ms sequential at 1,000 MiB/s. No failures |
| **6 VMs writing at once, io2 16,000** | **16,031 IOPS / 1,198 MiB/s**, the instance's EBS burst limit. Sequential etcd p99 127 ms, API 979 ms. No failures | **15,980 IOPS / 1,970 MiB/s**. Random: etcd p99 31 ms, the same as gp3. Sequential: etcd unaffected (2 ms), with the volume below its 4,000 MiB/s limit |

What that means for sizing:

- **Nesting costs about 5 points of overall overhead**, almost all of it in
  compute (3–5% against under 1%) and network latency (+0.45 ms against
  +0.17 ms). For compute-bound VMs, nested x86 is close to bare metal. For
  latency-sensitive or chatty VMs, Graviton metal is the better fit.
- **One VM's network throughput is capped at roughly 6–7.5 Gbit/s on both
  platforms**, about half of what pods on the same nodes sustain, **VM to VM
  on Harvester's default pod network**. Nesting does not cause it. **On a
  kube-ovn overlay, a VM talking to a host elsewhere in the VPC reached
  12–14 Gbit/s**, close to the node's own 14.35
  ([VM to and from the VPC](#vm-network-to-and-from-the-vpc)). So the cap
  belongs to the VM-to-VM path or the masquerade network, not to every VM
  NIC. See issue 1.
- **Provision gp3 above baseline for any disk-heavy cluster.** At 16,000 IOPS /
  1,000 MiB/s, VM random writes rise 4.8×, sequential writes 3.6× and
  sequential reads 2.9×, with no redeploy. Two things it does not help:
  sequential writes stop at about 460 MiB/s per VM disk, in Longhorn's
  per-volume engine path (replication is not the cause), and single-threaded
  fsync stays at about 800–900 IOPS (p99 1.2–1.4 ms). That second one matters
  for databases that commit synchronously. Replication accounts for only 16%
  of that latency; most of the rest is EBS's, and io2 cuts it (below).
- **A PostgreSQL VM does about 565 durable transactions per second on one
  connection, and about 4,600 on 32**, on Graviton with gp3 at 16,000 IOPS. One
  connection is bound by commit latency: each commit waits about 1.2–1.4 ms for
  Longhorn and EBS. More connections overlap their commits. The VM gets 81–90%
  of what the same database gets in a pod.
- **For a small OLTP database, provisioned gp3 IOPS buy little; latency is the
  limit.** At gp3's baseline the same database lost 0% (1 client) to 10% (32
  clients), while fio's write IOPS fell about 80%. Provisioning pays off for
  bulk work, such as loading data (55% faster) and sequential writes (3.6×), for
  databases larger than memory, and for several busy VMs sharing the cluster's
  volumes.
- **io2 is the change that speeds up commits.** At the same 16,000 IOPS, it
  raised fsync rate 74% and single-connection PostgreSQL 49%, at about 8× the
  cost of gp3 per volume. Every node pays it, because each node has one
  volume. It does not shield etcd from VMs that saturate its IOPS.
- **Size the volumes above the cluster's combined VM write demand, in IOPS
  and MiB/s.** etcd stayed near idle whenever the VMs did not reach the
  volume's limits, and reached about 31 ms (123 ms at gp3 1,000's sequential
  limit) whenever they did. gp3 at 2,000 MiB/s cut the sequential case from
  123 to 31 ms for $40 a volume more than 1,000 MiB/s.
- **At gp3's baseline, a cluster's total VM write capacity is one node's
  volume, and VM disk load can take the control plane down with it.** Every
  VM and etcd share 3,000 IOPS / 125 MiB/s. Even **one** VM writing to a filled
  disk saturates every node's volume and pushes etcd's fsync p99 to 31 ms,
  three times its 10 ms guideline. Six VMs doing sequential writes pushed it
  to 933 ms. API servers on two of the three nodes then failed their own
  liveness and readiness probes, with HTTP 500s, for about three minutes.
  They recovered when the load stopped. **On x86 the same load went further:**
  an etcd leader change, all three API servers restarted by the kubelet, a
  node NotReady and the VIP moving five times. **This is the most serious
  risk found:**
  provision the volumes for any real cluster, and give etcd a volume of its
  own (not yet supported by the module).
- **New VM disks are slower until written: confirmed.** Longhorn volumes are
  thin. On a fresh disk, a VM managed 1,119 random-write IOPS; after
  writing the disk once, 2,955. That is a 2.6× penalty on first writes.
- **Graviton guest VMs need v1.8.2 today.** On v1.9.0 they cannot boot (see
  the [README](../README.md#what-has-been-tested)).

---

## Configuration 1: x86, nested virtualization

| | |
| --- | --- |
| Harvester | v1.8.2 (Kubernetes v1.35.7+rke2r1) |
| Nodes | 3 × `m8i.4xlarge` (16 vCPU, 64 GiB), nested virtualization, one AZ |
| Node volume | gp3, 500 GiB, **3,000 IOPS / 125 MiB/s** (gp3 baseline; not provisioned higher) |
| Network | MTU 1500 (Terraform default). Instance: 7.5 Gbit/s baseline, 15 burst |
| VM | 4 vCPU / 8 GiB, Harvester defaults: one virtio-net queue, CPU limit = vCPUs, Burstable QoS |
| Measured | 2026-10-16, harvester-perf `6858e2c` |
| Runs | `20261016-173833`, `-181738`, `-203601`, `-215128`, `-220721`, `-235616` |

### VM overhead against a pod on the same node

Three runs with the same VM configuration, the default or the default plus
multiqueue, agree to within about 2 points in every category:

| Category | `-181738` | `-203601` (multiqueue) | `-235616` | What it measures |
| --- | --- | --- | --- | --- |
| Compute | +0.6% | +2.9% | +3.1% | sysbench CPU and memory |
| Scheduler | +34.3% | +35.7% | +33.1% | context switches, futex wake/wait, page faults |
| Disk | +4.6% | +5.4% | +3.8% | fio on Longhorn |
| Network | +29.1% | +33.8% | +33.0% | iperf3 and ping, VM to VM across two nodes |
| **Overall** | **+18.5%** | **+20.9%** | **+19.6%** | the four categories weighted equally |

**A VM on nested x86 delivers about 80% of what the same work gets in a pod on
the same node.** The cost is concentrated, not spread evenly:

| Figure (run `-235616`) | Pod | VM | VM overhead |
| --- | --- | --- | --- |
| CPU, per vCPU | 1,281 events/s | 1,246 | +2.7% |
| Memory bandwidth, all vCPUs | 14,740 MiB/s/vCPU | 14,630 | +0.7% |
| Context switches | 706,800 ops/s/vCPU | 489,400 | **+30.8%** |
| Futex wake/wait | 95,410 ops/s/vCPU | 42,290 | **+55.7%** |
| Page faults | 23,230 ops/s/vCPU | 22,710 | +2.2% |
| Disk seq read 1M | 175 MiB/s | 143 | +18.5% |
| Disk 4K write + fsync | 713 IOPS | 648 | +9.1% |
| Network, 1 stream | 7.38 Gbit/s | 7.24 | +1.9% |
| Network, 4 streams, 15 min sustained | **13.85 Gbit/s** | **7.36** | **+46.8%** |
| Network round trip | 0.30 ms | 0.75 ms | **2.5× the latency** (+59.9% as overhead) |

Compute-bound work barely notices nesting. The cost falls on anything that
makes the guest exit to the hypervisor: thread wakeups, inter-processor
interrupts, timers and packets. With nesting, every exit passes through two
hypervisors, Harvester's KVM and the Nitro hypervisor underneath it.

### Absolute figures: what a VM gets on this configuration

| | Value | Bounded by |
| --- | --- | --- |
| CPU | ≈1,250 sysbench events/s per vCPU | nothing measured; per-thread speed matches a pod |
| Disk seq write | 126 MiB/s | **the gp3 volume's 125 MiB/s**, in both modes |
| Disk 4K random write, qd32 | 2,950 IOPS | **the gp3 volume's 3,000 IOPS**, in both modes |
| Disk 4K random read, qd32 | 8,840 IOPS | about 3 × 3,000: Longhorn reads from all three replicas, each on a different node's volume |
| Disk 4K write + fsync, qd1 | 650 IOPS, p99 2.0 ms | gp3 latency plus Longhorn's synchronous three-way replication |
| Network, VM to VM | 7.2–7.4 Gbit/s, one stream or four | the VM path; see issue 1 |
| Network, pod to pod | 13.9 Gbit/s sustained for 15 min | at least that; no drop to the 7.5 Gbit/s baseline was seen |
| etcd WAL fsync p99 | under 4 ms (threshold 10 ms) | gp3, shared with Longhorn and the OS |
| etcd writes, 500 clients | 39,000/s, p99 21 ms | |
| VM start, creation to `Running` | p50 ≈15 s, p99 ≈20 s, for 50 VMIs | `Running` is QEMU started, not guest booted |

### Issues identified

These are recorded, not fixed. Each one says what was ruled out, so it is not
re-tested.

1. **VM network throughput is capped at about 7.4 Gbit/s, half of what the node
   sustains.** Four streams, VM to VM, hold 7.3–7.5 Gbit/s flat for 15 minutes,
   while pods on the same two nodes hold 13.9. One stream is equal in both
   modes, so the VM's four streams get no more than one. The VM path
   retransmits about 10× as much (230,892 against 21,631 over 15 minutes), so
   packets are being dropped inside it and TCP is backing off. Ruled out:
   - the AWS instance limit (pods sustain 13.9);
   - packet size (MSS 1398 in both modes);
   - the queue count (multiqueue with `queues='4'` verified: 7.7–8.1 Gbit/s);
   - the sending VM's CPU quota (0.3% of periods throttled during the test).

   With multiqueue **and** a VM CPU limit of 8, it reached 10.0 Gbit/s once,
   which leaves the receiving VM's quota as a suspect. **Nesting is ruled out
   too:** Graviton bare metal shows the same pattern, with VMs at 6.0 Gbit/s
   sustained against pods at 12.9 (configuration 2). Still open: KubeVirt's
   masquerade NAT, and the per-packet cost of the VM path. MTU 9001 would cut
   the packet rate about sixfold and is the next configuration to try.
2. **Exit-heavy work loses 30–56%, and network latency is 2.5× higher.** Context
   switches lose 31%, futex wake/wait 56%, and ping round trips grow from 0.30
   to 0.75 ms. This is nesting itself: giving the VM CPU headroom (limit 8 instead
   of 4) changes the CPU-bound figures by 1–6%. Expect it in databases, message
   brokers and anything chatty over the network. Graviton metal is the comparison
   that will size it.
3. **Disk figures describe gp3 at its baseline, not Harvester.** Writes sit at
   the volume's 3,000 IOPS and 125 MiB/s in both modes. The VM layer itself costs
   about 4% on disk.
4. **etcd, Longhorn and the OS share one volume and its 3,000 IOPS.** A busy VM
   disk competes with etcd's write-ahead log. etcd is healthy at idle (fsync p99
   under 4 ms), but nothing has measured it under VM disk load yet.
5. **VMs are Burstable and pods are Guaranteed.** Harvester sets a VM's CPU
   request to its limit divided by the CPU overcommit (1000% by default), so a VM
   has a tenth of a same-sized pod's CPU weight. That makes no difference on an
   idle node; on a contended one, the VM loses.

---

## Configuration 2: Graviton, bare metal

Same as configuration 1 except the platform: same Harvester version, node
count, volume, replica count, MTU, subnet and AZ, VM shape and
harvester-perf commit. The VM runs on plain KVM, with no nesting.

| | |
| --- | --- |
| Harvester | v1.8.2, arm64 (guest firmware `qemu-uefi-aarch64-202408`, which boots) |
| Nodes | 3 × `c7g.metal` (64 vCPU Graviton3, 128 GiB), bare metal, one AZ |
| Node volume | gp3, 500 GiB, 3,000 IOPS / 125 MiB/s, identical to configuration 1 |
| Network | MTU 1500. Instance: 30 Gbit/s, no burst tier |
| VM | 4 vCPU / 8 GiB, Harvester defaults, identical to configuration 1 |
| Measured | 2026-10-19, harvester-perf `6858e2c`, one run: `20261019-172256` |

All five suites passed.

### VM overhead: nested x86 against Graviton bare metal

| Figure | x86 nested (`-235616`) | Graviton metal (`-172256`) |
| --- | --- | --- |
| CPU, 1 thread / all vCPUs | +4.4% / +2.7% | +0.7% / +0.3% |
| Memory seq write / random 4K | +2.7% / +5.2% | +0.5% / +0.3% |
| Context switches | +30.8% | **+63.3%** |
| Futex wake/wait | **+55.7%** | +6.0% |
| Page faults | +2.2% | −9.0% |
| Disk seq read 1M | +18.5% | +1.5% |
| Disk 4K write + fsync | +9.1% | +7.0% |
| Network, 1 stream | +1.9% | +2.4% |
| Network, 4 streams, 15 min sustained | +46.8% | **+53.1%** |
| Network round trip | +59.9% (0.30 → 0.75 ms) | +48.0% (0.18 → 0.35 ms) |
| **Category: compute / scheduler / disk / network** | +3.1 / +33.1 / +3.8 / +33.0 | +0.4 / +27.8 / +2.6 / +25.7 |
| **Overall** | **+19.6%** | **+15.1%** |

Read the two columns as **each platform's VM measured against its own pods**.
That makes the overheads comparable even though the CPUs differ. The absolute
compute figures are not comparable: an Arm Neoverse V1 core and a Xeon core
score differently on sysbench regardless of virtualization.

### What changed, and what did not

1. **Nesting's own cost is small and specific.** Compute overhead goes from 1–5%
   to under 1%, and VM latency drops from +0.45 ms to +0.17 ms. That accounts
   for most of the 5-point drop in overall overhead.
2. **The network cap is the same without nesting.** VM to VM, four streams hold
   about 6.0 Gbit/s against pods' 12.9, the same half-of-pod shape as on x86. It
   is a property of Harvester's VM network path. On Graviton the VM also
   retransmits more (324,035 in 15 minutes, against the x86 VM's 230,892).
3. **The scheduler cost moves rather than disappearing.** Graviton VMs pay 63%
   on context switches, double x86's 31%, but almost nothing on futex, where x86
   pays 56%. The category totals are similar (28% against 33%). This is the cost
   of KVM itself, and its shape is architecture-specific. A likely reason, not
   measured, is that on Arm, waking a blocked vCPU goes through the interrupt
   controller. Either way, it is not nesting.
4. **Per-stream network speed is a property of the platform, not the VM.**
   Graviton pods manage 4.6 Gbit/s on one stream against x86's 7.4, and VMs track
   their pods on both. A single flow is limited by the per-core packet rate,
   which these Graviton3 cores deliver less of.

### Absolute figures, side by side

| | x86 nested | Graviton metal |
| --- | --- | --- |
| Disk seq write / 4K random write | 126 MiB/s / 2,947 IOPS | 126 MiB/s / 2,940 IOPS (the same gp3 caps) |
| Disk 4K write + fsync (VM) | 648 IOPS, p99 1.99 ms | 794 IOPS, p99 1.45 ms |
| Network, VM to VM, sustained | 7.4 Gbit/s | 6.0 Gbit/s |
| Network, pod to pod, sustained | 13.9 Gbit/s | 12.9 Gbit/s |
| etcd WAL fsync p99 / backend commit p99 | 3.95 / 3.98 ms | 3.91 / 6.67 ms |
| etcd concurrent writes | 39,148/s, p99 21 ms | 39,108/s, p99 27 ms |
| VM start, 50 VMIs | 100 s; every start 10–20 s | 96 s; every start 10–20 s |
| Harvester's own CPU **requests**, whole cluster | 14 cores of 45 | 31 cores of 188 |
| Harvester's own memory requests / use | 14.4 GiB / 17 GiB | 14.4 GiB / 20 GiB |

Harvester's CPU reservation grows with the node's core count, roughly 31%
of a 16-vCPU node against 17% of a 64-vCPU one. Its memory reservation does
not. On small nodes, plan for about a third of the CPU going to Harvester
itself.

One measurement gap: hvperf's density metrics query returned no data on this
cluster, although Prometheus had it. The query runs over a window as short as
the ramp, 96 s here, right after the ramp ends. The start times above come
from querying the same histogram directly.

---

## Configuration 3: Graviton, provisioned gp3

Configuration 2's cluster, with every node's root volume changed in place to
**16,000 IOPS / 1,000 MiB/s** (Terraform `volume_iops` / `volume_throughput`).
All three volumes finished optimizing, in about 15 minutes, before the run
started. Nothing else changed: same nodes, same Longhorn replicas, same flags.

| | |
| --- | --- |
| Measured | 2026-10-19/20, harvester-perf `6858e2c`, one run: `20261019-205938` |
| Instance limits | `c7g.metal` EBS: 20,000 Mbps / 80,000 IOPS, so the instance is not the cap |

All five suites passed.

### Disk: baseline against provisioned

| Figure | Pod, baseline → provisioned | VM, baseline → provisioned | VM change |
| --- | --- | --- | --- |
| Seq write 1M qd16 | 126 → 453 MiB/s | 126 → 452 MiB/s | ×3.6 |
| Seq read 1M qd16 | 374 → 1,577 MiB/s | 369 → 1,059 MiB/s | ×2.9 |
| 4K random write qd32 | 2,939 → 13,810 IOPS | 2,940 → 14,130 IOPS | ×4.8 |
| 4K random read qd32 | 8,820 → 21,530 IOPS | 8,828 → 21,590 IOPS | ×2.4 |
| 4K random read qd1, p99 | 1,188 → 1,106 µs | 1,237 → 1,188 µs | unchanged |
| 4K write + fsync qd1 | 854 → 857 IOPS | 794 → 792 IOPS | **unchanged** |
| Write + fsync, p99 | 1,368 → 1,335 µs | 1,450 → 1,401 µs | unchanged |

| etcd | Baseline | Provisioned |
| --- | --- | --- |
| WAL fsync p99 | 3.91 ms | 3.92 ms |
| Backend commit p99 | 6.67 ms | 3.94 ms |
| Serial / concurrent writes | 688 / 39,108 per s | 672 / 38,499 per s |

### What it shows

1. **Throughput and queue depth scale with the volume.** Random writes reach
   88% of the provisioned 16,000 IOPS, in both modes. Random reads exceed it,
   because Longhorn spreads reads over three replicas on three volumes.
2. **Sequential writes stop at about 452 MiB/s in both modes.** That rules out
   the VM layer, the volume (1,000 MiB/s provisioned) and the instance
   (2,500 MB/s). It is in Longhorn. **It is not replication:** with a single
   local replica it is 461 MiB/s (configuration 3b).
3. **Latency-bound I/O does not change at all.** Single-threaded fsync stays
   at about 800 IOPS, with p99 around 1.4 ms, because each write waits on a
   replica round trip. More IOPS cannot shorten that. etcd's WAL fsync is
   unchanged for the same reason.
4. **The pod reads faster than the VM, but that is not VM overhead.** Sequential
   reads are 1,577 MiB/s in the pod against 1,059 in the VM, which pushes the
   disk category from +2.6% to +7.8%. Configuration 3b explains it. With one
   replica, both modes read 1,006–1,008 MiB/s, the volume's provisioned
   1,000 MiB/s. With three, the pod spreads its reads over the three
   replicas' volumes more effectively than the VM does. The VM is giving up
   a multi-replica bonus, not paying a cost.

### Run-to-run variance on Graviton

The overall overhead fell from 15.1% to 9.7%, but **not because of the disk**.
The scheduler category went from +27.8% to +3.0%, and one figure is behind it:
the VM's context-switch rate doubled (147,000 to 294,000 ops/s/vCPU), while
the pod's held steady at about 400,000. Nothing about the volume touches
that. The Graviton VM's context-switch figure is simply unstable from run to
run, so Graviton's scheduler cost can only be given as a range, 3–28%, until
more runs narrow it. The other categories agree across the two runs: compute
+0.4% both times, network +25.7% and +25.5%.

---

## Configuration 3b: one local replica

Configuration 3's cluster and volume (16,000 IOPS / 1,000 MiB/s), with the
fio data disk on a Longhorn storage class with **one replica and
`dataLocality: best-effort`** (`perf-longhorn-1replica-local`). That puts the
single replica on the node where the disk is attached, so the data path has
no replication and no network. Placement was checked during the run: the bench
VM's disk was attached on node 3, and its one replica was running there. Root
disks kept the default three-replica class, and only the data disk changed.

| | |
| --- | --- |
| Measured | 2026-10-20, guest suite only, run `20261019-220850` |
| Run with | `--guest-storage-class perf-longhorn-1replica-local` |

| Figure | Pod, 3 → 1 replica | VM, 3 → 1 replica | VM overhead at 1 replica |
| --- | --- | --- | --- |
| Seq write 1M qd16 | 453 → 462 MiB/s | 452 → 461 MiB/s | +0.1% |
| Seq read 1M qd16 | 1,577 → 1,008 MiB/s | 1,059 → 1,006 MiB/s | +0.2% |
| 4K random write qd32 | 13,810 → 15,990 IOPS | 14,130 → 15,960 IOPS | +0.2% |
| 4K random read qd32 | 21,530 → 15,940 IOPS | 21,590 → 15,940 IOPS | 0.0% |
| 4K random read qd1, p99 | 1,106 → 995 µs | 1,188 → 1,020 µs | +2.4% |
| 4K write + fsync qd1 | 857 → 999 IOPS | 792 → 920 IOPS | +7.9% |
| Write + fsync, p99 | 1,335 → 1,106 µs | 1,401 → 1,171 µs | +5.6% |

What one replica shows:

1. **The ~460 MiB/s sequential-write cap is Longhorn's per-volume engine path,
   not replication.** It barely moves with the replica count, with no network
   in the path, and it is the same in both modes. To write faster than this,
   a VM needs more disks, not a faster volume.
2. **Random I/O reaches the volume exactly.** One replica takes writes to
   15,960 IOPS and reads to 15,940, both the provisioned 16,000. With three
   replicas, writes lose 12% to replication and reads gain 35% from
   spreading over three volumes.
3. **Replication is a small part of sync-write latency.** fsync p99 is 1.40 ms
   with three replicas and 1.17 ms with one, so replication costs 0.23 ms
   (16%). The VM layer adds about 0.07 ms on top of the pod. The remaining
   ~1.1 ms is Longhorn's engine plus EBS's own write latency, and nothing
   tested so far moves it.
4. **The VM layer costs almost nothing on disk** once nothing else is in the
   way: +0.0–0.2% on every throughput figure, and 2–8% on the latency-bound
   ones.

The storage class is left on the cluster for reuse, and it is not the
default. Do not use it for real VMs: one replica has no redundancy. To
remove it: `kubectl delete storageclass perf-longhorn-1replica-local`.

---

## Workload: PostgreSQL (pgbench)

A fresh Graviton cluster built to configuration 3's settings: 3 × `c7g.metal`,
v1.8.2, gp3 **created** at 16,000 IOPS / 1,000 MiB/s, and the default
three-replica `harvester-longhorn` class.

| | |
| --- | --- |
| Measured | 2026-10-20, guest suite with `--guest-pgbench`, run `20261020-113253` |
| PostgreSQL | 16.15, Ubuntu 24.04's package in both the VM and the pod |
| Workload | pgbench's TPC-B-like default, scale 100 (1.5 GiB database), 120 s per client count, client on the same machine over a Unix socket |
| Settings | `shared_buffers=1GB`, `max_wal_size=4GB`; durability on (`fsync`, `synchronous_commit`, `wal_sync_method=fdatasync`) |
| Storage | ext4 on a Longhorn volume: the VM formats its data disk itself; the pod gets a filesystem-mode PVC of the same class |

| Clients | Pod tps | Pod latency | VM tps | VM latency | VM overhead |
| --- | --- | --- | --- | --- | --- |
| 1 | 643 | 1.55 ms | **565** | 1.77 ms | 12.1% |
| 8 | 2,887 | 2.77 ms | **2,600** | 3.08 ms | 9.9% |
| 32 | 5,629 | 5.68 ms | **4,605** | 6.95 ms | 18.2% |

No transaction failed in any run.

### What it shows

1. **One connection is bound by commit latency, as the disk figures
   predicted.** In the same run, fio measured 808 fsyncs per second on the
   VM's disk (p99 1.43 ms). A pgbench transaction is several statements and
   one durable commit, so 565 per second, about 70% of the raw fsync rate, is
   what that ceiling allows. Provisioning more IOPS cannot raise it (see
   configuration 3). Only a lower-latency write path could, which is matrix
   tests 3 and 4.
2. **Throughput scales with connections:** 4.6× at 8 clients and 8.1× at 32.
   Concurrent commits share the work, so total throughput rises while each
   transaction waits a little longer. A database serving many connections
   gets far more than the single-connection figure.
3. **The VM costs 10–18% against the same database in a pod.** That is close
   to the overall VM overhead measured for this platform. The 32-client
   figure is the highest, where the database is most dependent on thread
   wakeups, which is where the VM layer costs most.

### The same database at gp3's baseline

The same cluster, with every volume changed in place to **3,000 IOPS /
125 MiB/s**. That took 82 minutes of optimizing, against about 15 for raising
them. The run started only once all three volumes reported `completed`
(`20261020-140320`).

| Clients | Pod: 16,000 → baseline | VM: 16,000 → baseline | VM overhead at baseline |
| --- | --- | --- | --- |
| 1 | 643 → 638 tps (−1%) | 565 → 564 tps (0%) | 11.6% |
| 8 | 2,887 → 2,843 tps (−2%) | 2,600 → 2,449 tps (−6%) | 13.9% |
| 32 | 5,629 → 5,106 tps (−9%) | 4,605 → 4,135 tps (−10%) | 19.0% |

| fio, same runs (VM) | 16,000 IOPS | Baseline |
| --- | --- | --- |
| 4K random write qd32 | 14,263 IOPS | 2,942 IOPS (−79%) |
| Sequential write | 454 MiB/s | 126 MiB/s (−72%) |
| 4K write + fsync qd1 | 808 | 808 (unchanged) |
| Loading the database (`pgbench -i`) | 20 s | 31 s (55% slower) |

**The volume lost about 80% of its write capacity, and the database lost at
most 10%.** This database fits in memory, so it reads almost nothing from
disk. What it writes is the write-ahead log, flushed on every commit, so it is
limited by how long a flush takes, not by how many the volume allows. Only at
32 clients, where commits are frequent enough to begin queueing, does the
lower IOPS ceiling show. Loading the data, which is bulk sequential I/O,
felt the full drop.

Sizing consequence: for a small, memory-resident OLTP database on one VM,
gp3's baseline is close to as good as provisioned. Provisioned IOPS are worth
it for:
- bulk loads and restores;
- databases larger than memory, which read from disk;
- any cluster where several VMs write at once, because the baseline's 3,000
  IOPS are shared cluster-wide. The contention test below measures this.

The VM overhead held at 10–19% at both volume settings.

### Graviton scheduler variance, six samples

The two pgbench runs added two more Graviton samples: +18.6% and −0.9%. That
makes five: −0.9, 3.0, 8.8, 18.6 and 27.8%. This run also shows the **pod's**
context-switch rate moving, from about 400,000 to 260,000 ops/s/vCPU. The
variance is in the host, not only in the VM. Quote Graviton's scheduler
overhead as roughly 0–28%, about 11% on average, and treat absolute
context-switch figures on `c7g.metal` as unstable from host to host. The io2
run added a sixth sample, +20.7%: −0.9 to 27.8%, about 13% on average.

---

## Contention: six VMs writing at once, gp3 baseline

The pgbench cluster, with volumes still at **3,000 IOPS / 125 MiB/s**. Six
VMs (4 vCPU, 8 GiB) were placed two per node, each with its own 10 GiB data
disk on the default three-replica class. All of them ran fio on one
wall-clock schedule, 180 s per phase: VM 0 alone first, then all six doing
4K random writes (qd32), then all six doing 1 MiB sequential writes (qd16).
Every VM started every phase on time (latest 0.5 s late). Node figures come
from node-exporter on each node's EBS volume. etcd figures come from a PodMonitor
scraping etcd every 10 s for the run, and from the API server's own timings of
its etcd requests.

| Run | `20261020-144624`, `run-perf.sh --suites guest --guest-contention 6` |
| --- | --- |

| Phase | Total VM writes | Per VM min / mean / max | Worst VM p99 | Each node's volume | Volume latency | etcd WAL fsync p99 | API → etcd p99 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Idle | – | – | – | 67–70 writes/s | 0.87 ms | 3.9 ms | 5.0 ms |
| One VM, 4K random | 1,119 IOPS | 1,119 | 36 ms | 1,188–1,191 writes/s | 0.87 ms | 3.9 ms | 7.4 ms |
| Six VMs, 4K random | **2,940 IOPS** | 314 / 490 / 1,358 | 271 ms | **3,004–3,007 writes/s** | 2.6–3.7 ms | **31 ms** | **49 ms** |
| Six VMs, 1 MiB sequential | **125 MiB/s** | 20.8 / 20.9 / 20.9 MiB/s | 1,283 ms | **125.1 MiB/s** | 43 ms | **236 ms** | **989 ms** |

### What it shows

1. **The cluster's write capacity is one volume's, as predicted, now
   measured.** Under both random and sequential load, all three nodes'
   volumes sat exactly at gp3's 3,000 writes/s and 125 MiB/s, together. The six
   VMs got 2,940 IOPS and 125 MiB/s between them, what a single VM gets on its
   own. Each VM write lands on all three volumes, so adding VMs adds no
   capacity.
2. **VM disk load reaches the control plane.** etcd shares those volumes. Its
   write-ahead-log fsync p99 went from 3.9 ms to 31 ms under random load and
   236 ms under sequential, past etcd's commonly cited 10 ms limit. The
   API server's p99 for etcd requests went from 5 ms to 49 ms and then
   989 ms. Every `kubectl` call and every controller loop pays that.
3. **It did not break, in three-minute bursts.** Across the window: no etcd
   leader changes, no failed proposals, no API 5xx or 429 responses, no
   restarted containers, all nodes Ready throughout, Longhorn volumes healthy,
   and the VIP lease never moved. Longer saturation was not tested and is a
   real risk: etcd's default election timeout is 1 s, and API-side latency
   was already approaching that.
4. **Sequential writes were shared evenly; random writes were not.** Under
   sequential load every VM got 20.8–20.9 MiB/s. Under random load, VM 0 got
   1,358 IOPS and the other five got 314–318. VM 0 is the only one whose disk
   had already been written, during the solo phase.
5. **New disks pay a first-write penalty.** VM 0, alone on a brand-new disk,
   managed 1,119 IOPS with its node volumes only 40% busy. Earlier single-VM
   runs, whose fio fills the disk before measuring, managed 2,942 at the same
   setting. Longhorn volumes are thin: the first write to each block also
   allocates it, at about 2.6× the cost. This is consistent across this run,
   but not yet isolated, and a contention run that pre-fills the disks would
   confirm it.

### The same test with every disk pre-filled

Same cluster, volumes and schedule, but each VM first wrote its whole 10 GiB
disk once (`--guest-contention-prefill`). The phases therefore measure
overwrites: the steady state of VMs that have been running for a while
(`20261020-155019`).

| Phase | Total VM writes | Per VM min / mean / max | Worst VM p99 | Each node's volume | etcd WAL fsync p99 | API → etcd p99 |
| --- | --- | --- | --- | --- | --- | --- |
| Pre-fill, all six at once | 6 × 10 GiB in 503 s | 20.0–20.9 MiB/s | – | at the 125 MiB/s cap | – | – |
| Idle | – | – | – | 61–62 writes/s | 3.9 ms | 13.8 ms |
| One VM, 4K random | **2,955 IOPS** | 2,955 | 14 ms | **3,001–3,003 writes/s** | **30.6 ms** | 43 ms |
| Six VMs, 4K random | 2,964 IOPS | **483 / 494 / 510** | 90 ms | 3,001–3,024 writes/s | **126 ms** | **986 ms** |
| Six VMs, 1 MiB sequential | 125 MiB/s | 20.2 / 20.8 / 21.7 MiB/s | 2,164 ms | 1,025–1,026 writes/s, 125 MiB/s | **933 ms** | **~5,000 ms** |

What pre-filling changed:

1. **The first-write penalty is confirmed.** One VM alone went from 1,119 IOPS
   on a fresh disk to 2,955 on a written one, the same as the earlier
   single-VM runs (2,942).
2. **Sharing is fair.** With filled disks, the six VMs got 483–510 IOPS each.
   The earlier 4× spread came entirely from fresh disks.
3. **One VM is enough to saturate the cluster.** On a written disk, a single
   VM drives all three node volumes to gp3's cap, and etcd's fsync p99 to
   31 ms.
4. **The control plane failed health checks.** In the sequential phase,
   etcd's fsync p99 reached 933 ms and the API server's etcd p99 about 5 s,
   the top of its histogram. API servers on two of the three nodes failed
   their own liveness and readiness probes ("InternalError" from the etcd
   check), and the API answered 148 requests with HTTP 500: 125 on the health
   endpoints and 22 pod reads. A Fleet pod failed to create its network
   sandbox. All of it fell within the sequential phase and ended with it.
   There were no etcd leader changes, no failed proposals, no restarts, and
   nodes stayed Ready. etcd logged about 11,000 applies slower than 100 ms
   over the run.

The fresh-disk run looked healthier only because first writes slowed the VMs
below the volumes' cap. **A cluster with established VMs is the worse case.**

### The pre-filled test at 16,000 IOPS / 1,000 MiB/s

The same cluster, test and flags, with every volume changed in place to
16,000 / 1,000, after all three reported `completed` (`20261020-172743`).
Only the pre-filled variant was run. The fresh-disk variant measured the
first-write penalty, which is a property of Longhorn's thin volumes rather
than of the volume tier, so there is no first-write figure at this tier.

| Phase | Baseline: total / per VM | 16,000: total / per VM | Baseline: etcd WAL p99 / API→etcd p99 | 16,000: etcd WAL p99 / API→etcd p99 |
| --- | --- | --- | --- | --- |
| Pre-fill, 6 × 10 GiB | 503 s; 20.0–20.9 MiB/s | **58 s**; 178–191 MiB/s | – | – |
| Idle | – | – | 3.9 / 13.8 ms | 4.0 / 17.5 ms |
| One VM, 4K random | 2,955 IOPS | **14,102 IOPS** | **30.6** / 43 ms | **3.9** / 15.6 ms |
| Six VMs, 4K random | 2,964 / 483–510 IOPS | **16,031 / 2,590–2,744 IOPS** | 126 / 986 ms | **30.9** / 48 ms |
| Six VMs, 1 MiB sequential | 125 / 20.2–21.7 MiB/s | **1,011 / 165–171 MiB/s** | 933 / ~5,000 ms | **123** / 952 ms |

| Control plane over the run | Baseline | 16,000 |
| --- | --- | --- |
| API HTTP 500s | **148** | 0 |
| API server liveness or readiness probe failures | **yes, on 2 of 3 nodes** | none |
| etcd applies slower than 100 ms | about 11,000 | 426 |
| etcd leader changes, failed proposals, restarts, nodes not Ready | none | none |

What provisioning bought:

1. **5–8× the capacity, with every volume still saturated together.**
   Random writes went from 2,964 to 16,031 IOPS and sequential from 125 to
   1,011 MiB/s. Those are, again, exactly the volumes' limits, now shared
   evenly six ways. One VM alone reached 14,102 IOPS, 88% of the volume. The
   cluster's write capacity is still one volume's; that volume is just faster.
2. **One busy VM no longer reaches etcd.** At baseline, a single VM's writes
   tripled etcd's fsync latency. At 16,000 IOPS it stayed at the idle 3.9 ms,
   because one VM no longer fills the volume.
3. **No failures, but etcd is still past its guideline when the VMs fill the
   volume.** Under six-VM random load, etcd's fsync p99 was 30.9 ms. Under
   sequential load it was 123 ms, and the API server's etcd p99 was 952 ms.
   Nothing failed in three-minute bursts, but the margin shrinks as VM write
   load approaches the volume's limit, at any tier.
4. **Filling new disks is about 9× faster:** 58 s against 503 s for 60 GiB.
   That matters for restores, imports and new VMs.

### Sizing consequences

- **Provision the volumes for any cluster running more than one write-heavy
  VM.** At baseline, one busy VM can take the whole cluster's write capacity.
- **Protect etcd: this is not optional.** It shares the volume, and at
  baseline, ordinary VM write load drove it to the edge of its election
  timeout and failed API server health checks. At 16,000 IOPS nothing failed,
  but VMs saturating the volume still pushed etcd's fsync p99 to 31–123 ms.
  Provisioning raises the ceiling; it does not separate the two. A dedicated volume for etcd, or for Longhorn, would, and
  the Terraform module does not support that yet.
- **Expect freshly provisioned VM disks to write more slowly** until their
  blocks have been written once.

---

## Configuration 4: Graviton, io2 at 16,000 IOPS

The same cluster again, with every volume changed in place from gp3
16,000 / 1,000 to **io2 at 16,000 IOPS**. That was the volumes' third
modification that day; EBS allows four per volume in any 24 hours. Both runs
started only once all three volumes reported `completed`.

| | |
| --- | --- |
| Measured | 2026-10-20/21: guest suite with pgbench (`20261020-183037`), then pre-filled 6-VM contention (`20261020-191134`) |
| Compared with | gp3 16,000 / 1,000 on the same cluster: `20261020-113253` (pgbench) and `20261020-172743` (contention) |
| Deploy with | `volume_type = "io2"`, `volume_iops = 16000` |

**Not a one-variable change.** io2's throughput follows from its IOPS
(0.256 MiB/s per IOPS, up to 4,000 MiB/s), so io2 at 16,000 IOPS allows
**4,000 MiB/s** against the gp3 run's 1,000. Latency figures compare cleanly.
Any figure bound by throughput, such as sequential writes under contention,
reflects both the volume type and the higher throughput limit.

### Single VM: latency drops, and synchronous work speeds up

| Figure | Pod: gp3 → io2 | VM: gp3 → io2 | VM change |
| --- | --- | --- | --- |
| 4K write + fsync qd1 | 865 → 1,581 IOPS | **808 → 1,402 IOPS** | **+74%** |
| Write + fsync, p99 | 1,368 → 954 µs | 1,434 → 1,057 µs | −26% |
| 4K random read qd1, p99 | 1,139 → 954 µs | 1,171 → 979 µs | −16% |
| 4K random read qd32 | 21,819 → 31,341 IOPS | 21,808 → 31,454 IOPS | +44% |
| 4K random write qd32 | 14,321 → 15,942 IOPS | 14,263 → 15,940 IOPS | +12%, now at the volume's 16,000 |
| Seq write 1M qd16 | 448 → 530 MiB/s | 454 → 518 MiB/s | +14% |
| Seq read 1M qd16 | 1,474 → 518 MiB/s | 721 → 815 MiB/s | noise; see below |

| pgbench clients | Pod: gp3 → io2 | VM: gp3 → io2 | VM change | VM latency | VM overhead on io2 |
| --- | --- | --- | --- | --- | --- |
| 1 | 643 → 1,021 tps | **565 → 844 tps** | **+49%** | 1.77 → 1.19 ms | 17.3% |
| 8 | 2,887 → 4,749 tps | **2,600 → 4,219 tps** | **+62%** | 3.08 → 1.90 ms | 11.2% |
| 32 | 5,629 → 6,578 tps | 4,605 → 5,473 tps | +19% | 6.95 → 5.85 ms | 16.8% |

What it shows:

1. **EBS's own write latency was a large share of commit time.** It answers
   what [matrix test 3](#remaining-in-priority-order) was meant to decide.
   Replication accounted for 16% of the fsync latency (configuration 3b).
   Switching the volume type cut it by about a quarter, and single-threaded
   fsync rate rose 74% in the VM and 83% in the pod, where provisioning gp3
   had changed nothing.
2. **Latency-bound databases gain the most.** One connection went from 565
   to 844 transactions/s, and eight from 2,600 to 4,219. At 32 clients the
   gain fell to 19% because the 4-vCPU VM ran out of CPU: its container was
   throttled in 64% of CFS periods, against 13.5% on gp3. A larger VM would
   take more of io2's gain at high concurrency.
3. **Loading the database barely changed** (19 s against 20 s in the VM).
   Bulk sequential work was not latency-bound on gp3 16,000 / 1,000.
4. **The VM overhead held** at 11–17% for pgbench, and +12.2% overall
   (compute 0.4 / scheduler 20.7 / disk −2.7 / network 26.8), within the
   Graviton range seen before.
5. **Sequential-read figures are unstable at this tier.** The pod fell from
   1,474 to 518 MiB/s while the VM rose. Longhorn reads from all three
   replicas on different nodes, so how evenly a run's reads spread decides the
   figure. It has moved this much between runs before; do not read it as an
   io2 effect.

### Six VMs at once, pre-filled

| Phase | gp3 16,000 / 1,000: total / per VM | io2 16,000: total / per VM | gp3: etcd WAL p99 / API→etcd p99 | io2: etcd WAL p99 / API→etcd p99 |
| --- | --- | --- | --- | --- |
| Pre-fill, 6 × 10 GiB | 58 s; 178–191 MiB/s | **34 s**; 305–487 MiB/s | – | – |
| Idle | – | – | 4.0 / 17.5 ms | 2.0 / 5.0 ms |
| One VM, 4K random | 14,102 IOPS | **16,008 IOPS** | 3.9 / 15.6 ms | 3.9 / 5.0 ms |
| Six VMs, 4K random | 16,031 / 2,590–2,744 IOPS | 15,980 / 2,526–2,768 IOPS | **30.9** / 48 ms | **31.1** / 33 ms |
| Six VMs, 1 MiB sequential | 1,011 / 165–171 MiB/s | **1,970 / 171–470 MiB/s** | **123** / 952 ms | **2.0** / 23 ms |

| Control plane over the run | gp3 16,000 / 1,000 | io2 16,000 |
| --- | --- | --- |
| API HTTP 500s or 429s, probe failures, restarts, leader changes, nodes not Ready | none | none |
| etcd applies slower than 100 ms | 426 | **2** |

What it shows:

1. **At the IOPS limit, io2 behaves exactly like gp3.** Six VMs doing random
   writes drove every node's volume to 16,000 writes/s on both. Each VM got
   the same share, and etcd's fsync p99 was 31 ms on both. A volume that is
   queueing at its limit adds the same delay whatever its unloaded latency.
   **io2 does not protect etcd from VMs that saturate its IOPS.**
2. **Sequential load no longer reached etcd.** On gp3 the six VMs hit its
   1,000 MiB/s throughput limit and etcd's p99 rose to 123 ms. On io2 they
   wrote 1,970 MiB/s, about half its 4,000 MiB/s limit, and etcd stayed at
   its idle 2.0 ms. Node write latency was 0.8 ms throughout that phase. This
   is the throughput headroom, per the caveat above, and not necessarily
   io2's latency. [Test 4b](#4b-gp3-at-16000-iops--2000-mibs) checks that
   with gp3 at 2,000 MiB/s.
3. **Sequential writes were shared unevenly** (171–470 MiB/s per VM) while
   the volumes were not at their limit. What capped the total at 1,970 MiB/s
   is not established. It is not the volume's throughput limit. Longhorn's
   per-volume engine path, about 460–520 MiB/s in single-VM runs, may be a
   factor.
4. **One VM got the whole volume**: 16,008 random-write IOPS, against 14,102
   on gp3, with etcd unaffected.

### Cost

Approximate list prices in us-east, per 500 GiB node volume per month
(check current pricing):

| Volume | Storage | Performance | Per node | 3 nodes |
| --- | --- | --- | --- | --- |
| gp3 baseline, 3,000 / 125 | $40 | – | $40 | $120 |
| gp3 16,000 / 1,000 | $40 | $65 IOPS + $35 throughput | $140 | $420 |
| gp3 16,000 / 2,000 (its maximum throughput) | $40 | $65 IOPS + $75 throughput | $180 | $540 |
| io2 16,000 | $63 | $1,040 IOPS | $1,103 | $3,308 |

### Sizing consequences

- **For latency-bound databases, io2 is the one change measured so far that
  moves commit rate.** It raised single-connection PostgreSQL throughput by
  half, where provisioning gp3 changed nothing. It costs about 8× as much
  per volume as gp3 at the same IOPS. Because the cluster has one volume per
  node, every node pays it, not only those running database VMs.
- **io2 is not a fix for control-plane contention.** At the IOPS limit, etcd
  degraded exactly as on gp3. Keeping VM writes off etcd's volume
  ([matrix 2b](#remaining-in-priority-order)) remains the fix.
- **Throughput headroom protected etcd under sequential load**, and gp3 at
  its 2,000 MiB/s maximum gets most of that benefit at a sixth of io2's
  price (4b, below).

### 4b: gp3 at 16,000 IOPS / 2,000 MiB/s

The same cluster, volumes changed in place from io2 back to gp3 at
16,000 IOPS and **2,000 MiB/s**, gp3's maximum throughput. That was the
fourth modification in 24 hours. Same pre-filled six-VM test
(`20261020-203513`). This separates io2's latency from its throughput
headroom.

| Phase | gp3 16,000 / 1,000 | gp3 16,000 / 2,000 | io2 16,000 (4,000 MiB/s) |
| --- | --- | --- | --- |
| Pre-fill, 6 × 10 GiB | 58 s | 38 s | 34 s |
| Idle: etcd WAL p99 / API→etcd p99 | 4.0 / 17.5 ms | 3.9 / 16.4 ms | **2.0 / 5.0 ms** |
| One VM, 4K random | 14,102 IOPS | 14,140 IOPS | **16,008 IOPS** |
| Six VMs, 4K random: total | 16,031 IOPS | 16,031 IOPS | 15,980 IOPS |
| … etcd WAL p99 / API→etcd p99 | 30.9 / 48 ms | 31.2 / 48 ms | 31.1 / 33 ms |
| Six VMs, 1 MiB sequential: total | 1,011 MiB/s | **2,045 MiB/s** | 1,970 MiB/s |
| … each node's volume | at its 1,000 MiB/s limit | **at its 2,000 MiB/s limit**, 2.0–4.3 ms per write | below its limits, 0.8 ms per write |
| … etcd WAL p99 / API→etcd p99 | **123 / 952 ms** | **31 / 25 ms** | **2.0 / 23 ms** |
| etcd applies slower than 100 ms, whole run | 426 | 3 | 2 |

API errors, probe failures, restarts, leader changes and nodes not Ready
were all zero on all three.

What it shows:

1. **The six VMs want about 2,000 MiB/s of sequential writes.** At gp3
   1,000 they were held to 1,011. At gp3 2,000 they reached 2,045, the
   volume's limit. On io2 they reached 1,970, short of its 4,000, and spread
   unevenly (171–470 MiB/s per VM), so the limit there is on the Longhorn and
   VM side.
2. **Doubling gp3's throughput took most of the harm away.** etcd's fsync
   p99 fell from 123 to 31 ms and the API server's etcd p99 from 952 to
   25 ms. That is the same 31 ms that every saturated volume has shown
   under random writes.
3. **etcd's latency follows whether the volume is saturated, not its type.**
   Saturated, at any tier and on either volume type, etcd's fsync p99 was
   about 31 ms (123 ms at gp3 1,000's sequential limit). Not saturated, it
   stayed near idle: 3.9 ms on gp3, 2.0 ms on io2. io2's own contribution is
   its lower latency: about half the idle etcd figure, and one VM reaching
   the full 16,000 IOPS at qd32 where gp3 held it to about 14,100.
4. **Provisioned capacity only protects etcd while VM demand stays below it.**
   A sizing rule follows: provision the volume above the cluster's combined
   VM write demand, in both IOPS and MiB/s, or separate etcd from it (2b).

---

## Configuration 5: x86 nested, gp3 at 16,000 / 1,000

Configuration 1's platform (3 × `m8i.4xlarge`, nested virtualization,
v1.8.2) on a new cluster, created with gp3 at **16,000 IOPS / 1,000 MiB/s**:
the same volumes as Graviton configuration 3. This is the first half of
matrix test 7; io2 on the same cluster is [configuration 6](#configuration-6-x86-nested-io2-at-16000-iops).

| | |
| --- | --- |
| Measured | 2026-10-21: guest suite with pgbench (`20261021-095446`), then pre-filled 6-VM contention (`20261021-103516`) |
| Compared with | x86 at gp3 baseline (`20261016-235616`), and Graviton at the same gp3 16,000 / 1,000 (`20261020-113253`, `20261020-172743`) |
| Instance limits | `m8i.4xlarge` EBS: 5,000 Mbps (about 600 MiB/s) baseline, 10,000 burst; 20,000 / 40,000 IOPS |
| EBS burst | used, not exhausted. CloudWatch `EBSByteBalance%` stayed at 98–99% through the guest suite and dipped to 93–94% in the six-VM sequential phase, then recovered. Every figure below had the burst available. |

### Single VM

| Figure (VM) | x86, gp3 baseline | **x86, gp3 16,000 / 1,000** | Graviton, gp3 16,000 / 1,000 |
| --- | --- | --- | --- |
| 4K random write qd32 | 2,947 IOPS | **11,775 IOPS** | 14,263 IOPS |
| 4K random read qd32 | 8,842 IOPS | **18,952 IOPS** | 21,808 IOPS |
| 4K random read qd1, p99 | 1,843 µs | 1,925 µs | 1,171 µs |
| Seq write 1M qd16 | 126 MiB/s | **298 MiB/s** | 454 MiB/s |
| Seq read 1M qd16 | 143 MiB/s | **143 MiB/s** (pod 183) | 721 MiB/s (pod 1,474) |
| 4K write + fsync qd1 | 648 IOPS | 640 IOPS | 808 IOPS |
| Write + fsync, p99 | 1,991 µs | 2,056 µs | 1,434 µs |

| pgbench clients | Pod tps | **VM tps** | VM latency | VM overhead | Graviton VM, same volumes |
| --- | --- | --- | --- | --- | --- |
| 1 | 516 | **441** | 2.27 ms | 14.5% | 565 tps, 1.77 ms |
| 8 | 2,459 | **2,096** | 3.82 ms | 14.8% | 2,600 tps |
| 32 | 6,190 | **4,988** | 6.42 ms | 19.4% | 4,605 tps |

Overall VM overhead: **+19.6%** (compute 2.4 / scheduler 33.0 / disk 5.4 /
network 32.5), the same as configuration 1's three runs. The VM layer's cost
on x86 does not depend on the volume.

What it shows:

1. **Provisioning helps x86 less than Graviton.** Random writes rose 4.0×
   (Graviton 4.8×) and sequential writes 2.4× (Graviton 3.6×). The
   sequential-write ceiling per VM disk is about **300 MiB/s on x86**,
   against about 460 on Graviton, in both the pod and the VM. The volume is
   not the limit: six VMs together reached 1,006 MiB/s. **Correction from
   configuration 6:** it is not a fixed engine cap either. On io2 the same
   disk wrote 584 MiB/s, so on x86 one disk's sequential writes are bound by
   per-write latency.
2. **Sequential reads did not move at all: 143 MiB/s at both tiers** (the
   pod: 175 → 183). On Graviton they rose 2.9×. The pod is capped too, so the
   guest's virtualization is not the cause, and random reads did scale (2.1×).
   **Narrowed down on EFS** ([EFS for VM data disks](#efs-for-vm-data-disks)):
   the same VM, through the same virtio and QEMU path, read 1,009 MiB/s from
   an EFS disk. So the limit is in Longhorn's read path on these nodes, not in
   the guest, the VM layer or the node's network. Matrix test 3 would place
   it within Longhorn.
3. **Sync-write latency is about 40% worse than Graviton and unchanged by
   provisioning.** Write + fsync p99 is 2.06 ms (Graviton 1.43 ms), and
   random read qd1 p99 1.9 ms against 1.2 ms. Both the node (an EC2 VM) and
   the guest (a nested VM) add latency to every I/O.
4. **pgbench follows that latency.** One connection gets 441 tps (Graviton
   565, −22%) and eight 2,096 (−19%). At 32 clients x86 is ahead, 4,988
   against 4,605: the VM's 4 x86 vCPUs do more work per transaction than 4
   Graviton vCPUs, and its container was not CPU-throttled. The VM overhead,
   15–19%, matches Graviton's.

### Six VMs at once, pre-filled

| Phase | x86: total / per VM | Graviton: total / per VM | x86: etcd WAL p99 / API→etcd p99 | Graviton: etcd WAL p99 / API→etcd p99 |
| --- | --- | --- | --- | --- |
| Pre-fill, 6 × 10 GiB | 60 s; 171–175 MiB/s | 58 s; 178–191 MiB/s | – | – |
| Idle | – | – | 3.9 / 14.8 ms | 4.0 / 17.5 ms |
| One VM, 4K random | **11,494 IOPS** | 14,102 IOPS | 3.9 / 15.1 ms | 3.9 / 15.6 ms |
| Six VMs, 4K random | 16,033 / 2,649–2,700 IOPS | 16,031 / 2,590–2,744 IOPS | 30.9 / 49 ms | 30.9 / 48 ms |
| Six VMs, 1 MiB sequential | 1,006 / 166–169 MiB/s | 1,011 / 165–171 MiB/s | **216 / 986 ms** | 123 / 952 ms |

| Control plane over the run | x86 | Graviton |
| --- | --- | --- |
| API HTTP 500s or 429s, probe failures, restarts, leader changes, nodes not Ready | none | none |
| etcd applies slower than 100 ms | **1,607** | 426 |
| Node volume write latency, sequential phase | **30 ms**, 4,070 writes/s of about 256 KiB | 8,100 writes/s of about 128 KiB |

What it shows:

1. **The cluster's capacity is the volume's on x86 too.** Six VMs reached
   exactly 16,000 IOPS and 1,000 MiB/s, as on Graviton. The instance's EBS
   limit did not bind, because the 10,000 Mbps burst (about 1,190 MiB/s)
   covers a 1,000 MiB/s volume. Sustained past the burst, about 600 MiB/s
   would be the ceiling instead.
2. **One VM alone gets less** (11,494 IOPS against 14,102), for the same
   reason as pgbench: at a fixed queue depth, higher latency per I/O means
   fewer I/Os.
3. **Random saturation affected etcd identically**: 31 ms, as on every
   saturated volume measured so far.
4. **Sequential saturation hurt etcd more on x86**: 216 ms against 123 ms,
   and about 4× as many slow applies. The node's writes were larger and
   queued for 30 ms each. Still no failures in three-minute bursts, but the
   margin to etcd's 1 s election timeout is smaller on x86.

### Sizing consequences

- **For latency-bound work, x86 nested is about 20–25% slower than Graviton
  metal on the same volumes**, before io2: commits and qd1 reads are
  bounded by I/O latency, and x86 adds about 0.6 ms to each.
- **Expect about 300 MiB/s sequential writes per VM disk on gp3 (580 on
  io2) and about 150 MiB/s sequential reads on either**, on `m8i.4xlarge`.
  More read throughput comes from more VMs or disks, not from the volume.
- **Beyond about 600 MiB/s of sustained VM writes, `m8i.4xlarge` needs its
  EBS burst.** A cluster that writes that much for long needs a larger
  instance (`m8i.8xlarge`: 10,000 Mbps baseline).

---

## Configuration 5b: x86 nested, gp3 baseline

Configuration 6's cluster, with every volume lowered in place to **gp3
3,000 IOPS / 125 MiB/s**. Lowering from io2 took 3 hours 12 minutes of
optimizing (Graviton: 82 minutes from gp3 16,000). This repeats Graviton's
baseline pgbench and pre-filled contention runs on x86.

| | |
| --- | --- |
| Measured | 2026-10-21: guest suite with pgbench (`20261021-163116`), then pre-filled 6-VM contention (`20261021-171215`), then the same contention test again to check it reproduces (`20261021-180736`) |
| Compared with | the same cluster at gp3 16,000 / 1,000 (configuration 5), and Graviton at baseline (`20261020-140320`, `20261020-155019`) |

### pgbench: barely affected, as predicted

| Clients | VM, gp3 16,000 / 1,000 | **VM, gp3 baseline** | Change | Graviton VM, baseline → 16,000 change |
| --- | --- | --- | --- | --- |
| 1 | 441 tps | **447 tps** | +1% | 0% |
| 8 | 2,096 tps | **2,060 tps** | −2% | −6% |
| 32 | 4,988 tps | **4,365 tps** | −12% | −10% |
| Loading the database (`pgbench -i`) | 28.8 s | 30.8 s | +7% | +55% |

fio, same run: random writes 11,775 → 2,940 IOPS (−75%) and sequential
writes 298 → 126 MiB/s, while write + fsync stayed at 653 IOPS. Overall VM
overhead +19.3%, unchanged. As on Graviton, a database that fits in memory is
limited by commit latency, and the baseline volume does not change that.
Only the 32-client run, where commits queue, felt the lower IOPS ceiling.

### Six VMs at once, pre-filled: a control-plane outage

| Phase | x86: total / per VM | x86 run 1: etcd WAL p99 / API→etcd p99 | x86 run 2 | Graviton: etcd WAL p99 / API→etcd p99 |
| --- | --- | --- | --- | --- |
| Pre-fill, 6 × 10 GiB | 506 s; 20.2–20.6 MiB/s (run 2: 510 s) | – | – | – |
| Idle | – | 3.9 / 14.8 ms | 3.9 / 10.9 ms | 3.9 / 13.8 ms |
| One VM, 4K random | 2,958 IOPS (run 2: 2,958) | **29.9** / 41 ms | 31.1 / 32 ms | 30.6 / 43 ms |
| Six VMs, 4K random | 2,964 / 493–496 IOPS (run 2: 2,958 / 489–495) | **127** / 982 ms | 126 / 982 ms | 126 / 986 ms |
| Six VMs, 1 MiB sequential | 125 / 20.1–21.7 MiB/s (run 2: 125 / 19.0–21.8) | **1,964 / about 9,900 ms** | **2,015 / about 9,900 ms** | 933 / about 5,000 ms |

Node volume write latency was 20–28 ms in the random phase and 231–235 ms
in the sequential phase.

| Control plane over the run | Graviton, baseline | **x86, baseline, run 1** | **x86, baseline, run 2** |
| --- | --- | --- | --- |
| etcd leader changes | 0 | **1** | 0 |
| etcd failed proposals / heartbeat send failures | 0 / 0 | **25 / 54** | **34 / 82** |
| etcd applies slower than 100 ms | about 11,000 | 10,172 | 15,578 |
| API server probe failures | liveness and readiness, 2 of 3 nodes | **liveness and readiness, all 3 nodes** | **liveness and readiness, all 3 nodes** |
| API HTTP 5xx / 429s | 148 / 0 | 139 / **22** | 125 (115 × 500, 10 × 504) / 0 |
| System containers restarted | none | **29**, about 40 restarts, including 3 kube-apiserver, 2 kube-controller-manager, 2 kube-scheduler and 5 kube-vip | **29**, including all 3 kube-apiserver, kube-controller-manager and kube-scheduler on 2 nodes each, 3 kube-vip |
| Cluster VIP (kube-vip lease) | did not move | **moved 5 times** | **moved 5 times** |
| A node NotReady | no | **yes**, node 1, until the end of the phase | **yes**, node 3, until 23:06:01Z, just after the phase ended |

**Reproduced.** The second run's latencies were within 3% of the first's, and
it took down the same components. It had no leader change, but more failed
proposals and heartbeat failures, so whether etcd elects a new leader is a
matter of timing. Measurement note: kube-state-metrics itself restarts
during the outage, so Prometheus's restart counts and node-Ready figures
undercount it (in run 2 they reported no restarts and all nodes Ready).
Run 2's restarts come from each container's last termination time, and its
NotReady node from the node's Ready condition.

What it shows:

1. **Graviton's warning was the mild version.** The same six VMs on x86
   pushed etcd's fsync latency past its 1 s election timeout, to 1,964 ms.
   etcd lost heartbeats and failed proposals, and changed leader. Every API
   server failed its liveness probe, so the kubelet restarted them, and every
   controller that depends on them restarted too. The cluster VIP moved five
   times as kube-vip lost and regained its lease.
2. **It took three minutes of ordinary VM writes.** Six VMs writing
   sequentially at 21 MiB/s each is not an extreme load. Any cluster at
   gp3's baseline with a handful of write-active VMs can reach it.
3. **The cluster recovered by itself.** Within a minute of the load
   stopping, every pod was Running and Ready, all nodes were Ready, and
   Longhorn's volumes were healthy. Longer load was not tested, and a
   sustained version would keep the control plane down.
4. **x86 fails first because each I/O is slower.** Up to the random phase
   the two platforms matched closely (127 against 126 ms). In the sequential
   phase, x86's node writes queued for about 230 ms, and etcd's fsyncs waited
   behind them.

---

## Configuration 6: x86 nested, io2 at 16,000 IOPS

Configuration 5's cluster, with every volume changed in place to **io2 at
16,000 IOPS**, after all three reported `completed`. This is matrix test 7b.

| | |
| --- | --- |
| Measured | 2026-10-21: guest suite with pgbench (`20261021-113738`), then pre-filled 6-VM contention (`20261021-121815`) |
| Compared with | the same cluster on gp3 16,000 / 1,000 (configuration 5), and Graviton on io2 16,000 (configuration 4) |
| EBS burst | used, not exhausted: `EBSByteBalance%` fell to 90–91% by the end of the sequential phase |

### Single VM

| Figure (VM) | x86 gp3 16,000 / 1,000 | **x86 io2 16,000** | Change | Graviton io2 16,000 |
| --- | --- | --- | --- | --- |
| 4K write + fsync qd1 | 640 IOPS | **1,060 IOPS** | **+66%** | 1,402 IOPS |
| Write + fsync, p99 | 2,056 µs | 1,352 µs | −34% | 1,057 µs |
| 4K random read qd1, p99 | 1,925 µs | 1,581 µs | −18% | 979 µs |
| 4K random write qd32 | 11,775 IOPS | 15,977 IOPS | +36%, at the volume's 16,000 | 15,940 IOPS |
| 4K random read qd32 | 18,952 IOPS | 24,073 IOPS | +27% | 31,454 IOPS |
| Seq write 1M qd16 | 298 MiB/s | **584 MiB/s** | **+96%** | 518 MiB/s |
| Seq read 1M qd16 | 143 MiB/s | 131 MiB/s (pod 151) | unchanged | 815 MiB/s |

| pgbench clients | Pod: gp3 → io2 | **VM: gp3 → io2** | VM change | VM latency on io2 | VM overhead on io2 | Graviton VM on io2 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 516 → 808 tps | **441 → 640 tps** | **+45%** | 1.56 ms | 20.8% | 844 tps |
| 8 | 2,459 → 4,286 tps | **2,096 → 3,374 tps** | **+61%** | 2.37 ms | 21.3% | 4,219 tps |
| 32 | 6,190 → 10,571 tps | **4,988 → 7,107 tps** | **+42%** | 4.50 ms | 32.8% | 5,473 tps |

Overall VM overhead: **+19.1%** (compute 2.6 / scheduler 32.5 / disk 6.9 /
network 30.2), unchanged.

What it shows:

1. **io2 helps x86 as much as Graviton.** Single-threaded fsync rose 66%
   (Graviton 74%), and pgbench 42–61% (Graviton 19–62%). x86 still trails
   Graviton by about 0.3 ms per synchronous write and about 25% at one
   connection.
2. **x86's sequential-write ceiling was latency, not Longhorn.** One disk
   wrote 584 MiB/s, nearly double gp3's 298. On Graviton the same change
   gained only 14%, so there the ~460–520 MiB/s ceiling is closer to a real
   engine limit.
3. **Sequential reads still did not move**: 131 MiB/s, after 143 at gp3 16,000
   and 143 at baseline. Neither volume type nor provisioning affects it, in
   the pod or the VM. On EFS the same VM read 1,009 MiB/s, which places it in
   Longhorn's read path on these nodes.
4. **At high concurrency x86 pulls ahead and the VM's overhead grows.** At
   32 clients the VM did 7,107 tps against Graviton's 5,473, and the pod
   10,571. Once I/O waits shrink, the VM's CPU and exit costs become the
   larger share: the overhead rose from 19% to 33%.

### Six VMs at once, pre-filled

| Phase | x86 gp3 16,000 / 1,000 | **x86 io2 16,000** | x86 gp3: etcd WAL p99 / API→etcd p99 | **x86 io2: etcd WAL p99 / API→etcd p99** |
| --- | --- | --- | --- | --- |
| Pre-fill, 6 × 10 GiB | 60 s | 49 s | – | – |
| Idle | – | – | 3.9 / 14.8 ms | 2.0 / 5.0 ms |
| One VM, 4K random | 11,494 IOPS | **16,033 IOPS** | 3.9 / 15.1 ms | 3.8 / 5.0 ms |
| Six VMs, 4K random | 16,033 IOPS | 16,031 IOPS | 30.9 / 49 ms | 30.9 / 39 ms |
| Six VMs, 1 MiB sequential | 1,006 MiB/s (the volume's limit) | **1,198 MiB/s (the instance's burst limit)** | 216 / 986 ms | **127 / 979 ms** |

| Control plane over the run | x86 gp3 | x86 io2 |
| --- | --- | --- |
| API HTTP 500s or 429s, probe failures, restarts, leader changes, nodes not Ready | none | none |
| etcd applies slower than 100 ms | 1,607 | 1,063 |
| Node volume write latency, sequential phase | 30 ms | 25.5 ms |

What it shows:

1. **On x86 the instance, not the volume, sets the sequential limit.** The
   six VMs wrote 1,198 MiB/s, which is `m8i.4xlarge`'s 10,000 Mbps EBS burst
   bandwidth. On Graviton, io2's 4,000 MiB/s left headroom and etcd stayed
   at 2 ms. Here the node's EBS path saturated instead, and etcd's p99 was
   127 ms with the API server's etcd p99 near 1 s, as with saturated gp3.
2. **The saturation rule holds wherever the limit is.** etcd degrades when
   VM writes reach the volume's IOPS, its MiB/s, *or the instance's EBS
   bandwidth*. Buying io2 does not create headroom the instance cannot
   carry.
3. **Past the burst it gets worse.** The burst balance fell about 10% in one
   three-minute phase. Sustained, the ceiling would drop to about 600 MiB/s,
   the baseline, and the same VM load would saturate it sooner.
4. **One VM reaches the full 16,000 IOPS on io2** (11,494 on gp3), as on
   Graviton.

### Sizing consequences

- **On x86, io2 is the change that speeds up commits**, by about half, as on
  Graviton. It costs about 8× as much as gp3 at the same IOPS.
- **Match the volume to the instance.** `m8i.4xlarge` carries about
  600 MiB/s sustained (1,190 burst), so volume throughput above that is paid
  for but cannot be used, and VM sequential load reaches the instance's limit
  first. A cluster that needs more sustained write bandwidth needs a larger
  instance, such as `m8i.8xlarge` at 10,000 Mbps baseline.

---

## VM network to and from the VPC

Matrix test 13, on configuration 5b's x86 cluster (3 × `m8i.4xlarge`, nested).
The runner, an `m8i.4xlarge` like the nodes, sat inside the VPC as the client.
On each node in turn it measured three paths, 30 s per test:

- **the node itself**, with a hostNetwork iperf3 server: the instance's own
  ceiling;
- **VM, it connects**: connections a VM opens to the runner. kube-ovn SNATs
  them to the VM's node address (`natOutgoing`), and they leave from that node;
- **VM, VPC connects**: connections the runner opens to the VM's overlay
  address. They arrive at node 1, which the VPC route for `10.60.0.0/24`
  names, and for a VM elsewhere cross the overlay to its node.

| | |
| --- | --- |
| Measured | 2026-10-21, `run-perf.sh --suites guest --guest-vpc-network default/overlay-network --runner-type m8i.4xlarge` (`20261021-191844`) |
| VM network | kube-ovn overlay `vm-overlay`, `10.60.0.0/24`, `natOutgoing`, DHCP; the VM's only NIC. MTU 1400 from DHCP on every VM (node 1500, less 100 for GENEVE) |
| Instance network | `m8i.4xlarge`: 7.5 Gbit/s baseline, 15 Gbit/s burst. Every test here is a 30 s burst |

| Node | Path | In, 1 stream | In, 4 | Out, 1 stream | Out, 4 | Round trip |
| --- | --- | --- | --- | --- | --- | --- |
| node 3 | node itself | 9.18 | 14.35 | 9.19 | 14.35 | 0.34 ms |
| node 3 | VM, it connects | 9.12 | 14.26 | 9.14 | 12.28 | 0.54 ms |
| node 3 | VM, VPC connects | 4.60 | 12.15 | 7.53 | 14.16 | 0.71 ms |
| **node 1 (route)** | node itself | 4.78 | 14.35 | 4.78 | 14.35 | 0.33 ms |
| **node 1 (route)** | VM, it connects | 4.77 | 14.27 | 4.77 | 12.34 | 0.52 ms |
| **node 1 (route)** | VM, VPC connects | 4.77 | 12.29 | 4.77 | 14.28 | 0.58 ms |
| node 2 | node itself | 4.78 | 14.35 | 4.78 | 14.35 | 0.36 ms |
| node 2 | VM, it connects | 4.76 | 14.27 | 4.77 | 12.40 | 0.62 ms |
| node 2 | VM, VPC connects | 4.77 | 12.60 | failed¹ | 14.29 | 0.74 ms |

Gbit/s. **In** is the runner → node or VM, **out** the reverse, whichever end
opened the connection. ¹ iperf3's control connection timed out once; the other
26 tests completed.

What it shows:

1. **A VM on the overlay gets close to the node's full bandwidth to the
   VPC.** With 4 streams, VMs reached 12.2–14.3 Gbit/s against the node's
   14.35, the instance's burst rate. That is about twice the 6–7.4 Gbit/s a
   VM got VM to VM on the default pod network. That figure had a VM at both
   ends and a different network (canal with masquerade, not kube-ovn), so
   this does not show which of the two causes it, but it does show that the
   VM NIC itself is not limited to 7 Gbit/s.
2. **The route node is not a bottleneck at this scale.** Inbound connections
   to VMs on the other two nodes, which cross node 1 and then the overlay,
   reached 12.2 and 12.6 Gbit/s, the same as a VM on node 1 itself (12.3).
   The hop costs latency: 0.71–0.74 ms against 0.58 ms. Every inbound flow
   shares node 1's bandwidth, so several VMs receiving at once would split
   about 14 Gbit/s burst, 7.5 sustained. That was not measured.
3. **Single flows mostly stop at about 4.8 Gbit/s, node or VM alike.** AWS
   documents a 5 Gbit/s limit per flow between instances outside a cluster
   placement group, and node 1 and node 2 sat exactly there. Node 3 ran a
   single flow at 9.2 Gbit/s, and VM-to-VM single streams inside the cluster
   earlier reached 7.4, so the limit does not apply to every pair. This run
   does not explain why. For sizing, assume 5 Gbit/s per connection to
   anything outside the cluster.
4. **The overlay adds about 0.2–0.4 ms of round trip** (0.52–0.74 ms against
   the node's 0.33–0.36), and costs 100 bytes of every packet: the VM's TCP
   segments are 1,348 bytes against the node's 1,448.
5. **The tests were bursts.** `m8i.4xlarge` sustains 7.5 Gbit/s; the 14 Gbit/s
   figures last as long as its network burst credit. The earlier pod-to-pod
   test held 13.9 Gbit/s for 15 minutes, but that was not repeated on this
   path.

### Sizing consequences

- **For VMs serving clients in the VPC, use a kube-ovn overlay with the VPC
  route.** One VM can then use most of the node's bandwidth.
- **Plan for 5 Gbit/s per connection** to or from anything outside the
  cluster, whatever the instance size.
- **All inbound VM traffic enters through one node.** Its bandwidth is the
  ceiling for every VM's inbound traffic together, and if it fails, inbound
  traffic stops until the route is repointed (README, "VM networking on
  EC2"). For more inbound bandwidth than one node has, a larger instance for
  that node is the only lever today.

---

## EFS for VM data disks

The x86 cluster (3 × `m8i.4xlarge`, nested) with its node volumes at **gp3
baseline, 3,000 / 125**: the setting at which six VMs writing through Longhorn
took the control plane down twice ([configuration 5b](#configuration-5b-x86-nested-gp3-baseline)).
This time each VM's data disk was on EFS, through the AWS EFS CSI driver set
up as in the repository README's "EFS for VM disks". Root disks stayed on
Longhorn.

| | |
| --- | --- |
| Measured | 2026-10-22, pre-filled 6-VM contention, `--guest-storage-class efs-sc --guest-data-volume-mode Filesystem` (`20261022-133813`) |
| EFS | one file system, General Purpose, Elastic throughput; one access point per VM disk; mount target in the nodes' zone |
| VM disk | Filesystem-mode PVC: KubeVirt keeps it as `disk.img` on the NFS mount; the guest sees a virtio disk |

| Phase | Longhorn, gp3 baseline (5b, run 1) | **EFS, nodes at gp3 baseline** | Longhorn, gp3 16,000 / 1,000 (configuration 5) |
| --- | --- | --- | --- |
| Pre-fill, 6 × 10 GiB | 506 s | **57 s**; 181–331 MiB/s per VM | 60 s |
| One VM, 4K random, qd32 | 2,958 IOPS, p99 13.6 ms | 2,898 IOPS, p99 18 ms | 11,494 IOPS, p99 3.6 ms |
| Six VMs, 4K random: total / per VM | 2,964 / 493–496 IOPS | **11,200 / 1,663–2,841 IOPS** | 16,033 / 2,649–2,700 IOPS |
| Six VMs, 1 MiB sequential: total / per VM | 125 / 20–22 MiB/s | **1,037 / 173 MiB/s** | 1,006 / 166–169 MiB/s |
| Node volume writes/s, busiest phase | 3,001 (at the volume's limit) | **58–73 (idle)** | 16,000 (at the limit) |
| etcd WAL fsync p99: idle / random / sequential | 3.9 / 127 / **1,964 ms** | **3.9 / 3.9 / 3.9 ms** | 3.9 / 31 / 216 ms |
| API→etcd p99, sequential | about 9,900 ms | **23 ms** | 986 ms |
| etcd applies slower than 100 ms | 10,172 | 147 | 1,607 |
| Control plane | **outage**: leader change, all API servers restarted, a node NotReady | no errors, no probe failures, no restarts, VIP held | no failures |

The one container restart during the run was the kube-ovn operator,
OOMKilled at its own memory limit (its fourth restart since install), and not
related to storage.

What it shows:

1. **EFS takes VM writes off etcd's volume entirely.** The node volumes saw
   only their idle 60–73 writes/s while six VMs wrote 11,200 IOPS and
   1,037 MiB/s. etcd's fsync p99 never left its idle 3.9 ms. On the same
   baseline volumes through Longhorn, the same load took the control plane
   down. This is the isolation that matrix test 2b aims at, reached without
   a second EBS volume.
2. **Cluster capacity no longer depends on the node volumes.** Six VMs on EFS
   got 3.8× the random IOPS and 8× the sequential throughput of Longhorn at
   baseline, about what Longhorn gets at 16,000 / 1,000, with the node
   volumes left at baseline.
3. **The cost is latency.** One VM alone at queue depth 32 got 2,898 IOPS,
   about 11 ms per write, against 3.6 ms p99 on Longhorn at 16,000 IOPS. It
   needs several VMs, or deep queues, to use EFS's capacity. Single-threaded
   sync writes and databases on EFS are not measured yet, and are likely to
   be much slower than on EBS.
4. **Sequential writes stopped at about 1,030 MiB/s for the whole file
   system**, split evenly (173 MiB/s per VM). EFS's own CloudWatch figure for
   the phase was the same, 1,029–1,030 MiB/s, and no node's network was
   close to its limit (each carried about 350 MiB/s), so this looks like the
   file system's Elastic write throughput limit. Not confirmed against AWS's
   published quota.
5. **Random writes cost more than they write.** In the random phase EFS's
   `DataWriteIOBytes` showed about 350 MiB/s, while the VMs wrote 11,200 ×
   4 KiB, about 44 MiB/s: roughly 8×. Elastic throughput bills by data
   transferred, so small random writes may cost several times their size.
   The cause, NFS write granularity or EFS metering, is not established.
6. **Not available on EFS disks:** Harvester VM backups and snapshots
   (README, "EFS for VM disks").

### One VM, and a database, on EFS

The guest suite in VM mode with pgbench, the VM's data disk on EFS, on the
same cluster (`20261022-140816`). There is no pod baseline: a pod cannot use
the same Filesystem-mode disk the same way, so this compares the same VM on
Longhorn, from configurations 5b and 5.

| Figure (VM) | Longhorn, gp3 baseline | Longhorn, gp3 16,000 / 1,000 | **EFS** |
| --- | --- | --- | --- |
| Seq write 1M qd16 | 126 MiB/s | 298 MiB/s | **356 MiB/s** |
| Seq read 1M qd16 | 154 MiB/s | 143 MiB/s | **1,009 MiB/s** |
| 4K random read qd32 | 8,822 IOPS | 18,952 IOPS | 12,972 IOPS |
| 4K random write qd32 | 2,940 IOPS | 11,775 IOPS | 3,097 IOPS |
| 4K random read qd1, p99 | 1.9 ms | 1.9 ms | **7.4 ms** |
| 4K write + fsync qd1 | 653 IOPS | 640 IOPS | **106 IOPS** |
| Write + fsync, p99 | 2.0 ms | 2.1 ms | **17.2 ms** |
| pgbench, 1 / 8 / 32 clients | 447 / 2,060 / 4,365 tps | 441 / 2,096 / 4,988 tps | **114 / 452 / 1,179 tps** |
| pgbench latency, 1 / 32 clients | 2.24 / 7.33 ms | 2.27 / 6.42 ms | **8.79 / 27.2 ms** |
| Loading the database | 30.8 s | 28.8 s | 25.5 s |

The CPU, memory and VM-to-VM network figures matched the Longhorn runs, as
they should: only the data disk moved.

What it shows:

1. **Synchronous writes are about 6× slower on EFS.** One write plus fsync
   averaged about 9.4 ms (106 per second), p99 17 ms, against about 1.5 ms on
   Longhorn. Every write a guest makes durable is a round trip to EFS.
2. **A database on EFS does about a quarter of the work.** pgbench managed
   114 / 452 / 1,179 tps at 1 / 8 / 32 clients, 74–78% below the same VM on
   Longhorn at 16,000 IOPS, and 74% below Longhorn at **baseline**. Each
   commit waited about 9 ms. More clients overlap commits, but not enough to
   close the gap.
3. **Sequential reads and writes are EFS's strength.** The VM read 1,009 MiB/s
   (7× Longhorn here) and wrote 356 MiB/s (above Longhorn's 298), and loaded
   the database fastest.
4. **Random I/O at depth sits between Longhorn's two tiers**: reads at 68%,
   writes at 26% of Longhorn at 16,000 IOPS, and both at or above Longhorn at
   baseline.

So EFS suits bulk and sequential data, and clusters where protecting the
control plane matters more than per-write latency.

### A VM entirely on EFS, and live migration

Same cluster, 2026-10-22. One VM with **both disks on EFS** (root disk from an
image on EFS) against one entirely on Longhorn, created together from the same
pinned Ubuntu 24.04 image and cloud-init.

How the root disk gets onto EFS: a VM image with `backend: cdi` and
`targetStorageClassName: efs-sc` downloads into a CDI DataVolume on EFS, and
each VM's root disk is a DataVolume cloned from it (Harvester v1.8.2,
`pkg/image/cdi`, `createDataVolume` in the VM controller). CDI's profile for
the EFS StorageClass already gives ReadWriteMany and Filesystem, so nothing
was configured for it. EFS has no CSI cloning, so CDI's clone strategy is
`copy`: each new root disk is a full copy of the image.

| From creation | All-Longhorn VM | All-EFS VM |
| --- | --- | --- |
| Image imported (3.5 GiB virtual size) | 24 s | 60 s |
| Root disk ready | immediate (cloned from Longhorn's backing image) | **162 s** (full copy) |
| VM Running | 22 s | 162 s |
| cloud-init finished, including 1 GiB written to each disk | 55 s | 245 s |

Both of the EFS VM's disks were `disk.img` files on NFS mounts, owned by
QEMU's user, and held exactly what the guest wrote.

**Live migration**, alternating between the two VMs, one at a time, three
times each between two nodes. The VMs were idle.

| | All-Longhorn VM | All-EFS VM |
| --- | --- | --- |
| Request to completion | 17.9, 17.9, 17.9 s | **7.1, 8.6, 7.2 s** |
| Memory copy (KubeVirt's start and end stamps) | 2–3 s | 2–3 s |

What it shows:

1. **A VM can run with no disk on Longhorn.** Root and data disks on EFS
   both work, with no cluster changes beyond the EFS setup.
2. **Creating VMs is slower: about 2.5 minutes per root disk.** Every VM's
   root disk is a full copy of its image; on Longhorn it is a near-instant
   clone. Creating many VMs at once would multiply that, all from the same
   file system.
3. **Live migration is about 2.5× faster on EFS: 7–9 s against 18 s.** Both
   VMs copied their (idle) memory in 2–3 s. The rest is handing the volumes
   to the target node, which for Longhorn means attaching each volume through
   its engine there, and for EFS just mounting the same file. A busy VM would
   add memory-copy time to both equally.

### Node failure

Both VMs running on node 2, which was then stopped with an ordinary EC2 stop
(an OS shutdown, not a forced power-off, to spare the node's own disk and
etcd). Harvester's `vm-force-reset-policy` and Longhorn's
`node-down-pod-deletion-policy` were at their defaults (enabled, 15 s,
`vmMigrationTimeout` 180 s; `do-nothing`). Times are from the stop request.

| Event | Time |
| --- | --- |
| Node 2 stops heartbeating (Ready: Unknown) | ≈75 s |
| Harvester taints node 2 `node.kubernetes.io/out-of-service`; both VMs are restarted elsewhere | ≈250 s |
| **All-EFS VM running on node 3** | **258 s** |
| **All-Longhorn VM running on node 3**, both volumes degraded (2 of 3 replicas) | **291 s** |
| Node 2 started again; Ready | 55 s after the start request |
| Longhorn volumes healthy again (data disk, root disk) | 169 s and 181 s after the start request: about 2 minutes of rebuild |

What it shows:

1. **Recovery took about 4 minutes on both storage types, set by Harvester,
   not by storage.** Node 2 went silent at about 75 s; Harvester waited its
   `vmMigrationTimeout` of 180 s, then marked the node out of service, which
   let both VMs restart elsewhere. `vm-force-reset-policy` is the lever for
   faster recovery; changing it was not tested.
2. **The EFS VM restarted 33 s sooner.** Its disks were just mounted on the
   new node; the Longhorn VM's volumes had to be attached through Longhorn
   first.
3. **The Longhorn VM ran on two of its three replicas until node 2 came
   back.** With three nodes and three replicas there is nowhere else to put
   the third, so the rebuild waits for the node, then took about 2 minutes
   for 1 GiB of data and a 3 GiB root disk at gp3 baseline. EFS has nothing
   to rebuild: the file system is regional and outside the cluster.
4. **The VIP lease moved to node 2 when it rejoined**, while the address
   itself stayed registered on node 1's network interface: the known VIP
   failover limitation (repository README, "The VIP does not fail over").
   The VIP still answered from all three nodes afterwards. The test did not
   check a client outside the cluster.

Not tested: a forced power-off (`stop-instances --force`), which skips the OS
shutdown, and the VMs under load while their node fails.

#### The force-reset policy, and a shorter timeout

How Harvester handles a node that stops responding
(`pkg/controller/master/node/node_down_controller.go`): once the node is
NotReady for `period` (15 s), it adds KubeVirt's drain taint, which asks
KubeVirt to live-migrate the node's VMs away. After `vmMigrationTimeout`
(180 s) more, it adds `node.kubernetes.io/out-of-service`, which
force-deletes the node's pods and releases their volumes, so the VMs restart
elsewhere. Recovery time is therefore roughly: time to NotReady + `period` +
`vmMigrationTimeout`.

The same test again, with `vmMigrationTimeout` set to 60 for the run and
restored to its default afterwards:

| | Default (180 s) | `vmMigrationTimeout` 60 |
| --- | --- | --- |
| Node silent (Ready: Unknown) | ≈75 s | 71 s |
| VMs released to restart elsewhere | ≈250 s | ≈163 s |
| **All-EFS VM running** | 258 s | **173 s** |
| **All-Longhorn VM running** | 291 s | **179 s** |
| Longhorn volumes healthy after the node returned | 169 / 181 s after start | 137 / 167 s after start |

Recovery fell by about 90 s, as the arithmetic predicts. The gap between
the EFS and Longhorn VMs was 33 s in the first run and 6 s in the second, so
EFS's restart advantage is real but small and varies.

**Why the default is 180 s:** the out-of-service taint declares the node
down for certain. A node that only looks down (a hung kubelet, a network
partition) may still be running its VMs. Force-deleting them and starting
copies elsewhere could leave two QEMU processes writing the same disk; both
Longhorn and EFS disks here are ReadWriteMany, so neither prevents it. The
timeout gives such a node time for its VMs to migrate off cleanly. A stopped
instance cannot show that risk, so these runs do not show a shorter timeout
to be safe.

#### kube-ovn did not recover from the second stop

After node 2's second stop and start, all three `ovn-central` replicas
(kube-ovn's OVN database cluster) sat in CrashLoopBackOff. After the first
stop they had recovered by themselves. The test VMs were on the default pod
network, so unaffected; VMs on the overlay lose kube-ovn's control plane (new
addresses, changes) while it is down.

**Cause: the OVN databases do not survive a node reboot.** `ovn-central` keeps
each member's Raft database on the node, in hostPath `/etc/origin/ovn`. On the
node OS, `/etc` is a writable overlay on tmpfs, and only the paths in
`PERSISTENT_STATE_PATHS` persist; `/etc/origin` is not one of them. So:

1. The first reboot wiped node 2's copy. Its startup script created a new
   database and joined again as a **new member**, while the cluster still
   listed the old one. Membership grew from three to four, needing three
   votes.
2. The second reboot wiped it again. The cluster now listed two dead
   members of four, and its two live members could never win an election
   (each node's `cluster/status`: "disconnected from the cluster (election
   timeout)", four servers listed). Without a leader, node 2 could not join,
   and dead members cannot be removed (`cluster/kick` needs a leader).
3. Each replica's startup script waits 30 s for each database, then exits
   with code 0, and CrashLoopBackOff restarts it.

Nodes 1 and 3 still held full databases, so no configuration was lost. Any
reboot of any node grows the membership again; the second one in a cluster's
life deadlocks it. A recovery was started (backups taken, `ovn-central` and
the operator stopped) but not finished before the cluster was torn down; the
planned steps are in the README. The fix, persisting `/etc/origin/ovn` or
moving kube-ovn's database to a persistent path, is not applied. It does not
suit databases or anything else that commits small writes synchronously.

---

## Configuration 8: m8i.16xlarge, and a second disk for VM data

Matrix test 2b, on a larger instance. Three `m8i.16xlarge` nodes (64 vCPU,
256 GiB, 30 Gbit/s network, 20,000 Mbps / 80,000 IOPS of EBS, nested
virtualization), Harvester v1.8.2. Each node has its 500 GiB gp3 **root
volume at baseline (3,000 / 125)**, holding the OS, etcd, Longhorn's default
disk (images) and the monitoring add-on, plus a **second 500 GiB gp3 volume at
16,000 IOPS / 1,000 MiB/s**, added to Longhorn as a disk tagged `vmdata`. VM
data disks go on it through a StorageClass with `diskSelector: vmdata` and
three replicas. Setup is in the repository README, "A second disk for VM
data".

| | |
| --- | --- |
| Measured | 2026-10-26/27: A `20261026-180212`, B `20261026-184900`, C `20261026-190211`, D `20261026-195934`, E (density) below |
| Zone | **us-east-2a**. Every earlier x86 run was in us-east-2b: `m8i.24xlarge` and then `m8i.16xlarge` had no capacity there (see "Not comparable" below) |
| Changes made during the runs | the third node's second disk was missing its `vmdata` tag and was given it; a harness fix to the reported root volume; for run D only, the second disks were made unschedulable. Each is in the change log for this session |

### Run A: six VMs writing to the second disks, root at baseline

| Phase | Total / per VM | etcd WAL fsync p99 | API→etcd p99 |
| --- | --- | --- | --- |
| Pre-fill, 6 × 10 GiB | 168–171 MiB/s per VM, 62 s | – | – |
| Idle | – | 3.9 ms | 17.5 ms |
| One VM, 4K random | 10,280 IOPS | 3.9 ms | 23 ms |
| Six VMs, 4K random | 16,088 / 2,583–2,752 IOPS | **3.9 ms** | 11 ms |
| Six VMs, 1 MiB sequential | 1,006 / 167–168 MiB/s | **3.9 ms** | 23 ms |

Per device, in both write phases: the **root volumes stayed at 56–62
writes/s, their idle rate**, while the second disks were at their limits
(15,992–16,001 writes/s random, 4,012–4,015 writes/s of 1,000 MiB/s
sequential). Control plane over the run: no leader changes, failed
proposals, **slow applies (0)**, HTTP 5xx or 429s, restarts or probe
failures.

### Run D: the same test with every VM disk on the root volume

The same cluster with the **root volumes raised to 16,000 / 1,000** and the
second disks made unschedulable, so all 36 replicas (six VMs, two disks
each, three replicas) went to the root volume, alongside etcd. This is the
configuration every earlier x86 run used.

| Six VMs writing | All disks on the root volume (D) | VM disks on the second disk (A) | 4xlarge, all on root at 16,000 / 1,000 (configuration 5) |
| --- | --- | --- | --- |
| 4K random: total; etcd WAL p99 / API→etcd p99 | 16,029 IOPS; **31.1 / 48 ms** | 16,088 IOPS; **3.9 / 11 ms** | 16,033 IOPS; 30.9 / 49 ms |
| 1 MiB sequential: total; etcd WAL p99 / API→etcd p99 | 1,006 MiB/s; **210 / 984 ms** | 1,006 MiB/s; **3.9 / 23 ms** | 1,006 MiB/s; 216 / 986 ms |
| etcd applies slower than 100 ms | 2,139 | **0** | 1,607 |
| HTTP 5xx | 1 | 0 | 0 |

What A and D show:

1. **A second disk for VM data isolates etcd completely, and keeps EBS
   latency for the VMs.** With the root volume at baseline and VM writes
   saturating the second disk, etcd never left its idle 3.9 ms and logged
   no slow applies. This is the result matrix tests W2, 4 and E1 pointed
   to, and unlike EFS it keeps block-device latency for the VMs.
2. **A bigger instance does not protect etcd on its own.** With everything
   on one volume, the 16xlarge behaved exactly like the 4xlarge at the same
   tier: 31 ms under random saturation, 210 ms and an API server near 1 s
   under sequential. Separating the volumes, not the instance size, is
   what changes it.
3. **The root volume can stay at baseline** once VM data is elsewhere. It
   carried etcd, the OS, images and monitoring at about 60 writes/s.

### Run B: one VM and a database, data disk on the second disk

| Figure (VM) | 4xlarge, us-east-2b, gp3 16,000 / 1,000 (configuration 5) | 16xlarge, us-east-2a, second disk at 16,000 / 1,000 |
| --- | --- | --- |
| 4K random write qd32 | 11,775 IOPS | 10,211 IOPS |
| 4K random read qd32 | 18,952 IOPS | 16,884 IOPS |
| Seq write / read 1M qd16 | 298 / 143 MiB/s | 297 / 129 MiB/s |
| 4K random read qd1, p99 | 1.9 ms | **2.8 ms** |
| Write + fsync qd1 | 640 IOPS, p99 2.1 ms | **430 IOPS, p99 3.2 ms** |
| pgbench, 1 / 8 / 32 clients | 441 / 2,096 / 4,988 tps | **318 / 1,493 / 3,597 tps** |
| Overall VM overhead | +19.6% | +21.1% |
| Network, 1 stream (pod and VM) | 7.4 Gbit/s | **4.62 Gbit/s** |
| Network round trip, pod / VM | 0.30 / 0.75 ms | **0.47 / 0.95 ms** |

**Not comparable on latency.** Node-to-node round trip on this cluster was
0.41–0.42 ms (ping between nodes), against about 0.3 ms on the us-east-2b
clusters; neither used a placement group. Longhorn acknowledges a write only
when all three replicas, on three nodes, have it, so every synchronous write
pays that distance: fsync and pgbench are about 30% slower here, and qd1
read latency 47% higher, for that reason, not because of the second disk or
the instance size. The
single-stream cap of 4.62 Gbit/s is EC2's per-flow limit between instances
that are not close; the us-east-2b nodes evidently were. A **cluster
placement group**, which keeps a cluster's instances physically close, would
likely recover this, and is worth testing; the module does not set one.

The VM overhead (+21.1%) and every throughput figure match the 4xlarge, as
expected: per-VM costs do not depend on node size.

### Run C: node capacity, footprint and etcd

- **Pods per node are capped at 200** (Harvester's setting, not Kubernetes'
  default of 110); 34–77 were already running per node.
- **Harvester's CPU reservation grows with node size**: 34.2 of 188 cores
  requested (18%), 22.6 of them Longhorn's, whose instance managers reserve a
  share of each node's CPU. Actual use was 1.6 cores and 22.5 GiB.
- **etcd on a baseline root volume**: `check perf` passes; 533 serial and
  38,406 concurrent writes/s, WAL fsync p99 3.91 ms, backend commit p99
  3.97 ms, matching the 4xlarge.

### Run E: density to failure (`20261026-202311`)

hvperf's density suite with `--max-vms 0 --batch-size 20`, adding container-disk
VMIs until a batch fails. Root volumes at 16,000 / 1,000 (raised for run D),
the second disks schedulable again.

| | |
| --- | --- |
| VMIs Running and healthy | **440** across three nodes |
| Stopped by | **Kubernetes' pod limit**: the next batch was unschedulable, "Too many pods" on all three nodes. At 200 pods per node, Harvester's own pods leave room for about 150 VMs per node |
| Ramp | 14 min 29 s |
| VMI creation to `Running` | p50 17.8 s, p95 28.9 s, p99 31.3 s (the 4xlarge, at 50 VMIs: about 15 s / 20 s at p50 / p99) |
| Control plane during the ramp | worst 2-minute p99s: API→etcd 61–69 ms, all non-watch API requests 95 ms; no HTTP 5xx or 429s, no restarts, nodes Ready. etcd's own histograms were not scraped for this run |
| Root volume | at most 929 writes/s on the busiest node |

So on this size, **the VM count is limited by pods, not by CPU, memory or
storage**: 440 small VMs used a fraction of 188 cores and 768 GiB. Raising
the per-node pod limit would be the next lever; whether Harvester supports
changing it was not checked. The VMs here were tiny (CirrOS container disks),
so a real workload would reach CPU or memory limits sooner.

---

## Harvester v1.9.0 on configuration 5's platform

Every run above is v1.8.2. This repeats configuration 5 on v1.9.0: the same
3 × `m8i.4xlarge`, gp3 at 16,000 IOPS / 1,000 MiB/s, harvester-perf `6858e2c`
and guest flags.

| | |
| --- | --- |
| Harvester | v1.9.0 (Kubernetes v1.36.3+rke2r1, etcd 3.6.14 as on v1.8.2), amd64 AMI `ami-093d8890dc83951cb` |
| Measured | 2026-10-29: full suite with pgbench (`20261029-144143`), then pre-filled 6-VM contention (`20261029-152253`) |
| Compared with | configuration 5 (`20261021-095446`, `20261021-103516`); etcd, footprint and density against configuration 1 (`20261016-173833`) |
| Not the same as those runs | etcd metrics were not exposed (`etcd_expose_metrics` off), so etcd's own histograms are missing. The cluster also ran the kube-ovn add-on and vip-controller, and its nodes had been rebooted for the [vip-controller tests](../vip-controller/README.md), which moved etcd leadership off node 1 |

### Single VM, etcd, footprint and density: the same as v1.8.2

| Figure | v1.8.2 | **v1.9.0** |
| --- | --- | --- |
| VM overhead (compute / scheduler / disk / network) | +19.6% (2.4 / 33.0 / 5.4 / 32.5) | **+18.6%** (2.6 / 32.1 / 2.6 / 31.9) |
| pgbench VM tps, 1 / 8 / 32 clients | 441 / 2,096 / 4,988 | **438 / 2,069 / 4,899** |
| VM 4K random write / read, qd32 | 11,775 / 18,952 IOPS | 11,252 / 17,913 IOPS (the pod fell by the same 5%) |
| VM seq write / read, 1M qd16 | 298 / 143 MiB/s | 299 / 136 MiB/s |
| VM 4K write + fsync, qd1 | 640 IOPS, p99 2.06 ms | 644 IOPS, p99 2.02 ms |
| VM network, 4 streams / round trip | 7.53 Gbit/s / 0.81 ms | 7.95 Gbit/s / 0.71 ms |
| etcd writes, serial / 500 clients | 652 / 39,148 per s | **497 / 30,123 per s**, see below |
| etcd serializable reads, 500 clients | 190,300/s | 185,326/s |
| 50 VMIs, creation to `Running` | 100 s; p50 ≈15 s, p99 ≈20 s | 105 s; p50 15.0 s, p99 19.9 s |
| Allocatable per node | 15 cores, 61.8 GiB, 200 pods | the same |
| kube-system CPU / memory requests | 5.7 cores / 7.7 GiB | 7.8 / 9.9; **4.8 / 7.5 without kube-ovn** (2.9 cores / 2.6 GiB) |

**etcd writes are down 23–25%, and linearizable reads 36%, because the
benchmark ran against a follower.** It talks to etcd on 127.0.0.1 on node 1.
In every earlier run that member was the leader; here node 1 had been
rebooted, and node 3 led. On a follower, each write and each linearizable
read needs a round trip to the leader. Serializable reads, which stay local,
did not change. A clean comparison needs leadership moved back to node 1
(`etcdctl move-leader`) and the etcd suite rerun.

### Six VMs at once, pre-filled: the same storage, a slower control plane

| Phase | v1.8.2: total | **v1.9.0: total** | v1.8.2: API→etcd p99 | **v1.9.0: API→etcd p99** (create / get / update) |
| --- | --- | --- | --- | --- |
| Pre-fill, 6 × 10 GiB | 60 s; 171–175 MiB/s | 60 s; 172–186 MiB/s | – | – |
| Idle | – | – | 14.8 ms | 19.0 ms |
| One VM, 4K random | 11,494 IOPS | 11,334 IOPS | 15.1 ms | 21.0 ms |
| Six VMs, 4K random | 16,033 IOPS | 15,181 IOPS | 49 ms | **820 / 64 / 93 ms** |
| Six VMs, 1 MiB sequential | 1,006 MiB/s | 996 MiB/s | 986 ms | **990 / 3,645 / 995 ms** |

| Over the run (20:08–20:21 UTC) | v1.9.0 |
| --- | --- |
| Nodes not Ready, etcd leader changes, heartbeat failures | none |
| API HTTP 500s | 1, from node 1's API server |
| Restarts | **kubeovn-operator, 7**, both replicas: each lost its leader lease when renewing through `10.53.0.1` timed out |
| etcd WAL fsyncs over 128 ms, since node start | node 1: 0; nodes 2 and 3: 192 and 230, none over 512 ms |
| Node volume write latency, sequential phase | node 1: **3 ms**; nodes 2 and 3: **25 ms** (v1.8.2: 30 ms on all three) |
| iowait, sequential phase | node 1: 2 cores; nodes 2 and 3: 9 cores each |

What it shows:

1. **The storage result does not change with the release.** Six VMs reached
   the volume's 1,000 MiB/s and within 5% of its 16,000 IOPS, as on v1.8.2.
2. **The control plane suffered more**, by the API server's figures:
   p99 3.6 s for reads in the sequential phase against 1.0 s, and 0.8 s for
   creates in the random phase against 49 ms. Nothing failed except the
   kube-ovn operator, which v1.8.2's run did not have.
3. **The latency was on nodes 2 and 3.** Their volumes queued writes (25 ms,
   9 cores of iowait) and their API servers saw 3.7–3.8 s to etcd, while
   node 1, writing the same 990 MiB/s to an identical volume, queued for 3 ms
   and saw 0.96 s. CPU per pod was the same on all three nodes, and no extra
   writer was found on nodes 2 and 3. Not explained.
4. **One run, with confounds**: kube-ovn's 17 pods, etcd leadership on a
   different node, and no etcd histograms. So this is not yet a v1.9.0
   regression. It is the first contention result that needs a rerun: on a
   fresh v1.9.0 cluster without the add-ons, with `etcd_expose_metrics` on.
   Graviton cannot answer it, since v1.9.0 arm64 guests do not boot.

---

## Test matrix

### Measured

Each row changes one thing from the row it builds on, so a difference can be
attributed to that change.

| # | Change | Question it answered | Result |
| --- | --- | --- | --- |
| 1 | — (x86 nested, gp3 baseline, MTU 1500) | the baseline | 18.5–20.9% VM overhead over three runs |
| 2 | Graviton `c7g.metal`, v1.8.2 | how much of the overhead is nesting | about 5 points; the network cap remains. The scheduler figure varies run to run (3–28%) |
| 3 | 2 + gp3 provisioned (`volume_iops` / `volume_throughput`) | where disk tops out once the volume stops limiting it | throughput ×3–5; fsync unchanged; seq write capped at ~460 MiB/s by Longhorn |
| 3b | 3 + one local Longhorn replica (`--guest-storage-class`) | how much of the fsync latency and the write cap is replication | 16% of fsync latency; none of the cap |
| 4 | 3 + io2 at 16,000 IOPS (`volume_type = "io2"`), in place | whether a lower-latency volume shortens sync writes, and whether it shields etcd | fsync +74%, pgbench +49–62% at 1–8 clients; at the IOPS limit, etcd degrades exactly as on gp3. About 8× gp3's cost |
| 4b | 4 changed back to gp3 at 16,000 IOPS / 2,000 MiB/s | whether throughput headroom alone keeps etcd healthy under sequential VM load | mostly: sequential etcd p99 123 → 31 ms, API 952 → 25 ms, at about $180 per volume against io2's $1,100. It reached the volume's limit, so not io2's 2.0 ms |
| 7a | 1 + gp3 16,000 / 1,000, new cluster; guest suite with pgbench, and pre-filled contention | what provisioning, a database and contention look like on nested x86 | random write 4.0×, seq write capped at ~300 MiB/s, **seq read stuck at 143 MiB/s**, fsync unchanged; pgbench 441 / 2,096 / 4,988 tps; contention as Graviton, but sequential etcd p99 216 ms |
| 7c | 7a lowered to gp3 baseline (3,000 / 125), in place | how bad baseline is on x86, for a database and under contention | pgbench −2% to −12% only. Contention caused **a control-plane outage, reproduced in two runs**: etcd fsync p99 about 2 s, all three API servers restarted, a node NotReady, the VIP moving, one leader change |
| 7b | 7a + io2 at 16,000 IOPS, in place | whether io2's latency gain holds on x86 | yes: fsync +66%, pgbench +42–61%, seq write per disk doubled to 584 MiB/s. Sequential contention hit the instance's EBS burst limit (1,198 MiB/s) and etcd p99 reached 127 ms |
| V1 | 7a on Harvester v1.9.0, new cluster with kube-ovn and vip-controller, etcd metrics off | whether the release changes any figure | [no, except under contention](#harvester-v190-on-configuration-5s-platform): VM overhead 18.6%, pgbench within 2%, density the same. etcd writes −25% (a follower, not the release). Six saturating VMs: storage the same, API→etcd p99 3.6 s against 1.0 s, kubeovn-operator restarted 7 times; unexplained, rerun needed |
| 13 | 5b's cluster + a kube-ovn overlay and its VPC route; runner `m8i.4xlarge` as the VPC client (`--guest-vpc-network`) | what VMs get to and from the rest of the VPC | 4 streams: 12.2–14.3 Gbit/s, near the node's own 14.35, inbound through the route node included; single flows about 4.8 Gbit/s (EC2's per-flow limit). The overlay adds 0.2–0.4 ms of round trip |
| E2 | E1's cluster, guest suite in VM mode with pgbench, data disk on EFS | what one VM and a database get from EFS | fsync 106 IOPS (p99 17 ms), pgbench 114 / 452 / 1,179 tps: about a quarter of Longhorn. Seq read 1,009 MiB/s, which places x86's ~140 MiB/s Longhorn read limit in Longhorn |
| E5 | E4 again with `vmMigrationTimeout` 60 (restored afterwards) | how much the force-reset timeout sets recovery time | VMs back at 173 s (EFS) and 179 s (Longhorn), about 90 s sooner, as predicted. kube-ovn's `ovn-central` did not recover from this second stop |
| E4 | E3's two VMs, their node stopped | how long a VM takes to come back after its node fails, on EFS and on Longhorn | about 4 minutes for both, set by Harvester's force-reset policy (node silent ≈75 s + `vmMigrationTimeout` 180 s). EFS VM up at 258 s, Longhorn at 291 s and degraded until the node returned, then a 2-minute rebuild |
| E3 | E1's cluster: a VM with root and data disks on EFS (image with `backend: cdi`), against an all-Longhorn VM; three live migrations each | whether a VM can run with no Longhorn disk, and what EFS does to VM creation and migration | yes. Root disk ready in 162 s (CDI copies the image) against an instant clone; live migration 7–9 s against 18 s on Longhorn |
| E1 | 7c's cluster at gp3 baseline, VM data disks on EFS (Elastic) | whether EFS keeps VM writes off etcd's volume | **yes**: node volumes idle, etcd fsync p99 3.9 ms throughout, no failures, where Longhorn at the same baseline had an outage. 11,200 random IOPS / 1,037 MiB/s across six VMs; about 11 ms per write for one VM |
| 2b | 3 × `m8i.16xlarge`, root gp3 baseline, a second gp3 16,000 / 1,000 disk per node for VM data (configuration 8) | whether a separate volume for VM data keeps the control plane healthy | **yes**: six VMs saturating the second disks left the root volumes idle and etcd at 3.9 ms, with 0 slow applies. The same load on the root volume at 16,000 / 1,000: 31–210 ms, 2,139 slow applies |
| W1 | 3, and 3 lowered to baseline + pgbench (`--guest-pgbench`) | what a real database gets | 565 / 2,600 / 4,605 tps at 1 / 8 / 32 clients (16,000 / 1,000); 564 / 2,449 / 4,135 at baseline; 10–19% VM overhead |
| W2 | 3 at baseline and at 16,000 / 1,000 + six VMs writing at once (`--guest-contention 6 [--guest-contention-prefill]`) | whether the cluster shares one volume's write capacity, and what that does to etcd | total = one volume's capacity at every tier. At baseline with filled disks, API server health probes failed; at 16,000 no failures, but etcd p99 31–123 ms when saturated |

### Remaining, in priority order

IDs are stable labels that the text above links to; the order is the priority.

| ID | Test | Question it answers | Infrastructure | Notes |
| --- | --- | --- | --- | --- |
| — | **A cluster placement group** | how much of Longhorn's synchronous-write latency is the distance between nodes | module change: `aws_placement_group` with strategy `cluster` | Configuration 8's nodes were 0.41 ms apart against about 0.3 ms before, and fsync and pgbench were 25–35% slower. Trade-off: a cluster placement group concentrates nodes, so one hardware failure can affect more of them. |
| 8 | **Long contention**: six VMs saturating the volumes for 30–60 min | whether "no failures" holds beyond three-minute bursts | `run-perf.sh` passthrough for guest-bench's `--contention-seconds` | Every no-failure result so far is a 180 s phase. The warning above rests on etcd's 1 s election timeout. |
| 9 | **Operational events under load**: Longhorn replica rebuild after a node reboot, VM live migration, a large image import | how long maintenance takes, and what it does to running VMs and etcd | new harness: a node reboot during W2; migration timing per VM | Rebuild traffic lands on the same shared volumes as VM writes and etcd. Harvester upgrades drain nodes by live migration, so migration time is what an upgrade costs per VM. |
| 10 | **Network with several VM pairs at once, and VM to VM on the overlay** | whether the ~6–7 Gbit/s cap is per VM (so a node's total scales towards the instance limit) or per node; and whether it is the default pod network's, since test 13 showed a VM on the kube-ovn overlay reaching 12–14 Gbit/s to the VPC | guest-bench: several bench/peer pairs on the same nodes | "A bigger instance raises the total across VMs" above is inferred from one VM pair, not measured. |
| 11 | **pgbench larger than memory** (scale about 500–1,000, against the VM's 8 GiB) | what a database that reads from disk gets; io2's lower read latency should matter more | `PG_SCALE` in `perf/guest/bench.py` is fixed at 100; needs an option | The scale-100 runs read almost nothing from disk. |
| 12 | **A larger VM** (8–16 vCPU) for pgbench | how far io2's gain extends at high concurrency | `--guest-vcpus` | At 32 clients on io2 the 4-vCPU VM was throttled in 64% of CFS periods. |
| 3 | **Node-level disk, below Longhorn** (old 3c) | how much of the remaining sync-write latency is EBS and how much is Longhorn's engine; and where in Longhorn x86 sequential reads stop at about 150 MiB/s | none; a privileged pod on a node | E2 placed the x86 read limit in Longhorn: the same VM read 1,009 MiB/s from EFS. Run it on x86 first. |
| 5 | **External storage: EBS CSI**, one EBS volume per VM disk | whether bypassing Longhorn removes the shared-volume limit and the ~460 MiB/s cap | EBS CSI driver | First confirm that Harvester v1.8.2 supports third-party CSI for VM disks, and whether for boot disks too. Trade-off: no live migration, no Longhorn replication, and single-AZ volumes. |
| 6 | **EFS on Graviton**, and recovery with a shorter `vm-force-reset-policy` | EFS latency on bare metal; how fast a VM can come back after a node failure | the Graviton cluster; a Harvester setting | Contention, the single-VM suite, root disks, live migration and node failure on EFS are measured (E1–E4). |
| — | **More Graviton samples** | a stable range for the Graviton scheduler figure | none | Six samples so far: −1% to 28%, mean about 13%. The pod varies too, so the variance is in the host. More samples come with every run. |

### Optional

| Test | Question | Infrastructure |
| --- | --- | --- |
| MTU 9001 | whether the VM network cap is a per-packet cost | redeploy (MTU is deploy-time) |
| `m8i.8xlarge` | how figures scale with instance size; it also doubles EBS bandwidth to 10,000 Mbps baseline. Test 7b showed `m8i.4xlarge`'s EBS bandwidth limits sequential VM writes, and its burst, about 1,190 MiB/s, is exactly `m8i.8xlarge`'s baseline. Rerun 7b's contention there to confirm | redeploy |
| Multi-AZ | what cross-AZ latency does to Longhorn's synchronous replication and to etcd | module change: every node is in one `subnet_id` today. Until then, state that the cluster is single-AZ |
| On-prem baseline | how AWS compares with existing Harvester clusters | an on-prem cluster; the scripts run unchanged |

Notes for the runs ahead:

- **Graviton needs v1.8.2.** v1.9.0 arm64 guests cannot boot (the
  [README](../README.md#what-has-been-tested) has the cause), and
  `run-perf.sh` refuses the guest and density suites there.
- **Graviton is not a pure "nesting removed" comparison**, because the CPU
  architecture changes too. The VM-against-pod overhead is still comparable,
  since each platform is measured against its own pods. The absolute figures are
  not.
- **Use the same harvester-perf commit** (`--perf-ref 6858e2c`), and the same
  guest flags, for every row.
