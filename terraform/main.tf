# ── DATA ────────────────────────────────────────────────────────────
data "aws_availability_zones" "available" {}

# ── VPC ─────────────────────────────────────────────────────────────
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "p2-vpc"
  cidr = "10.0.0.0/16"

  azs            = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets = ["10.0.1.0/24", "10.0.2.0/24"]

  enable_nat_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  tags = { Project = "p2-eks" }
}

# ── EKS CLUSTER ─────────────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.31"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  # vpc-cni MUST install before nodes — TC2 lesson
  cluster_addons = {
    vpc-cni = {
      most_recent                 = true
      before_compute              = true
      resolve_conflicts_on_create = "OVERWRITE"
    }
    coredns = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
    }
    kube-proxy = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
    }
  }

  eks_managed_node_groups = {
    p2_nodes = {
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 4
      desired_size   = 2

      # CNI policy attached explicitly — TC2 lesson
      iam_role_additional_policies = {
        AmazonEKS_CNI_Policy = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
      }
    }
  }

  tags = { Project = "p2-eks" }
}

# ── OIDC PROVIDER (for External Secrets Operator) ───────────────────
data "aws_iam_openid_connect_provider" "eks" {
  url        = module.eks.cluster_oidc_issuer_url
  depends_on = [module.eks]
}

# ── AWS SECRETS MANAGER ─────────────────────────────────────────────
resource "aws_secretsmanager_secret" "mysql_creds" {
  name                    = "p2/mysql-credentials"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "mysql_creds" {
  secret_id = aws_secretsmanager_secret.mysql_creds.id
  secret_string = jsonencode({
    root-password = var.db_root_password
    wp-password   = var.db_wp_password
    wp-user       = "wordpress_user"
    wp-database   = "wordpress_db"
  })
}

# ── IAM ROLE FOR EXTERNAL SECRETS OPERATOR ──────────────────────────
resource "aws_iam_role" "eso" {
  name = "p2-eso-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${data.aws_iam_openid_connect_provider.eks.url}:sub" = "system:serviceaccount:default:eso-sa"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "eso_secrets" {
  name = "p2-eso-secrets-policy"
  role = aws_iam_role.eso.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = aws_secretsmanager_secret.mysql_creds.arn
    }]
  })
}
