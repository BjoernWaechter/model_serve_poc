# EKS cluster for Ray Serve

Installs an EKS cluster with KubeRay + Ray Serve and the same production
infrastructure stack as the sister `eks-kserve` cluster.

## Architecture – Inference Request Path

```mermaid
flowchart TB
    client([Client])

    subgraph aws["AWS"]
        r53["Route 53<br/>*.ray.domain → ALB"]
        alb["Application Load Balancer<br/>(ray-group, long idle_timeout)"]

        subgraph eks["EKS Cluster"]
            subgraph kuberay["KubeRay"]
                operator["KubeRay Operator<br/>(reconciles RayService/RayCluster)"]
            end

            subgraph sys_ng["System Node Group (m6i.xlarge, 2-6 nodes)"]
                kuberay
                cas["Cluster Autoscaler"]
                karp_ctrl["Karpenter Controller"]
                mon["Prometheus + Grafana"]
            end

            subgraph cpu_ng["CPU Node Group (m6i.2xlarge, 1-5 nodes)"]
                head["Ray Head<br/>(dashboard :8265, serve :8000)"]
            end

            subgraph gpu_ng["GPU Nodes (Karpenter, g5.2xlarge)"]
                worker["Ray GPU Worker<br/>(Serve deployment replicas)"]
            end

            cas -.-|"scales"| sys_ng
            cas -.-|"scales"| cpu_ng
            karp_ctrl -.-|"provisions"| gpu_ng
            head -.-|"in-tree autoscaler"| worker
        end

        s3["S3<br/>Working Dir / Artifacts"]
        efs["EFS<br/>Model Weight Cache"]
    end

    client -->|"HTTPS"| r53
    r53 --> alb
    alb -->|"HTTP :80"| head
    head --> worker
    worker -->|"download weights"| s3
    worker -->|"read cached weights"| efs

    style aws fill:#f7f7f7,stroke:#232f3e
    style eks fill:#e8f4f8,stroke:#1a73e8
    style kuberay fill:#0865ad,stroke:#0865ad,color:#fff
    style gpu_ng fill:#fff3e0,stroke:#e65100
    style cpu_ng fill:#e8eaf6,stroke:#283593
    style sys_ng fill:#ede7f6,stroke:#512da8
    style operator color:#fff
```

**Request flow:** Client → Route 53 (`*.ray.<domain>`) → ALB (ray-group, long idle timeout for cold starts) → Ray head pod (`dashboard.ray.<domain>` → `:8265`, `serve.ray.<domain>` → `:8000`) → GPU worker (Karpenter-provisioned, Bottlerocket NVIDIA). On cold start, the worker downloads the Ray `working_dir` archive from S3 and caches model weights on EFS. Ray's in-tree autoscaler scales Serve replicas; Cluster Autoscaler manages the system/CPU ASGs; Karpenter provisions/consolidates GPU nodes.

## What's in here

| File | Purpose |
|------|---------|
| `vpc.tf` | 3-AZ private VPC with 9 subnets (system/cpu/gpu slices) + 3 NAT gateways |
| `data.tf` | AZ discovery, ECR token, GPU instance-type offering filter |
| `eks.tf` | EKS cluster (v1.33), managed node groups (system + cpu), CSI + Pod Identity addons |
| `iam.tf` | IRSA roles: EBS/EFS CSI, LB controller, Ray S3, Cluster Autoscaler |
| `autoscaler.tf` | Cluster Autoscaler (managed node groups only — Karpenter handles GPU) |
| `load_balancer.tf` | AWS Load Balancer Controller |
| `karpenter.tf` | Karpenter + GPU `EC2NodeClass` / `NodePool` (Bottlerocket NVIDIA, AZ-restricted) |
| `gpu_operator.tf` | NVIDIA GPU Operator (device plugin + DCGM exporter) |
| `storage.tf` | S3 artifact bucket, EFS cache, gp3 default StorageClass |
| `monitoring.tf` | kube-prometheus-stack + Ray/KubeRay/DCGM scrape configs, Grafana ALB |
| `keda.tf` | KEDA (optional event-driven autoscaling) |
| `namespaces.tf` | `ray-serve` namespace with quotas, limit range, IRSA-bound service account |
| `route53.tf` | `*.ray.<domain>`, `grafana.<domain>`, `mlflow.<domain>` wildcard/alias records |
| `ray_serve.tf` | KubeRay operator, Ray dashboard + serve services, shared ray-group ALB |
| `mlflow.tf` | Optional MLflow tracking server |
| `cleanup.tf` | Destroy-time hook: deletes RayServices, NodeClaims, PVCs, LBs; drains ASGs |
| `vars.tf` / `variables_scaling.tf` | All tunables |

## Configuration

Copy the example file and fill in your values:

```
cp terraform.tfvars.example terraform.tfvars
```

Set the following variables in `terraform.tfvars`:

- **route53_zone_id** – ID of your Route 53 hosted zone for the public domain. Find it with `aws route53 list-hosted-zones`. The domain name is derived from the zone automatically.

## Usage

```
cd model_serve_poc/eks-ray/iac
terraform init
terraform apply
```

Delete cluster:

```
terraform destroy
```
