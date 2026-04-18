# EKS cluster for Kserve
Installs an EKS cluster with installed Kserve CRDs (custom resource defintion)


## Architecture – Inference Request Path

```mermaid
flowchart TB
    client([Client])

    subgraph aws["AWS"]
        r53["Route 53<br/>*.kserve.domain → NLB"]
        nlb["Network Load Balancer<br/>(cross-zone, TCP keepalive)"]

        subgraph eks["EKS Cluster"]
            subgraph istio["Istio Service Mesh"]
                igw["Istio Ingress Gateway<br/>Host-based routing via VirtualService"]
            end

            subgraph knative["Knative Serving"]
                activator["Knative Activator<br/>(buffers requests during scale-from-zero)"]
                autoscaler["Knative Autoscaler<br/>(scale-to-zero, target 200 RPS)"]
            end

            subgraph gpu_ng["GPU Node Group (g5.2xlarge – 1x A10G, 0-2 nodes)"]
                subgraph gpu_pod["GPU Inference Pod"]
                    qp["Queue Proxy<br/>(concurrency control, metrics)"]
                    vllm["vLLM OpenAI API<br/>(model server, port 8080)"]
                    init["Storage Initializer<br/>(pulls model on pod start)"]
                end
            end

            subgraph cpu_ng["CPU Node Group (m6i.2xlarge – 8 vCPU, 0-10 nodes)"]
                subgraph cpu_pod["CPU Inference Pod"]
                    qp2["Queue Proxy<br/>(concurrency control, metrics)"]
                    sklearn["sklearn / xgboost / …<br/>(model server, port 8080)"]
                    init2["Storage Initializer<br/>(pulls model on pod start)"]
                end
            end

            cas["Cluster Autoscaler<br/>(scales GPU/CPU node groups)"]
        end

        s3["S3<br/>Model Artifacts"]
        efs["EFS<br/>Model Weight Cache"]
    end

    hf["HuggingFace Hub<br/>(model source)"]

    client -->|"HTTPS"| r53
    r53 --> nlb
    nlb -->|"TCP :8080"| igw
    igw --> activator
    activator --> qp
    activator --> qp2
    autoscaler -.-|"scales pods"| gpu_pod
    autoscaler -.-|"scales pods"| cpu_pod
    cas -.-|"scales nodes"| gpu_ng
    cas -.-|"scales nodes"| cpu_ng
    qp --> vllm
    qp2 --> sklearn
    init -->|"download weights"| s3
    init -->|"download weights"| hf
    init2 -->|"download model"| s3
    vllm -->|"read cached weights"| efs
    init -->|"cache weights"| efs

    style aws fill:#f7f7f7,stroke:#232f3e
    style eks fill:#e8f4f8,stroke:#1a73e8
    style istio fill:#466bb0,stroke:#466bb0,color:#fff
    style knative fill:#0865ad,stroke:#0865ad,color:#fff
    style gpu_ng fill:#fff3e0,stroke:#e65100
    style cpu_ng fill:#e8eaf6,stroke:#283593
    style gpu_pod fill:#e6ffe6,stroke:#2d8a2d
    style cpu_pod fill:#e6ffe6,stroke:#2d8a2d
    style igw color:#fff
    style activator color:#fff
    style autoscaler color:#fff
```

**Request flow:** Client → Route 53 (wildcard DNS) → NLB → Istio Ingress Gateway → Knative Activator (wakes pods if scaled to zero) → Queue Proxy sidecar → vLLM model server. On cold start, the Storage Initializer pulls model weights from S3 or HuggingFace and caches them on EFS. The Knative Autoscaler manages pod scaling (including scale-to-zero) while the Cluster Autoscaler provisions or removes GPU/CPU nodes as needed.

## Configuration

Copy the example file and fill in your values:

```
cp terraform.tfvars.example terraform.tfvars
```

Set the following variables in `terraform.tfvars`:

- **route53_zone_id** – The ID of your Route 53 hosted zone for the public domain. Find it with `aws route53 list-hosted-zones`. The domain name is derived from the zone automatically.

The file is gitignored, so your secrets stay local.

## Usage

```
cd model_serve_poc/eks-kserve/iac
terraform init
terraform apply
```

Delete cluster
```
terraform destroy
```
