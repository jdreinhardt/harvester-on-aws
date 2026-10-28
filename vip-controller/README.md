# vip-controller

Makes the VPC follow kube-vip's election, so the Harvester VIP fails over on
EC2. Optionally, VPC routes follow it too. Status: **both have been run on a
cluster by hand (results below); not yet built into the image.** The
design and the reasoning behind it are in the main README, under "The VIP does
not fail over" → "Proposed design".

## What it does

kube-vip elects a leader through the Lease `harvester-system/plndr-svcs-lock`
and binds the VIP on that node's `mgmt-br`. The VPC ignores that: the VIP only
reaches the node whose ENI it is registered on, which is node 1 from launch
onward.

This runs on every control-plane node. Every 2 seconds it reads the Lease. When
the Lease names its own node and has not expired, it asks EC2 which ENI in the
VPC holds the VIP and, if that is not its own primary ENI, calls
`AssignPrivateIpAddresses` with `AllowReassignment`, which moves the address in
one call. The old node does not need to be alive.

While it holds the Lease it re-checks every `RECHECK_INTERVAL` (default 10s),
so a re-election with the old holder still healthy is repaired too.

It never unassigns the VIP, never touches another node's ENI except through
that reassignment, and leaves binding the address to kube-vip.

| File | |
| --- | --- |
| `main.go` | configuration, the Lease loop |
| `claim.go` | EC2: who holds the VIP, claiming it, instance metadata |
| `routes.go` | the optional routes ConfigMap, repointing routes |
| `claim_test.go`, `routes_test.go` | the claim, lease and route decisions, with a fake EC2 |
| `Dockerfile` | cross-compiles per architecture into a `scratch` image |
| `deploy/vip-controller.yaml` | ServiceAccount, Role, RoleBinding, DaemonSet |
| `deploy/routes-configmap.example.yaml` | an example routes ConfigMap |
| `deploy/iam-policy.json` | the instance-role policy, VIP only |
| `deploy/iam-policy-routes.json` | the same, plus route table edits |

## Routes that follow the VIP (optional)

A VPC route targets an ENI or instance, never an IP address, so a route for an
overlay CIDR names one node and stays there when the VIP moves. If that node
dies, inbound traffic to the overlay black-holes (main README, "VM networking
on EC2"). The controller can repoint such routes along with the VIP.

It follows aws-vpc-move-ip's design: **only routes you list explicitly are
changed, and they must already exist.** The controller replaces a listed
route's target; it never creates or deletes a route, and never looks for
routes by what they currently point at. A blackholed route left on a stopped
node is still found by its destination, and repointed.

The list is the ConfigMap `harvester-system/vip-controller-routes`. Each key is
a route table ID; each value lists destination CIDRs in that table, one per
line:

```yaml
data:
  rtb-0123456789abcdef0: |
    10.60.0.0/24
    10.61.0.0/24
```

* **No ConfigMap, no route changes.** That is the default.
* **Read on every check** while the node holds the Lease: on becoming holder,
  then every `RECHECK_INTERVAL`. Adding, removing or editing entries takes
  effect within that interval, with no restart. Removing an entry stops
  managing that route; it does not delete it.
* **Checked before changing.** For each listed route it reads the current
  target and calls `ReplaceRoute` only if the target is not its own ENI, so the
  periodic check also repairs a route someone repointed by hand.
* **Errors do not block other routes.** A missing route or table is logged on
  every check (`... has no route for 10.62.0.0/24; create it first`) and the
  rest are still handled. An invalid ConfigMap (a key that is not `rtb-...`, a
  value that is not an IPv4 CIDR, or a CIDR with host bits set) is logged and
  no routes are changed until it is fixed.
* **Source/destination check must be off on every node that can hold the VIP**,
  not just the one the route first named, since any of them may become the
  target. The module's `disable_source_dest_check` (CloudFormation:
  `DisableSourceDestCheck`) applies to every node.

`deploy/routes-configmap.example.yaml` is a starting point. It is a separate
file from `vip-controller.yaml` so that re-applying the manifest never
overwrites your routes.

## Configuration

| Variable | |
| --- | --- |
| `VIP` | Required. The cluster VIP. Set in the manifest. |
| `NODE_NAME` | Required. From the downward API; must match kube-vip's `holderIdentity`. |
| `RECHECK_INTERVAL` | Optional, a Go duration. Default `10s`. |

The manifest also points the client at `127.0.0.1:6443`, the API server on the
same node, rather than the service IP.

## Build

```bash
go test ./...
```

One archive per architecture, each tagged `harvester-aws/vip-controller:0.2.0`
to match the manifest. Build into the local engine and `docker save`, because
the default `docker` buildx driver cannot write an archive directly:

```bash
for a in amd64 arm64; do
  docker buildx build --platform linux/$a -t harvester-aws/vip-controller:0.2.0-$a --load .
  docker tag harvester-aws/vip-controller:0.2.0-$a harvester-aws/vip-controller:0.2.0
  docker save harvester-aws/vip-controller:0.2.0 | gzip -9 > vip-controller-$a.tar.gz
done
```

The archives are about 10 MB (amd64) and 9 MB (arm64). RKE2 and `ctr` import
`.tar.gz` directly.

## IAM (manual)

Nothing in this repository creates the role or the policy; add them by hand,
as for EFS. One role serves both: an instance can carry only one, so EFS adds
its policy to this role rather than creating another.

**1. Pick the policy.**

| Policy | Use when | Placeholders |
| --- | --- | --- |
| `deploy/iam-policy.json` | VIP failover only | `REGION`, `ACCOUNT_ID`, `SUBNET_ID` |
| `deploy/iam-policy-routes.json` | VIP failover, plus a routes ConfigMap | the above, plus one `ROUTE_TABLE_ID` entry per route table in the ConfigMap |

What each statement allows:

| Statement | Action | Scope |
| --- | --- | --- |
| `FindVipHolder` | `ec2:DescribeNetworkInterfaces` | `*`; the action has no resource-level permissions |
| `ClaimVipInClusterSubnet` | `ec2:AssignPrivateIpAddresses` | network interfaces in the cluster's subnet (`ec2:Subnet` condition) |
| `ReadRouteTables` | `ec2:DescribeRouteTables` | `*`; no resource-level permissions |
| `RepointListedRouteTables` | `ec2:ReplaceRoute` | only the route tables listed; add an ARN when you add a table to the ConfigMap |

Route tables are VPC-wide and may be shared with other subnets, so
`ReplaceRoute` is the broader grant. Use the routes policy only if you use the
routes ConfigMap. The policy and the ConfigMap must list the same tables: a
table in the ConfigMap but not the policy fails with `UnauthorizedOperation`
on every check.

**2. Create the role and attach it to every node.** The role name is yours to
choose; the commands use `harvester-node-role`.

```bash
aws iam create-role --role-name harvester-node-role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam put-role-policy --role-name harvester-node-role \
  --policy-name vip-controller --policy-document file://iam-policy.json   # with placeholders filled in
aws iam create-instance-profile --instance-profile-name harvester-node-role
aws iam add-role-to-instance-profile --instance-profile-name harvester-node-role \
  --role-name harvester-node-role

# For each node:
aws ec2 associate-iam-instance-profile --instance-id i-xxxxxxxx \
  --iam-instance-profile Name=harvester-node-role
```

To switch to the routes policy later, run `put-role-policy` again with
`iam-policy-routes.json` and the same policy name; it replaces the old one.

Credentials come from instance metadata; the pod runs on the host network, so
the hop limit does not matter for it. **Every pod on a node can use this
role**, though, because the hop limit is 2 for EFS (main README, "Notes and
gotchas").

## Try it on a test cluster

1. Attach the policy to the instance role.
2. Copy the archive for the cluster's architecture to every control-plane node
   and import it:

   ```bash
   gunzip -c vip-controller-amd64.tar.gz | sudo /var/lib/rancher/rke2/bin/ctr --address /run/k3s/containerd/containerd.sock -n k8s.io images import -
   ```

3. Set `VIP` in `deploy/vip-controller.yaml` and apply it.
4. Watch it: `kubectl -n harvester-system logs -l app.kubernetes.io/name=vip-controller -f --prefix`.

## Checked on a v1.8.2 cluster

* kube-vip's `holderIdentity` is the Kubernetes node name
  (`harvester-<instance id>`), and only the holder has the VIP on `mgmt-br`.
  Its `leaseDurationSeconds` is 5.
* `harvester-system` has no Pod Security labels, and kube-vip already runs
  there on the host network.
* The API server answers on `127.0.0.1:6443` with a valid certificate: RKE2's
  own `rke2.yaml` uses that address.

## Measured: forced re-election (2026-10-28)

v1.8.2, three m8i.4xlarge nodes in one subnet, `RECHECK_INTERVAL` 10s. Node 1's
kube-vip pod was deleted at t=0. Each node pinged the VIP every ~0.25 s; the
Lease holder and the ENI holding the VIP were polled about once a second.

| t (s) | |
| --- | --- |
| +0.4 | last successful ping from every node |
| +0.6 | Lease held by node 3; node 3 has the VIP bound on `mgmt-br` |
| ≈ +0.6 | node 3's controller claims it (same second, per its log) |
| +1.7 | EC2 reports the VIP on node 3's ENI (first poll after the claim) |
| +1.9 | pings succeed again from all three nodes, including node 1 and node 2, whose packets now cross the VPC to node 3 |

So the VIP was unreachable for at most about 1.5 s, and the IAM policy above
was sufficient for the claim.

What this does **not** show:

* **A node failure.** Deleting the pod is graceful: kube-vip released the lease
  and node 3 took it at once. A stopped or crashed node is detected only when
  the lease expires (`leaseDurationSeconds` 5), so expect a few seconds more.
* **Whether EC2 authorizes against the ENI the address is taken from.** Both
  ENIs were in the subnet the `ec2:Subnet` condition names, as every node's is
  in this module, so the run satisfies the condition either way.
* **HTTPS from the nodes.** `curl https://<vip>/` from a node answered 302
  throughout, because kube-proxy rewrites locally originated traffic to a
  LoadBalancer address on every node, so it never left the node. Ping is the
  meaningful probe from a node; an HTTPS probe needs a host that is not a node.

## Measured: holding node stopped (2026-10-28)

Same cluster. Node 3 held the lease and the VIP; it was stopped with a normal
`stop-instances` at t=0 (16:46:38 UTC). A t3.micro in the same subnet, not a
node, pinged the VIP and fetched `https://<vip>/` every ~0.25 s.

| t (s) | |
| --- | --- |
| +0.6 | first failed ping: node 3's shutdown has taken its kube-vip down |
| +6.8 | node 2's kube-vip acquires the lease (it was not released, so it expired) and binds the VIP |
| +7.8 | node 2's controller claims the VIP (`AssignPrivateIpAddresses` in CloudTrail at 16:46:46) |
| ≈ +9 | pings succeed again |
| +45 | node 3 `NotReady` |
| +94 to +143 | **a second outage**: ping and HTTPS both fail for about 50 s (below) |
| +236 | node 3 started; `Ready` about 45 s later. Its controller restarted from the imported image, which survived the reboot. No loss during the rejoin, and the lease stayed on node 2. |

**The failover itself took about 9 s**, of which about 6 s was waiting for the
lease to expire. The controller added about 1 s.

**HTTPS failed intermittently from +0.6 s until node 3's ingress endpoint went
not-ready**, about 1 request in 2 at first. That is not the VIP: it is the
`ingress-expose` service still sending a share of connections to the
ingress-nginx pod on the stopped node. The same applies to the `kubernetes`
service: node 1's kube-vip could not reach the API through `10.53.0.1` for
about 80 s. The controller's use of `127.0.0.1:6443` avoids that.

**The second outage is not explained.** Throughout it the lease stayed on node
2, the VIP stayed bound on node 2's `mgmt-br` and on node 2's ENI, and no
controller or kube-vip logged anything. It lines up with node 3 finishing its
power-off: the instance spent about 90 s in `stopping`, and CloudTrail records
the EBS grant being retired at 16:48:23. A repeat should also ping node 2's own
address and record the probe host's neighbour table, to tell a node-2 problem
from a VPC one.

## Measured: holding node stopped, repeat (2026-10-28)

Node 2 held the lease and the VIP; stopped at t=0 (16:54:23 UTC). The probe
host also pinged every node's own address, and logged its neighbour table.

| t (s) | |
| --- | --- |
| +0.1 | node 2's kube-vip deletes the VIP and exits **without releasing the lease**; its API server deregisters itself (node 2's own logs, read after restart) |
| +1.1 | VIP pings start failing |
| +0.1 to +91 | kube-vip on nodes 1 and 3 cannot read the lease: every attempt through the `kubernetes` service IP `10.53.0.1` times out |
| +91.3 | node 3's kube-vip acquires the lease and binds the VIP |
| +93 | node 3's controller claims it |
| +94.6 | VIP pings succeed again |
| +95.3 | node 2's own address stops answering: the instance is finally off |
| +264 | node 2 started; `Ready` about 3 minutes later. No loss on the VIP or any node during the restart, and the lease stayed on node 3. |

**This time the VIP was down for about 94 s, and the controller was not the
slow part.** It claimed within 2 s of kube-vip taking the lease, as in every
run. The time went on kube-vip's election: the surviving nodes reach the API
server through the service IP, and for as long as node 2 was shutting down
those requests timed out. Some timeouts were client-side, some were the API
server reporting it could not answer in time. Node 3's controller reads the
same Lease through `127.0.0.1:6443` and logged no errors over the same period.
Why the service path failed for so long is not established.

In the first stop test node 2's kube-vip got through after about 7 s. Two runs
are too few to say which is typical.

**The 50 s second outage from the first stop test did not recur.** The
neighbour table rules out the probe host's ARP cache as a cause: pings to the
VIP recovered at +94.6 s while the cached entry still held node 2's MAC, and it
switched to node 3's only at +95 s. The VPC delivers by IP address, not by
cached MAC.

The pings to nodes 1 and 3 never dropped.

## Measured: routes following the VIP (2026-10-28, image 0.2.0)

ConfigMap listing `10.60.0.0/24` in `rtb-0cab7af01e54b0f43`, with
`iam-policy-routes.json` on the role, its `ReplaceRoute` limited to that one
table. The route and the VIP's ENI were polled about every 1.5 s.

* **On rollout**, the route pointed at an ENI from an earlier cluster and was
  `blackhole`. Node 3, the holder, repointed it within a second of starting
  (`routed 10.60.0.0/24 ... (was eni-0b7ccb0115a375d76)`), and it went
  `active`. So a blackholed route is found by its destination and repaired, and
  `ReplaceRoute` scoped to the route table is enough: EC2 did not also require
  permission on the target ENI.
* **Forced re-election** (node 3's kube-vip pod deleted at t=0): node 1 took
  the lease, and its controller claimed the VIP and repointed the route in the
  same second (17:28:45). The poll saw the VIP on node 1 at +2.4 s and the
  route at +3.9 s; the difference is the poll's spacing.

The VIP claim runs first and does not depend on the routes: a route that is
missing, or a table the policy does not cover, is logged and never stops the
VIP from moving. That ordering is from the code, not from a failure test on the
cluster.

`rtb-0cab7af01e54b0f43` is this VPC's **main** route table, used by every
subnet without its own, so the `ReplaceRoute` grant covers all of them. A
dedicated route table for the cluster's subnet would narrow that.

No VM was running on the `10.60.0.0/24` overlay subnet, and kube-ovn's
control plane was down after the two node stops (main README, kube-ovn known
issue), so this shows the route following the VIP, not traffic reaching a VM
through it. Overlay reachability
through a routed node was measured separately (perf test 13).

## Still to verify

* Why kube-vip's API requests through `10.53.0.1` fail while a node shuts down.
  kube-vip takes its API address from the in-cluster defaults, which is part
  of Harvester's chart; changing it would mean changing that chart.
* The 50 s second outage in the first stop test.
* A crash rather than a clean stop (`stop-instances --force`), where kube-vip
  gets no chance to release anything.
* Route following when the holding node is stopped. It runs in the same pass
  as the VIP claim, so it should take the same time.
