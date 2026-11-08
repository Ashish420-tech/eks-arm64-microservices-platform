variable "cluster_endpoint_public_access_cidrs" {
  description = "Your trusted public IP CIDR for Kubernetes API access"
  type        = list(string)
}
