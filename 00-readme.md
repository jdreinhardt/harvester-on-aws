# Harvester (SUSE Virtualization) on AWS EC2

Builds an EC2 AMI from a stock Harvester ISO and boots it into a working,
self-bootstrapping single-node cluster.

Targets Harvester **v1.8.2**.

---

## How it works

Harvester has no cloud image and no EC2 support. But `harvester-installer` does
have a two-phase "preloaded disk" flow that fits AWS exactly, and this repo uses
it rather than inventing anything.

**Phase 1** runs the installer under QEMU with `harvester.install.mode=install`.
That is a deliberately *incomplete* install — from `pkg/config/cos.go`:

```go
if cfg.Install.Mode != ModeInstall {
    initRancherdStage(config, &initramfs)   // rancherd config + bootstrap resources
    initramfs.Hostname = cfg.OS.Hostname
    UpdateManagementInterfaceConfig(...)     // mgmt-bo bond + mgmt-br bridge
}
```

So the image has the OS laid down but no cluster identity: no
`/etc/rancher/rancherd/config.yaml`, no bootstrap resources, no network
profiles, no hostname. That is what makes it reusable as an AMI.

**On first boot**, `console.go` sees `mode: install` in `/oem/harvester.config`,
sets `alreadyInstalled = true`, and calls `mergeCloudInit()`, which reads
**`/oem/userdata.yaml`**. If that file sets `install.automatic: true`, the
installer skips its TUI and runs `configureInstalledNode()` — which generates
the rancherd config and every bootstrap resource (Fleet `ManagedChart`s for
`harvester` and `harvester-crd`, monitoring/logging/kube-ovn CRDs, harvester
settings, addons, the Rancher ingress) and restarts `rancherd`.

Harvester does this itself: `package/harvester-os/files/usr/sbin/stream-disk`,
the script that installs *from* a prebuilt raw image, ends with

```bash
curl -k -o /oem/userdata.yaml ${HARVESTER_STREAMDISK_CLOUDINIT_URL}
```

**Phase 2** installs the glue that produces that file on EC2, plus the
AWS-specific boot fixes.

**Phase 3** launches the instance and passes a Harvester configuration as EC2
user-data.

```
EC2 user-data (a Harvester config)
        |
        v
harvester-aws-config.service        <- phase 2; IMDSv2; ordered before the installer getty
        |
        v
/oem/userdata.yaml
        |
        v
harvester-installer  ->  configureInstalledNode()
        |
        v
/etc/rancher/rancherd/config.yaml + /var/lib/rancher/rancherd/bootstrap/*
        |
        v
rancherd  ->  RKE2  ->  Rancher  ->  harvester / harvester-crd ManagedCharts
```

---

## Requirements

**Instance type must support nested virtualization and boot UEFI.**

Harvester needs `/dev/kvm` (`preflight.KVMHostCheck`) or KubeVirt cannot run
guests. Two separate constraints collide on EC2:

* All current x86_64 **bare metal** instances are legacy BIOS only, and
  Harvester dropped BIOS support (`preflight.BIOSCheck`).
* **Nested virtualization** on virtualized instances is supported on M7i, M7i-flex,
  M8i, M8id, M8i-flex, C7i, C7i-flex, C8i, C8id, C8i-flex, R7i, R7iz, R8i,
  R8id, R8i-flex, X8i, I7i and I7ie — and those are UEFI.

So: `m8i.4xlarge` (the default). It must be launched with
`--cpu-options NestedVirtualization=enabled`; **it is opt-in per instance**, and
without it there is no `/dev/kvm` even on a supported type.
`03-launch-instance.sh` checks both the AMI boot mode and the instance type
before it launches anything.

**Build host** — Linux with KVM, QEMU, OVMF, `zstd`. The build VM defaults to
**8 vCPU / 16 GiB**, matching what Harvester's own CI uses
(`ipxe-examples/vagrant-pxe-harvester/settings.yml`). The install is not a light
workload: `harv-install`'s `preload_rke2_images()` starts a real RKE2 server in a
chroot and imports several GB of container images through containerd. Budget
~15 GiB of free disk for what the sparse image actually allocates.

**Helper instance** — any EC2 Linux instance with an extra EBS volume attached,
plus an IAM role that can read your S3 bucket. `gdisk` (for `sgdisk`) is nice to
have; `fdisk` is used as a fallback.

---

## Phase 0 — artifacts

Download from the [Harvester releases](https://github.com/harvester/harvester/releases)
into `./artifacts/`:

```
harvester-v1.8.2-amd64.iso
harvester-v1.8.2-vmlinuz-amd64
harvester-v1.8.2-initrd-amd64
```

## Phase 1 — build the raw image

```bash
./01-build-instance.sh
```

Produces `artifacts/harvester-v1.8.2-amd64.raw{,.zst}` — 250 GiB by default,
UEFI, with
`mode: install` in `/oem/harvester.config`. The whole guest console is copied to
`artifacts/harvester-install-console.log`, and the script checks that log and
the resulting partition table before it compresses. It needs no root.

While QEMU runs, the terminal belongs to the guest. **Ctrl-C goes to the guest;
Ctrl-A then X aborts.** The script restores the terminal on exit either way.

`--force` rebuilds over an existing image. Without it the script refuses,
because a failed *script* is not the same as a failed *install* — if the guest
reached `Powering off.` the image is complete and only needs compressing:

```bash
zstd -T0 --force artifacts/harvester-v1.8.2-amd64.raw
```

Override with env vars: `HARVESTER_VERSION`, `DISK_SIZE_GIB`,
`PERSISTENT_SIZE`, `MEMORY_MIB`, `SMP`, `QEMU_TIMEOUT`, `OS_PASSWORD`,
`OS_PASSWORD_HASH`, `OVMF_CODE`.

### If phase 1 fails

The installer prints `** Installation Failed **` and then, deliberately, leaves
the VM running instead of powering off. Log in on that same console as
`rancher` / `rancher` and read `/var/log/console.log` for the real error. The
script also tails the captured console log for you and exits non-zero.

Failures during `Load images from .../rke2-images...tar.zst` are almost always
resources rather than anything Harvester-specific:

| Symptom | Cause |
|---|---|
| `Importing elapsed: ... 0.0 B (0.0 B/s)`, `watchdog: BUG: soft lockup ... khugepaged` | Guest memory. Raise `MEMORY_MIB`, or free host RAM. |
| `zstd` / `ctr import` exits 1 early | Host disk full — the sparse image still allocates ~10–15 GiB. |

The disk is attached with `cache=none,discard=unmap` for the same reason:
`cache=writeback` on a 250 GiB image fills the host page cache with dirty pages
while the installer writes, starving the guest.

> `os.password` is written **verbatim** into `/etc/shadow`. Nothing in the
> non-interactive path hashes it — `harvester-installer` only calls
> `GetEncryptedPasswd()` from the interactive TUI. A plaintext value silently
> disables password login instead of setting it, so the script hashes it for
> you with `openssl passwd -6`.

## Phase 1.5 — write the image to an EBS volume

Upload:

```bash
aws s3 cp artifacts/harvester-v1.8.2-amd64.raw.zst s3://your-bucket/
```

Attach a volume of **exactly `DISK_SIZE_GIB`** to a helper instance — 250 GiB
by default, or 130 if you built small. Then:

```bash
sudo ./01b-write-image.sh --source s3://your-bucket/harvester-v1.8.2-amd64.raw.zst --device /dev/nvme1n1
```

> **Do not** use the obvious one-liner:
>
> ```bash
> aws s3 cp s3://bucket/key.zst - | zstd -dc | sudo dd of=/dev/nvme1n1   # DON'T
> ```
>
> `aws s3 cp` writing to stdout does a single, non-resumable GET. Its retry
> logic cannot help, because the bytes it already emitted have gone downstream
> into `zstd` and `dd` — there is nothing to rewind. Writing to a *file* would
> use parallel multipart ranged GETs with per-part retries; streaming to stdout
> disables all of that. A half-hour connection to S3 only has to hiccup once:
>
> ```
> 169160474624 bytes (169 GB) copied, 1289 s, 131 MB/s
> download failed: ... ConnectionResetError(104, 'Connection reset by peer')
> /*stdin*\ : Read error (39) : premature end
> ```
>
> `01b-write-image.sh` fetches the object in ranged chunks instead. Each chunk
> is staged in a small scratch file and only emitted downstream once it has
> been fetched intact, so any chunk can be retried without corrupting the
> stream — and scratch usage is one chunk, not the whole object, so it works on
> a helper instance with a small root volume. It then verifies the partition
> table and the `COS_*` filesystem labels before declaring success.
>
> Options: `--chunk-mib` (default 256), `--retries` (default 6), `--scratch`,
> `--yes`.

> **Size the helper volume to match the image, not to match what you intend to
> launch.** An EBS snapshot's `VolumeSize` is the size of the volume it was taken
> from — not the bytes actually used — and `register-image` will not declare a
> root volume smaller than its snapshot. So the helper volume becomes the
> permanent *minimum* root volume for every instance launched from that AMI.
> A 130 GiB helper volume lets you launch at anything from 250 GiB up; a 500 GiB
> one locks you to 500 GiB and forfeits the deploy-time sizing entirely. Phase 3
> refuses the mismatch rather than letting EBS reject it later.
>
> Smaller than the image is not an option either: the GPT backup header sits in
> the image's last sector and is non-zero, so `conv=sparse` writes rather than
> skips it, and `dd` fails with ENOSPC.

> The old workflow used a volume 1 GiB larger than the image to dodge
> "partition corruption". That symptom is just the GPT backup header sitting
> mid-disk when the image is smaller than the volume. Matching the sizes avoids
> it entirely; phase 2 also relocates the header (`sgdisk --move-second-header`,
> the same thing Harvester's `stream-disk` does with `echo w | fdisk`) so a
> larger volume works too. Add `--grow-data-disk` to expand
> `HARV_LH_DEFAULT` into the extra space.

## Phase 2 — customize for AWS

```bash
sudo ./02-customize-instance.sh /dev/nvme1n1
```

| | |
|---|---|
| `COS_GRUB` | ESP renamed to `EFI/BOOT/BOOTX64.EFI` — the removable-media path AWS boots for a snapshot-registered AMI |
| `COS_STATE` | `active.img`/`passive.img` `bootargs.cfg` → `console=ttyS0,115200n8` only, and `net.ifnames=0`; same settings mirrored into `grubcustom` so they survive an OS upgrade |
| `COS_OEM` | `99_aws.yaml` + `aws/stage-initramfs.sh` + `aws/configure.sh` |
| `COS_OEM` | `harvester.config` left alone — `mode: install` **must** stay |

Options: `--grow-data-disk`, `--no-serial-console`.

Three details worth knowing:

*Longhorn's data partition.* The first boot uses os2's stock rootfs layout,
which mounts only `COS_OEM` and `COS_PERSISTENT`. The entry that mounts
`HARV_LH_DEFAULT` at Longhorn's `defaultDataPath` lives in
`/oem/99_custom.yaml`, which the installer writes *during* that boot — and
rootfs stages only run in the initrd. Since `configureInstalledNode()` ends with
`harv-restart-services` (restart rancherd, no reboot), Longhorn would otherwise
come up with its data path on the `/var` tmpfs overlay and every volume would go
`faulted`. `aws/configure.sh` mounts the partition itself before the installer
runs. Later boots do not need it. This affects Harvester's own `stream-disk`
flow too, not just this repo.


*Console.* `/sys/class/tty/console/active` lists the *preferred* console last,
and both `setup-installer.sh` and `isFirstConsoleTTY()` key off the **first**
entry. With the stock `console=ttyS0 console=tty1` the installer lands on ttyS0
but `/dev/console` is tty1, so systemd and rancherd output never reaches EC2
Serial Console. Dropping tty1 puts everything on serial.

*Ordering.* `elemental-setup-boot.service` is only `Before=getty.target`, which
does **not** order it before the getty units — they are `Before=getty.target`
too and start in parallel. The installer reads `/oem/userdata.yaml` the instant
it starts, so phase 2 stages a real systemd unit plus a `Wants=`/`After=`
drop-in on the installer's getty. `Wants=` rather than `Requires=` so a failed
fetch still gives you the interactive installer on the serial console instead of
no console at all.

## Phase 2.5 — snapshot and register the AMI

```bash
# after detaching the volume from the helper instance
SNAP=$(aws ec2 create-snapshot --volume-id vol-xxxxxxxx \
        --description "harvester-v1.8.2" \
        --query SnapshotId --output text)
aws ec2 wait snapshot-completed --snapshot-ids "$SNAP"

aws ec2 register-image \
  --name "harvester-v1.8.2" \
  --architecture x86_64 \
  --virtualization-type hvm \
  --boot-mode uefi \
  --root-device-name /dev/sda1 \
  --block-device-mappings "DeviceName=/dev/sda1,Ebs={SnapshotId=$SNAP,VolumeSize=250,VolumeType=gp3,DeleteOnTermination=true}" \
  --ena-support \
  --sriov-net-support simple \
  --imds-support v2.0
```

`--virtualization-type hvm` is not optional: the CLI defaults to `paravirtual`.
`--boot-mode uefi` is not optional either — phase 3 refuses to launch otherwise.

## Phase 3 — launch

```bash
./03-launch-instance.sh \
  --ami ami-xxxxxxxx \
  --subnet subnet-xxxxxxxx \
  --sg sg-xxxxxxxx \
  --key-name aws-testing
```

Picks a free VIP from the subnet if you don't pass `--vip`, generates a token,
builds the Harvester configuration, launches with nested virtualization on, and
assigns the VIP as a secondary private IP on the instance's ENI.

`--mtu 9000` is worth passing if you intend to run a kube-ovn overlay later —
it can only be set at install time, and it saves the GENEVE overhead. It is not
required; the overlay works at the default 1500. See
[VM networking on EC2](#vm-networking-on-ec2).

That is *create* mode, which bootstraps a new cluster. To add a node to an
existing one, use `--join` — see [Clustering](#clustering).

`--dry-run` prints the configuration and launch parameters without creating
anything, and makes no API calls beyond the read-only preflight.

### The VIP

Harvester's management plane lives on a VIP served by kube-vip. Inside a VPC an
address only reaches an instance if it is registered on that instance's ENI, so
the VIP must be a **secondary private IP** of the node — that is the
`assign-private-ip-addresses` call. It also has to be chosen before launch,
because it goes into user-data.

Nothing needs to pin kube-vip to an interface: the chart ships
`vip_interface: ""` and kube-vip picks the default-route interface, which on a
configured Harvester node is `mgmt-br`.

### Security group

| Port | |
|---|---|
| 22 | SSH |
| 443 | Harvester UI and API, on the VIP |
| 6443 | Kubernetes API |
| 9345 | RKE2 supervisor |

Plus **all traffic from the group to itself** — source `sg-xxxxxxxx`, not a
CIDR. etcd (2379–2380), the kubelet (10250), Longhorn (3260, 9500–9504) and
kube-ovn's GENEVE tunnels (UDP 6081) all run node to node, and enumerating them
is more trouble than it is worth:

```bash
aws ec2 authorize-security-group-ingress --group-id sg-xxxxxxxx \
  --protocol -1 --source-group sg-xxxxxxxx
```

This matters for a single node too — kube-ovn tunnels to itself.

---

## Clustering

Add nodes with `--join`, pointing at the existing cluster and passing the token
the first node printed:

```bash
./03-launch-instance.sh \
  --ami ami-xxxxxxxx \
  --subnet subnet-xxxxxxxx \
  --sg sg-xxxxxxxx \
  --key-name aws-testing \
  --mtu 9000 \
  --join 172.31.15.253 \
  --token harvester-aws-xxxxxxxxxxxxxxxx \
  --name harvester-node-2
```

`--join` takes a bare address and expands it to `https://<addr>:443`, the same
normalisation `getFormattedServerURL()` does in the installer. In join mode the
script skips VIP selection entirely and does not call
`assign-private-ip-addresses` — the VIP belongs to the cluster and stays
registered on the first node's ENI.

### Promotion needs three nodes

Harvester does not let you join a node *as* a control-plane member. Every node
joins as an rke2-agent, and a controller promotes it afterwards
(`harvester/pkg/controller/master/node/promote_controller.go`).

**Nothing is promoted until the cluster has three nodes:**

```go
// early return if the node number not enough
if len(nodeList) < defaultSpecManagementNumber {   // 3
    return node, nil
}
```

So a two-node cluster looks like this, and it is correct, not a fault:

```
NAME                          STATUS   ROLES                VERSION
harvester-00970497c00695cab   Ready    control-plane,etcd   v1.35.7+rke2r1
harvester-01220f10839ffb118   Ready    <none>               v1.35.7+rke2r1
```

That makes sense — etcd quorum needs three members, so there is nothing useful
to do with two. Add the third and the controller promotes the two workers to
`control-plane,etcd`, switching each from `rke2-agent` to `rke2-server`.
Promotion also requires the node to be **Ready** and healthy, so a node that
never finished joining is never a candidate.

`--role` steers this explicitly (`install.role`):

| Role | Behaviour |
|---|---|
| unset / `default` | Eligible for automatic promotion |
| `management` | Preferred for control-plane + etcd |
| `worker` | Never promoted — use for nodes beyond the third |
| `witness` | etcd-only quorum member, maximum 1 |

So HA control plane plus dedicated workers is: first three nodes unset or
`management`, everything after that `worker`. `witness` gives you a 2+1
topology — quorum without a third full node — but Harvester taints it
`node-role.kubernetes.io/etcd=true:NoExecute` and expects it to have **no**
Longhorn data partition (`ShouldCreateDataPartitionOnOsDisk()` returns false).
An AMI built by phases 1–2 always carries `HARV_LH_DEFAULT` and phase 2 grows
and mounts it, so `witness` is untested here and the script warns.

**What actually makes a node a joiner** is one field. `rancherd-config.yaml` is
templated as:

```
{{if .ServerURL -}}
server: {{ .ServerURL }}
role: agent
{{- else -}}
role: cluster-init
{{- end }}
```

so `server_url` — **top-level in the config, not under `install`** — is the
whole distinction. `install.mode: join` is set alongside it for consistency, but
it is `server_url` that decides the shape.

**Point `--join` at the VIP, not at a node.** This is the easy mistake and the
failure is opaque. A node's own primary address answers on 443 perfectly well
— `/ping` returns `pong` — but Rancher's certificate is issued for the VIP
only, so rancherd fails verification and retries forever:

```
failed to bootstrap system, will retry: generating plan:
Get "https://172.31.16.75:443/system-agent-install.sh": tls: failed to verify
certificate: x509: certificate is valid for 10.52.0.6, 10.52.0.93,
10.53.72.101, 172.31.31.251, not 172.31.16.75
```

The address in the SAN list that you did *not* use is the VIP. Because
`rancherd.service` sets `TimeoutStartSec=0`, the unit never fails — it sits in
`activating` indefinitely with no rke2 units ever created, which looks like a
hang rather than an error.

On AWS the two are easy to tell apart: a VIP is a **secondary** private address
on the ENI, a node's own address is the **primary**. Phase 3 checks this before
launching and refuses an address that is primary. To find the VIP by hand:

```bash
aws ec2 describe-network-interfaces \
  --filters Name=attachment.instance-id,Values=i-xxxxxxxx \
  --query 'NetworkInterfaces[].PrivateIpAddresses[?!Primary].PrivateIpAddress'
```

Note that filtering on `addresses.private-ip-address` matches the primary too,
so it does **not** tell you whether an address is the VIP.

**The port must be 443 or 8443.** `harv-update-rke2-server-url` rewrites the URL
to the RKE2 supervisor port 9345, but only if it matches
`^https://(.*):(8443|443)`. Any other port is left untouched and the node never
joins, with nothing obvious in the logs. Phase 3 rejects it up front.

### Longhorn replicas do not follow the node count

**Joining a node changes no replica count, anywhere.** Nothing in Harvester
watches the node count and rebalances — the only thing that reads replica counts
is the upgrade validator, and it reads them to *complain* (below). Plan for this
before you build the cluster, because retrofitting is the awkward path.

`--replica-count` is create-only: it feeds the harvester chart values, and
`genBootstrapResources()` only runs for `mode: create`, so it is fixed by the
node that bootstrapped the cluster. Passing it with `--join` warns and is
ignored. It lands as the `numberOfReplicas` **parameter** on two StorageClasses,
`harvester-longhorn` and `vmstate-persistence`
(`deploy/charts/harvester/templates/harvester-storageclass.yaml`), and Longhorn
copies that into each Volume at provision time.

So there are two separate things to change, and neither happens on its own:

**New volumes** take their count from the StorageClass. StorageClass
`parameters` are **immutable** in Kubernetes, so this cannot be edited in place
— the StorageClass has to be deleted and recreated. `harvester-longhorn` is
chart-managed (`harvesterhci.io/is-reserved-storageclass: "true"`), so raise the
ManagedChart value and let Fleet recreate it:

```bash
kubectl -n fleet-local edit managedchart harvester
#   spec.values.storageClass.replicaCount: 3
```

Deleting a StorageClass does not disturb existing PVs or PVCs — a bound PV
already carries its own parameters and does not consult the class again.

**Existing volumes** keep whatever count they were created with. Longhorn will
rebuild onto the new node once you raise it per volume:

```bash
kubectl -n longhorn-system get volumes.longhorn.io
kubectl -n longhorn-system patch volumes.longhorn.io <vol> \
  --type=merge -p '{"spec":{"numberOfReplicas":3}}'

# watch it heal: degraded -> healthy
kubectl -n longhorn-system get volumes.longhorn.io <vol> \
  -o jsonpath='{.status.robustness}{"\n"}'
```

**The trap:** once the cluster has more than one node, any single-replica volume
**blocks upgrades**. `checkAllSingleReplicaVols()` in
`pkg/webhook/resources/upgrade/validator.go` rejects the Upgrade resource with:

> Following PVCs with single-replica volume, even the volume is detached,
> upgrade may have potential data integrity concerns: …

and it explicitly *skips the check when `len(nodes) == 1`*. So a single-node
cluster at `replica_count: 1` is fine and upgrades cleanly — and the moment you
join a second node, every volume you created before then starts blocking
upgrades until you patch it.

**The easy path:** if you intend a three-node cluster, bootstrap node 1 with
`--replica-count 3` from the start. Volumes created while only one node exists
sit at `Degraded` — Longhorn will not put two replicas of the same volume on one
node — but they attach and run normally, and heal on their own as nodes 2 and 3
join. That is much less work than retrofitting both the StorageClass and every
existing volume afterwards.

### MTU: set it explicitly

**Leave `--mtu` unset and a multi-node cluster will not form.** This one cost
real debugging time, so it is worth stating plainly.

harvester-installer only writes an `mtu=` line into the bridge and bond
NetworkManager connections when the value is explicitly set
(`pkg/config/templates/nm-bridge.nmconnection`):

```
[ethernet]
{{ if gt .Bridge.MTU 0 -}}
mtu={{ .Bridge.MTU }}
{{- end }}
```

With nothing set, an EC2 node comes up like this:

```
eth0:    mtu 1500
mgmt-bo: mtu 1500
mgmt-br: mtu 9001     <-- ENA's native MTU, on a 1500 bond
```

The bridge keeps ENA's 9001 while the bond and NIC underneath it sit at 1500.
Sockets route via `mgmt-br`, so TCP derives an **8961 MSS** from the bridge and
happily emits segments the bond then drops.

The failure is nasty because it is size-dependent:

| | |
|---|---|
| TCP handshake (0-length) | works |
| `nc -z`, `ping` | works |
| TLS ClientHello (~1.6 KB) | **silently dropped** |

So `nc` reports the port open, the connection establishes, and then the first
real payload vanishes. On a joining node that surfaces as rke2-agent looping on:

```
Failed to validate connection to cluster at https://<vip>:9345:
  failed to get CA certs: Get "https://127.0.0.1:6444/cacerts":
  context deadline exceeded
```

`127.0.0.1:6444` is rke2's own client-side load balancer — it is timing out
because *its* upstream is black-holed, not because anything local is wrong.

Traffic to port 443 keeps working throughout, which is thoroughly misleading:
that terminates at the Rancher ingress **pod**, and the CNI installs an MSS
clamp (`TCPMSS --clamp-mss-to-pmtu`) for pod-bound traffic. Host services like
the RKE2 supervisor on 9345 get no such clamp.

None of this shows up on a single node, because nothing exercises host-to-host
TCP until a second node appears.

To confirm it on a running pair, look at the MSS in the SYN rather than at the
interfaces:

```bash
sudo tcpdump -ni any "tcp port 9345 and host <other-node>" -c 20
```

`options [mss 8961, ...]` on a path that fails `ping -M do -s 8972` is the
signature. Note that `ping -M do -s 1472` **succeeding** does not clear MTU as a
cause — the path carries 1500 fine; the problem is that TCP thinks it can send
9001.

Runtime fix on both nodes, which does not survive a reboot:

```bash
sudo ip link set mgmt-br mtu 1500
```

The durable fix is to set it at install time, and **what matters is that it is
set at all** — not which value. Phase 3 defaults to `--mtu 1500`, which puts
1500 on the bridge, the bond, and (by inheritance) the slave.

1500 is the default rather than 9000 because AWS caps anything leaving the VPC
— internet gateway, VPN, Direct Connect, inter-region peering — at 1500
regardless of what your instances negotiate. TCP normally survives that via MSS
negotiation (the remote end advertises ~1460 and the minimum wins), but UDP
above 1500 and anything relying on PMTUD does not, and for a VM on the overlay
that ICMP has to find its way back through GENEVE and `natOutgoing`. 1500
removes the question.

`--mtu 9000` is a reasonable opt-in if you want it. Everything stays inside the
VPC at 9001, and the clearest win is Longhorn replication between nodes, which
is bulk transfer that never leaves the VPC. Treat it as an optimisation to
adopt deliberately and measure, not a default. `--mtu 0` leaves it unset, which
is the broken case above; the script warns.

### The VIP does not fail over

This is the honest limitation of the current setup. kube-vip advertises the VIP
with gratuitous ARP, and **the VPC ignores ARP for address ownership** — an
address reaches an instance only because it is registered on that instance's
ENI. So if the node holding the VIP dies, kube-vip will happily elect a new
holder inside the cluster, and the VPC will keep routing the VIP to the dead
node's ENI.

In other words: clustering gives you Kubernetes-level and Longhorn-level
redundancy, but the management endpoint is still a single point of failure.

Failing over means moving the secondary private IP between ENIs via the EC2 API
(`unassign-private-ip-addresses` then `assign-private-ip-addresses`), which
needs something watching the cluster with IAM permissions — or putting a network
load balancer in front of the nodes' primary IPs on 443/6443 and treating *that*
as the management endpoint. The NLB is the cleaner answer and is a natural fit
for a CloudFormation template alongside the VPC, subnet and security group.

### machine-id and SSH host keys

Every node launched from the same AMI could in principle share
`/etc/machine-id`, since the AMI is a snapshot of an installed system rather
than a fresh install. **Verified that it does not** — two nodes from the same
AMI:

```
harvester-05f81047acf2addd0:  2aaabdc89bf05cc6418ec5496aaadb11
harvester-0d7cef94665fb5631:  0459a42072adeb5be69ff8cb6aab05c2
```

The elemental layer regenerates it per node on first boot. harvester-installer
never references machine-id at all, so nothing in the Harvester configuration
path depends on it either way. No scrubbing step is needed in phase 2.

Node identity is independent of this regardless: Kubernetes node names come from
the hostname, which phase 3 sets per instance (`harvester-<instance-id>`).

---

## VM networking on EC2

**Bridged VM networking cannot work on EC2.** This is a VPC constraint, not a
Harvester one, and no amount of Harvester configuration gets around it:

* The Nitro hypervisor validates the Ethernet header of every frame leaving an
  instance and drops anything whose **source MAC is not the ENI's**. A bridged
  VM has its own MAC, so its traffic never reaches the VPC.
* It also passes only ARP, IPv4 and IPv6 — **802.1Q-tagged frames are dropped**,
  so VLAN networks cannot traverse the VPC regardless of MAC.
* Disabling the source/destination check does **not** help. It relaxes only the
  check that the instance is the source or destination *IP*; the MAC check
  stays.

Two symptoms follow from this:

**"No NICs available" when creating a cluster network.** The node has one ENI,
so one NIC — `eth0` — and it is enslaved to `mgmt-bo`. The link monitor reports
each NIC's `MasterIndex` (`harvester-network-controller`,
`pkg/controller/agent/linkmonitor/controller.go`), and an already-enslaved NIC
is not offered as an uplink. Attaching a second ENI does make `eth1` appear in
the picker — but it will not make bridged traffic work, so it only moves the
failure later.

**`DHCP failed` when adding a VLAN to `mgmt`.** Harvester probes a new VM
network by attaching a job pod to it and running a DHCP client to auto-detect
the CIDR and gateway; on failure it records `Connectivity: DHCP failed`
(`pkg/helper/helper.go`, `pkg/utils/nad.go`). The probe leaves the node with the
pod's MAC, so the VPC drops it and no offer comes back. Untagged (VLAN 1) fails
the same way — the MAC check alone is enough.

This applies to **bare metal instances too**. The enforcement lives in the Nitro
Card for VPC, which is the network dataplane for every Nitro instance; bare
metal gives you direct access to the CPU and memory, not to that card. (AWS
publishes no explicit metal-vs-virtual comparison for this specific check, so
that is an architectural inference, not a quoted guarantee — but bare metal is
moot for Harvester on AWS today anyway, since the x86_64 `.metal` types are
legacy BIOS and Harvester requires UEFI.)

One thing that *does* work regardless: traffic between VMs **on the same node**
over a bridge never reaches the ENI, so it is not subject to any of this. It is
only traffic leaving the instance that gets dropped.

### What does work

**Management Network (masquerade)** — the default, and the zero-setup option.
Harvester's stock VM template uses `masquerade: {}` on the pod network
(`pkg/data/template.go`), and KubeVirt NATs the VM's traffic through the pod's
network namespace, so it egresses with the node's MAC and IP. Pick *Management
Network* rather than a VM Network when adding a VM's NIC.

Note this is **not** the `mgmt` ClusterNetwork — the names collide but they are
different things. The VM sees a private address (KubeVirt's masquerade CIDR,
`10.0.2.2/24` by default) that is identical in every VM, NAT'd to the pod IP.
Outbound works; inbound needs a Service or the Harvester load balancer; VMs
cannot address each other by guest IP.

**kube-ovn overlay** — a real L3 network for VMs, and the working answer on
EC2. GENEVE encapsulates VM traffic between node IPs, so the VPC only ever sees
the node's own MAC and IP. This is confirmed working: VMs get a DHCP lease and
DNS, reach the internet and the rest of the VPC, and are reachable from the VPC.

The full sequence:

**1. Make sure the MTU is set** — phase 3 defaults to `--mtu 1500`, which is
all the overlay needs. See [MTU](#mtu-set-it-explicitly); leaving it unset
breaks node-to-node traffic on a cluster.

For the *overlay specifically*, jumbo frames are only an optimisation. kube-ovn
computes the guest MTU itself and hands it over DHCP — `mtu` is in
`necessaryV4DHCPOptions` (`pkg/ovs/ovn-nb-dhcp_options.go`) — so a DHCP guest on
a 1500 underlay comes up at ~1450 and never fragments. A guest configured
**statically** is the exception: it takes 1500, ignores the advertised value,
and black-holes large packets.

**2. Enable the `kubeovn-operator` addon** (*Advanced > Add-ons*). Marked
experimental. It installs Kube-OVN as a **secondary** CNI alongside canal.

**3. Check the CIDRs do not overlap.** The addon defaults (pod `10.54.0.0/16`,
service `10.55.0.0/16`, join `100.64.0.0/16`) already avoid the cluster's own
`10.52.0.0/16` / `10.53.0.0/16` and a default VPC's `172.31.0.0/16`, so the
stock values are safe as-is.

**4. Create an overlay VM Network** (*Networks > VM Networks*, type *Overlay*).
Note its name and namespace — say `vm-overlay` in `default`.

**5. Create the Subnet** that backs it. The link is one-to-one: the subnet's
`provider` must be `<nad-name>.<nad-namespace>.ovn`
(`harvester-network-controller`, `pkg/utils/nad.go`), and the UI only offers
overlay networks not already claimed by a subnet.

```yaml
apiVersion: kubeovn.io/v1
kind: Subnet
metadata:
  name: vm-overlay
spec:
  protocol: IPv4
  cidrBlock: 10.60.0.0/24
  gateway: 10.60.0.1
  excludeIps:
    - 10.60.0.1
  provider: vm-overlay.default.ovn     # <nad>.<namespace>.ovn
  vpc: ovn-cluster
  natOutgoing: true                    # SNAT to the node IP on the way out
  enableDHCP: true
  dhcpV4Options: "dns_server=172.31.0.2"
```

**`dhcpV4Options` is not optional.** With `enableDHCP: true` and nothing else,
the guest gets an address and a gateway but `/etc/resolv.conf` comes back
**empty** — kube-ovn's generated DHCP option set (`pkg/ovs/util.go`) includes
`lease_time`, `router`, `server_id` and `mtu`, and simply has no `dns_server`.
Nothing logs an error; DNS just does not work.

The value is the VPC's own resolver: **the base of the VPC CIDR, plus two**
(`172.31.0.0/16` → `172.31.0.2`). That is the right choice over a public
resolver — it also resolves private hosted zones and EC2 internal names.

Setting `dhcpV4Options` at all does **not** cost you the other options.
`buildDHCPv4Options()` fills in anything missing from `necessaryV4DHCPOptions`
(`lease_time`, `router`, `server_id`, `server_mac`, `mtu`), so a single
`dns_server=...` is enough.

Mind the separators — they are not what you would guess:

```yaml
  # several options: comma-separated, no enclosing braces
  dhcpV4Options: "dns_server=172.31.0.2,lease_time=7200"

  # one option with several values: braces, comma or semicolon inside
  dhcpV4Options: "dns_server={172.31.0.2,8.8.8.8}"
```

Wrapping the whole list in braces (`"{dns_server=...,lease_time=...}"`) is the
easy mistake: `splitDHCPOptions()` never splits inside braces, so the result is
one malformed option, `strings.Split(option, "=")` returns three parts,
`parseDHCPOptions()` drops it, and you are back to no DNS with nothing logged.

**6. Create a VM on that network.** Harvester's VM mutating webhook swaps the
NIC's binding to `managedtap`
(`harvester/pkg/webhook/resources/virtualmachine/mutator.go`) when the NAD is an
OVN one — you do not set that yourself. Confirm with:

```bash
kubectl get vmi <name> -o jsonpath='{.spec.domain.devices.interfaces}'
kubectl get vmi <name> -o jsonpath='{.metadata.annotations.ips\.kubeovn\.io}'
```

At this point the VM has an address, DNS, and outbound reachability to both the
internet and the VPC.

**7. To reach VMs *from* the VPC**, the overlay CIDR has to be routed back. Add
a route to the VPC route table pointing the subnet at the node's ENI, and turn
off that instance's source/destination check so it is allowed to forward for
addresses that are not its own:

```bash
aws ec2 create-route --route-table-id rtb-xxxxxxxx \
  --destination-cidr-block 10.60.0.0/24 --network-interface-id eni-xxxxxxxx

aws ec2 modify-instance-attribute --instance-id i-xxxxxxxx --no-source-dest-check
```

This works — but note it pins the overlay to one node's ENI, so it does not
survive that node being replaced, and it does not load-balance across a cluster.

If traffic still does not flow after this, check the **security group** before
anything else. The node's SG governs the encapsulated packets, and a VM talking
to something else in the VPC looks to the SG like the *node* talking to it.

Two constraints worth knowing up front:

* **Stay on the default VPC (`ovn-cluster`).** Its subnets egress via
  `natOutgoing` at the subnet level, SNAT'd through the node — which is exactly
  what the VPC will accept. A **custom** VPC needs a VPC NAT Gateway, and that
  gateway attaches to an external subnet on an underlay/provider network with
  VLAN config, which lands back on the bridged-traffic problem and will not work
  on EC2.
* The overlay attaches to the `mgmt` cluster network
  (`pkg/utils/nad.go`: *"OVN is only attached to mgmt network for now"*), so it
  needs **no extra NIC** — a second ENI buys you nothing here, and was confirmed
  to be a dead end.

Docs: [Kube-OVN Operator (Experimental)](https://docs.harvesterhci.io/v1.8/advanced/addons/kubeovn-operator/),
[VPC](https://docs.harvesterhci.io/v1.8/networking/kubeovn-vpc/),
[VPC NAT Gateway](https://docs.harvesterhci.io/v1.8/networking/kubeovn-vpcnatgateway/).

Sources: [Setting up Layer 2 Networking on Amazon EC2](https://aws.amazon.com/blogs/networking-and-content-delivery/setting-up-layer-2-networking-on-amazon-ec2/),
[Limit (filter) traffic by MAC address](https://repost.aws/questions/QU3QRvQ45jTxiF6Hw1asP-KQ/limit-filter-traffic-by-mac-address).

---

## Watching a bootstrap

Expect 15–25 minutes. Everything logs to the serial console.

```bash
./follow-console.sh --instance-id i-xxxxxxxx --tee console.txt
```

`get-console-output` is a snapshot API, not a stream — each call returns the
most recent ~64 KB of the buffer. `follow-console.sh` polls it and prints only
what is new, so it reads like `tail -f`. It strips the installer TUI's ANSI
redraws by default (`--raw` keeps them), stops on `--until REGEX`, and exits
when the instance stops. For a one-shot dump instead:

```bash
aws ec2 get-console-output --instance-id i-xxxxxxxx --latest --query Output --output text > console.txt
```

For a genuinely live stream, attach to the serial console:

```bash
aws ec2-instance-connect send-serial-console-ssh-public-key \
  --instance-id i-xxxxxxxx --serial-port 0 \
  --ssh-public-key file://~/.ssh/id_ed25519.pub
ssh i-xxxxxxxx.port0@serial-console.ec2-instance-connect.<region>.aws | tee console.txt
```

Lower latency, but it is an interactive TTY: one session per instance, and
since phase 2 puts the console on ttyS0 only, it is the same terminal the
Harvester installer and dashboard draw on — anything you type goes to them.

Once SSH is up:

```bash
sudo journalctl -u harvester-aws-config     # user-data -> /oem/userdata.yaml
sudo cat /var/log/harvester-aws-config.log
sudo cat /var/log/console.log               # harvester-installer
sudo journalctl -fu rancherd                # cluster bootstrap

sudo cat /oem/userdata.yaml                 # what the installer was given
sudo cat /etc/rancher/rancherd/config.yaml  # exists once configured
ls /var/lib/rancher/rancherd/bootstrap/

export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin
kubectl get managedchart -n fleet-local
kubectl get pods -A
```

Then `https://<vip>`, `admin` / `admin`.

### If it stops at the installer TUI

That means `/oem/userdata.yaml` was missing or rejected. Check
`journalctl -u harvester-aws-config` — the usual causes are no user-data on the
instance, user-data that isn't a YAML mapping, or `install.mode: create` with no
`install.vip`.

### Customizing the node configuration

EC2 user-data is a
[Harvester configuration file](https://docs.harvesterhci.io/latest/install/harvester-configuration/).
`configure.sh` merges it over a set of runtime-derived defaults (hostname from
the instance id, install device resolved from the disk carrying `COS_STATE`,
SSH key from the launch keypair, `eth0`/DHCP management interface), your values
winning, then forces `install.automatic: true` and `scheme_version: 1`.

Anything the config file supports works — `install.role`, `system_settings`,
`os.ntp_servers`, `install.addons`, joining an existing cluster with
`install.mode: join` plus `server_url`. Pass a whole file with
`--user-data-file`.

---

## Disk layout, and how much space VMs actually get

Harvester uses the elemental/cOS immutable layout. Six partitions, and only one
of them holds VM disks:

| Partition | Size on a 250 GiB image | Mounted at | Holds |
|---|---|---|---|
| `COS_GRUB` | 64 MiB | ESP | bootloader |
| `COS_OEM` | 50 MiB | `/oem` | `harvester.config`, `99_custom.yaml`, `grubenv`, this repo's `aws/` glue |
| `COS_RECOVERY` | 8 GiB | — | recovery system image |
| `COS_STATE` | 15 GiB | — | `cOS/active.img` + `cOS/passive.img`, the A/B OS image pair, and `grub2/grub.cfg` |
| `COS_PERSISTENT` | **150 GiB** | `/usr/local` | **node** state |
| `HARV_LH_DEFAULT` | **the remainder (~77 GiB)** | `/var/lib/harvester/defaultdisk` | **Longhorn — this is where VM disks live** |

`COS_PERSISTENT` is *not* VM storage. It backs the `PERSISTENT_STATE_PATHS`
bind mounts — `/var/lib/rancher` (RKE2 plus the whole containerd image store,
which Harvester preloads heavily), `/var/lib/kubelet`, `/var/lib/longhorn`
(Longhorn's own binaries and engine images, not volume data), `/var/log`,
`/etc/rancher`, `/etc/NetworkManager`, `/home`, `/root` and so on.

150 GiB is Harvester's default and its enforced minimum
(`util.MinPersistentSize`); the installer picks `max(30% of disk, 150 GiB)`. On
a 250 GiB disk — also the enforced minimum, `util.MinDiskSize` — that leaves
only about 77 GiB for VMs. Enabling the `rancher-monitoring` addon alone claims
57 GiB of it (Prometheus 50, Alertmanager 5, Grafana 2).

### Sizing: leave the defaults, grow at deploy time

`HARV_LH_DEFAULT` is the **last** partition, so it is the only one that can be
grown in place. `aws/configure.sh` grows it to fill the volume on first boot,
before the installer runs — automatically, with no configuration:

```bash
./01-build-instance.sh                     # 250 GiB image, 150 GiB COS_PERSISTENT

./03-launch-instance.sh --ami … --volume-size 500    # Longhorn gets ~427 GiB
./03-launch-instance.sh --ami … --volume-size 250    # Longhorn gets ~77 GiB
```

This costs nothing on the launch side. The AMI's floor ends up at 250 GiB, which
is Harvester's own floor anyway (`config.SingleDiskMinSizeGiB`), so a
default-sized build never restricts what you can launch on.

`--data-disk-size 200Gi` exists to *cap* the data partition rather than fill the
volume. Growing is the default; you only reach for the flag to leave room for
something else.

**Leave `PERSISTENT_SIZE` at 150 GiB unless you are throwing the cluster away.**
It is not padding:
[harvester#3842](https://github.com/harvester/harvester/issues/3842) raised the
cap from 100 GB precisely because that was "too tight for increasing local
images (especially upgrade path)" — `/var/lib/rancher`'s container image store,
`/var/lib/kubelet`, `/etc/rancher`, logs and third-party services all share it,
and running it close to full triggers premature garbage collection.

Measured on a freshly bootstrapped v1.8.2 node, the preloaded image store alone
is **~34 GiB**:

```
$ df -h /usr/local
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p5   49G   34G   13G  73% /usr/local
```

At the default 150 GiB that is ~23% used, with room for an upgrade to stage a
second set of images before discarding the first. At 50 GiB it is 73% used with
13 GiB spare — fine for a node you intend to throw away, not for one you intend
to upgrade.

For short-lived test builds where you want the image to move faster, trimming is
reasonable — just know what you are giving up:

```bash
DISK_SIZE_GIB=130 PERSISTENT_SIZE=50Gi ./01-build-instance.sh --force
```

Two things bound how small you can go:

* **Build size floors at `PERSISTENT_SIZE + ~73 GiB`.** `util.fixedOccupiedSize`
  is `(50 + 15360 + 8192 + 64 + 51200) MiB` — the fixed partitions plus a hard
  50 GiB reservation for the data partition. Ask for more persistent space than
  `DISK_SIZE_GIB` minus that and `ParsePartitionSize()` **silently clamps it**,
  because phase 1 passes `skipchecks=true`. At `PERSISTENT_SIZE=50Gi` the floor
  is ~124 GiB. Verify afterwards with `sfdisk -l` on the raw image rather than
  trusting it.
* **The volume must still be ≥ 250 GiB**, however small the AMI.
  `checkDevice()` → `validateDiskSize()` takes no skip-checks argument and
  `Validate()` calls `diskChecks()` unconditionally. Phase 3 refuses a smaller
  `--volume-size` rather than letting you discover it at boot.

### The bigger lever: do not write zeroes

Most of the image is zeroes, and writing them to EBS is what actually costs you
time — twice over. `01b-write-image.sh` passes `conv=sparse` to `dd` by default,
so those blocks are seeked over rather than written. The write finishes far
faster, and because an EBS snapshot only stores blocks that were *written*, the
snapshot stays small and quick too. Writing 250 GiB of zeroes makes all of them
"written" and bloats every snapshot taken from that volume.

This is safe on a freshly created volume, which reads as zeroes. Re-using a
volume that already holds an image is not — skipped blocks keep their old
contents. The script warns if the target already has a partition table, and
`--no-sparse` turns it off.

## Notes and gotchas

**Never change `mode: install` in `/oem/harvester.config`.** It is what makes
the installer treat the disk as already-installed and read
`/oem/userdata.yaml`. Phase 2 refuses to run on an image that lacks it.

**`mergo.Merge` only fills empty fields.** `/oem/harvester.config` is merged
*under* `/oem/userdata.yaml`, so anything already set at build time wins —
which is why `install.device` has to be patched on disk (`configure.sh` does
it) rather than overridden from user-data. `os.hostname` and `os.password` are
the exceptions; `mergeCloudInit()` assigns those explicitly.

**`/oem/harvester.config` key names are not the documented ones.** It is
`yaml.v3`-marshalled Go structs with no yaml tags, so keys are the lowercased
field names — `vipmode`, `replicacount`, `schemeversion`. The documented
snake_case spelling applies to `userdata.yaml`, which is parsed through the
installer's fuzzy-name schema mapper.

**`/oem/userdata.yaml` contains the cluster token** and possibly a password
hash. It is written `0600` and left in place, matching what `stream-disk` does.

**An OS upgrade replaces `active.img`**, reverting the `bootargs.cfg` console
and `net.ifnames` patches. The `grubcustom` copy is the fallback; after an
upgrade the console ordering degrades to "everything on serial, TUI on tty1".

**Longhorn replica count** defaults to 1 here because this is a single node.
Pass `--replica-count` for multi-node.

**The bond needs `fail_over_mac=active`, or there is no network at all.**
`UpdateManagementInterfaceConfig` always builds `mgmt-bo` under `mgmt-br`, and
in active-backup mode the bonding driver rewrites each slave's MAC to the
bond's. ENA refuses, and the enslavement aborts rather than warns
(`bond_main.c`, `bond_enslave`):

```c
if (!bond->params.fail_over_mac ||
    BOND_MODE(bond) != BOND_MODE_ACTIVEBACKUP) {
        res = dev_set_mac_address(slave_dev, ...);
        if (res) {
                slave_err(bond_dev, slave_dev, "Error %d calling set_mac_address\n", res);
                goto err_restore_mtu;          /* enslavement ABORTS */
        }
}
```

The symptom is `mgmt-bo: (slave eth0): Error -95 calling set_mac_address`
(`-95` = `EOPNOTSUPP`) repeating as NetworkManager retries, `mgmt-bo` with no
slaves, and no DHCP. `fail_over_mac=active` makes the kernel skip that call and
take the bond's MAC *from* the active slave instead — the ENI MAC, which is the
only source MAC the VPC will accept anyway. All three bond options must be
given together, because `updateBond()` supplies its `mode`/`miimon` defaults
only when `bond_options` is absent entirely. Note the kernel honours
`fail_over_mac` only in active-backup mode, so no other bond mode works on EC2.

**The management interface becomes a bridge over a bond.**
`configureInstalledNode()` wipes the NetworkManager profiles and creates
`mgmt-bo` (a one-slave bond over `eth0`) plus `mgmt-br`, then runs `nmcli
networking off; nmcli networking on`. The node drops off the network for a few
seconds during that — expected, and it happens before SSH is reachable anyway.
The bridge inherits `eth0`'s MAC, so DHCP returns the same primary private IP.

**Source/destination checking.** Traffic from the node uses `eth0`'s MAC and
either the primary IP or the VIP, both registered on the ENI, so the default
src/dst check is fine for the cluster itself. It is *not* fine once guest VMs
get addresses the ENI doesn't know about — if you go on to use Harvester VLAN
networking you will need `modify-instance-attribute --no-source-dest-check`
plus routes, which this repo does not set up.

**Jumbo frames.** ENA defaults to MTU 9001, but `checkMTU()` caps
`install.management_interface.mtu` at 9000, so you cannot match it exactly.
Leaving it unset gives a 1500 MTU bond and bridge, which works fine.

---

## What changed from the original attempt

The previous version got the hard part right — building with `mode=install` and
patching the ESP and GRUB — but nothing ever configured the node:

* **Nothing produced `/oem/userdata.yaml`**, so the installer had nothing to act
  on and sat at the TUI. This was the whole reason bootstrap never started.
* `harvester-post-bootstrap.sh` tried to `helm install harvester` directly,
  which skips the Fleet `ManagedChart` machinery and every prerequisite in
  `rancherd-10-harvester.yaml` — it could start but never finish. It was also
  never actually executed; `99_aws.yaml` copied it and printed "Bootstrap
  triggered successfully" without running it.
* **There was no network on first boot.** The image ships `no-auto-default=*`
  and a `mode=install` image has no connection profiles, so `nmcli device
  connect eth0` had nothing to activate and IMDS was unreachable.
* `02-customize-instance.sh` referenced an undefined `$HVST_CFG` under `set -u`,
  so it aborted partway through step 5 — the `tty`, `silent`, `replicacount`
  and hostname edits and steps 6–7 never ran on any image.
* The `sed` patches targeted a schema that doesn't exist: `sans: []` is not a
  field of `Install`, and `s|mode: .*|mode: create|` also rewrites the
  `vipmode:` line, producing an invalid vip mode.
* `--cpu-options NestedVirtualization=enabled` was missing, so there would have
  been no `/dev/kvm` regardless.
* `OS_PASSWORD="rancher"` produced an unusable `/etc/shadow` entry.
* kube-vip was patched to `vip_interface=eth0`; the correct interface is
  `mgmt-br`, and the chart auto-detects it.

`01-build-instace-bios.sh` stays deleted — Harvester requires UEFI.
