# EKS ARM64 Microservices Platform

Enterprise-style AWS EKS platform using ARM64 Graviton workers.

## Infrastructure
- AWS Region: ap-south-1
- Terraform remote state: Amazon S3
- VPC: 10.0.0.0/16
- Availability Zones: ap-south-1a, ap-south-1b, ap-south-1c
- Public subnets: 3
- Private subnets: 3
- Internet Gateway: 1
- NAT Gateway: 1

## Technology Stack
- AWS EKS
- Ubuntu 24.04 ARM64
- Karpenter
- Terraform
- Node.js
- Kong API Gateway
- Prometheus and Grafana
- Loki and Tempo
- Argo CD
