resource "helm_release" "gpu_operator" {
  name             = "gpu-operator"
  repository       = "https://helm.ngc.nvidia.com/nvidia"
  chart            = "gpu-operator"
  version          = "v23.9.1"
  namespace        = "gpu-operator"
  create_namespace = true

  # Bottlerocket NVIDIA variant (auto-selected by Karpenter for GPU nodes)
  # ships with drivers and container toolkit pre-installed — only the device
  # plugin and DCGM exporter are needed from the operator.
  set {
    name  = "driver.enabled"
    value = "false"
  }

  set {
    name  = "toolkit.enabled"
    value = "false"
  }

  set {
    name  = "devicePlugin.enabled"
    value = "true"
  }

  set {
    name  = "dcgmExporter.enabled"
    value = "true"
  }

  # Bottlerocket uses systemd cgroup management which triggers
  # https://github.com/NVIDIA/gpu-operator/issues/430 — disable the
  # /dev/char symlink creation that the validator requires.
  set {
    name  = "validator.driver.env[0].name"
    value = "DISABLE_DEV_CHAR_SYMLINK_CREATION"
  }

  set {
    name  = "validator.driver.env[0].value"
    value = "true"
    type  = "string"
  }

  set {
    name  = "node-feature-discovery.worker.tolerations[0].key"
    value = "nvidia.com/gpu"
  }

  set {
    name  = "node-feature-discovery.worker.tolerations[0].operator"
    value = "Exists"
  }

  set {
    name  = "node-feature-discovery.worker.tolerations[0].effect"
    value = "NoSchedule"
  }

  depends_on = [module.eks, time_sleep.wait_k8s_ready]
}
