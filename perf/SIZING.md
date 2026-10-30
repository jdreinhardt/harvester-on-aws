# Sizing Harvester on AWS

What to deploy, and what to expect from it, for a three-node Harvester cluster
on EC2. This is the short version. Every figure comes from a measured run;
[FINDINGS.md](FINDINGS.md) has the detail, the method and the caveats, and
links back to each run in `perf/results/`.

**Scope.** Harvester v1.8.2, three nodes in one Availability Zone, built with
this repository's Terraform module. Two platforms were measured: `m8i.4xlarge`
(x86, VMs run nested on Nitro) and `c7g.metal` (Graviton, bare metal). Each
node has a single 500 GiB EBS root volume, measured as gp3 at baseline, gp3
provisioned, and io2. On x86, VM data disks were also measured on Amazon EFS,
and on a second EBS volume per node (`m8i.16xlarge`, in a different
Availability Zone from the other x86 runs). Guest VMs were 4 vCPU / 8 GiB
Ubuntu 24.04.

## The short version

1. **Never run write-active VMs on gp3's baseline (3,000 IOPS / 125 MiB/s).**
   Six ordinary VMs writing at once took the x86 control plane down for three
   minutes, twice in two runs: etcd's fsync latency reached about 2 s, every
   API server was restarted, a node went NotReady and the cluster VIP moved.
   Graviton survived the same load, but with failed API health checks.
2. **Give each node a second EBS volume for VM data.** With VM disks on it,
   six VMs saturating it left the root volumes idle at gp3's baseline and etcd
   at its idle 3.9 ms, with no slow requests at all; the same load on a
   provisioned root volume slowed etcd to 31–210 ms. It keeps EBS latency for
   the VMs, unlike EFS, and costs about $140 a month per node at 16,000 IOPS /
   1,000 MiB/s. Setup is in the repository README, "A second disk for VM data".
3. **Without a second volume, size the root volume above the cluster's
   combined VM write load.** Each VM write lands on every node's volume, so the
   whole cluster's write capacity is *one* volume's. etcd shares that volume. It
   stays healthy while VM writes stay below the limit, and degrades once they
   reach it, on every volume type and instance size tested.
4. **Choose io2 for databases that commit synchronously.** At the same IOPS it
   made single-connection PostgreSQL 45–49% faster on both platforms. It costs
   about 8× as much as gp3, on every node, and it does not protect etcd.
5. **Graviton bare metal is faster per I/O and per VM; x86 nested is fine for
   compute.** VM overhead is 8–15% on Graviton against about 19% on x86, and
   x86 adds about 0.3–0.8 ms to every synchronous or single-queue disk I/O.
6. **Put VMs that serve the VPC on a kube-ovn overlay.** There, one VM reached
   12–14 Gbit/s to and from the VPC, close to the node's own bandwidth, against
   6–7 Gbit/s VM to VM on the default network. Plan for 5 Gbit/s per
   connection.
7. **EFS for VM data disks protects the control plane, at a high latency
   cost.** With six VMs writing to EFS, the node volumes stayed idle at gp3's
   baseline and etcd never left 3.9 ms. But each synchronous write takes about
   9 ms, so PostgreSQL ran at about a quarter of its Longhorn speed. Harvester
   cannot back up or snapshot VMs with EFS disks.

## How the cluster uses its disks

Everything a node writes goes to its one EBS root volume: the OS, etcd, and
every Longhorn replica stored on that node. Longhorn keeps three replicas of
each VM disk, one per node, and writes to all three before a write completes.

So:

- **The cluster's write capacity is one volume's**, not three. Three nodes at
  16,000 IOPS give VMs 16,000 write IOPS in total, shared by every VM.
- **etcd competes with every VM for that volume.** When VM writes fill it,
  etcd's commits queue behind them, and the API server, every controller and
  kube-vip slow with it.
- **The instance's own EBS bandwidth is a third limit**, alongside the
  volume's IOPS and MiB/s. Whichever one VM writes reach first is the one that
  hurts etcd.

What VM write saturation did to etcd's write-ahead-log fsync p99, against its
10 ms guideline and 1 s election timeout:

| Volume | Six VMs, 4K random writes | Six VMs, 1 MiB sequential writes | Control plane |
| --- | --- | --- | --- |
| gp3 3,000 / 125, Graviton | 126 ms | 933 ms | API health probes failed on 2 of 3 nodes |
| **gp3 3,000 / 125, x86** | 127 ms | **≈2,000 ms** | **Outage**: leader change, all API servers restarted, a node NotReady |
| gp3 16,000 / 1,000, Graviton | 31 ms | 123 ms | No failures |
| gp3 16,000 / 1,000, x86 | 31 ms | 216 ms | No failures |
| gp3 16,000 / 2,000, Graviton | 31 ms | 31 ms | No failures |
| io2 16,000, Graviton | 31 ms | 2.0 ms (writes stayed below the volume's limit) | No failures |
| io2 16,000, x86 | 31 ms | 127 ms (the instance's EBS limit) | No failures |
| **gp3 3,000 / 125, x86, VM data disks on EFS** | **3.9 ms** (idle) | **3.9 ms** (idle) | No failures; the node volumes saw no VM writes |
| gp3 16,000 / 1,000, `m8i.16xlarge`, everything on the root volume | 31 ms | 210 ms | No failures; 2,139 slow etcd requests |
| **gp3 3,000 / 125 root, VM data on a second gp3 16,000 / 1,000 volume, `m8i.16xlarge`** | **3.9 ms** (idle) | **3.9 ms** (idle) | No failures, no slow etcd requests; the root volumes stayed idle |

Every "no failures" result comes from three-minute bursts. Longer saturation
was not tested.

## Choosing the instance

| | `m8i.4xlarge` (x86, nested) | `c7g.metal` (Graviton, bare metal) |
| --- | --- | --- |
| Per node | 16 vCPU, 64 GiB | 64 vCPU, 128 GiB |
| Left for VMs after Harvester's CPU requests | about 31 of 45 cores (Harvester takes about a third) | about 157 of 188 cores |
| Harvester's memory use, whole cluster | about 17 GiB | about 20 GiB |
| VM overhead against a pod | 18.5–20.9% | 8.5–15.1% (the scheduler figure varies by host) |
| CPU-bound work | 1–5% slower than a pod | under 1% slower |
| Synchronous write (fsync), p99, gp3 / io2 | 2.06 / 1.35 ms | 1.43 / 1.06 ms |
| EBS bandwidth | 5,000 Mbps (≈600 MiB/s), 10,000 burst for about 30 min a day; 20,000 IOPS | 20,000 Mbps (≈2,380 MiB/s); 80,000 IOPS |
| Network | 7.5 Gbit/s, 15 burst | 30 Gbit/s |
| Guest firmware | any release | needs **v1.8.2**; v1.9.0 arm64 guests do not boot |

- **x86 nested** suits compute-bound and general-purpose VMs. Its weakness is
  I/O latency, and its EBS bandwidth: past about 600 MiB/s of sustained
  writes it runs on burst credit.
- **Graviton metal** suits latency-sensitive, chatty or write-heavy VMs, and
  more VMs per node. It needs arm64 guest images.
- **Bigger x86 nodes** raise the EBS limit (`m8i.16xlarge`: 20,000 Mbps, no
  burst) and the VM count, but **do not protect etcd by themselves**: with
  everything on one volume, an `m8i.16xlarge` slowed etcd exactly as an
  `m8i.4xlarge` did. A second volume for VM data is what does.

### How many VMs fit

Measured on 3 × `m8i.16xlarge` with small VMs (CirrOS container disks):
**440 VMs**, about 150 per node, before the next ones could not be scheduled.
The limit was **Kubernetes' pods per node** (200 on Harvester), not CPU,
memory or storage, and the control plane stayed healthy throughout (API
requests' worst p99 95 ms). VM start time at that density: p50 18 s, p99
31 s. Real VMs, larger than these, would reach CPU or memory limits first on
smaller nodes; on large nodes, plan for the pod limit. Harvester's own CPU
reservation also grows with node size, mostly Longhorn's: 34 of 188 cores on
`m8i.16xlarge` (18%).

## Choosing the volume

Approximate list prices, us-east, three 500 GiB volumes per month (check
current pricing):

| Volume | Cost, 3 nodes | Cluster VM write capacity | Single-connection PostgreSQL (VM), x86 / Graviton | Use it for |
| --- | --- | --- | --- | --- |
| gp3 3,000 / 125 | ≈$120 | 3,000 IOPS, 125 MiB/s | 447 / 564 tps | **Nothing with write-active VMs** |
| gp3 16,000 / 1,000 | ≈$420 | 16,000 IOPS, 1,000 MiB/s | 441 / 565 tps | One volume per node, with VM writes kept below its limits |
| gp3 16,000 / 2,000 | ≈$540 | 16,000 IOPS, 2,000 MiB/s | not measured (throughput does not change commit latency, so expect the 16,000 / 1,000 figures) | Bulk or sequential writers, on Graviton |
| io2 16,000 | ≈$3,300 | 16,000 IOPS, 4,000 MiB/s | **640 / 844 tps** | Commit-latency-bound databases |
| **gp3 3,000 / 125 root + gp3 16,000 / 1,000 second volume** | ≈$120 + $420 = **≈$540** | 16,000 IOPS, 1,000 MiB/s, on the second volume | 318 tps on x86 (a slower-network cluster; see Network) | **The default for clusters with write-active VMs**: etcd never shares a volume with VMs |

- **Provisioning gp3 buys capacity, not latency.** Single-threaded fsync and
  small in-memory databases barely change between gp3 baseline and 16,000
  IOPS. What changes is how much write load the cluster can absorb before
  etcd suffers, and bulk work: loads, restores and sequential writes.
- **io2 buys latency.** fsync rate rose 66% (x86) and 74% (Graviton); pgbench
  rose 45–62% at 1–8 clients. At 32 clients it rose 42% on x86 and 19% on Graviton, where the VM's 4 vCPUs became the limit.
- **Do not provision past the instance's EBS limit.** On `m8i.4xlarge`,
  volume throughput above about 600 MiB/s is only usable while the burst
  lasts; io2's 4,000 MiB/s cannot be reached at all.
- **gp3 throughput needs IOPS too**: at most 0.25 MiB/s per IOPS, so
  2,000 MiB/s needs at least 8,000 IOPS. The module checks this at plan time.

## VM data disks on EFS

Measured on x86 only, with the node volumes at gp3 baseline and the VMs' root
disks still on Longhorn. Setup, including the IAM role and security group
rule it needs, is in the repository README's "EFS for VM disks".

| | Longhorn, gp3 16,000 / 1,000 | EFS (Elastic throughput) |
| --- | --- | --- |
| Six VMs at once, 4K random write | 16,000 IOPS | 11,200 IOPS |
| Six VMs at once, sequential write | ≈1,000 MiB/s | ≈1,040 MiB/s (looks like the file system's write limit) |
| etcd while six VMs write | 31–216 ms | **3.9 ms**, unchanged from idle |
| One VM, fsync, one thread | 640 IOPS, p99 2.1 ms | **106 IOPS, p99 17 ms** |
| One VM, pgbench, 1 / 8 / 32 clients | 441 / 2,096 / 4,988 tps | **114 / 452 / 1,179 tps** |
| One VM, sequential read | ≈140 MiB/s | **≈1,000 MiB/s** |
| Harvester VM backups and snapshots | yes | **no** |

- **Use it for** bulk and sequential data, and clusters where keeping VM
  writes away from etcd matters more than per-write latency. It needs no node
  volume provisioning for those disks. Each EFS disk belongs to one VM, as
  `disk.img` on its own access point; to share data between VMs, guests
  would mount EFS over NFS themselves, which is not what was measured.
- **Do not use it for databases** or anything that commits small writes
  synchronously: every durable write is a round trip of about 9 ms.
- **Back it up outside Harvester**, for example with AWS Backup on the file
  system (not tested here). Harvester cannot back up or snapshot a VM with
  any EFS disk.
- **Check the bill.** Elastic throughput charges per GB transferred, and 4K
  random writes were metered at roughly 8× their size (about 350 MiB/s for
  44 MiB/s of writes). The cause is not established.

## What one VM gets

4 vCPU / 8 GiB VM, three-replica Longhorn data disk:

| | x86, gp3 16,000 / 1,000 | x86, io2 16,000 | Graviton, gp3 16,000 / 1,000 | Graviton, io2 16,000 |
| --- | --- | --- | --- | --- |
| 4K random write, qd32 | 11,800 IOPS | 16,000 IOPS | 14,100 IOPS | 15,900 IOPS |
| Sequential write, one disk | ≈300 MiB/s | ≈580 MiB/s | ≈450 MiB/s | ≈520 MiB/s |
| Sequential read, one disk | ≈140 MiB/s (a Longhorn limit on these nodes; see below) | ≈130 MiB/s | 720–1,060 MiB/s | ≈815 MiB/s |
| fsync, one thread | 640 IOPS | 1,060 IOPS | 808 IOPS | 1,402 IOPS |
| pgbench, 1 / 8 / 32 clients | 441 / 2,096 / 4,988 tps | 640 / 3,374 / 7,107 tps | 565 / 2,600 / 4,605 tps | 844 / 4,219 / 5,473 tps |

- **More throughput comes from more disks and more VMs, not from the volume.**
  One VM disk tops out at the figures above, well below what the volume
  allows; six VMs together reached the volume's limits.
- **A VM's new disk is slower until written**: thin Longhorn volumes pay about
  2.6× on first writes.
- **pgbench at 32 clients is CPU-bound in 4 vCPUs** on io2. Give database VMs
  more vCPUs to use io2's headroom.

## Network

| | x86 | Graviton |
| --- | --- | --- |
| VM to VM, default network, sustained | ≈7.4 Gbit/s | ≈6.0 Gbit/s |
| VM to VM round trip | 0.75 ms | 0.35 ms |
| VM on the kube-ovn overlay, to and from a VPC host, 4 streams | 12–14 Gbit/s (burst) | not measured |
| One connection to anything outside the cluster | ≈4.8 Gbit/s (EC2's per-flow limit) | not measured |

- **Bridged and VLAN VM networks cannot work on EC2.** Use the kube-ovn
  overlay; the repository README's "VM networking on EC2" has the setup.
- **All inbound VPC traffic to overlay VMs enters through one node**, the one
  the VPC route names. It was not a bottleneck with one VM, but every VM's
  inbound traffic shares that node's bandwidth. If that node fails, inbound
  traffic stops until the route is repointed; outbound is unaffected.
- **The overlay adds about 0.2–0.4 ms of round trip** and 100 bytes per packet
  (guest MTU 1400).
- **Distance between nodes is part of every disk write.** Longhorn completes a
  write only when all three replicas, on three nodes, have it. One cluster's
  nodes were 0.41 ms apart against about 0.3 ms for the others, and its
  synchronous writes and PostgreSQL were about 30% slower; single connections
  between those nodes also stopped at 4.6 Gbit/s, EC2's per-flow limit
  between instances that are not close. A **cluster placement group** keeps
  instances close and would likely recover this, at the cost of putting the
  nodes on fewer racks. Not yet tested; the module does not set one.

## Recommended starting points

| Cluster | Instance | Node volume | Why |
| --- | --- | --- | --- |
| **Anything with write-active VMs** | either | **gp3 3,000 / 125 root, plus a second gp3 16,000 / 1,000 volume for VM data** | etcd never shares a volume with VM writes. Measured on `m8i.16xlarge` |
| General-purpose VMs, light disk use, one volume per node | either | gp3 16,000 / 1,000 | Room for bursts; etcd slows only when VM writes reach the volume's limit |
| Many VMs, or steady bulk writes | `c7g.metal` | gp3 16,000 / 2,000 | The most write bandwidth per dollar; the instance carries it |
| Databases, latency-bound | `c7g.metal` | io2, IOPS above the combined write load | Lowest commit latency measured: the most transactions per connection. At 32 connections x86 on io2 did more (7,107 against 5,473 tps), so for highly concurrent databases compare both |
| Compute-heavy, x86-only software | `m8i.4xlarge` or larger | gp3 16,000 / 1,000 | Compute overhead is small; keep sustained writes under ≈600 MiB/s |
| Bulk data, where the control plane must stay healthy | `m8i.4xlarge` (measured) | gp3 sized for the root disks; data disks on EFS | VM data writes never reach etcd's volume. Not for databases; no Harvester backups |
| Anything | — | **not** gp3 3,000 / 125 | Measured control-plane outages |

Then estimate the cluster's peak combined VM writes, in IOPS and MiB/s, and
check that they stay below all three limits: the volume's IOPS, its MiB/s, and
the instance's EBS bandwidth. How much margin to keep below them was not
measured. Below them, etcd stayed near idle; at them, it did not. With a
second volume for VM data, those limits apply to the second volume, and etcd
is unaffected either way; the instance's EBS bandwidth is still shared by
both.

Terraform:

```hcl
instance_type     = "c7g.metal"   # or m8i.4xlarge
volume_type       = "gp3"         # or "io2" (then no volume_throughput)
volume_iops       = 16000
volume_throughput = 1000          # gp3 only; up to 2000, needs IOPS >= 4x this
```

All of these change in place on a running cluster, without replacing nodes.
AWS allows four volume modifications per 24 hours, and lowering a volume can
take hours to finish. The second volume is not part of the module: it is
created, attached and added to Longhorn by hand (README, "A second disk for VM
data"), and it survives `tofu destroy`.

## Not yet known

These are open, and could change the advice above:

- **A second volume for VM root (image) disks**, not only data disks, and the
  module creating the second volume rather than a manual step.
- **A cluster placement group**, and how much of Longhorn's write latency it
  recovers.
- **Saturation longer than three minutes**, at any tier.
- **Where in Longhorn x86 sequential reads stop at about 140 MiB/s** per VM
  disk. The same VM read about 1,000 MiB/s from EFS, so the limit is in
  Longhorn's read path on these nodes, not in the guest or the network.
- **EFS: root disks, Graviton, and its write limit.** Booting from EFS, EFS
  latency on bare metal, and whether ≈1,040 MiB/s is the file system's
  Elastic write limit are all unmeasured.
- **Replica rebuilds and live migration under load**, for example during a
  node reboot or a Harvester upgrade.
- **Clusters larger than three nodes, multi-AZ clusters**, and a higher
  pods-per-node limit for dense clusters.
- **Databases larger than memory**, which read from disk.
- **Sustained (not burst) network figures** on the overlay path.
