# =============================================================================
# Argo CD — Per-team AppProjects (multi-tenant KServe)
# =============================================================================
# Driven by var.teams — the same variable namespaces.tf uses. An AppProject
# is created only for teams whose source_repos list is non-empty; teams with
# an empty source_repos still get a namespace + quotas but no AppProject,
# useful for non-GitOps namespaces.
#
# Each AppProject is pinned to the team's one destination namespace and the
# team's whitelisted repos. Teams' Application CRs must set
# spec.project: <team-ns>  to inherit the guardrails — an Application left on
# the `default` project bypasses them. That's an ArgoCD design choice, not
# something we can enforce from here. Pair with a Kyverno policy if you need
# the project field enforced.

locals {
  # Only teams with a non-empty source_repos get an AppProject. Also gate on
  # install_argocd so we don't try to create the CR before the CRDs exist.
  argocd_project_teams = var.install_argocd ? {
    for name, cfg in var.teams : name => cfg if length(cfg.source_repos) > 0
  } : {}
}

resource "kubectl_manifest" "team_appproject" {
  for_each = local.argocd_project_teams

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"
    metadata = {
      name      = each.key
      namespace = kubernetes_namespace.argocd[0].metadata[0].name
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
        "team"                         = each.key
      }
    }
    spec = {
      description = "Scoped to namespace ${each.key}."

      # Explicit repo list — a wildcard here would let any team sync from any
      # repo the argocd-repo-server can reach, including other teams' repos.
      sourceRepos = each.value.source_repos

      destinations = [{
        server    = "https://kubernetes.default.svc"
        namespace = kubernetes_namespace.team[each.key].metadata[0].name
      }]

      # No cluster-scoped resources — ClusterServingRuntime, CRDs, RBAC, etc.
      # stay admin-only. Add entries here if a team genuinely needs one.
      clusterResourceWhitelist = []

      # Minimal surface. Extend per team as needed — e.g. HPA, PVC, Service
      # if they start running sidecars alongside the InferenceService.
      namespaceResourceWhitelist = [
        { group = "serving.kserve.io", kind = "InferenceService" },
        { group = "serving.kserve.io", kind = "ServingRuntime" },
        { group = "", kind = "ConfigMap" },
        { group = "", kind = "Secret" },
      ]

      # Only emit a role block when groups are provided. An empty groups list
      # still creates a role that nobody is bound to, which is noise.
      roles = length(each.value.oidc_groups) > 0 ? [{
        name        = "developer"
        description = "Sync + get on Applications in ${each.key}."
        groups      = each.value.oidc_groups
        policies = [
          "p, proj:${each.key}:developer, applications, sync, ${each.key}/*, allow",
          "p, proj:${each.key}:developer, applications, get,  ${each.key}/*, allow",
        ]
      }] : []
    }
  })

  depends_on = [
    helm_release.argocd,
    kubernetes_namespace.team,
  ]
}
