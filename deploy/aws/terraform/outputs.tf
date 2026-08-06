output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value     = module.eks.cluster_endpoint
  sensitive = true
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "rds_endpoint" {
  value = module.database.db_instance_endpoint
}

output "rds_master_secret_arn" {
  value     = module.database.db_instance_master_user_secret_arn
  sensitive = true
}

output "redis_primary_endpoint" {
  value = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "uploads_bucket" {
  value = aws_s3_bucket.uploads.id
}

output "ecr_repository_urls" {
  value = { for name, repository in aws_ecr_repository.application : name => repository.repository_url }
}

output "application_secret_arn" {
  value = aws_secretsmanager_secret.application.arn
}

output "application_pod_identity_role_arn" {
  value = aws_iam_role.application.arn
}

output "external_secrets_pod_identity_role_arn" {
  value = aws_iam_role.external_secrets.arn
}

output "load_balancer_controller_role_arn" {
  value = module.load_balancer_controller_role.iam_role_arn
}

output "certificate_arn" {
  value = try(aws_acm_certificate_validation.application[0].certificate_arn, null)
}

output "external_dns_pod_identity_role_arn" {
  value = try(aws_iam_role.external_dns[0].arn, null)
}
