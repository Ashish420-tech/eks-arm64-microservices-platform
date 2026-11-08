#!/usr/bin/env bash
set -Eeuo pipefail

REGION="ap-south-1"
CLUSTER="eks-arm64-platform"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
VERSION="1.15.1"
STACK="Karpenter-${CLUSTER}"
NODE_ROLE="KarpenterNodeRole-${CLUSTER}"
CONTROLLER_ROLE="${CLUSTER}-karpenter"

echo "=========================================="
echo " KARPENTER AWS INFRASTRUCTURE PREPARATION"
echo "=========================================="

# 1. Validate cluster
STATUS="$(aws eks describe-cluster \
  --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.status' --output text)"

[[ "$STATUS" == "ACTIVE" ]] || {
  echo "ERROR: EKS cluster is not ACTIVE"
  exit 1
}

echo "Cluster verified: $CLUSTER"

# 2. Download and validate official version-pinned template
mkdir -p terraform/karpenter

TEMPLATE="terraform/karpenter/cloudformation-${VERSION}.yaml"

curl -fsSL \
  "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${VERSION}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml" \
  -o "$TEMPLATE"

aws cloudformation validate-template \
  --template-body "file://${TEMPLATE}" >/dev/null

echo "Official Karpenter template validated: $VERSION"

# 3. Deploy IAM roles, controller policies and interruption queue
echo "Deploying CloudFormation stack: $STACK"

aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER}"

aws cloudformation wait stack-create-complete \
  --region "$REGION" \
  --stack-name "$STACK" 2>/dev/null || \
aws cloudformation wait stack-update-complete \
  --region "$REGION" \
  --stack-name "$STACK"

echo "CloudFormation stack deployed."

# 4. Discover private subnets
PRIVATE_SUBNETS=(
  subnet-0d9f016166181c7f7
  subnet-0e7415d431f422108
  subnet-079760377520076c4
)

echo "Adding Karpenter discovery tags to private subnets..."

aws ec2 create-tags \
  --region "$REGION" \
  --resources "${PRIVATE_SUBNETS[@]}" \
  --tags "Key=karpenter.sh/discovery,Value=${CLUSTER}"

# 5. Tag existing EKS cluster security group
CLUSTER_SG="sg-00a4976a8663eda74"

echo "Adding discovery tag to existing cluster security group..."

aws ec2 create-tags \
  --region "$REGION" \
  --resources "$CLUSTER_SG" \
  --tags "Key=karpenter.sh/discovery,Value=${CLUSTER}"

# 6. Retrieve dedicated Karpenter node role
NODE_ROLE_ARN="$(aws iam get-role \
  --role-name "$NODE_ROLE" \
  --query 'Role.Arn' --output text)"

echo "Karpenter node role: $NODE_ROLE_ARN"

# 7. Authorize Karpenter-created nodes to join EKS
if kubectl get configmap aws-auth -n kube-system -o yaml 2>/dev/null |
   grep -qF "$NODE_ROLE_ARN"; then
  echo "Node role mapping already exists."
else
  echo "Creating EKS node identity mapping..."

  eksctl create iamidentitymapping \
    --cluster "$CLUSTER" \
    --region "$REGION" \
    --arn "$NODE_ROLE_ARN" \
    --username 'system:node:{{EC2PrivateDNSName}}' \
    --group system:bootstrappers \
    --group system:nodes \
    --no-duplicate-arns
fi

# 8. Create controller Pod Identity association
ASSOCIATION_ID="$(aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER" \
  --region "$REGION" \
  --query "associations[?namespace=='kube-system' && serviceAccount=='karpenter'].associationId | [0]" \
  --output text)"

if [[ -n "$ASSOCIATION_ID" && "$ASSOCIATION_ID" != "None" ]]; then
  echo "Karpenter Pod Identity already exists: $ASSOCIATION_ID"
else
  echo "Creating Karpenter Pod Identity configuration..."

  cat > terraform/karpenter/pod-identity.yaml <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER}
  region: ${REGION}
iam:
  podIdentityAssociations:
    - namespace: kube-system
      serviceAccountName: karpenter
      createServiceAccount: true
      roleName: ${CONTROLLER_ROLE}
      permissionPolicyARNs:
        - arn:aws:iam::${ACCOUNT}:policy/KarpenterControllerNodeLifecyclePolicy-${CLUSTER}
        - arn:aws:iam::${ACCOUNT}:policy/KarpenterControllerIAMIntegrationPolicy-${CLUSTER}
        - arn:aws:iam::${ACCOUNT}:policy/KarpenterControllerEKSIntegrationPolicy-${CLUSTER}
        - arn:aws:iam::${ACCOUNT}:policy/KarpenterControllerInterruptionPolicy-${CLUSTER}
        - arn:aws:iam::${ACCOUNT}:policy/KarpenterControllerZonalShiftPolicy-${CLUSTER}
        - arn:aws:iam::${ACCOUNT}:policy/KarpenterControllerResourceDiscoveryPolicy-${CLUSTER}
EOF

  eksctl create podidentityassociation \
    -f terraform/karpenter/pod-identity.yaml
fi

# 9. Verify infrastructure
echo
echo "===== CLOUDFORMATION STACK ====="
aws cloudformation describe-stacks \
  --stack-name "$STACK" \
  --region "$REGION" \
  --query 'Stacks[0].StackStatus' --output text

echo
echo "===== NODE ROLE ====="
aws iam get-role \
  --role-name "$NODE_ROLE" \
  --query 'Role.Arn' --output text

echo
echo "===== KARPENTER POD IDENTITY ====="
aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER" \
  --region "$REGION" \
  --query "associations[?namespace=='kube-system' && serviceAccount=='karpenter']" \
  --output table

echo
echo "===== DISCOVERY TAGS ====="
aws ec2 describe-subnets \
  --region "$REGION" \
  --subnet-ids "${PRIVATE_SUBNETS[@]}" \
  --query 'Subnets[].{Subnet:SubnetId,Discovery:Tags[?Key==`karpenter.sh/discovery`].Value | [0]}' \
  --output table

echo
echo "===== KARPENTER AWS PREPARATION COMPLETE ====="
echo "No Karpenter worker EC2 instances have been requested."
