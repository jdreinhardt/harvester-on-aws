# --- Image -------------------------------------------------------------------

variable "ami_ssm_parameter" {
  description = <<-EOT
    Name of an SSM parameter holding the Harvester AMI id, published at the end
    of phase 2.5 (or by `make ami`). The AMI's boot mode must be uefi; Harvester
    dropped legacy BIOS and nothing here can check it for you.

    The architecture is its own path segment, so a build of one architecture can
    never repoint the parameter the other one reads:

      /harvester/ami/amd64/latest   x86 instance types
      /harvester/ami/arm64/latest   Graviton *.metal types

    This must match instance_type's architecture. Terraform cannot derive one
    variable's default from another, so switching to a Graviton type means
    changing both. A mismatch fails at apply with "The architecture 'arm64' of
    the specified instance type does not match the architecture 'x86_64' of the
    specified AMI".
  EOT
  type        = string
  default     = "/harvester/ami/amd64/latest"
}

variable "ami_id" {
  description = "Literal AMI id. Overrides ami_ssm_parameter when set; useful for testing a one-off image."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = <<-EOT
    Must give Harvester /dev/kvm and clear the 32 GiB memory floor. Two ways,
    mutually exclusive:

      x86      a virtualized type supporting nested virtualization. List them:
                 aws ec2 describe-instance-types --filters \
                   Name=processor-info.supported-features,Values=nested-virtualization
      arm64    a Graviton *.metal type (c6g.metal, c7g.metal, c8g.metal-24xl,
               m8g.metal-24xl, ...). Bare metal has the real CPU, so no opt-in
               is needed -- and it REJECTS the nested-virtualization flag rather
               than ignoring it, which is why cpu_options below is conditional.

    Metal is arm64-only in practice: x86_64 *.metal types are legacy BIOS and
    Harvester dropped BIOS support, while ARM server platforms are UEFI-native
    (SBBR mandates it).

    Must match ami_ssm_parameter's architecture.
  EOT
  type        = string
  default     = "m8i.4xlarge"
}

# --- Placement ---------------------------------------------------------------

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "All nodes land here. vip_address must be a free address within it."
  type        = string
}

variable "key_name" {
  description = "EC2 key pair. Its public key is added to the rancher user by /oem/aws/configure.sh."
  type        = string
}

# --- Cluster shape -----------------------------------------------------------

variable "node_count" {
  description = <<-EOT
    1, 3 or 5. Nothing between is useful: Harvester's promote controller returns
    early below three nodes, so a two-node cluster leaves the second unpromoted.
    At 5, nodes 4 and 5 get install.role=worker so the management trio is nodes
    1-3 by construction rather than whichever three the controller picks.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = contains([1, 3, 5], var.node_count)
    error_message = "node_count must be 1, 3 or 5."
  }
}

variable "cluster_token" {
  description = <<-EOT
    Shared by every node. Treat as a secret: it authorises joining the cluster.
    Generate with `openssl rand -hex 24`. `sensitive` only hides it from plan
    output -- it is stored in plain text in Terraform state and in the
    instances' user-data, so protect the state backend and restrict
    ec2:DescribeInstanceAttribute.
  EOT
  type        = string
  sensitive   = true

  validation {
    # Interpolated into YAML user-data, so restrict the alphabet as well.
    condition     = can(regex("^[A-Za-z0-9._+/=-]{16,}$", var.cluster_token))
    error_message = "cluster_token must be at least 16 characters of A-Z a-z 0-9 . _ + / = -."
  }
}

# --- Addresses ---------------------------------------------------------------

variable "vip_address" {
  description = <<-EOT
    Management VIP, assigned as a secondary private address on node 1. Inside a
    VPC an address only reaches an instance if it is registered there, and
    kube-vip's ARP means nothing. Node 1's own address is assigned by EC2; only
    the VIP needs pinning.
  EOT
  type        = string
}

variable "admin_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach SSH, the UI and the Kubernetes API. Unlike the
    CloudFormation template there is no cap here -- Terraform can iterate, where
    CloudFormation cannot build a variable-length list of objects.
    Use your own addresses, not 0.0.0.0/0. Node-to-node traffic uses a
    self-referencing rule and does not need this widened.
  EOT
  type        = list(string)
}

variable "overlay_client_cidr" {
  description = <<-EOT
    Source CIDR allowed to reach VMs on a kube-ovn overlay, typically the VPC or
    subnet CIDR. Needed only alongside a VPC route sending the overlay CIDR at a
    node; without it the nodes drop that traffic before they can forward it, even
    with source/destination checking disabled.
    BROAD by necessity: security group rules match on source, protocol and port,
    never on destination, so permitting arbitrary VM ports means all protocols --
    which also lets these sources reach the NODES on any port, including etcd,
    the kubelet and Longhorn. Leave empty if you are not routing an overlay.
  EOT
  type        = string
  default     = ""
}

variable "management_nlb" {
  description = <<-EOT
    Load balancer in front of the nodes on 443, so the management endpoint
    survives losing a node -- the VIP does not fail over, because it is a
    secondary address on one ENI and the VPC ignores kube-vip's ARP.
    "internet-facing" also allocates an Elastic IP for a fixed public address.
    "none" leaves the VIP as the only endpoint.
  EOT
  type        = string
  default     = "internet-facing"

  validation {
    condition     = contains(["internet-facing", "internal", "none"], var.management_nlb)
    error_message = "management_nlb must be internet-facing, internal or none."
  }
}

variable "control_plane_via_nlb" {
  description = <<-EOT
    Also put 6443 (kubectl) behind the load balancer,
    for reaching the Kubernetes API from OUTSIDE the VPC on an address that
    survives losing a node.
    It does NOT change where joining nodes point. A Network Load Balancer cannot
    be reached by its own registered targets -- verified, and not fixable by
    disabling client IP preservation -- so server_url always uses the VIP, and
    cluster expansion still depends on node 1.
    Requires an AMI whose configure.sh writes the RKE2 tls-san drop-in on every
    node; without it the nodes' certificates lack the load balancer's name and
    kubectl fails verification whenever the balancer does not pick node 1.
  EOT
  type        = bool
  default     = false
}

# --- Storage -----------------------------------------------------------------

variable "volume_size" {
  description = <<-EOT
    Root volume in GiB. 250 is the floor: validateDiskSize() in
    harvester-installer is not gated by skipchecks. Must also be at least the
    size of the AMI snapshot.
  EOT
  type        = number
  default     = 250

  validation {
    condition     = var.volume_size >= 250
    error_message = "volume_size must be at least 250 GiB."
  }
}

variable "replica_count" {
  description = <<-EOT
    Longhorn replicas. Fixed at bootstrap by node 1 and immutable afterwards, so
    plan it up front. Use 1 only for node_count = 1: single-replica volumes block
    upgrades once a cluster has more than one node.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = contains([1, 3], var.replica_count)
    error_message = "replica_count must be 1 (single node) or 3."
  }
}

variable "ebs_kms_key_id" {
  description = "Optional KMS key ARN for the root volumes. They are always encrypted; empty uses the account's default EBS key (aws/ebs)."
  type        = string
  default     = ""
}

# --- Advanced ----------------------------------------------------------------

variable "mtu" {
  description = <<-EOT
    Management interface MTU. What matters is that it is set at all: without it
    mgmt-br keeps ENA's 9001 over a 1500 bond, TCP derives an 8961 MSS, and every
    segment above 1500 is silently dropped -- handshakes succeed and the first
    real payload vanishes. 1500 matches the cap AWS applies to anything leaving
    the VPC. 9000 is a valid opt-in.
  EOT
  type        = number
  default     = 1500

  validation {
    # checkMTU() in harvester-installer accepts 576..9000 (not ENA's 9001).
    condition     = var.mtu >= 576 && var.mtu <= 9000
    error_message = "mtu must be between 576 and 9000."
  }
}

variable "disable_source_dest_check" {
  description = <<-EOT
    Disable EC2's source/destination check. Required only to reach VM addresses
    from the VPC over a kube-ovn overlay: outbound is SNATed by natOutgoing and
    works either way, but inbound needs the node to forward for addresses that
    are not its own, which the check blocks silently. Disabling it also lets
    the node emit traffic from addresses that are not its own, so leave it off
    unless you set overlay_client_cidr and add the VPC route.
  EOT
  type        = bool
  default     = false
}

variable "password_hash" {
  description = <<-EOT
    Optional SHA-512 crypt hash for the rancher user (mkpasswd -m sha-512), for
    logging in on the EC2 serial console. SSH is key-only regardless. Empty
    leaves the rancher user with no usable password.
  EOT
  type        = string
  default     = ""
  sensitive   = true

  validation {
    # Written verbatim to /etc/shadow, so a plaintext value would not set a
    # password at all. Also interpolated into YAML user-data.
    condition     = var.password_hash == "" || can(regex("^\\$[^\"\\\\]+$", var.password_hash))
    error_message = "password_hash must be a crypt hash (mkpasswd -m sha-512), not a plaintext password."
  }
}

variable "name_prefix" {
  description = "Prefix for resource names and tags. Must be unique per deployment: several of these names are account-unique."
  type        = string
  default     = "harvester"

  validation {
    # Target group names are capped at 32 characters and the longest suffix this
    # module appends is "-supervisor" (11). Without this the failure arrives at
    # apply time, from AWS, after most of the cluster already exists.
    condition     = length(var.name_prefix) <= 21
    error_message = "name_prefix must be 21 characters or fewer (target group names are capped at 32, and \"-supervisor\" takes 11)."
  }
}
