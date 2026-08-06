locals {
  resource_name = "${var.name}-${var.environment}"
  azs           = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  tags = merge({
    Application = "multica"
    Environment = var.environment
    ManagedBy   = "terraform"
  }, var.tags)
}

module "vpc" {
  source = "./vendor/vpc"

  name = local.resource_name
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets  = [for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, index)]
  private_subnets = [for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, index + 4)]
  intra_subnets   = [for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, index + 8)]

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway
  enable_dns_hostnames   = true
  enable_dns_support     = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

module "eks" {
  source = "./vendor/eks"

  cluster_name    = local.resource_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access           = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs     = var.cluster_public_access_cidrs
  cluster_endpoint_private_access          = true
  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
    eks-pod-identity-agent = {
      most_recent    = true
      before_compute = true
    }
  }

  eks_managed_node_groups = {
    application = {
      name           = "application"
      instance_types = var.node_instance_types
      ami_type       = "AL2023_ARM_64_STANDARD"
      capacity_type  = "ON_DEMAND"
      min_size       = var.node_min_size
      desired_size   = var.node_desired_size
      max_size       = var.node_max_size
      labels = {
        workload = "multica"
      }
      update_config = {
        max_unavailable_percentage = 33
      }
    }
  }
}

resource "aws_security_group" "database" {
  name_prefix = "${local.resource_name}-postgres-"
  description = "PostgreSQL access from EKS nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    protocol        = "tcp"
    from_port       = 5432
    to_port         = 5432
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
}

module "database" {
  source = "./vendor/rds"

  identifier           = local.resource_name
  engine               = "postgres"
  engine_version       = var.postgres_engine_version
  family               = "postgres17"
  major_engine_version = "17"
  instance_class       = var.postgres_instance_class

  db_name                     = "multica"
  username                    = "multica_admin"
  port                        = 5432
  manage_master_user_password = true

  allocated_storage     = var.postgres_allocated_storage
  max_allocated_storage = var.postgres_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  multi_az              = true

  subnet_ids             = module.vpc.intra_subnets
  create_db_subnet_group = true
  vpc_security_group_ids = [aws_security_group.database.id]
  publicly_accessible    = false

  backup_retention_period          = 14
  deletion_protection              = var.postgres_deletion_protection
  skip_final_snapshot              = false
  final_snapshot_identifier_prefix = "${local.resource_name}-final"
  copy_tags_to_snapshot            = true

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  create_monitoring_role                = false
  monitoring_role_arn                   = "arn:aws-cn:iam::460592757249:role/rds-monitoring-role"
  monitoring_interval                   = 60
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

  parameters = [
    { name = "log_min_duration_statement", value = "1000" },
    { name = "log_lock_waits", value = "1" },
    { name = "idle_in_transaction_session_timeout", value = "60000" }
  ]
}

resource "aws_security_group" "redis" {
  name_prefix = "${local.resource_name}-redis-"
  description = "Redis access from EKS nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    protocol        = "tcp"
    from_port       = 6379
    to_port         = 6379
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_elasticache_subnet_group" "this" {
  name       = local.resource_name
  subnet_ids = module.vpc.intra_subnets
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = local.resource_name
  description          = "Multica realtime fanout and shared ephemeral state"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = var.redis_node_type
  port                 = 6379
  num_cache_clusters   = var.redis_num_cache_clusters

  automatic_failover_enabled = var.redis_num_cache_clusters > 1
  multi_az_enabled           = var.redis_num_cache_clusters > 1
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  apply_immediately          = false

  subnet_group_name        = aws_elasticache_subnet_group.this.name
  security_group_ids       = [aws_security_group.redis.id]
  snapshot_retention_limit = 7
  maintenance_window       = "sun:05:00-sun:06:00"
}

resource "aws_kms_key" "application" {
  description             = "Multica attachment encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "application" {
  name          = "alias/${local.resource_name}"
  target_key_id = aws_kms_key.application.key_id
}

resource "aws_s3_bucket" "uploads" {
  bucket_prefix = "${local.resource_name}-uploads-"
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.application.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
    noncurrent_version_expiration { noncurrent_days = 30 }
  }
}

resource "aws_ecr_repository" "application" {
  for_each = toset(["backend", "frontend"])

  name                 = "${local.resource_name}-${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
}

resource "aws_ecr_lifecycle_policy" "application" {
  for_each   = aws_ecr_repository.application
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Retain the latest 30 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}
