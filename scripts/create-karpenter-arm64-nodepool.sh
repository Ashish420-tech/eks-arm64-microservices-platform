#!/usr/bin/env bash
set -Eeuo pipefail

CLUSTER="eks-arm64-platform"
REGION="ap-south-1"
NODE_ROLE="KarpenterNodeRole-${CLUSTER}"
DIR="terraform/karpenter"

mkdir -p "$DIR"

echo "===== VERIFYING KARPENTER CONTROLLER ====="
kubectl rollout status deployment/karpenter \
  -n kube-system --timeout=180s

echo "===== VERIFYING AWS DISCOVERY TAGS ====="

aws ec2 describe-subnets \
  --region "$REGION" \
  --subnet-ids \
    subnet-0d9f016166181c7f7 \
    subnet-0e7415d431f422108 \
    subnet-079760377520076c4 \
  --query 'Subnets[].Tags[?Key==`karpenter.sh/discovery`].Value | [0]' \
  --output text

echo "===== VERIFYING NODE ROLE ====="
aws iam get-role --role-name "$NODE_ROLE" \
  --query 'Role.Arn' --output text

echo "===== CREATING EC2NODECLASS ====="

cat > "$DIR/arm64-graviton-ec2nodeclass.yaml" <<EOF
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: arm64-graviton
spec:
  role: ${NODE_ROLE}

  amiSelectorTerms:
    - alias: al2023@latest

  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${CLUSTER}

  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${CLUSTER}

  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    httpPutResponseHopLimit: 2
    httpTokens: required

  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 30Gi
        volumeType: gp3
        encrypted: true
        deleteOnTermination: true
EOF

kubectl apply -f "$DIR/arm64-graviton-ec2nodeclass.yaml"

echo "===== WAITING FOR EC2NODECLASS READINESS ====="

kubectl wait \
  --for=condition=Ready \
  ec2nodeclass/arm64-graviton \
  --timeout=240s

echo "===== CREATING ARM64 NODEPOOL ====="

cat > "$DIR/arm64-graviton-nodepool.yaml" <<'EOF'
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: arm64-graviton
spec:
  template:
    metadata:
      labels:
        workload-tier: application
        architecture: arm64
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: arm64-graviton

      requirements:
        - key: kubernetes.io/arch
          operator: In
          values:
            - arm64

        - key: kubernetes.io/os
          operator: In
          values:
            - linux

        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - on-demand

        - key: karpenter.k8s.aws/instance-family
          operator: In
          values:
            - t4g
            - c7g
            - m7g

        - key: karpenter.k8s.aws/instance-size
          operator: In
          values:
            - medium
            - large
            - xlarge

        - key: topology.kubernetes.io/zone
          operator: In
          values:
            - ap-south-1a
            - ap-south-1b
            - ap-south-1c

      expireAfter: 720h
      terminationGracePeriod: 1h

  limits:
    cpu: "8"
    memory: 32Gi

  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 5m
    budgets:
      - nodes: "1"
EOF

kubectl apply -f "$DIR/arm64-graviton-nodepool.yaml"

echo "===== WAITING FOR NODEPOOL READINESS ====="

kubectl wait \
  --for=condition=Ready \
  nodepool/arm64-graviton \
  --timeout=180s

echo
echo "===== EC2NODECLASS STATUS ====="
kubectl get ec2nodeclass arm64-graviton -o wide

echo
echo "===== NODEPOOL STATUS ====="
kubectl get nodepool arm64-graviton -o wide

echo
echo "===== NODEPOOL DETAILS ====="
kubectl describe nodepool arm64-graviton

echo
echo "===== CURRENT WORKER NODES ====="
kubectl get nodes -L kubernetes.io/arch,node.kubernetes.io/instance-type

echo
echo "===== NODECLAIMS ====="
kubectl get nodeclaims

echo
echo "===== ARM64 NODEPOOL CONFIGURATION COMPLETE ====="
echo "No test workload was created."
echo "No additional EC2 nodes should be launched yet."
