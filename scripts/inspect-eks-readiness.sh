#!/usr/bin/env bash
set -Eeuo pipefail

REGION="ap-south-1"
CLUSTER="eks-arm64-platform"

echo "=========================================="
echo " EKS PLATFORM READINESS INSPECTION"
echo "=========================================="

echo
echo "===== 1. AWS CLUSTER STATUS ====="
aws eks describe-cluster \
  --name "$CLUSTER" \
  --region "$REGION" \
  --query 'cluster.{Name:name,Status:status,Version:version,Endpoint:endpoint}' \
  --output table

echo
echo "===== 2. KUBECTL CONTEXT ====="
kubectl config current-context

echo
echo "===== 3. KUBERNETES VERSION ====="
kubectl version

echo
echo "===== 4. WORKER NODES AND ARCHITECTURE ====="
kubectl get nodes \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,ARCH:.metadata.labels.kubernetes\.io/arch,INSTANCE:.metadata.labels.node\.kubernetes\.io/instance-type,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory'

echo
echo "===== 5. NODE TAINTS ====="
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints'

echo
echo "===== 6. KARPENTER PODS ====="
kubectl get pods -A | grep -i karpenter || true

echo
echo "===== 7. KARPENTER CRDS ====="
kubectl get crds | grep -i karpenter || true

echo
echo "===== 8. KARPENTER NODEPOOLS ====="
kubectl get nodepools.karpenter.sh -o wide 2>&1 || true

echo
echo "===== 9. KARPENTER EC2NODECLASSES ====="
kubectl get ec2nodeclasses.karpenter.k8s.aws -o wide 2>&1 || true

echo
echo "===== 10. STORAGE CLASSES ====="
kubectl get storageclass

echo
echo "===== 11. EXISTING PLATFORM NAMESPACES ====="
kubectl get namespaces

echo
echo "===== 12. EXISTING PLATFORM WORKLOADS ====="
kubectl get deployments,statefulsets,pods -A | grep -E 'karpenter|microservices|postgres' || true

echo
echo "===== 13. NODE CAPACITY ====="
kubectl describe nodes | grep -E 'Name:|Instance Type:|Architecture:|cpu |memory |Allocated resources:|Requests:|Limits:' || true

echo
echo "===== 14. KUBERNETES PERMISSIONS ====="
kubectl auth can-i create deployments -n microservices
kubectl auth can-i create secrets -n microservices
kubectl auth can-i create statefulsets -n microservices

echo
echo "=========================================="
echo " INSPECTION COMPLETED"
echo "=========================================="
