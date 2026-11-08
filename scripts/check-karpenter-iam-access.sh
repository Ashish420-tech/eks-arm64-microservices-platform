#!/usr/bin/env bash
set -euo pipefail

USER_NAME="serverless-deploy-user"

echo "===== IAM USER ====="
aws iam get-user --user-name "$USER_NAME" \
  --query 'User.{Name:UserName,Arn:Arn}' --output table

echo
echo "===== USER ATTACHED POLICIES ====="
aws iam list-attached-user-policies \
  --user-name "$USER_NAME" --output table

echo
echo "===== USER INLINE POLICIES ====="
aws iam list-user-policies \
  --user-name "$USER_NAME" --output table

echo
echo "===== IAM GROUPS ====="
aws iam list-groups-for-user \
  --user-name "$USER_NAME" \
  --query 'Groups[].GroupName' --output table

echo
echo "===== EXISTING KARPENTER IAM ROLES ====="
aws iam list-roles \
  --query "Roles[?contains(RoleName, 'Karpenter')].RoleName" \
  --output table

echo
echo "===== EXISTING KARPENTER CLOUDFormation STACK ====="
aws cloudformation describe-stacks \
  --stack-name Karpenter-eks-arm64-platform \
  --query 'Stacks[].{Name:StackName,Status:StackStatus}' \
  --output table 2>&1 || true

echo
echo "===== EKS POD IDENTITY ASSOCIATIONS ====="
aws eks list-pod-identity-associations \
  --cluster-name eks-arm64-platform \
  --region ap-south-1 \
  --output table

echo
echo "===== CHECK COMPLETED ====="
