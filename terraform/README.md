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

## Two differences from the CloudFormation template

**`admin_cidrs` has no cap.** CloudFormation cannot build a variable-length list
of objects — `Fn::ForEach` merges keys into the parent object and fails with
`Duplicate key 'Cidr'` — so the template uses five fixed slots guarded by
`Fn::Length`. `dynamic "entry"` has no such limit.

**No launch templates.** `AWS::EC2::Instance` cannot enable nested
virtualization, so the template routes everything through launch templates.
`aws_instance` takes `cpu_options` directly, so instances are declared plainly.

## The provider floor is not negotiable

`cpu_options.nested_virtualization` **does not exist before AWS provider 6.0**.
On 5.x the argument is rejected outright, which is the right way to find out —
silently dropping it would produce nodes that install cleanly and then cannot
start a single VM, because there would be no `/dev/kvm`.

## Variables worth thinking about

| | |
|---|---|
| `node_count` | 1, 3 or 5. Two is never useful — promotion needs three. |
| `control_plane_via_nlb` | Adds 6443 and 9345 to the load balancer and points joining nodes at it. Needs an AMI whose `configure.sh` writes the tls-san drop-in. |
| `mtu` | Defaults to 1500. What matters is that it is set at all. |
| `overlay_client_cidr` | Opens the nodes to this source on **all** protocols. Only with a VPC route for the overlay CIDR. |
| `replica_count` | Fixed at bootstrap and immutable afterwards. |

## Changing user-data replaces nodes

`user_data_replace_on_change = true` is deliberate. User-data is read once, at
first boot, so a node cannot pick up a change in place — leaving it out would let
Terraform report success while the running cluster kept the old configuration.

The practical consequence matches CloudFormation, where `LaunchTemplate` is a
create-only property: anything feeding user-data — `mtu`, `cluster_token`,
`replica_count`, `control_plane_via_nlb`, the AMI — is a **deploy-time**
decision. Changing it rebuilds the cluster.
