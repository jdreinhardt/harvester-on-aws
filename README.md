# Harvester on AWS EC2

Builds an EC2 AMI from a stock Harvester ISO and boots it into a working,
self-bootstrapping Harvester cluster — one node, or three to five with an HA
control plane. Scripts for the image build and a CloudFormation template for
the deployment.

Current default targets Harvester **v1.9.0**.

For a high-level account of what this does and why — rather than how — see
[OVERVIEW.md](OVERVIEW.md).

---

## Quick start

```bash
make ami SUBNET_ID=subnet-xxxxxxxx KEY_NAME=my-key
```

That builds an AMI end to end — roughly two hours, most of it the install and
the snapshot — and publishes the id to SSM, where the CloudFormation template
picks it up. Then:

```bash
make teardown        # remove the helper instance, volume and security group
```

The Makefile only fills the gaps between the numbered scripts: AWS resource
lifecycle, SSH, and snapshot polling. The scripts remain the single source of
truth, and the phase-by-phase instructions below still work by hand.

Everything happens on the helper instance, **including the QEMU install**.
`01-build-instance.sh --device` writes straight to the attached EBS volume, so
there is no raw image file, no `zstd`, and no S3 round trip — phases 1 and 1.5
collapse into one step, and `01b-write-image.sh` is only needed if you are
moving a prebuilt image around.

Progress is stamped under `.make/`, so an interrupted run resumes instead of
repeating the install. That also means **`make ami` is a no-op after a
successful run** — `.make/ami-id` already exists. To build again:

```bash
make rebuild        # teardown + clear the stamps
make ami ...
```

`rebuild` prints the previous snapshot and AMI ids rather than deleting them, so
nothing is orphaned silently. `make clean` is the gentler version: it clears the
build stamps but keeps `snapshot-id` and `ami-id`.

**AMI names are unique per account per region.** `register-image` rejects a
duplicate rather than overwriting, and it does so at the *very end* of a
two-hour build. So `AMI_NAME` defaults to
`harvester-$(HARVESTER_VERSION)-$(BUILD_ID)` with a timestamp, and successive
builds never collide. If you pin `AMI_NAME` yourself, `make check` verifies it
is free before anything is created.

| | |
|---|---|
| Required | `SUBNET_ID`, `KEY_NAME` |
| Optional | `HARVESTER_VERSION`, `HELPER_OS`, `HELPER_TYPE`, `HELPER_ROOT_SIZE`, `VOLUME_SIZE`, `SSM_PARAMETER`, `SSH_CIDR`, `KEY_FILE`, `AMI_NAME`, `BUILD_ID` |

`HELPER_ROOT_SIZE` (default 60 GiB) is the helper's **own** disk, not the build
target. It has to hold the Harvester ISO plus the QEMU and OVMF packages, and
distro defaults are far too small — AL2023 ships an 8 GiB root, which the ISO
download fills and fails with `curl: (23) Failure writing output to destination`.

The root device name is read from the AMI rather than assumed, because it
differs by distro (`/dev/xvda` on AL2023, `/dev/sda1` on Ubuntu). A block device
mapping that does not match the AMI's root device does not resize the root — it
silently attaches an **extra** volume and leaves the root at its default size.

`HELPER_OS` is `al2023` (default) or `ubuntu`. Only four things differ between
them and the Makefile switches all four — package names, the login user, and the
two OVMF paths, which `01-build-instance.sh` takes as environment variables:

| | al2023 | ubuntu |
|---|---|---|
| Packages | `qemu-system-x86 qemu-img edk2-ovmf` | `qemu-system-x86 qemu-utils ovmf` |
| Login user | `ec2-user` | `ubuntu` |
| OVMF | `/usr/share/OVMF/OVMF_CODE.fd` | `/usr/share/OVMF/OVMF_CODE_4M.fd` |

**Building a different Harvester version** is just the version variable:

```bash
make ami SUBNET_ID=subnet-xxxxxxxx KEY_NAME=my-key \
  HARVESTER_VERSION=v1.8.2 SSM_PARAMETER=/harvester/ami/v1.8.2
```

Pass `SSM_PARAMETER` as well when you are testing. Left at its default the build
repoints `/harvester/ami/latest`, which is what the CloudFormation template
reads — so the next stack deploy would silently pick up the new, untested image.

The version only selects download URLs and file names. Nothing else is pinned to
a release, but a new one is genuinely untested, and the first things that would
surface a change are the partition count check at the end of phase 1 (it expects
six) and the configuration schema (`scheme_version: 1`).

The helper defaults to `m8i.4xlarge` because it needs **nested virtualization**
for the same reason the Harvester nodes do — the install imports several GB of
container images through a real RKE2 server, and software emulation turns an
hour into days. The Makefile launches it with
`--cpu-options NestedVirtualization=enabled`, which is **launch-time only**: a
supported instance type still has no `/dev/kvm` without it, and it cannot be
turned on afterwards. If a helper somehow comes up without it, `make teardown`
and relaunch — there is no way to fix it in place. `SSH_CIDR` defaults to this machine's public address rather than
opening SSH to the world.

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

## What has been tested

This is a proof of concept. This table shows what has and has not been tested. Anything
not listed may work, but known state is unclear.

**Harvester versions**

| | Image build | Bootstrap | Clustering | VM networking | Notes |
|---|---|---|---|---|---|
| **v1.9.0** | yes | yes | 3 nodes | yes | The default. Validated end to end, via both CloudFormation and Terraform. |
| **v1.8.2** | yes | yes | 3 nodes | yes | Works, but `natOutgoing` is not exposed in the UI — see [natOutgoing](#natoutgoing--check-it-is-set). |

Nothing in the tooling is version-aware, so a newer release will most likely
build. The two checks that would catch a breaking change are the partition count
at the end of phase 1 (it expects six) and the configuration schema
(`scheme_version: 1`).

**Deployment paths**

| | Tested against | Notes |
|---|---|---|
| `make ami` | v1.8.2, v1.9.0 | Built the current published AMI. |
| Manual scripts (`01`/`02`/`03`) | v1.8.2, v1.9.0 | The original path; the Makefile wraps it. |
| CloudFormation | v1.8.2, v1.9.0 | Deployed, 3 nodes. On v1.9.0 with `ControlPlaneViaNlb`, `tls-san` verified on all three nodes' certificates. |
| Terraform | v1.9.0 | Deployed, 3 nodes, with the NLB. |

**Configurations**

| | Tested | Untested |
|---|---|---|
| Node count | 3 | 1 and 5 are implemented and allowed, but never deployed |
| Instance type | `m8i.4xlarge` | Every other allowed value. They are filtered on nested virtualization support, not verified |
| Node role | `default` (1-3) | `worker` (nodes 4-5 at `node_count = 5`), `witness` — the script warns on the latter |
| Availability zone | single | Multi-AZ is not implemented |
| Region | `us-east-2` | Nothing is region-specific except the AMI, which is per-region by construction |

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
harvester-v<version>-amd64.iso
harvester-v<version>-vmlinuz-amd64
harvester-v<version>-initrd-amd64
```

## Phase 1 — build the raw image

```bash
./scripts/01-build-instance.sh
```

Produces `artifacts/harvester-v<version>-amd64.raw{,.zst}` — 250 GiB by default,
UEFI, with
`mode: install` in `/oem/harvester.config`. The whole guest console is copied to
`artifacts/harvester-install-console.log`, and the script checks that log and
the resulting partition table before it compresses. It needs no root.

While QEMU runs, the terminal belongs to the guest. **Ctrl-C goes to the guest;
Ctrl-A then X aborts.** The script restores the terminal on exit either way.

`--device /dev/nvmeXn1` installs straight onto a block device instead of a raw
file — what `make ami` uses on the helper instance, and what makes phase 1.5
unnecessary. It needs root, refuses the machine's own root disk, and skips the
compression step. The rest of this section describes the file-based path.

`--force` rebuilds over an existing image. Without it the script refuses,
because a failed *script* is not the same as a failed *install* — if the guest
reached `Powering off.` the image is complete and only needs compressing:

```bash
zstd -T0 --force artifacts/harvester-v<version>-amd64.raw
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
aws s3 cp artifacts/harvester-v<version>-amd64.raw.zst s3://your-bucket/
```

Attach a volume of **exactly `DISK_SIZE_GIB`** to a helper instance (250 GiB
by default). Then:

```bash
sudo ./scripts/01b-write-image.sh --source s3://your-bucket/harvester-v<version>-amd64.raw.zst --device /dev/nvme1n1
```

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
>
> Smaller than the image is not an option either: the GPT backup header sits in
> the image's last sector and is non-zero, so `conv=sparse` writes rather than
> skips it, and `dd` fails with ENOSPC.

## Phase 2 — customize for AWS

```bash
sudo ./scripts/02-customize-instance.sh /dev/nvme1n1
```

| | |
|---|---|
| `COS_GRUB` | ESP renamed to `EFI/BOOT/BOOTX64.EFI` — the removable-media path AWS boots for a snapshot-registered AMI |
| `COS_STATE` | `active.img`/`passive.img` `bootargs.cfg` → `console=ttyS0,115200n8` only, and `net.ifnames=0`; same settings mirrored into `grubcustom` so they survive an OS upgrade |
| `COS_OEM` | `99_aws.yaml` + `aws/stage-initramfs.sh` + `aws/configure.sh` |
| `COS_OEM` | `harvester.config` — only `install.device` is patched; `mode: install` **must** stay |

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
        --description "harvester-v<version>" \
        --query SnapshotId --output text)

# Poll rather than `aws ec2 wait snapshot-completed`. Every EC2 waiter gives up
# after 40 attempts at 15s -- 10 minutes -- and a first snapshot of a 250 GiB
# volume routinely takes an hour, so the waiter exits non-zero while the
# snapshot is still pending.
until [ "$(aws ec2 describe-snapshots --snapshot-ids "$SNAP" \
          --query 'Snapshots[0].State' --output text)" = completed ]; do
  sleep 30
done

aws ec2 register-image \
  --name "harvester-v<version>" \
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
./scripts/03-launch-instance.sh \
  --ami ami-xxxxxxxx \
  --subnet subnet-xxxxxxxx \
  --sg sg-xxxxxxxx \
  --key-name aws-testing
```

This picks a free VIP from the subnet if you don't pass `--vip`, generates a
token, builds the Harvester configuration, launches with nested virtualization
enabled, and assigns the VIP as a secondary private IP on the instance's ENI.

`--mtu` defaults to 1500 and you should leave it there. What matters is that it
is set *at all* — an unset MTU produces a node that cannot talk to other nodes.
`--mtu 9000` is a deliberate opt-in, and `--mtu 0` reproduces the broken case.
See [MTU](#mtu-set-it-explicitly).

That is *create* mode, which bootstraps a new cluster. To add a node to an
existing one, use `--join` — see [Clustering](#clustering).

`--dry-run` prints the configuration and launch parameters without creating
anything, and makes no API calls beyond the read-only preflight.

The whole stack can also be deployed through a CloudFormation template found in this repository,
or the equivalent [Terraform module](terraform/README.md).

**`validate-template` is a weak check.** It does not run transforms, and it does
not check parameter defaults against their type. It will happily pass a template
with a missing resource reference or an SSM path in an `AWS::EC2::Image::Id`
default. Before trusting a change, create a change set and inspect the processed
template:

```bash
aws cloudformation create-change-set --stack-name probe --change-set-name probe \
  --change-set-type CREATE --template-body file://cloudformation.yaml \
  --capabilities CAPABILITY_AUTO_EXPAND --parameters ...
aws cloudformation get-template --stack-name probe --change-set-name probe \
  --template-stage Processed
aws cloudformation delete-stack --stack-name probe
```

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
| 80 | HTTP for redirect |
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
./scripts/03-launch-instance.sh \
  --ami ami-xxxxxxxx \
  --subnet subnet-xxxxxxxx \
  --sg sg-xxxxxxxx \
  --key-name aws-testing \
  --mtu 1500 \
  --join 172.31.15.253 \
  --token harvester-aws-xxxxxxxxxxxxxxxx \
  --name harvester-node-2
```

* `--mtu` must match whatever node 1 was launched with.
* `--join` takes the cluster VIP, not a node address.
* `--token` is the token node 1 printed.

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

If you intend a three-node cluster, bootstrap node 1 with
`--replica-count 3` from the start. Volumes created while only one node exists
sit at `Degraded` — Longhorn will not put two replicas of the same volume on one
node — but they attach and run normally, and heal on their own as nodes 2 and 3
join. That is much less work than retrofitting both the StorageClass and every
existing volume afterwards.

### MTU: set it explicitly

**Leave `--mtu` unset and a multi-node cluster will not form.** 

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

The failure is hard to notice because it is size-dependent:

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

`--mtu 9000` is opt-in if you want it. Everything stays inside the
VPC at 9001, and the clearest win is Longhorn replication between nodes, which
is bulk transfer that never leaves the VPC. Treat it as an optimisation to
adopt deliberately and measure, not a default. `--mtu 0` leaves it unset, which
is the broken case above; the script warns.

### The VIP does not fail over

This is a limitation of the current setup. kube-vip advertises the VIP
with gratuitous ARP, and **the VPC ignores ARP for address ownership** — an
address reaches an instance only because it is registered on that instance's
ENI. So if the node holding the VIP dies, kube-vip will happily elect a new
holder inside the cluster, and the VPC will keep routing the VIP to the dead
node's ENI.

In other words: clustering gives you Kubernetes-level and Longhorn-level
redundancy, but the management endpoint is still a single point of failure.

**There is a second, quieter problem: nothing keeps kube-vip and AWS in sync.**

Two independent facts make the VIP work today:

1. kube-vip elects a leader and binds the VIP on **that** node's `mgmt-br`.
2. AWS routes the VIP to node 1's ENI, because that is where CloudFormation
   registered it as a secondary private address at stack creation.

Nothing enforces that these agree. They line up because node 1 won the lease
first and keeps renewing it. If kube-vip ever re-elects while node 1 is still
healthy — a pod restart, a missed lease renewal — the VIP ends up bound on one
node and routed to another, and simply stops answering. No failure event, no
error, just an address that goes dark. Rebinding it is a kube-vip concern; the
route is an AWS one, and neither knows about the other.

The load balancer sidesteps this for external clients, which is the main reason
to treat it as the real management endpoint rather than a convenience. An
overlay VIP driven by an agent (below) would fix it properly, by making the AWS
side follow the election instead of being set once.

Failing over means moving the secondary private IP between ENIs via the EC2 API
(`unassign-private-ip-addresses` then `assign-private-ip-addresses`), which
needs something watching the cluster with IAM permissions — or putting a network
load balancer in front of the nodes and treating *that* as the management
endpoint.

The CloudFormation template takes the second approach; see
[Management endpoint](#management-endpoint). The VIP still does not move, but it
stops being the thing *you* connect to.

**It does not stop being the thing the cluster connects to.** A load balancer
cannot serve its own targets, so `server_url` still points at the VIP and a
joining node still resolves it to node 1's ENI. Losing that node leaves the
cluster running and the UI reachable, but no further nodes can join until the
address is moved by hand. The measurement behind that is in the same section.

---

## CloudFormation

`cloudformation.yaml` deploys 1, 3 or 5 nodes from an AMI you have already
built. It does not build the AMI — phases 0–2 still run by
hand, and the AMI id is a parameter.

```bash
aws cloudformation create-stack \
  --stack-name harvester \
  --template-body file://cloudformation.yaml \
  --parameters \
    ParameterKey=AmiSsmParameter,ParameterValue=/harvester/ami/latest \
    ParameterKey=VpcId,ParameterValue=vpc-xxxxxxxx \
    ParameterKey=SubnetId,ParameterValue=subnet-xxxxxxxx \
    ParameterKey=KeyName,ParameterValue=aws-testing \
    ParameterKey=VipAddress,ParameterValue=172.31.31.251 \
    ParameterKey=ClusterToken,ParameterValue="$(openssl rand -hex 16)" \
    ParameterKey=AdminCidrs,ParameterValue='203.0.113.4/32\,198.51.100.0/24' \
  --capabilities CAPABILITY_AUTO_EXPAND
```

`CAPABILITY_AUTO_EXPAND` is required — the template uses the
`AWS::LanguageExtensions` transform. No IAM capability is needed; the stack
creates no IAM resources.

Note the escaped comma in `AdminCidrs`: the CLI splits `ParameterValue` on
commas, so each comma *inside* the value must be `\,`.

`AmiSsmParameter` is the **name of an SSM parameter**, not an AMI id — it
defaults to `/harvester/ami/latest`, so deploying never involves pasting an AMI.
Publish it once at the end of phase 2.5:

```bash
aws ssm put-parameter --name /harvester/ami/latest \
  --type String --overwrite --value ami-xxxxxxxx
```

The parameter type is `AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>`, which
resolves the name to an AMI id at deploy time. It will **not** accept a literal
`ami-…` — that would be read as an SSM parameter name and fail the lookup. Use
`AmiIdOverride` for a one-off image.

Note that plain `AWS::EC2::Image::Id` with an SSM path as its default
**validates fine and then fails at stack creation** — `validate-template` does
not check defaults against their parameter type.

### Admin access is a prefix list

The stack owns a prefix list holding the admin CIDRs, and the security group
carries **four rules** — 22, 80, 443, 6443 — referencing it, regardless of how
many CIDRs there are. Adding or removing an admin range is a stack update to the
prefix list, not a change to the security group.

The CIDRs arrive as **one comma-separated parameter**, but the slots behind it
are fixed.

`Entries` is a variable-length array of objects. `Fn::ForEach` cannot build it —
it **merges keys into the parent object**, so iterating over CIDRs fails at
transform time with:

```
Transform AWS::LanguageExtensions failed with:
Duplicate key 'Cidr' when merging keys to parent object in Fn::ForEach
```

What does work is `Fn::Length` (also from `AWS::LanguageExtensions`) guarding
fixed slots. It resolves at transform time, so each slot is gated on "the list is
at least this long", and an unused slot is removed entirely by `AWS::NoValue`
rather than left blank — so the array shrinks to however many were supplied:

```yaml
MaxEntries:
  Fn::Length: !Ref AdminCidrs
Entries:
  - Cidr: !Select [0, !Ref AdminCidrs]
    Description: Admin CIDR 1
  - !If [HasCidr2, {Cidr: !Select [1, !Ref AdminCidrs], Description: Admin CIDR 2}, !Ref 'AWS::NoValue']
```

The guard is not optional: an out-of-range `Fn::Select` is a hard error, not an
empty value. Raising the cap past 5 means one more condition and one more entry.

Note the conditions are written in **long form** (`Fn::Not`, `Fn::Equals`).
Short-form tags cannot nest that deeply — `!Not [!Equals [!Length [...], 1]]` is
a YAML parse error.

**Mind `MaxEntries`.** It is what counts against the security group's rule quota
(60 by default), *not* the number of entries actually present — and it counts
once per referencing rule. That is why it is computed with `Fn::Length` instead
of hardcoded. The group carries four rules (22, 80, 443, 6443), so two CIDRs
cost 8 of the 60 — where a fixed `MaxEntries: 5` would cost 20 whether or not
the slots were used.

### Source/destination check

EC2 discards packets whose source or destination address is not the instance's
own. That is fine for VM traffic leaving the cluster, which `natOutgoing` SNATs
to the node address — but reaching VM addresses **from** the VPC requires the
node to forward for the overlay CIDR, which the check blocks. The packets simply
disappear; nothing logs anything.

The `DisableSourceDestCheck` parameter reads as **"disable the check"**, not as the
EC2 property of the same name — `true` disables it, `false` leaves EC2's normal
behaviour in place. It defaults to `true`, because that is what a cluster
running an overlay needs, and applies to node 1's ENI and to every other node's
instance. Set it to `false` if you are not routing an overlay CIDR to these
nodes.

This replaces the manual `modify-instance-attribute --no-source-dest-check` step
the script-based path needs.

### Parameter sections

The console renders each `ParameterGroup` as its own labelled section —
Image, Placement, Cluster shape, Addresses, Storage, Advanced. CloudFormation
has no real multi-page form, so that is as close as it gets.

### It must use a launch template

`AWS::EC2::Instance`'s `CpuOptions` does **not** expose `NestedVirtualization` —
only `AWS::EC2::LaunchTemplate`'s does. Confirm for yourself:

```bash
aws cloudformation describe-type --type RESOURCE \
  --type-name AWS::EC2::Instance --query Schema --output text | grep -c NestedVirtualization
```

Without it the nodes boot, fail `preflight.KVMHostCheck`, and KubeVirt has no
`/dev/kvm`. So the CPU options live in launch templates and the instances
reference them. There are three, differing only in user-data: `create` for node
1, `join` for nodes 2-3, and `worker` for nodes 4-5 (which add
`install.role=worker` so they are never promoted).

### No wait conditions

`DependsOn` is present on every joining node for a tidy event order, but nothing
relies on it. CloudFormation calls an instance `CREATE_COMPLETE` once it is
*running* — about 30 seconds, against the 15–25 minutes a bootstrap takes — so
`DependsOn` cannot express "wait for the cluster".

It does not need to. `rancherd.service` sets `TimeoutStartSec=0` and retries the
join indefinitely, and rke2-agent retries every ~22 seconds. A node that starts
before the cluster is up converges on its own. This was verified the hard way: a
joining node sat in that loop for about two hours across three separate failures
and completed as soon as each was fixed, with no restart.

That avoids `AWS::CloudFormation::WaitCondition`, which would otherwise have
meant signalling from inside the node — `cfn-signal` is a Python package that
will not install on the immutable SLE Micro base, leaving a raw `curl -X PUT` to
a presigned handle URL as the only option.

### Management endpoint

`ManagementNlb` puts a network load balancer in front of the nodes on 443, which
is what makes the management endpoint survive losing a node. Three values:

| | |
|---|---|
| `internet-facing` (default) | Load balancer plus an Elastic IP, so the address is fixed and reachable from outside the VPC |
| `internal` | Load balancer on a private address only |
| `none` | No load balancer; the VIP stays the only endpoint |

Every node runs the ingress, so any of them can serve the UI.

**A load balancer cannot serve the cluster's own nodes.** This is the hard
limit, and it was learned the expensive way.

A Network Load Balancer does not support hairpinning: **a registered target
cannot connect to the load balancer it belongs to.** Disabling client IP
preservation does *not* lift it — verified on a live cluster, where a joining
node timed out on `https://<nlb>/cacerts` both before and after, while the
identical request from outside the VPC returned instantly.

Two consequences, both baked into the templates:

* **`server_url` always points at the VIP**, never the load balancer. Joining
  nodes are targets, so they cannot reach it. Cluster expansion therefore still
  depends on node 1 being alive.
* **There is no 9345 listener.** The RKE2 supervisor's only clients are joining
  nodes, and those are targets — the listener would have no reachable consumer.

`ControlPlaneViaNlb` therefore does something narrower than its name suggests:
it adds a **6443** listener so the Kubernetes API is reachable **from outside
the VPC** on an address that survives losing a node. It changes nothing for the
nodes themselves.

The broader conclusion is worth stating plainly, because it rules out a whole
class of fix: a load balancer can give *external* clients an address that
outlives any single node, but it can never give that to the **cluster's own
members**. Anything cluster-internal — joins, the supervisor — needs an address
that genuinely moves. That makes
[`aws-vpc-move-ip`](#natoutgoing--check-it-is-set) the only mechanism that can
work for it, not one option among several.

**6443 still needs an AMI with the tls-san drop-in.** harvester-installer writes
the RKE2 config carrying `tls-san` only on the bootstrap node:

```go
if config.ServerURL == "" {
    stage.Files = append(... "/etc/rancher/rke2/config.yaml.d/90-harvester-server.yaml" ...)
}
```

Measured on a live cluster, the VIP reaches every node by some other,
special-cased route, but SANs set through `sans` reach only node 1. Seeing the
VIP everywhere is **not** evidence that extra SANs propagate. `configure.sh`
fixes it by writing the drop-in itself on every node, from `aws.tls_sans` in
user-data — with the VIP listed first, because an explicit `tls-san` replaces
whatever supplies it implicitly and omitting it silently drops the VIP from a
joined node's certificate.

Because the template cannot tell which AMI you are launching, 6443 is behind
`ControlPlaneViaNlb`, default `false`.

**Adding a node by hand.** Both templates emit ready-made join user-data —
`JoinUserData` in CloudFormation, `join_user_data` and `worker_user_data` in
Terraform — with the real VIP, TLS SANs, MTU and bond options already filled in.
The cluster token is a **placeholder**: CloudFormation outputs have no `NoEcho`
equivalent, so anything there is readable by anyone with `DescribeStacks`.
Whoever is adding a node already has the token.

The instance still needs the same AMI, nested virtualization enabled, IMDSv2,
the cluster's security group and subnet, and a root volume of at least
`VolumeSize`.

**Access control.** The prefix list is applied twice — once on the load
balancer's own security group and again on the nodes. Client IP preservation is
on by default for instance targets, so the nodes see the real client address and
`AdminCidrs` is still what actually gates access. Health checks come from the
load balancer's addresses rather than the client's, so they get their own rule
referencing the load balancer's security group.

With `internet-facing`, the UI is reachable from the internet by anyone inside
`AdminCidrs`. Putting `0.0.0.0/0` there would publish it.

**Health checks are HTTPS, not TCP connects.** Port 443 accepts connections well
before Rancher is serving, so a bare connect would mark a node healthy part-way
through its bootstrap. 443 probes `/ping` for a `200`.

With `ControlPlaneViaNlb=true`, 6443 probes `/readyz` for a **401**. Every
kube-apiserver endpoint — `/readyz`, `/livez`, `/healthz`, `/version` — requires
authentication and answers 401 unauthenticated, so a 401 proves it is serving.
Matching 200 would never pass, and a TCP connect would pass even on a wedged
apiserver still holding the port.

**Production direction: ALB for the UI, NLB for the API.**

If the API is ever put behind a load balancer it must be a network one, and it
needs the SAN problem above solved first. kubectl authenticates with
**client certificates**, and an application load balancer terminates TLS — which
ends the mTLS session at the load balancer and leaves the apiserver with no
client certificate to authenticate. TLS passthrough is a requirement there.

The UI has no such constraint, and an ALB buys real things for a production
deployment:

* An ACM certificate on a name you own, so the browser warning goes away and
  renewal is automatic — the one thing this setup cannot fix today.
* Authentication at the edge. An ALB can require OIDC or Cognito sign-in before
  traffic ever reaches Rancher, which is a stronger control than a CIDR list.
* Access logs and WAF, neither of which a network load balancer offers.
* Separate exposure for each endpoint — the UI reachable by a wider group, the
  API restricted to operators — instead of the single `AdminCidrs` list that
  currently gates both.

**One thing to fix at the same time.** `sans` currently carries the load
balancer's AWS-generated hostname, which is **not stable** — replace the load
balancer and the name changes, leaving a certificate SAN that no longer matches
and a `kubectl` that fails until node 1's RKE2 config is corrected. A Route 53
record in front of the endpoint, with *that* name in `sans`, survives load
balancer replacement and is worth doing before anything depends on it.

**What it does not fix:** all nodes are in one subnet, so this survives a node
failure, not an availability zone failure. Spreading nodes across AZs would need
the subnet list to become a parameter and would put Longhorn replication across
zones — a separate decision.

### What the template does not do

* **Build the AMI.** Phases 0–2, by hand.
* **Create the VPC or subnet.** Both are parameters. The template assumes a
  working subnet with outbound access.
* **Validate the AMI or instance type.** CloudFormation cannot query EC2 for
  boot mode or `nested-virtualization` support. Phase 3 does check both, so a
  `./scripts/03-launch-instance.sh --dry-run` against the same AMI and instance type is
  a worthwhile preflight before creating the stack.
* **Set up kube-ovn.** The addon, the NAD and the Subnet are in-cluster
  configuration applied after bootstrap — see
  [VM networking on EC2](#vm-networking-on-ec2).
* **Make the VIP itself fail over.** It stays a secondary address on node 1's
  ENI. The load balancer sidesteps this by becoming the endpoint instead — see
  [Management endpoint](#management-endpoint).

### Parameters worth thinking about

| | |
|---|---|
| `NodeCount` | 1, 3 or 5. Two is not useful — promotion needs three. At 5, nodes 4 and 5 launch with `install.role=worker` so the management trio is nodes 1–3 by construction, not whichever three the controller picks. |
| `InstanceType` | A dropdown restricted to nested-virtualization types that clear Harvester's 32 GiB floor. Regenerate it with `describe-instance-types --filters Name=processor-info.supported-features,Values=nested-virtualization`. |
| `ReplicaCount` | Fixed at bootstrap. Use 3 for a cluster; 1 only for `NodeCount=1`. |
| `Mtu` | Defaults to 1500. Do not remove it — see [MTU](#mtu-set-it-explicitly). |
| `VipAddress` | The only address you pick. Node 1's own private address is assigned by EC2 as normal — the ENI declares just the VIP as a secondary. `PrivateIpAddressSpecification` requires both `PrivateIpAddress` and `Primary` on each *entry*, but does not require a `Primary: true` entry to be present. |
| `AdminCidrs` | Comma-separated, **maximum 5**. Anything past the fifth is silently ignored. |
| `OverlayClientCidr` | Optional. Opens the nodes to this source on **all** protocols, which is what routing traffic into overlay VMs requires. Empty unless you have added the VPC route. |
| `AmiIdOverride` | Optional literal `ami-…`, bypassing the SSM lookup for a one-off image. |
| `ManagementNlb` | `internet-facing` (default), `internal` or `none`. Balances 443 across the management nodes so the endpoint survives losing a node; `internet-facing` also allocates an Elastic IP. |
| `ControlPlaneViaNlb` | Adds 6443 and 9345 to the load balancer and points joining nodes at it. Default `false`; needs an AMI whose `configure.sh` writes the tls-san drop-in. |
| `DisableSourceDestCheck` | Reads as *disable the check*: `true` (the default) disables it, `false` leaves EC2's normal behaviour alone. Disabling is required to reach VM addresses from the VPC over a kube-ovn overlay; see below. |

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

The same manifest, with the MTU from 5b already set and each field annotated, is
in [`examples/ovn-subnet.yml`](examples/ovn-subnet.yml) — edit `provider` and
`dhcpV4Options`, then apply it.

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

**5b. Set the subnet MTU explicitly.** kube-ovn derives the guest MTU from the
**node interface MTU at daemon start**, minus the tunnel overhead
(`pkg/daemon/config.go`):

```go
mtu = iface.MTU
...
config.MTU = mtu - util.GeneveHeaderLength   // GeneveHeaderLength = 100
```

That is a snapshot. If the kube-ovn daemon started while `mgmt-br` was still at
ENA's 9001 — which is what happens when the node MTU was never set, see
[MTU](#mtu-set-it-explicitly) — guests are handed **8901** over DHCP and then
black-hole anything large on a path that only carries 1500. Fixing the node MTU
afterwards does **not** recompute it.

When this is wrong, the failure is **size-dependent**: small requests succeed
and large transfers stall. That is the signature to look for. A failure that
hits every packet size equally is *not* this — see
[natOutgoing](#natoutgoing--check-it-is-set), which presents as a total
loss of off-node connectivity regardless of size.

Pin it on the Subnet, which overrides the computed value
(`pkg/controller/subnet.go`: `if subnet.Spec.Mtu > 0 { mtu = int(subnet.Spec.Mtu) }`)
and flows into the DHCP options:

```yaml
spec:
  mtu: 1400          # node MTU 1500 - 100 GENEVE overhead
```

Check what a guest actually got, from inside the VM:

```bash
ip link show            # look for the overlay NIC's mtu
ping -M do -s 1372 1.1.1.1    # 1400-byte frame: should work
ping -M do -s 8873 1.1.1.1    # 8901-byte frame: should fail
```

and from the cluster:

```bash
kubectl get subnet <name> -o jsonpath='{.spec.mtu}{"\n"}'
```

Guests need a new lease to pick up a changed value — reboot the VM, or renew
its DHCP lease.

### natOutgoing — check it is set

**v1.9.0 exposes `natOutgoing` in the UI. Earlier releases do not.**

On v1.8.2 the overlay network flow neither sets it nor offers it, so a Subnet
created through the UI comes up with NAT disabled and VMs cannot reach anything
off the node. On v1.9.0 you can set it at creation; on anything older, create
the Subnet with `kubectl` instead.

Either way it is worth checking, because the failure is quiet and the symptom
is misleading:

```
NAME          PROVIDER                      CIDR            PRIVATE   NAT
ovn-default   ovn                           10.54.0.0/16    false     true
vm-overlay    overlay-network.default.ovn   10.60.0.0/24    false     false   <-- broken
```

The symptom pattern is distinctive, and worth learning because it looks like an
MTU problem until you test more than one packet size:

| From the VM to | Result |
|---|---|
| another node's IP | **works** |
| the VPC resolver (`x.x.0.2`) | times out |
| anything on the internet, **any packet size** | times out |
| — and the same URLs work fine from an SSH session on the node | |

A VM packet to another node is GENEVE-encapsulated, so what reaches the wire
carries the *node's* address as the outer source and AWS is happy. A packet to
the internet or to the VPC resolver is not an overlay destination, so it egresses
`eth0` as an ordinary IP packet — and without SNAT it leaves with a `10.60.0.x`
source, which Nitro drops because that address is not registered on the ENI. It
is the same source-address enforcement that makes bridged networking impossible.

The tell that separates this from an MTU black hole is that it is **completely
size-independent**: a 500-byte ping fails exactly like a 1400-byte one.

```bash
kubectl get subnet -o wide                    # check the NAT column
kubectl patch subnet vm-overlay --type=merge -p '{"spec":{"natOutgoing":true}}'
```

The patch takes effect immediately — it is a router NAT rule, not something the
guest holds, so no reboot and no new DHCP lease. Make sure your Subnet manifest
carries `natOutgoing: true` as well, or re-applying it will quietly undo the fix.

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

**That route is a single point of failure, and it is not the VIP.** A VPC route
targets an ENI, an instance or a gateway — never a bare IP address — so it
cannot point at the VIP even if you wanted it to. It names one node's interface.

Two consequences, one better than the VIP's situation and one the same:

* **Any node will do.** GENEVE meshes every node, so whichever node the route
  names can forward to a VM running anywhere in the cluster. It does not have to
  be the node holding the VIP, and nothing keeps the two together.
* **If that node dies, inbound traffic to the overlay black-holes.** Outbound is
  unaffected — `natOutgoing` SNATs through whichever node the VM happens to be
  on — so this fails asymmetrically: VMs can still reach out, but nothing in the
  VPC can reach them.

Recovery is one API call, repointing the route at a surviving node:

```bash
aws ec2 replace-route --route-table-id rtb-xxxxxxxx \
  --destination-cidr-block 10.60.0.0/24 --network-interface-id eni-yyyyyyyy   # a surviving node
```

That is cheaper than the VIP, which needs an unassign followed by an assign, but
it is still manual and still needs something watching to be automatic.

A load balancer does not help here the way it does for the management endpoint.
Network load balancers can take IP targets, but those must sit inside the VPC
CIDR (or reach on-premises over Direct Connect or VPN); overlay addresses
qualify as neither. Exposing individual VM ports through a Kubernetes
`LoadBalancer` service is the idiomatic alternative, but on Harvester that
allocates from the VIP pool and inherits the same AWS limitation.

For a proof of concept this is fine — it is one route and one command to repair.
It is listed here so it is a known limitation rather than a surprise.

**The established fix is the `aws-vpc-move-ip` pattern.** It is an OCF resource
agent from `resource-agents` (SUSE's own, and widely used for SAP HANA on AWS):
a cluster agent watches which node is active and rewrites the route table entry
to point at it. That is precisely this problem — an address AWS will not let you
move by ARP, moved instead by an API call.

Doing it here means something in-cluster watching node health and calling
`ec2:ReplaceRoute`, or an EventBridge rule on EC2 state-change driving a Lambda.
The in-cluster version knows whether the CNI is actually working rather than just
whether EC2 says the instance is running; the Lambda needs no IAM on the nodes,
which today have **no instance profile at all** — adding one takes the stack from
zero IAM resources to `CAPABILITY_IAM`.

Note this does **not** replace the load balancer. An overlay address of this kind
sits outside the VPC CIDR and is not publicly routable, so it solves east-west
reachability inside the VPC, not the public management endpoint. See
[Management endpoint](#management-endpoint).

**Three things are required, and missing any one drops the traffic silently:**

1. The **route**, above — gets packets to a node.
2. **Source/destination check disabled** — lets that node forward for addresses
   that are not its own. The template does this by default.
3. A **security group rule** permitting the traffic inbound. This is the one that
   is easy to miss: the nodes' group only admits the admin CIDRs and itself, so
   traffic from elsewhere in the VPC is dropped before it can be forwarded, even
   with the route and the check in place.

Set `OverlayClientCidr` (usually the VPC or subnet CIDR) and the template adds
the third. See [Source/destination check](#sourcedestination-check).

Be aware it is **broad by necessity**. Security group rules match on source,
protocol and port, never on destination, so there is no way to permit "traffic
bound for the overlay" specifically. Since a VM may serve any port, the rule is
all-protocols — which also lets those sources reach the **nodes** on any port,
including etcd, the kubelet and Longhorn. Scope the source as tightly as the
workload allows rather than reaching for the whole VPC out of habit.

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
./scripts/follow-console.sh --instance-id i-xxxxxxxx --tee console.txt
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
./scripts/01-build-instance.sh                     # 250 GiB image, 150 GiB COS_PERSISTENT

./scripts/03-launch-instance.sh --ami … --volume-size 500    # Longhorn gets ~427 GiB
./scripts/03-launch-instance.sh --ami … --volume-size 250    # Longhorn gets ~77 GiB
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
DISK_SIZE_GIB=130 PERSISTENT_SIZE=50Gi ./scripts/01-build-instance.sh --force
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
