# Clean up resources created outside Terraform (by Kubernetes controllers and
# autoscalers) before destroying the infrastructure. Without this, ENIs from
# load balancers, EFS mount targets, and autoscaled instances block VPC
# subnet and security-group deletion.
resource "null_resource" "cleanup_before_destroy" {
  # Must depend on the AWS Load Balancer Controller so the destroy-time
  # provisioner runs *before* the controller is uninstalled. Otherwise the
  # controller can't deprovision the NLB + its tagged security groups
  # (k8s-traffic-*, k8s-<ns>-<svc>-*), and those SGs orphan into the VPC and
  # block subnet/VPC deletion.
  depends_on = [
    module.eks,
    helm_release.aws_lb_controller,
  ]

  triggers = {
    cluster_name = var.cluster_name
    region       = var.aws_region
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

      echo "=== Removing Kubernetes finalizers and workloads ==="
      # Delete all InferenceServices so pods terminate and nodes can drain
      $KUBECTL delete inferenceservices --all --all-namespaces --timeout=60s || true

      # Give Knative controllers a moment to reconcile deletions
      sleep 10

      # Strip finalizers from Knative internal ingresses so namespaces don't
      # get stuck in Terminating. Once the Knative controller is gone nobody
      # is left to remove these finalizers.
      $KUBECTL get ingresses.networking.internal.knative.dev \
            --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null | \
      while read -r ns name; do
        if [ -n "$ns" ] && [ -n "$name" ]; then
          echo "Removing finalizers from knative ingress $name in namespace $ns"
          $KUBECTL patch ingresses.networking.internal.knative.dev "$name" -n "$ns" \
            --type=merge -p '{"metadata":{"finalizers":null}}' || true
        fi
      done

      # Delete all Knative services and routes to unblock namespace deletion
      $KUBECTL delete ksvc --all --all-namespaces --timeout=30s || true
      $KUBECTL delete routes.serving.knative.dev --all --all-namespaces --timeout=30s || true
      $KUBECTL delete ingresses.networking.internal.knative.dev --all --all-namespaces --timeout=30s || true

      # Delete all PVCs to release EBS volumes (reclaim_policy=Retain leaves them)
      $KUBECTL delete pvc --all --all-namespaces --timeout=60s || true

      echo "=== Deleting LoadBalancer services (releases NLB ENIs) ==="
      # Delete Services while the AWS Load Balancer Controller is still
      # running — the controller is what deprovisions the NLB *and* its
      # associated security groups (k8s-traffic-<cluster>-* shared backend SG
      # and k8s-<ns>-<svc>-* frontend SG, both tagged elbv2.k8s.aws/cluster).
      # Bypassing the controller leaves those SGs orphaned and blocks VPC
      # deletion — prefer controller-driven teardown, fall back to direct
      # AWS API calls only if the controller fails to finish in time.
      #
      # NLB deprovisioning takes 3–5 min; kubectl's --timeout is how long it
      # waits for the Service object itself (blocked by the LBC's finalizer
      # until the NLB is gone). Give it enough headroom.
      $KUBECTL delete svc --field-selector spec.type=LoadBalancer \
        --all-namespaces --timeout=600s || true

      echo "Waiting for LBC-managed NLBs to be deprovisioned..."
      NLB_GONE=0
      for i in $(seq 1 60); do
        LB_ARNS=$(aws elbv2 describe-load-balancers \
          --region ${self.triggers.region} \
          --query "LoadBalancers[].LoadBalancerArn" --output text)
        LEFTOVER=""
        for arn in $LB_ARNS; do
          CLUSTER_TAG=$(aws elbv2 describe-tags \
            --region ${self.triggers.region} \
            --resource-arns "$arn" \
            --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster'].Value | [0]" \
            --output text)
          if [ "$CLUSTER_TAG" = "${self.triggers.cluster_name}" ]; then
            LEFTOVER="$LEFTOVER $arn"
          fi
        done
        if [ -z "$LEFTOVER" ]; then
          echo "All LBC-managed load balancers deprovisioned"
          NLB_GONE=1
          break
        fi
        echo "LBs still present ($i/60):$LEFTOVER"
        sleep 10
      done

      if [ "$NLB_GONE" != "1" ]; then
        echo "=== LBC failed to deprovision NLBs in time — force-deleting ==="
        # Fallback only. This leaves LBC-managed SGs orphaned; the block
        # below sweeps them up via direct API calls.
        for arn in $LEFTOVER; do
          echo "Force-deleting $arn"
          aws elbv2 delete-load-balancer \
            --region ${self.triggers.region} \
            --load-balancer-arn "$arn" || true
        done
        echo "Waiting for NLB ENIs to detach..."
        for i in $(seq 1 30); do
          ENIS=$(aws ec2 describe-network-interfaces \
            --region ${self.triggers.region} \
            --filters "Name=vpc-id,Values=${self.triggers.vpc_id}" \
                      "Name=interface-type,Values=network_load_balancer" \
            --query "NetworkInterfaces[].NetworkInterfaceId" --output text)
          if [ -z "$ENIS" ]; then
            echo "All NLB ENIs released"
            break
          fi
          echo "NLB ENIs still present ($i/30): $ENIS"
          sleep 10
        done
      fi

      echo "Waiting for LBC-managed security groups to be deleted..."
      for i in $(seq 1 60); do
        SGS=$(aws ec2 describe-security-groups \
          --region ${self.triggers.region} \
          --filters "Name=tag:elbv2.k8s.aws/cluster,Values=${self.triggers.cluster_name}" \
          --query "SecurityGroups[].GroupId" --output text)
        if [ -z "$SGS" ]; then
          echo "All LBC-managed security groups deleted"
          break
        fi
        echo "SGs still present ($i/60): $SGS"
        # If NLBs were force-deleted, the LBC won't come back to clean up
        # the SGs — try to delete them directly. Harmless if the LBC is
        # still working on them (delete will just fail with DependencyViolation).
        if [ "$NLB_GONE" != "1" ]; then
          for sg in $SGS; do
            aws ec2 delete-security-group \
              --region ${self.triggers.region} \
              --group-id "$sg" 2>/dev/null || true
          done
        fi
        sleep 10
      done

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
