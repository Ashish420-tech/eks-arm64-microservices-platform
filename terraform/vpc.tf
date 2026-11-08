module "vpc" {
  source = "./vpc"

  project_name = "eks-arm64-platform"
  vpc_cidr     = "10.0.0.0/16"
}
