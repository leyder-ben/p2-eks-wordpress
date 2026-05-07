output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "eso_role_arn" {
  value = aws_iam_role.eso.arn
}

output "secret_arn" {
  value = aws_secretsmanager_secret.mysql_creds.arn
}
