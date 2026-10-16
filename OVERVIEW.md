# Harvester on AWS — Overview

This is a general overview of the project and current state. For the
operational detail including build steps, configuration, and failure modes,
see [the readme](README.md).

---

## Goal and result

The goal was Harvester running on EC2. More than just
running, it needed to *feel* cloud-native in its deployment. That meant
deployment should be simple, clustering included, along with the expected
functionality of deploying and running virtual machines.

What does work:

* A repeatable image build, for x86 and Arm.
* A CloudFormation template that deploys one, three, or five nodes.
* A Terraform module that does the same.
* Nodes on both x86 and Arm (Graviton) instances.
* VM networking that works, with internet access.
* A high-availability management endpoint.
* A high-availability kubernetes control plane.

What doesn't work:

* Bridge or VLAN networks.
* VIP failover. See [the readme](README.md#the-vip-does-not-fail-over) for
  what this impacts.

---

## EC2 user-data is the configuration channel

AWS expects one golden image plus per-instance configuration injected at boot.
Every launch path assumes it: the console, the CLI, CloudFormation, autoscaling
groups. That is what "click and deploy" means in practice. The image is
generic, and whatever makes an instance that particular instance shows up at
launch time as user-data.

Harvester historically works the other way around. The installer expects
someone at a console answering questions, or a PXE environment pointing at a
config server. It does not read cloud metadata, has no cloud-init integration,
and has no idea EC2 exists.

The link between the two is a small first-boot script baked into the image. It
pulls the instance's user-data from the metadata service, translates it into
the config file the Harvester installer expects, and stages it before the
installer runs. The installer then configures the node non-interactively and
hands off to the cluster bootstrap.

With that in place, Harvester behaves like any other cloud image. Configuration
goes in at launch, a configured node comes out, with no console access and no
manual step. Fully automatable.

* **Clustering** can be achieved with a small tweak to additional instances at
  deployment. The same mechanism creates a new cluster or joins an existing
  one, and it behaves the same on AWS as it does on-prem.
* **The CloudFormation template** uses this to allow for simple, full
  environment deployments. The role and clustering information is fed in at
  initialization.

The script uses IMDSv2 with a hop limit of 1, so the user-data — which carries
the cluster token — can't be fetched through a forged request (SSRF) or from
inside a pod. It is still readable by root on the node, and through the EC2 API
by anyone allowed `ec2:DescribeInstanceAttribute` or
`ec2:DescribeLaunchTemplateVersions`, so treat those permissions as access to
the token.

---

## EC2 is not the same as a physical server

Harvester was designed for bare metal, and not all of the design decisions work
the same with EC2.

**Hardware virtualization.** Harvester runs VMs, so it needs CPU virtualization
support. On an Intel or AMD instance that means nested virtualization, which is
recent, opt-in per instance, and only available on certain instance types.
Without it a node installs cleanly and then can't start a single VM.
CloudFormation can only enable it through a launch template, not a plain
instance, so the template is built around that.

**UEFI boot, and why Arm is different.** Harvester dropped legacy BIOS. Intel
and AMD bare-metal instances are BIOS-only, which rules out the obvious "just
use bare metal" answer for them and leaves nested virtualization as the only
path.

Arm is the exception, and it inverts the problem. No virtualized Graviton
instance offers nested virtualization at all — but Arm server platforms are
required by their own specification to boot UEFI, so Graviton *bare metal*
works where Intel bare metal cannot. The deployment is the mirror image: Arm
nodes run on real hardware and need no virtualization opt-in, and in fact
reject the request for it.

**Network bonding.** Harvester always puts a bond underneath its management
bridge, and bonding normally rewrites the NIC's MAC address. The ENA adapter
refuses, which aborts the setup. The bond is configured to keep the adapter's
own MAC instead.

**MTU.** AWS designed its network interfaces for high throughput, and they
natively support jumbo frames. This causes issues if a default MTU is not set
explicitly. Without one set, a node can come up with its bridge at one MTU and
the hardware beneath it at another, causing problems as soon as a second node
joins.

**Disk layout.** With no real installer running, the partition layout is fixed
when the image is built. The storage now expands on first boot to fill whatever
volume size was chosen.

---

## The management endpoint

Harvester's console lives on a VIP that it claims by broadcasting on the local
network. AWS doesn't support broadcast or multicast inside a VPC, so the ARP
that claims the VIP goes nowhere. An address only reaches an instance if AWS
has been told it belongs there, which means the VIP has to be registered
explicitly. Once registered, the VIP does not move if that node fails, so the
Network Load Balancer ends up being the cleaner solution.

The network load balancer sits in front of the nodes with a fixed public IP.
Every node serves both the UI and the Kubernetes API, so the NLB routes to
whichever ones are healthy and the endpoint survives losing a node.

For production, the natural split is an ALB for the web UI and the NLB for the
API. The API has to stay on an NLB: `kubectl` authenticates with client
certificates, and an ALB terminates TLS, which leaves the API server with
nothing to authenticate. The ALB adds real certificates to the UI and also
allows for more granular permissions using IAM/Cognito/OIDC.

---

## VM networking

Bridged networking cannot work on EC2. AWS inspects every packet leaving an
instance and drops anything not sourced from an address it has registered.
Harvester's standard VM networking is fundamentally incompatible with that. It
isn't configurable, and it applies to bare metal too.

What works is an overlay. VM traffic gets encapsulated inside ordinary
host-to-host traffic, so AWS only ever sees instances talking to instances. VMs
get their own addresses, reach the internet and the wider network, and can be
reached in return.

---

## Known limitations

| | |
|---|---|
| Availability zone | All nodes share one AZ. Survives node failure, not zone failure. For Arm this bites harder than it sounds: bare metal capacity is per-zone and genuinely runs out, so the choice of zone is not always free. |
| Certificates | The UI certificate is self-signed. Getting rid of the browser warning needs a domain. |
| Floating address | The cluster's own floating address is pinned to one node by AWS, while the software that owns it may move it to another. They agree today, but nothing enforces it. The load balancer avoids depending on it for access; the cluster still depends on it to add nodes. |
| VM networking | Bridged and VLAN networking will never work on AWS. |
| Inbound to VMs | Reaching overlay VMs from the VPC needs a route pinned to one node's interface. If that node fails, inbound breaks while outbound keeps working. Manual workaround available. |
| Image build | Automated end to end by a single command, but it still has to be run deliberately — it is not continuous integration, and it takes about two hours per architecture. |
| Performance | On Intel and AMD, VMs run nested, which costs something versus bare metal. Arm nodes run on bare metal and do not pay that cost. |
| Arm guest VMs | Work on v1.8.2. On v1.9.0 the guest firmware has an upstream defect that stops any VM booting; the nodes themselves are unaffected. Fixed upstream, awaiting a packaging rebuild. |
