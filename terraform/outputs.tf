output "management_url" {
  description = "Load-balanced management endpoint. Survives losing a node, unlike the VIP."
  value       = local.nlb_enabled ? "https://${aws_lb.mgmt[0].dns_name}" : "https://${var.vip_address}"
}

output "management_public_ip" {
  description = "Fixed public address of the management endpoint."
  value       = local.nlb_public ? aws_eip.nlb[0].public_ip : null
}

output "vip" {
  description = "Management VIP -- a secondary private address on node 1."
  value       = var.vip_address
}

output "ami_in_use" {
  value = local.ami_id
}

output "node_ids" {
  value = aws_instance.node[*].id
}

output "node_private_ips" {
  value = aws_instance.node[*].private_ip
}

output "security_group_id" {
  value = aws_security_group.nodes.id
}

output "admin_prefix_list_id" {
  description = "Edit this to change who may reach the cluster; no apply needed for a security group change."
  value       = aws_ec2_managed_prefix_list.admin.id
}

output "watch_bootstrap" {
  description = "Follow the first node coming up."
  value       = "./scripts/follow-console.sh --instance-id ${aws_instance.node[0].id} --tee console.txt"
}

# --- Ready-made user-data for adding a node by hand --------------------------
#
# The token is a placeholder rather than the real value: whoever adds a node
# already has it, and putting it here would leak it into `tofu output` and state
# in plain sight. Everything else is the fiddly part -- tls_sans, the bond
# options that work around ENA refusing a MAC change, the MTU that must be set
# at all, and server_url on port 443 so harv-update-rke2-server-url rewrites it
# to the supervisor's 9345.
#
# The instance itself still needs: the same AMI, nested virtualization enabled,
# IMDSv2, this security group and subnet, and a root volume of at least
# var.volume_size GiB.

output "join_user_data" {
  description = "User-data for manually adding a management node. Replace REPLACE_WITH_CLUSTER_TOKEN."
  value = templatefile("${path.module}/user-data.tftpl", {
    cluster_token = "REPLACE_WITH_CLUSTER_TOKEN"
    mode          = "join"
    role          = ""
    server_url    = local.join_endpoint
    vip           = var.vip_address
    replica_count = var.replica_count
    mtu           = var.mtu
    password_hash = ""
    tls_sans      = local.tls_sans
  })
}

output "worker_user_data" {
  description = "As join_user_data, plus install.role=worker so the node is never promoted."
  value = templatefile("${path.module}/user-data.tftpl", {
    cluster_token = "REPLACE_WITH_CLUSTER_TOKEN"
    mode          = "join"
    role          = "worker"
    server_url    = local.join_endpoint
    vip           = var.vip_address
    replica_count = var.replica_count
    mtu           = var.mtu
    password_hash = ""
    tls_sans      = local.tls_sans
  })
}
