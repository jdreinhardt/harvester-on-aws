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
