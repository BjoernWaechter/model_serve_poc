# Destroy-time cleanup of resources created outside Terraform by Kubernetes
# controllers and Karpenter. Without this, ENIs from ALBs, EFS mount
# targets, Karpenter-provisioned EC2 instances, and PVCs block VPC subnet
# and security-group deletion during `terraform destroy`.
resource "null_resource" "cleanup_before_destroy" {
  depends_on = [module.eks]

  triggers = {
    cluster_name = var.cluster_name
    region       = var.region
    endpoint     = module.eks.cluster_endpoint
    ca_data      = module.eks.cluster_certificate_authority_data
    vpc_id       = module.vpc.vpc_id
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -e

      # Authenticate to the cluster the same way the Terraform providers do —
      # no dependency on ~/.kube/config.
      CA_FILE=$(mktemp)
      echo "${self.triggers.ca_data}" | base64 -d > "$CA_FILE"
      trap "rm -f $CA_FILE" EXIT

      EKS_TOKEN=$(aws eks get-token \
        --cluster-name "${self.triggers.cluster_name}" \
        --region "${self.triggers.region}" \
        --output json | jq -r '.status.token')

      export KUBECTL="kubectl --server=${self.triggers.endpoint} --certificate-authority=$CA_FILE --token=$EKS_TOKEN"

      echo "=== Removing webhooks that block resource deletion ==="
      $KUBECTL delete validatingwebhookconfigurations --all --timeout=30s || true
      $KUBECTL delete mutatingwebhookconfigurations --all --timeout=30s || true

      echo "=== Deleting RayService / RayCluster workloads ==="
      # Deleting the RayService CRs first lets KubeRay drain pods cleanly so
      # Karpenter reclaims GPU nodes before we scale ASGs.
      $KUBECTL delete rayservices.ray.io --all --all-namespaces --timeout=120s || true
      $KUBECTL delete rayclusters.ray.io --all --all-namespaces --timeout=120s || true

      # Give KubeRay a moment to reconcile deletions and finalize pods.
      sleep 15

      echo "=== Deleting Karpenter NodePools / NodeClaims ==="
      # Karpenter-provisioned instances are not in ASGs; deleting the
      # NodeClaims returns them via the Karpenter controller's finalizers.
      $KUBECTL delete nodepool --all --timeout=60s || true
      $KUBECTL delete ec2nodeclass --all --timeout=60s || true
      $KUBECTL delete nodeclaims --all --timeout=120s || true

      echo "=== Deleting PVCs to release EBS volumes ==="
      $KUBECTL delete pvc --all --all-namespaces --timeout=60s || true

      echo "=== Deleting LoadBalancer services and Ingresses (releases ALB ENIs) ==="
      $KUBECTL delete svc --field-selector spec.type=LoadBalancer \
        --all-namespaces --timeout=120s || true
      $KUBECTL delete ingress --all --all-namespaces --timeout=120s || true

      # Fallback: delete ALBs/NLBs via AWS API in case the LB controller is
      # already gone and couldn't deprovision them.
      echo "=== Deleting remaining load balancers in VPC via AWS API ==="
      LB_ARNS=$(aws elbv2 describe-load-balancers \
        --region ${self.triggers.region} \
        --query "LoadBalancers[].LoadBalancerArn" --output text)
      for arn in $LB_ARNS; do
        LB_VPC=$(aws elbv2 describe-load-balancers \
          --region ${self.triggers.region} \
          --load-balancer-arns "$arn" \
          --query "LoadBalancers[0].VpcId" --output text 2>/dev/null)
        if [ "$LB_VPC" = "${self.triggers.vpc_id}" ]; then
          echo "Deleting load balancer $arn"
          aws elbv2 delete-load-balancer \
            --region ${self.triggers.region} \
            --load-balancer-arn "$arn" || true
        fi
      done

      # Wait for LB ENIs to detach.
      echo "Waiting for load balancer ENIs to release..."
      for i in $(seq 1 12); do
        ENIS=$(aws ec2 describe-network-interfaces \
          --region ${self.triggers.region} \
          --filters "Name=vpc-id,Values=${self.triggers.vpc_id}" "Name=association.public-ip,Values=*" \
          --query "NetworkInterfaces[].NetworkInterfaceId" --output text)
        if [ -z "$ENIS" ]; then
          echo "All public IPs released"
          break
        fi
        echo "ENIs still attached ($i/12): $ENIS"
        sleep 10
      done

      echo "=== Scaling managed-node-group ASGs to zero ==="
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

      echo "=== Terminating any remaining Karpenter instances ==="
      # Karpenter tags instances with karpenter.sh/nodepool; catch any left
      # behind after NodeClaim deletion.
      KARP_INSTANCES=$(aws ec2 describe-instances \
        --region ${self.triggers.region} \
        --filters "Name=vpc-id,Values=${self.triggers.vpc_id}" \
                  "Name=tag-key,Values=karpenter.sh/nodepool" \
                  "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query "Reservations[].Instances[].InstanceId" --output text)
      if [ -n "$KARP_INSTANCES" ]; then
        echo "Terminating Karpenter instances: $KARP_INSTANCES"
        aws ec2 terminate-instances \
          --region ${self.triggers.region} \
          --instance-ids $KARP_INSTANCES || true
      fi

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
