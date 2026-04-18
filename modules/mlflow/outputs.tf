output "namespace" {
  description = "Namespace the MLflow release was deployed into"
  value       = var.namespace
}

output "tracking_service" {
  description = "In-cluster MLflow tracking service (host:port)"
  value       = "mlflow-tracking.${var.namespace}.svc.cluster.local:80"
}

output "admin_user" {
  description = "MLflow admin username (from the chart-generated secret)"
  value       = try(nonsensitive(data.kubernetes_secret.mlflow.data["admin-user"]), "")
}

output "admin_password" {
  description = "MLflow admin password (from the chart-generated secret)"
  value       = try(data.kubernetes_secret.mlflow.data["admin-password"], "")
}

output "alb_dns_name" {
  description = "DNS name of the ALB fronting MLflow (known after apply — the Ingress blocks until the LBC populates status)"
  value       = kubernetes_ingress_v1.mlflow.status[0].load_balancer[0].ingress[0].hostname
}

# alb_zone_id intentionally lives outside the module — callers should use
# their own `data "aws_lb_hosted_zone_id"` data source in the root module.
# Putting it inside the module caused the data source to be deferred to
# apply (Terraform pessimistically treats module-local data sources as
# dependent on the module's own resources), producing spurious route53
# zone_id "known after apply" diffs on every plan.
