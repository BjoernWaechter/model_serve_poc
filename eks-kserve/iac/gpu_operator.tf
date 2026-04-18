resource "helm_release" "gpu_operator" {
  name             = "gpu-operator"
  repository       = "https://helm.ngc.nvidia.com/nvidia"
  chart            = "gpu-operator"
  version          = "v23.9.1"
  namespace        = "gpu-operator"
  create_namespace = true

  values = [
    yamlencode({
      # AL2023_x86_64_NVIDIA AMI ships with drivers and container runtime
      # pre-installed — only the device plugin and DCGM exporter are needed.
      driver        = { enabled = false }
      toolkit       = { enabled = false }
      devicePlugin  = { enabled = true }
      dcgmExporter  = { enabled = true }

      # AL2023_x86_64_NVIDIA uses systemd cgroup management which triggers
      # https://github.com/NVIDIA/gpu-operator/issues/430 — disable the
      # /dev/char symlink creation that the validator requires.
      validator = {
        driver = {
          env = [{
            name  = "DISABLE_DEV_CHAR_SYMLINK_CREATION"
            value = "true"
          }]
        }
      }

      # Pin the operator deployment to the system MNG. Without this it stays
      # Pending on a cluster whose only non-GPU nodes carry CriticalAddonsOnly.
      operator = {
        nodeSelector = { role = "system" }
        tolerations = [{
          key      = "CriticalAddonsOnly"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }]
      }

      "node-feature-discovery" = {
        # NFD master + gc are Deployments — schedule on system nodes.
        master = {
          nodeSelector = { role = "system" }
          tolerations = [{
            key      = "CriticalAddonsOnly"
            operator = "Equal"
            value    = "true"
            effect   = "NoSchedule"
          }]
        }
        gc = {
          nodeSelector = { role = "system" }
          tolerations = [{
            key      = "CriticalAddonsOnly"
            operator = "Equal"
            value    = "true"
            effect   = "NoSchedule"
          }]
        }
        # NFD worker is a DaemonSet that needs to run on GPU nodes to label them.
        worker = {
          tolerations = [{
            key      = "nvidia.com/gpu"
            operator = "Exists"
            effect   = "NoSchedule"
          }]
        }
      }
    })
  ]

  depends_on = [module.eks]
}
