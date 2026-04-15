# Clean up resources created outside Terraform (by Kubernetes controllers and
# autoscalers) before destroying the infrastructure. Without this, ENIs from
# load balancers, EFS mount targets, and autoscaled instances block VPC
# subnet and security-group deletion.
resource "null_resource" "cleanup_before_destroy" {
  depends_on = [module.eks]

  triggers = {
    cluster_name = var.cluster_name
    region       = var.aws_region
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -e

      echo "=== Removing webhooks that block resource deletion ==="
      kubectl delete validatingwebhookconfigurations --all --timeout=30s || true
      kubectl delete mutatingwebhookconfigurations --all --timeout=30s || true

      echo "=== Removing Kubernetes finalizers and workloads ==="
      # Delete all InferenceServices so pods terminate and nodes can drain
      kubectl delete inferenceservices --all --all-namespaces --timeout=60s || true

      # Delete all PVCs to release EBS volumes (reclaim_policy=Retain leaves them)
      kubectl delete pvc --all --all-namespaces --timeout=60s || true

      echo "=== Deleting LoadBalancer services (releases NLB ENIs) ==="
      kubectl delete svc --field-selector spec.type=LoadBalancer \
        --all-namespaces --timeout=120s || true

      # Wait for NLB ENIs to detach
      echo "Waiting for load balancer ENIs to release..."
      sleep 30

      echo "=== Scaling ASGs to zero ==="
      for asg in $(aws autoscaling describe-auto-scaling-groups \
        --region ${self.triggers.region} \
        --query "AutoScalingGroups[?contains(Tags[?Key=='eks:cluster-name'].Value, '${self.triggers.cluster_name}')].AutoScalingGroupName" \
        --output text); do
        echo "Scaling $asg to 0"
        aws autoscaling update-auto-scaling-group \
          --region ${self.triggers.region} \
          --auto-scaling-group-name "$asg" \
          --min-size 0 --max-size 0 --desired-capacity 0
      done

      echo "=== Waiting for instances to terminate ==="
      sleep 30
      for i in $(seq 1 20); do
        INSTANCES=$(aws autoscaling describe-auto-scaling-groups \
          --region ${self.triggers.region} \
          --query "AutoScalingGroups[?contains(Tags[?Key=='eks:cluster-name'].Value, '${self.triggers.cluster_name}')] | [].Instances[].InstanceId" \
          --output text)
        if [ -z "$INSTANCES" ]; then
          echo "All instances terminated"
          break
        fi
        echo "Waiting for instances to terminate ($i/20): $INSTANCES"
        sleep 15
      done
    EOT
  }
}
