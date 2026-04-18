resource "kubernetes_namespace" "kserve_test" {
  count = var.deploy_test ? 1 : 0

  metadata {
    name = "kserve-test"

    labels = {
      "istio-injection"                    = "enabled"
      "serving.kserve.io/inferenceservice" = "enabled"
    }
  }

  depends_on = [module.eks]
}

resource "kubectl_manifest" "sklearn_iris_test" {
  count = var.deploy_test ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: "serving.kserve.io/v1beta1"
    kind: "InferenceService"
    metadata:
      name: "iris"
      namespace: kserve-test
    spec:
      predictor:
        annotations:
          prometheus.kserve.io/port: "8080"
          prometheus.kserve.io/path: /metrics
        minReplicas: 2
        maxReplicas: ${var.cpu_node_max}
        model:
          modelFormat:
            name: sklearn
          storageUri: "gs://kfserving-examples/models/sklearn/1.0/model"
          resources:
            requests:
              cpu: "100m"
              memory: "512Mi"
            limits:
              cpu: "1"
              memory: "1Gi"
  YAML

  depends_on = [
    kubectl_manifest.kserve_cluster_resources,
    kubernetes_namespace.kserve_test,
  ]
}

# vLLM ClusterServingRuntime — not included in default kserve-cluster-resources
resource "kubectl_manifest" "vllm_serving_runtime" {
  count = var.deploy_test ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: serving.kserve.io/v1alpha1
    kind: ClusterServingRuntime
    metadata:
      name: kserve-vllm
    spec:
      annotations:
        prometheus.kserve.io/port: "8080"
        prometheus.kserve.io/path: /metrics
      supportedModelFormats:
        - name: vLLM
          version: "1"
          autoSelect: true
      protocolVersions:
        - v2
        - grpc-v2
      containers:
        - name: kserve-container
          image: vllm/vllm-openai:v0.8.3
          command: ["python3", "-m", "vllm.entrypoints.openai.api_server"]
          args:
            - --model=/mnt/models
            - --served-model-name=model
            - --port=8080
          ports:
            - containerPort: 8080
              protocol: TCP
  YAML

  depends_on = [kubectl_manifest.kserve]
}

resource "kubectl_manifest" "phi3_gpu_test" {
  count = var.deploy_test ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: serving.kserve.io/v1beta1
    kind: InferenceService
    metadata:
      name: llm1
      namespace: kserve-test
      annotations:
        # Allow up to ${floor(var.knative_progress_deadline / 60)} min for GPU node scale-up + driver init + image pull + model download
        serving.knative.dev/progress-deadline: "${var.knative_progress_deadline}s"
    spec:
      predictor:
        minReplicas: 0
        maxReplicas: ${var.gpu_node_max}
        # Per-request timeout — must be long enough for the full cold-start
        # chain (node scale-up + image pull + model download + vLLM init).
        # Knative default is 300s (5 min) which is too short for GPU cold starts.
        timeout: ${var.knative_progress_deadline}
        model:
          modelFormat:
            name: vLLM
          runtime: kserve-vllm
          storageUri: hf://microsoft/Phi-3-mini-4k-instruct
          resources:
            requests:
              cpu: "2"
              memory: "8Gi"
              nvidia.com/gpu: "1"
            limits:
              cpu: "4"
              memory: "16Gi"
              nvidia.com/gpu: "1"
        tolerations:
          - key: nvidia.com/gpu
            operator: Exists
            effect: NoSchedule
  YAML

  depends_on = [
    kubectl_manifest.vllm_serving_runtime,
    kubernetes_namespace.kserve_test,
  ]
}
