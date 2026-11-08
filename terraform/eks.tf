module "eks" {
  source = "./eks"

  cluster_name       = "eks-arm64-platform"
  kubernetes_version = "1.36"

  subnet_ids = module.vpc.private_subnet_ids

  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  bootstrap_instance_type = "t4g.small"
}
