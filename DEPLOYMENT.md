# Deployment guide

The steps to get a working Harvester cluster on AWS, from nothing to logging
in to the UI. For why things are the way they are, see the
[README](README.md).

1. [Before you start](#1-before-you-start)
2. [Build the AMI](#2-build-the-ami)
3. [Create the instance role](#3-create-the-instance-role)
4. Deploy, in one of three ways:
   [CloudFormation](#4a-deploy-with-cloudformation),
   [Terraform](#4b-deploy-with-terraform) or
   [by hand](#4c-deploy-by-hand)
5. [Watch the bootstrap and log in](#5-watch-the-bootstrap-and-log-in)
6. [Check vip-controller](#6-check-vip-controller)
7. [Tear down](#7-tear-down)

The examples use amd64. For arm64, see [arm64](#arm64) at the end.

## 1. Before you start

You need:

- **AWS CLI v2**, recent enough to know `--cpu-options NestedVirtualization`.
- **Docker**, which `make ami` uses to build the vip-controller image.
- **A VPC and one subnet** with outbound internet access. All nodes go in this
  subnet.
- **An EC2 key pair**, with its private key at `~/.ssh/<key name>.pem`.

Then choose two values and keep them for the rest of the guide.

**A VIP:** a free private address in the subnet. It becomes the cluster's
management address. Make sure nothing is using it already (this should print
nothing):

```bash
aws ec2 describe-network-interfaces \
  --filters Name=addresses.private-ip-address,Values=172.31.31.31 \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
```

**A cluster token:** at least 16 characters, shared by every node. Keep it
somewhere safe; every node added later needs it.

```bash
export TOKEN=$(openssl rand -hex 24)
echo $TOKEN
```

## 2. Build the AMI

This takes about two hours. It launches a helper instance, installs Harvester
onto an EBS volume, registers an AMI, and publishes the AMI's ID to the SSM
parameter `/harvester/ami/amd64/latest`. The CloudFormation template and the
Terraform module read that parameter.

```bash
make ami SUBNET_ID=subnet-xxxxxxxx KEY_NAME=my-key
```

To follow the build:

```bash
tail -f .make/amd64/build.log
```

When it finishes, remove the helper instance:

```bash
make teardown
```

## 3. Create the instance role

vip-controller moves the VIP to whichever node holds kube-vip's lease, so the
UI survives losing a node. It is deployed by default, but it can't move
anything until the nodes have this role. Without the role, the VIP stays on
node 1. You can also add the role after deploying
([step 6](#6-check-vip-controller)).

Nothing in this repository creates IAM. These commands create a role and an
instance profile, both named `harvester-node-role`; you can choose any name.

**1. Fill in the policy.** Use your own region, account ID and the subnet from
step 1:

```bash
sed -e 's/REGION/us-east-2/g' \
    -e 's/ACCOUNT_ID/123456789012/g' \
    -e 's/SUBNET_ID/subnet-xxxxxxxx/g' \
    vip-controller/deploy/iam-policy.json > /tmp/iam-policy.json
```

The policy lets a node look up network interfaces, and move the VIP onto a
network interface in that subnet only:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "FindVipHolder",
      "Effect": "Allow",
      "Action": "ec2:DescribeNetworkInterfaces",
      "Resource": "*"
    },
    {
      "Sid": "ClaimVipInClusterSubnet",
      "Effect": "Allow",
      "Action": "ec2:AssignPrivateIpAddresses",
      "Resource": "arn:aws:ec2:us-east-2:123456789012:network-interface/*",
      "Condition": {
        "StringEquals": {
          "ec2:Subnet": "arn:aws:ec2:us-east-2:123456789012:subnet/subnet-xxxxxxxx"
        }
      }
    }
  ]
}
```

**2. Create the role and the instance profile:**

```bash
aws iam create-role --role-name harvester-node-role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam put-role-policy --role-name harvester-node-role \
  --policy-name vip-controller --policy-document file:///tmp/iam-policy.json
aws iam create-instance-profile --instance-profile-name harvester-node-role
aws iam add-role-to-instance-profile --instance-profile-name harvester-node-role \
  --role-name harvester-node-role
```

Whoever deploys the cluster needs `iam:PassRole` on this role.

### Routes that follow the VIP (also optional)

Only needed if a VPC route points an overlay CIDR at a node, so that VMs on
the overlay can be reached from the VPC. Setting up that overlay is covered in
the README's [VM networking on EC2](README.md#vm-networking-on-ec2).
vip-controller can repoint those routes along with the VIP:

1. Use `vip-controller/deploy/iam-policy-routes.json` instead of
   `iam-policy.json` above. Fill in `ROUTE_TABLE_ID` too, once for each route
   table.
2. Deploy with source/destination check disabled: CloudFormation
   `DisableSourceDestCheck=true`, or Terraform `disable_source_dest_check = true`.
3. After the cluster is up, create the route if it doesn't exist yet, then
   list it in this ConfigMap and apply it with `kubectl apply -f`:

   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: vip-controller-routes
     namespace: harvester-system
   data:
     rtb-0123456789abcdef0: |
       10.60.0.0/24
   ```

   Each key is a route table ID, and each value lists that table's destination
   CIDRs, one per line. vip-controller only changes where listed routes point;
   it never creates or deletes a route.

## 4a. Deploy with CloudFormation

This creates 3 nodes, a security group and a prefix list for the admin
CIDRs.

```bash
aws cloudformation create-stack \
  --stack-name harvester \
  --template-body file://cloudformation.yaml \
  --capabilities CAPABILITY_AUTO_EXPAND \
  --parameters \
    ParameterKey=VpcId,ParameterValue=vpc-xxxxxxxx \
    ParameterKey=SubnetId,ParameterValue=subnet-xxxxxxxx \
    ParameterKey=KeyName,ParameterValue=my-key \
    ParameterKey=VipAddress,ParameterValue=172.31.31.31 \
    ParameterKey=ClusterToken,ParameterValue=$TOKEN \
    ParameterKey=AdminCidrs,ParameterValue='203.0.113.4/32\,198.51.100.0/24' \
    ParameterKey=NodeInstanceProfile,ParameterValue=harvester-node-role
```

- `AdminCidrs` is who may reach SSH, the UI and the Kubernetes API, up to
  five CIDRs. Escape each comma inside the value as `\,`.
- Without the instance role from step 3, leave out `NodeInstanceProfile`.
- To reach the UI from outside the VPC, add
  `ManagementNlb=internet-facing`. This puts a load balancer with an Elastic
  IP in front of the UI.
- For a single node, add `NodeCount=1` and `ReplicaCount=1`.
- Set `NodeInstanceProfile` only when you create the stack. Changing it later
  replaces every node.

Wait for the stack, then read its outputs:

```bash
aws cloudformation wait stack-create-complete --stack-name harvester
aws cloudformation describe-stacks --stack-name harvester \
  --query 'Stacks[0].Outputs' --output table
```

`DashboardUrl` is the UI on the VIP. With a load balancer, `ManagementUrl` is
the UI through it. The stack is complete before Harvester is, so go on to
[step 5](#5-watch-the-bootstrap-and-log-in).

## 4b. Deploy with Terraform

This creates the same resources as CloudFormation. It needs AWS provider 6.0 or later, and works
with OpenTofu or Terraform.

Create `tf-deploy.tf` in the repository root. Git ignores this file, along
with the state files.

```hcl
provider "aws" { region = "us-east-2" }

module "harvester" {
  source = "./terraform"

  vpc_id        = "vpc-xxxxxxxx"
  subnet_id     = "subnet-xxxxxxxx"
  key_name      = "my-key"
  vip_address   = "172.31.31.31"
  cluster_token = "<your token>"
  admin_cidrs   = ["203.0.113.4/32", "198.51.100.0/24"]

  # Omit without the instance role from step 3.
  iam_instance_profile = "harvester-node-role"

  # To reach the UI from outside the VPC through a load balancer:
  # management_nlb = "internet-facing"

  # For a single node:
  # node_count    = 1
  # replica_count = 1
}

output "management_url" { value = module.harvester.management_url }
output "vip" { value = module.harvester.vip }
output "node_ids" { value = module.harvester.node_ids }
output "watch_bootstrap" { value = module.harvester.watch_bootstrap }
```

The token is stored in the state file in plain text, so keep it out of shared
places. One way is to leave it out of the file and run
`export TF_VAR_cluster_token=...` instead; this needs a
`variable "cluster_token" {}` at the top of the file, and
`cluster_token = var.cluster_token` in the module block.

```bash
tofu init
tofu apply
```

`management_url` is the UI: the VIP, or the load balancer if you turned it
on. `watch_bootstrap` prints the command for
[step 5](#5-watch-the-bootstrap-and-log-in).

## 4c. Deploy by hand

This launches the nodes one at a time with the AWS CLI. It builds no load
balancer, so the UI is only on the VIP.

Set these once:

```bash
export SUBNET=subnet-xxxxxxxx
export VPC=vpc-xxxxxxxx
export KEY=my-key
export VIP=172.31.31.31
export ADMIN_CIDR=203.0.113.4/32
export TYPE=m8i.4xlarge
export AMI=$(aws ssm get-parameter --name /harvester/ami/amd64/latest \
  --query Parameter.Value --output text)
```

**1. Security group.** The nodes need SSH, HTTP, HTTPS, the Kubernetes API and
the RKE2 supervisor from your network, and all traffic between each other:

```bash
SG=$(aws ec2 create-security-group --group-name harvester-nodes \
  --description "Harvester nodes" --vpc-id $VPC --query GroupId --output text)
for port in 22 80 443 6443 9345; do
  aws ec2 authorize-security-group-ingress --group-id $SG \
    --protocol tcp --port $port --cidr $ADMIN_CIDR
done
aws ec2 authorize-security-group-ingress --group-id $SG \
  --protocol -1 --source-group $SG
```

**2. User-data for node 1.** Node 1 creates the cluster. Save this as
`node1.yaml`, replacing the token and the VIP with yours:

```yaml
aws:
  data_disk_size: "max"
  vip_controller: true          # keep it; it waits for the instance role
scheme_version: 1
token: "<your token>"
install:
  automatic: true
  mode: create
  management_interface:
    interfaces:
      - name: eth0
    method: dhcp
    bond_options:
      mode: "active-backup"
      miimon: "100"
      fail_over_mac: "active"
    mtu: 1500
  vip: "172.31.31.31"
  vip_mode: static
  harvester:
    storage_class:
      replica_count: 3          # 1 for a single node
```

Keep `bond_options` and `mtu` exactly as shown: nodes without them can't
network on EC2. The file holds the cluster token, so keep it out of the
repository and delete it once the nodes are up.

**3. Launch node 1 and give it the VIP.** The VIP has to go on node 1's
network interface straight away. Leave out `--iam-instance-profile` if you
skipped step 3.

```bash
read ID ENI < <(aws ec2 run-instances \
  --image-id $AMI --instance-type $TYPE \
  --subnet-id $SUBNET --security-group-ids $SG --key-name $KEY \
  --cpu-options NestedVirtualization=enabled \
  --metadata-options HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":250,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' \
  --iam-instance-profile Name=harvester-node-role \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=harvester-node-1}]' \
  --user-data file://node1.yaml \
  --query 'Instances[0].[InstanceId,NetworkInterfaces[0].NetworkInterfaceId]' \
  --output text)
aws ec2 assign-private-ip-addresses --network-interface-id $ENI \
  --private-ip-addresses $VIP
echo "node 1: $ID"
```

Then wait for node 1 to finish bootstrapping
([step 5](#5-watch-the-bootstrap-and-log-in)) before adding more nodes.

**4. User-data for nodes 2 and 3.** These nodes join through the VIP. Save
this as `join.yaml`:

```yaml
aws:
  data_disk_size: "max"
scheme_version: 1
token: "<your token>"
server_url: "https://172.31.31.31:443"
install:
  automatic: true
  mode: join
  management_interface:
    interfaces:
      - name: eth0
    method: dhcp
    bond_options:
      mode: "active-backup"
      miimon: "100"
      fail_over_mac: "active"
    mtu: 1500
```

`mtu` must match node 1's. A joining node has no `vip` and no `storage_class`;
those belong to the cluster.

**5. Launch nodes 2 and 3.** Use the same command as for node 1, with
`join.yaml`, a different `Name` tag, and no `assign-private-ip-addresses`:

```bash
for n in 2 3; do
  aws ec2 run-instances \
    --image-id $AMI --instance-type $TYPE \
    --subnet-id $SUBNET --security-group-ids $SG --key-name $KEY \
    --cpu-options NestedVirtualization=enabled \
    --metadata-options HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":250,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' \
    --iam-instance-profile Name=harvester-node-role \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=harvester-node-$n}]" \
    --user-data file://join.yaml \
    --query 'Instances[0].InstanceId' --output text
done
```

Nodes join as workers, and are promoted to the control plane once there are
three and they are `Ready`.

`scripts/03-launch-instance.sh` does all of this for you: it generates the
user-data, picks a free VIP and assigns it. Run it with `--help` for its
options.

## 5. Watch the bootstrap and log in

A new cluster takes 15–25 minutes to come up. Follow node 1's serial console:

```bash
./scripts/follow-console.sh --instance-id i-xxxxxxxx --tee console.txt
```

Then open the UI and log in as `admin` / `admin`:

| Deployed with | UI |
| --- | --- |
| CloudFormation | the `DashboardUrl` output, or `ManagementUrl` with a load balancer |
| Terraform | the `management_url` output |
| By hand | `https://<VIP>` |

The VIP is private, so to reach it from outside the VPC you need a VPN, or
a load balancer (`ManagementNlb` / `management_nlb`).

To use `kubectl`, SSH to any node as `rancher` with your key:

```bash
ssh -i ~/.ssh/my-key.pem rancher@<node address>
sudo -i
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml PATH=$PATH:/var/lib/rancher/rke2/bin
kubectl get nodes
```

Every node should show `Ready`, and on a 3-node cluster each should have the
`control-plane,etcd` roles.

## 6. Check vip-controller

```bash
kubectl -n harvester-system get pods -l app.kubernetes.io/name=vip-controller -o wide
kubectl -n harvester-system logs -l app.kubernetes.io/name=vip-controller --prefix
```

There should be one pod per node, all `Running`. One of them, on the node
holding the lease, should have logged `this node holds the lease`.

If the logs show `UnauthorizedOperation`, the node has no instance role, or
the role's policy names the wrong subnet. To attach the role to a running
node:

```bash
aws ec2 associate-iam-instance-profile --instance-id i-xxxxxxxx \
  --iam-instance-profile Name=harvester-node-role
```

## 7. Tear down

| Deployed with | Command |
| --- | --- |
| CloudFormation | `aws cloudformation delete-stack --stack-name harvester` |
| Terraform | `tofu destroy` |
| By hand | `aws ec2 terminate-instances --instance-ids <ids>`, then `aws ec2 delete-security-group --group-id $SG` once they're gone |

The AMI, its snapshot, the SSM parameter and the IAM role stay. Delete them
separately if you no longer need them.

## arm64

Graviton nodes must be bare metal, since no virtualized Graviton type offers
nested virtualization. The differences:

- **Build:** `make ami ARCH=arm64 SUBNET_ID=... KEY_NAME=...`, which
  publishes to `/harvester/ami/arm64/latest`. Tear down with
  `make teardown ARCH=arm64`.
- **CloudFormation:** add `AmiSsmParameter=/harvester/ami/arm64/latest` and a
  `.metal` `InstanceType`, such as `c7g.metal`.
- **Terraform:** set `ami_ssm_parameter = "/harvester/ami/arm64/latest"` and
  `instance_type = "c7g.metal"`.
- **By hand:** read the arm64 SSM parameter, use a `.metal` type, and **leave
  out `--cpu-options`**, which bare metal rejects.

Bare metal capacity runs out by availability zone. If a launch fails with
`InsufficientInstanceCapacity`, try a subnet in another zone, or use a
capacity reservation.

Guest VMs don't boot on arm64 Harvester v1.9.0
([README](README.md#what-has-been-tested)). For
arm64 VMs, build v1.8.2 instead with `HARVESTER_VERSION=v1.8.2`.
