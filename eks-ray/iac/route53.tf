# =============================================================================
# Route 53 — public DNS for the cluster's external services
# =============================================================================
# All cluster endpoints alias the ALB fronting the corresponding ingress.
#
# Hostname scheme:
#   grafana.<domain>          → monitoring ALB
#   mlflow.<domain>            → mlflow ALB (when install_mlflow=true)
#   *.ray.<domain>             → ray-group ALB (ray-dashboard, ray-serve,
#                                and any future RayService hostnames)

data "aws_route53_zone" "main" {
  zone_id = var.route53_zone_id
}

locals {
  # Strip the trailing dot Route 53 returns on zone names.
  public_domain = trimsuffix(data.aws_route53_zone.main.name, ".")
}

# Look up the shared ray-group ALB provisioned by the AWS Load Balancer
# Controller from the ray-dashboard / ray-serve ingresses. Both ingresses
# use alb.ingress.kubernetes.io/group.name=ray-group so they share one ALB.
data "aws_lbs" "ray_group" {
  tags = {
    "ingress.k8s.aws/stack" = "ray-group"
  }

  depends_on = [kubernetes_ingress_v1.ray_dashboard, kubernetes_ingress_v1.ray_serve]
}

data "aws_lb" "ray_group" {
  count = length(data.aws_lbs.ray_group.arns) > 0 ? 1 : 0
  arn   = tolist(data.aws_lbs.ray_group.arns)[0]
}

# Wildcard — any RayService endpoint published under *.ray.<domain> resolves
# automatically. The Ingress's `host` field selects which service the ALB
# forwards to.
resource "aws_route53_record" "ray_wildcard" {
  count = length(data.aws_lb.ray_group) > 0 ? 1 : 0

  zone_id         = data.aws_route53_zone.main.zone_id
  name            = "*.ray.${local.public_domain}"
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = data.aws_lb.ray_group[0].dns_name
    zone_id                = data.aws_lb.ray_group[0].zone_id
    evaluate_target_health = false
  }
}

# Grafana ALB — created by kubernetes_ingress_v1.grafana in monitoring.tf.
data "aws_lbs" "grafana" {
  tags = {
    "ingress.k8s.aws/stack" = "monitoring/grafana"
  }

  depends_on = [kubernetes_ingress_v1.grafana]
}

data "aws_lb" "grafana" {
  count = length(data.aws_lbs.grafana.arns) > 0 ? 1 : 0
  arn   = tolist(data.aws_lbs.grafana.arns)[0]
}

resource "aws_route53_record" "grafana" {
  count = length(data.aws_lb.grafana) > 0 ? 1 : 0

  zone_id         = data.aws_route53_zone.main.zone_id
  name            = "grafana.${local.public_domain}"
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = data.aws_lb.grafana[0].dns_name
    zone_id                = data.aws_lb.grafana[0].zone_id
    evaluate_target_health = false
  }
}

# Canonical ALB hosted zone ID for this region. Lives at the root (not
# inside module.mlflow) so Terraform reads it at plan time — module-local
# data sources get deferred to apply, producing spurious "known after apply"
# diffs on the alias zone_id.
data "aws_lb_hosted_zone_id" "alb" {}

# MLflow ALB — the module's Ingress waits for LB reconciliation, so
# alb_dns_name is guaranteed to be set by the time this record is created.
resource "aws_route53_record" "mlflow" {
  count = var.install_mlflow ? 1 : 0

  zone_id         = data.aws_route53_zone.main.zone_id
  name            = "mlflow.${local.public_domain}"
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = module.mlflow[0].alb_dns_name
    zone_id                = data.aws_lb_hosted_zone_id.alb.id
    evaluate_target_health = false
  }
}
