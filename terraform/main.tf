# =============================================================================
# Harvester (SUSE Virtualization) on EC2 -- 1, 3 or 5 nodes.
#
# Equivalent to cloudformation.yaml, but Terraform expresses two things more
# directly than CloudFormation can:
#
#   * admin_cidrs has no cap. CloudFormation cannot build a variable-length list
#     of objects -- Fn::ForEach merges keys into the parent object -- so the
#     template uses five fixed slots. for_each has no such limit.
#   * No launch templates. AWS::EC2::Instance cannot enable nested
#     virtualization, so the template routes everything through launch
#     templates; aws_instance takes cpu_options directly.
# =============================================================================

locals {
  ami_id = var.ami_id != "" ? var.ami_id : nonsensitive(data.aws_ssm_parameter.ami[0].value)

  nlb_enabled = var.management_nlb != "none"
  nlb_public  = var.management_nlb == "internet-facing"
  cp_via_nlb  = local.nlb_enabled && var.control_plane_via_nlb

  # Management nodes only. Promotion keeps the control plane on 1-3, and that is
  # where the UI and API are guaranteed to be served.
  mgmt_nodes   = range(min(var.node_count, 3))
  worker_nodes = range(3, var.node_count)

  # The VIP is listed FIRST deliberately. An explicit tls-san replaces whatever
  # supplies it implicitly on a joined node -- listing only the load balancer
  # names silently removes the VIP from that node's certificate.
  tls_sans = local.nlb_enabled ? concat(
    [var.vip_address, aws_lb.mgmt[0].dns_name],
    local.nlb_public ? [aws_eip.nlb[0].public_ip] : []
  ) : []

  # Always the VIP, never the load balancer. A Network Load Balancer does not
  # support hairpinning: a registered target cannot connect to the load balancer
  # it belongs to, and disabling client IP preservation does NOT lift that --
  # verified on a live cluster, where a joining node timed out on
  # https://<nlb>/cacerts either way while the same request from outside the VPC
  # succeeded.
  #
  # So joining nodes must reach the control plane directly, which means the VIP,
  # which means cluster expansion still depends on node 1 being alive. Fixing
  # that needs an address that can actually move -- see the aws-vpc-move-ip note
  # in the readme -- not a load balancer.
  join_endpoint = "https://${var.vip_address}:443"
}

data "aws_ssm_parameter" "ami" {
  count = var.ami_id == "" ? 1 : 0
  name  = var.ami_ssm_parameter
}

# --- Admin access ------------------------------------------------------------

resource "aws_ec2_managed_prefix_list" "admin" {
  name           = "${var.name_prefix}-admin"
  address_family = "IPv4"
  # Sized to what was actually given. max_entries -- not the entry count -- is
  # what counts against a security group's rule quota, once per referencing rule.
  max_entries = length(var.admin_cidrs)

  dynamic "entry" {
    for_each = var.admin_cidrs
    content {
      cidr        = entry.value
      description = "Admin CIDR ${entry.key + 1}"
    }
  }

  tags = { Name = "${var.name_prefix}-admin" }
}

# --- Security groups ---------------------------------------------------------

resource "aws_security_group" "nodes" {
  name        = "${var.name_prefix}-nodes"
  description = "Harvester nodes"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name_prefix}-nodes" }
}

resource "aws_vpc_security_group_ingress_rule" "admin" {
  for_each = { for p in [22, 80, 443, 6443] : tostring(p) => p }

  security_group_id = aws_security_group.nodes.id
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  prefix_list_id    = aws_ec2_managed_prefix_list.admin.id
  description       = "Admin access ${each.key}"
}

# etcd (2379-2380), the kubelet (10250), Longhorn (3260, 9500-9504) and
# kube-ovn's GENEVE tunnels (UDP 6081) all run node to node; enumerating them is
# more trouble than it is worth. Needed even on a single node -- kube-ovn tunnels
# to itself.
resource "aws_vpc_security_group_ingress_rule" "node_to_node" {
  security_group_id            = aws_security_group.nodes.id
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.nodes.id
  description                  = "All traffic between cluster nodes"
}

# Pairs with a VPC route sending the overlay CIDR at a node and with
# source/destination checking disabled. All three are required; missing any one
# drops the traffic silently.
resource "aws_vpc_security_group_ingress_rule" "overlay_clients" {
  count = var.overlay_client_cidr != "" ? 1 : 0

  security_group_id = aws_security_group.nodes.id
  ip_protocol       = "-1"
  cidr_ipv4         = var.overlay_client_cidr
  description       = "Clients allowed to reach overlay VMs"
}

# Terraform's aws_security_group REMOVES the default allow-all egress rule when
# no egress block is declared -- unlike CloudFormation's AWS::EC2::SecurityGroup,
# which leaves AWS's default in place. Without these the cluster fails in a
# thoroughly confusing way: node 1 comes up fine (inbound works, and its images
# are preloaded in the AMI so it needs nothing outbound), while nodes 2 and 3
# never join and every load balancer health check fails.
resource "aws_vpc_security_group_egress_rule" "nodes" {
  security_group_id = aws_security_group.nodes.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "All outbound"
}

resource "aws_vpc_security_group_egress_rule" "nlb" {
  count = local.nlb_enabled ? 1 : 0

  security_group_id = aws_security_group.nlb[0].id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "All outbound -- health checks to the targets"
}

resource "aws_security_group" "nlb" {
  count = local.nlb_enabled ? 1 : 0

  name        = "${var.name_prefix}-nlb"
  description = "Harvester management load balancer"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name_prefix}-nlb" }
}

resource "aws_vpc_security_group_ingress_rule" "nlb_ports" {
  for_each = local.nlb_enabled ? { for p in concat([443], local.cp_via_nlb ? [6443] : []) : tostring(p) => p } : {}

  security_group_id = aws_security_group.nlb[0].id
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  prefix_list_id    = aws_ec2_managed_prefix_list.admin.id
  description       = "Management ${each.key}"
}

# Health checks come from the load balancer's own addresses, not the client's,
# so they need their own rule. Client traffic still arrives with the real source
# address (client IP preservation is on by default for instance targets), so
# admin_cidrs remains the actual access control at the node.
resource "aws_vpc_security_group_ingress_rule" "nlb_health" {
  for_each = local.nlb_enabled ? { for p in concat([443], local.cp_via_nlb ? [6443] : []) : tostring(p) => p } : {}

  security_group_id            = aws_security_group.nodes.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = aws_security_group.nlb[0].id
  description                  = "NLB health checks ${each.key}"
}

# --- Nodes -------------------------------------------------------------------

resource "aws_instance" "node" {
  count = var.node_count

  ami                    = local.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.nodes.id]
  key_name               = var.key_name
  source_dest_check      = !var.disable_source_dest_check

  # Opt-in per instance. Without it there is no /dev/kvm even on a supported
  # instance type, and KubeVirt cannot run guests.
  cpu_options {
    nested_virtualization = "enabled"
  }

  # IMDSv2 only; /oem/aws/configure.sh does the token handshake. Hop limit 2 so
  # pods can reach IMDS.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_size = var.volume_size
    volume_type = "gp3"
  }

  # Only node 1 carries the VIP, as a secondary private address.
  secondary_private_ips = count.index == 0 ? [var.vip_address] : []

  user_data = templatefile("${path.module}/user-data.tftpl", {
    cluster_token = var.cluster_token
    mode          = count.index == 0 ? "create" : "join"
    role          = count.index >= 3 ? "worker" : ""
    server_url    = count.index == 0 ? "" : local.join_endpoint
    vip           = var.vip_address
    replica_count = var.replica_count
    mtu           = var.mtu
    password_hash = var.password_hash
    tls_sans      = local.tls_sans
  })

  # User-data is only read once, at first boot, so a change means a new node.
  user_data_replace_on_change = true

  tags = {
    Name          = "${var.name_prefix}-node-${count.index + 1}"
    HarvesterRole = count.index == 0 ? "create" : (count.index >= 3 ? "worker" : "join")
  }
}
