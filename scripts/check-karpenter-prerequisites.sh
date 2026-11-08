#!/usr/bin/env bash
set -u

REGION=ap-south-1
CLUSTER=eks-arm64-platform

echo "===== AWS IDENTITY ====="
aws sts get-caller-identity \
  --query '{Account:Account,Arn:Arn}' --output json

echo "===== TOOL VERSIONS ====="
aws --version
eksctl version
helm version --short

echo "===== CLUSTER NETWORK ====="
aws eks describe-cluster \
  --region "$REGION" --name "$CLUSTER" \
  --query 'cluster.resourcesVpcConfig.{VPC:vpcId,Subnets:subnetIds,SecurityGroups:securityGroupIds,ClusterSecurityGroup:clusterSecurityGroupId}' \
  --output json

echo "===== NODE ROLE ====="
aws eks describe-nodegroup \
  --region "$REGION" --cluster-name "$CLUSTER" \
  --nodegroup-name eks-arm64-platform-bootstrap \
  --query 'nodegroup.{Status:status,NodeRole:nodeRole,InstanceTypes:instanceTypes}' \
  --output json

echo "===== POD IDENTITY ADDON ====="
aws eks describe-addon \
  --region "$REGION" --cluster-name "$CLUSTER" \
  --addon-name eks-pod-identity-agent \
  --query 'addon.{Status:status,Version:addonVersion}' \
  --output json

echo "===== EKS ACCESS MODE ====="
aws eks describe-cluster \
  --region "$REGION" --name "$CLUSTER" \
  --query 'cluster.accessConfig.authenticationMode' \
  --output text

echo "===== SUBNET DISCOVERY TAGS ====="
aws ec2 describe-subnets \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=vpc-0f1f4651b2947cf30" \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,MapPublicIP:MapPublicIpOnLaunch,Tags:Tags}' \
  --output json

echo "===== SECURITY GROUP TAGS ====="
aws ec2 describe-security-groups \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=vpc-0f1f4651b2947cf30" \
  --query 'SecurityGroups[].{ID:GroupId,Name:GroupName,Tags:Tags}' \
  --output json

echo "===== KARPENTER HELM RELEASE ====="
helm list -A --filter '^karpenter$'

echo "===== EBS CSI ADDON ====="
aws eks describe-addon \
  --region "$REGION" --cluster-name "$CLUSTER" \
  --addon-name aws-ebs-csi-driver \
  --query 'addon.{Status:status,Version:addonVersion}' \
  --output json

echo "===== EC2 ARM64 INSTANCE OFFERINGS ====="
for type in t4g.small t4g.medium c7g.large m7g.large; do
  echo "--- $type ---"
  aws ec2 describe-instance-type-offerings \
    --region "$REGION" \
    --location-type availability-zone \
    --filters "Name=instance-type,Values=$type" \
    --query 'InstanceTypeOfferings[].Location' \
    --output text
done

echo "===== CURRENT NODES ====="
kubectl get nodes -o wide

echo "===== COMPLETE ====="
