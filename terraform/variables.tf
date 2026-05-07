variable "aws_region" {
  default = "us-east-2"
}

variable "cluster_name" {
  default = "p2-eks-cluster"
}

variable "db_root_password" {
  description = "MySQL root password"
  sensitive   = true
}

variable "db_wp_password" {
  description = "WordPress DB user password"
  sensitive   = true
}
