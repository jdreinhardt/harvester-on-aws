# --- Image -------------------------------------------------------------------

variable "ami_ssm_parameter" {
  description = <<-EOT
    Name of an SSM parameter holding the Harvester AMI id, published at the end
    of phase 2.5. The AMI's boot mode must be uefi; Harvester dropped legacy BIOS
    and nothing here can check it for you.
  EOT
  type        = string
  default     = "/harvester/ami/latest"
}

variable "ami_id" {
  description = "Literal AMI id. Overrides ami_ssm_parameter when set; useful for testing a one-off image."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = <<-EOT
    Must support nested virtualization (Harvester needs /dev/kvm) and clear the
    32 GiB memory floor. List candidates with:
      aws ec2 describe-instance-types --filters \
        Name=processor-info.supported-features,Values=nested-virtualization
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
  description = "Shared by every node. Treat as a secret: it authorises joining the cluster."
  type        = string
  sensitive   = true
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
    Also put 6443 (kubectl) and 9345 (RKE2 supervisor) behind the load balancer,
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
}

variable "disable_source_dest_check" {
  description = <<-EOT
    Disable EC2's source/destination check. Required to reach VM addresses from
    the VPC over a kube-ovn overlay: outbound is SNATed by natOutgoing and works
    either way, but inbound needs the node to forward for addresses that are not
    its own, which the check blocks silently.
  EOT
  type        = bool
  default     = true
}

variable "password_hash" {
  description = <<-EOT
    SHA-512 crypt hash for the rancher user (mkpasswd -m sha-512). Empty keeps
    the password baked in during phase 1. A plaintext value here does not set a
    password, it disables password login.
  EOT
  type        = string
  default     = ""
  sensitive   = true
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
