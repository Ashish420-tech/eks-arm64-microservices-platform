variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC IPv4 CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "AWS availability zones"
  type        = list(string)

  default = [
    "ap-south-1a",
    "ap-south-1b",
    "ap-south-1c"
  ]
}

variable "public_subnet_cidrs" {
  type = list(string)

  default = [
    "10.0.0.0/20",
    "10.0.32.0/20",
    "10.0.64.0/20"
  ]
}

variable "private_subnet_cidrs" {
  type = list(string)

  default = [
    "10.0.16.0/20",
    "10.0.48.0/20",
    "10.0.80.0/20"
  ]
}

variable "single_nat_gateway" {
  description = "Use one NAT gateway to reduce learning environment costs"
  type        = bool
  default     = true
}
