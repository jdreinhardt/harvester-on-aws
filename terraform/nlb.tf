# =============================================================================
# Management endpoint
#
# 443 always; 6443 and 9345 only with control_plane_via_nlb, because they need an
# AMI whose configure.sh writes the RKE2 tls-san drop-in on every node.
#
# harvester-installer writes the config carrying tls-san only on the bootstrap
# node (`if config.ServerURL == ""`). Measured on a live three-node cluster, the
# VIP still reaches every node by some other, special-cased route -- but SANs set
# through `sans` reach only node 1. Balancing the control plane on such an image
# succeeds only while the balancer picks node 1 and fails verification the rest
# of the time. configure.sh writing the drop-in itself is what fixes it.
# =============================================================================

resource "aws_eip" "nlb" {
  count  = local.nlb_public ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-mgmt" }
}

resource "aws_lb" "mgmt" {
  count = local.nlb_enabled ? 1 : 0

  name               = "${var.name_prefix}-mgmt"
  load_balancer_type = "network"
  internal           = !local.nlb_public
  security_groups    = [aws_security_group.nlb[0].id]

  subnet_mapping {
    subnet_id     = var.subnet_id
    allocation_id = local.nlb_public ? aws_eip.nlb[0].id : null
  }

  tags = { Name = "${var.name_prefix}-mgmt" }
}

locals {
  # An HTTPS probe rather than a TCP connect: the ports accept connections well
  # before anything is serving, and a bare connect would mark a node healthy
  # part-way through its bootstrap.
  #
  # 6443 matches 401, not 200. Every kube-apiserver endpoint requires
  # authentication and answers 401 unauthenticated, so a 401 proves it is
  # serving; 200 would never pass. 9345 /ping answers 200 "pong" unauthenticated.
  target_groups = merge(
    { ui = { port = 443, path = "/ping", matcher = "200" } },
    local.cp_via_nlb ? {
      api        = { port = 6443, path = "/readyz", matcher = "401" }
      supervisor = { port = 9345, path = "/ping", matcher = "200" }
    } : {}
  )
}

resource "aws_lb_target_group" "mgmt" {
  for_each = local.nlb_enabled ? local.target_groups : {}

  name        = "${var.name_prefix}-${each.key}"
  vpc_id      = var.vpc_id
  port        = each.value.port
  protocol    = "TCP"
  target_type = "instance"

  health_check {
    protocol            = "HTTPS"
    path                = each.value.path
    matcher             = each.value.matcher
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "${var.name_prefix}-${each.key}" }
}

resource "aws_lb_target_group_attachment" "mgmt" {
  for_each = local.nlb_enabled ? {
    for pair in setproduct(keys(local.target_groups), local.mgmt_nodes) :
    "${pair[0]}-${pair[1]}" => { tg = pair[0], node = pair[1] }
  } : {}

  target_group_arn = aws_lb_target_group.mgmt[each.value.tg].arn
  target_id        = aws_instance.node[each.value.node].id
  port             = local.target_groups[each.value.tg].port
}

resource "aws_lb_listener" "mgmt" {
  for_each = local.nlb_enabled ? local.target_groups : {}

  load_balancer_arn = aws_lb.mgmt[0].arn
  protocol          = "TCP"
  port              = each.value.port

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mgmt[each.key].arn
  }
}
