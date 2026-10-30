# Terraform module

Equivalent to `cloudformation.yaml`. Same cluster, same decisions, expressed
where Terraform is more direct. See the [main readme](../README.md) for why any
of it is shaped the way it is — everything there about MTU, TLS SANs, promotion
and the overlay applies unchanged.

```hcl
module "harvester" {
  source = "./terraform"

  vpc_id        = "vpc-xxxxxxxx"
  subnet_id     = "subnet-xxxxxxxx"
  key_name      = "aws-testing"
  vip_address   = "172.31.31.31"
  cluster_token = var.cluster_token
  admin_cidrs   = ["203.0.113.4/32", "198.51.100.0/24"]
}
```

## Three differences from the CloudFormation template

**`admin_cidrs` has no cap.** CloudFormation cannot build a variable-length list
of objects — `Fn::ForEach` merges keys into the parent object and fails with
`Duplicate key 'Cidr'` — so the template uses five fixed slots guarded by
`Fn::Length`. `dynamic "entry"` has no such limit.

**No launch templates.** `AWS::EC2::Instance` cannot enable nested
virtualization, so the template routes everything through launch templates.
`aws_instance` takes `cpu_options` directly, so instances are declared plainly.

**Metal detection is a regex.** CloudFormation has no substring test usable in a
`Condition` — `Fn::Contains` exists only in `Rules` — so the template enumerates
every Graviton metal type in an `Fn::Or`, which caps at 10 entries. Here it is
`can(regex("\\.metal(-|$)", var.instance_type))`, so adding a metal type needs no
change to the module.

## The provider floor is not negotiable

`cpu_options.nested_virtualization` **does not exist before AWS provider 6.0**.
On 5.x the argument is rejected outright, which is the right way to find out —
silently dropping it would produce nodes that install cleanly and then cannot
start a single VM, because there would be no `/dev/kvm`.

## Architecture

`instance_type` and `ami_ssm_parameter` must agree, and Terraform cannot derive
one variable's default from another — so switching architecture means changing
both:

| | `instance_type` | `ami_ssm_parameter` |
|---|---|---|
| x86 | `m8i.4xlarge` (default) | `/harvester/ami/amd64/latest` (default) |
| arm64 | `c7g.metal`, `c8g.metal-24xl`, … | `/harvester/ami/arm64/latest` |

Build the matching AMI with `make ami ARCH=arm64`, or both at once with
`make ami-all`.

arm64 nodes run on **bare metal**, because no virtualized Graviton type offers
nested virtualization. That works only on ARM: x86_64 `.metal` types are legacy
BIOS and Harvester dropped BIOS support, while ARM server platforms are
UEFI-native. `cpu_options` is omitted automatically on metal — the flag is
rejected there, not ignored.

A mismatch fails at apply with *"The architecture 'arm64' of the specified
instance type does not match the architecture 'x86_64' of the specified AMI"*.

## Variables worth thinking about

| | |
|---|---|
| `node_count` | 1, 3 or 5. Two is never useful — promotion needs three. |
| `control_plane_via_nlb` | Adds 6443 to the load balancer, for reaching the API from outside the VPC. Does **not** change where joining nodes point — a load balancer cannot serve its own targets. Needs an AMI whose `configure.sh` writes the tls-san drop-in. |
| `mtu` | Defaults to 1500. What matters is that it is set at all. |
| `overlay_client_cidr` | Opens the nodes to this source on **all** protocols. Only with a VPC route for the overlay CIDR. |
| `replica_count` | Fixed at bootstrap and immutable afterwards. |
| `volume_type` | `gp3` (default), `io1` or `io2` for each node's root volume. io1/io2 need `volume_iops`, and take no `volume_throughput`: io2's throughput follows from IOPS, at 0.256 MiB/s per IOPS up to 4,000 MiB/s. io2 costs far more per IOPS; what it buys is lower write latency, which bounds commit-heavy work. Changes in place. |
| `volume_iops` / `volume_throughput` | Provisioning for each node's root volume, which holds the OS, etcd and every Longhorn replica. Unset gives a new gp3 volume the baseline, 3,000 IOPS / 125 MiB/s, but leaves an existing volume unchanged, so to go back to baseline set `3000` / `125` explicitly. **Do not run write-active VMs at gp3's baseline:** it caps the whole cluster's VM writes and can destabilize etcd (see [perf/FINDINGS.md](../perf/FINDINGS.md)). Like `volume_type`, these change **in place** on a running cluster, with no node replacement. AWS allows up to four modifications per volume in a rolling 24 hours, each only after the previous one completes, and a large volume can take hours to finish optimizing. Provisioning beyond the instance's own EBS limit is paid for but unusable. gp3 allows at most 0.25 MiB/s per IOPS, so 2,000 MiB/s (its maximum) needs at least 8,000 IOPS. **Changing an existing volume from io1/io2 to gp3 above 750 MiB/s fails** with a throughput-to-IOPS ratio error: the AWS provider sends only the attributes that changed, leaves out the unchanged IOPS, and AWS assumes gp3's 3,000. Make that change with `aws ec2 modify-volume --volume-type gp3 --iops N --throughput M` instead, after which `tofu plan` shows no changes; doing it in two applies would use two of the four modifications. |
| `disable_source_dest_check` | Default `false`. Set `true` only alongside `overlay_client_cidr` and a VPC route for the overlay. |
| `vip_controller` | Default `false`. `true` has node 1 deploy [vip-controller](../vip-controller/README.md) at first boot, so the VIP follows kube-vip's election. Needs the instance role from that README, through `iam_instance_profile` or added by hand. The image is in every AMI from `make ami` either way, so on a running cluster turn it on with `kubectl apply` instead: changing this replaces node 1. |
| `iam_instance_profile` | Default `null`. Name of an **existing** instance profile to attach to every node, for vip-controller or EFS. The module creates no IAM; make the role and profile as in [vip-controller](../vip-controller/README.md#iam-manual) or the README's [EFS section](../README.md#efs-for-vm-disks). Changes in place, with no node replacement. `null` leaves a profile attached by hand alone. |
| `cluster_token` | At least 16 characters of `A-Za-z0-9._+/=-`; `openssl rand -hex 24`. Stored in plain text in state and in instance user-data — protect both. |

## Changing user-data replaces nodes

`user_data_replace_on_change = true` is deliberate. User-data is read once, at
first boot, so a node cannot pick up a change in place — leaving it out would let
Terraform report success while the running cluster kept the old configuration.

The practical consequence matches CloudFormation, where `LaunchTemplate` is a
create-only property: anything feeding user-data — `mtu`, `cluster_token`,
`replica_count`, `control_plane_via_nlb` — is a **deploy-time** decision. The
volume settings are the exception: they change in place.
Changing it rebuilds the cluster.

## The AMI is not followed automatically

The AMI is the exception: `ignore_changes = [ami]`. `ami_ssm_parameter` is
re-read on every plan, and `make ami` repoints `/harvester/ami/<arch>/latest`
by default, so without this the first apply after any build would replace every
node — root volumes, and with them every VM disk, included. New nodes still
launch from whatever the parameter says at the time. To move an existing node
onto a new image, replace it deliberately:

```bash
tofu apply -replace='module.harvester.aws_instance.node[2]'
```

## Root volumes are encrypted

Always, with the account's default EBS key unless `ebs_kms_key_id` names
another. Turning encryption on forces replacement, so a cluster created before
this change will be rebuilt by its next apply — destroy and recreate it
deliberately rather than letting an unrelated apply do it.
