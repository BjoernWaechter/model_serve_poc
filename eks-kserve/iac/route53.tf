# =============================================================================
# Route 53 — public DNS for the cluster's external services
# =============================================================================
# All three subdomains alias the same Istio NLB. Istio routes by the Host
# header set in each VirtualService (Grafana directly, llm1/iris via KServe's
# auto-generated routes once domainTemplate=={{.Name}}.{{.IngressDomain}}).

data "aws_route53_zone" "main" {
  zone_id = var.route53_zone_id
}

# Look up the NLB created by the AWS Load Balancer Controller for the Istio
# ingress service. The controller tags it with the originating service name.
data "aws_lbs" "istio_ingress" {
  tags = {
    "service.k8s.aws/stack" = "istio-system/istio-ingress"
  }

  depends_on = [helm_release.istio_ingress]
}

data "aws_lb" "istio_ingress" {
  arn = tolist(data.aws_lbs.istio_ingress.arns)[0]
}

locals {
  # Public domain derived from the Route 53 hosted zone (e.g. "awswaechterei.de").
  # The Route 53 API returns zone names with a trailing dot, which we strip so
  # the value can be interpolated cleanly into hostnames and URLs.
  public_domain = trimsuffix(data.aws_route53_zone.main.name, ".")

  # Root-level single-label subdomains (e.g., grafana.<domain>). Each entry
  # here needs a matching VirtualService in the cluster that filters on the
  # Host header.
  root_subdomains = ["grafana"]
}

resource "aws_route53_record" "root_subdomain" {
  for_each = toset(local.root_subdomains)

  zone_id = data.aws_route53_zone.main.zone_id
  name    = "${each.key}.${local.public_domain}"
  type    = "A"
  # Adopt existing records left by prior partial applies instead of failing
  # with InvalidChangeBatch. Safe because the alias target is deterministic
  # (the Istio NLB looked up by tag).
  allow_overwrite = true

  alias {
    name                   = data.aws_lb.istio_ingress.dns_name
    zone_id                = data.aws_lb.istio_ingress.zone_id
    evaluate_target_health = false
  }
}

# Wildcard for *.kserve.<domain> — every KServe InferenceService resolves
# automatically (llm1.kserve.<domain>, iris.kserve.<domain>, any future
# services). No per-service DNS records, no Terraform churn when a team
# deploys a new model.
resource "aws_route53_record" "kserve_wildcard" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "*.kserve.${local.public_domain}"
  type    = "A"
  allow_overwrite = true

  alias {
    name                   = data.aws_lb.istio_ingress.dns_name
    zone_id                = data.aws_lb.istio_ingress.zone_id
    evaluate_target_health = false
  }
}

# Canonical ALB hosted zone ID for this region. Lives at the root (not
# inside module.mlflow) so Terraform reads it at plan time — module-local
# data sources get deferred to apply, producing spurious "known after apply"
# diffs on the alias zone_id.
data "aws_lb_hosted_zone_id" "alb" {}

# MLflow lives on its own ALB (provisioned by the LBC from the module's
# Ingress), separate from the Istio NLB that handles KServe traffic.
# The module's Ingress waits for LB reconciliation, so the alias target is
# guaranteed to be set by the time this record is created.
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

# Argo CD on its own ALB. Same alias-to-ALB pattern as mlflow — the Ingress
# blocks until the LBC has populated the hostname, so this record resolves
# on first apply.
resource "aws_route53_record" "argocd" {
  count = var.install_argocd ? 1 : 0

  zone_id         = data.aws_route53_zone.main.zone_id
  name            = "argocd.${local.public_domain}"
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = kubernetes_ingress_v1.argocd[0].status[0].load_balancer[0].ingress[0].hostname
    zone_id                = data.aws_lb_hosted_zone_id.alb.id
    evaluate_target_health = false
  }
}
