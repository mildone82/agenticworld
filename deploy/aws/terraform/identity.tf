resource "aws_secretsmanager_secret" "application" {
  name                    = "${local.resource_name}/application"
  description             = "Operator-populated Multica application secrets; no value is stored by Terraform"
  recovery_window_in_days = 30
}

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "application" {
  name = "${local.resource_name}-application"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "application" {
  name = "attachments"
  role = aws_iam_role.application.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
        Resource = "${aws_s3_bucket.uploads.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.uploads.arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.application.arn
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "application" {
  cluster_name    = module.eks.cluster_name
  namespace       = "multica"
  service_account = "multica"
  role_arn        = aws_iam_role.application.arn
}

resource "aws_iam_role" "external_secrets" {
  name = "${local.resource_name}-external-secrets"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "external_secrets" {
  name = "read-multica-secrets"
  role = aws_iam_role.external_secrets.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue"]
      Resource = [
        aws_secretsmanager_secret.application.arn,
        module.database.db_instance_master_user_secret_arn
      ]
    }]
  })
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets.arn
}

module "load_balancer_controller_role" {
  source = "./vendor/iam//modules/iam-role-for-service-accounts-eks"

  role_name                              = "${local.resource_name}-aws-load-balancer-controller"
  attach_load_balancer_controller_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_acm_certificate" "application" {
  count = var.domain_name == "" ? 0 : 1

  domain_name       = var.domain_name
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "certificate_validation" {
  for_each = var.domain_name == "" || var.route53_zone_id == "" ? {} : {
    for option in aws_acm_certificate.application[0].domain_validation_options : option.domain_name => {
      name  = option.resource_record_name
      type  = option.resource_record_type
      value = option.resource_record_value
    }
  }

  zone_id = var.route53_zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.value]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "application" {
  count = var.domain_name == "" || var.route53_zone_id == "" ? 0 : 1

  certificate_arn         = aws_acm_certificate.application[0].arn
  validation_record_fqdns = [for record in aws_route53_record.certificate_validation : record.fqdn]
}

resource "aws_budgets_budget" "monthly" {
  name         = "${local.resource_name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Application$multica"]
  }

  dynamic "notification" {
    for_each = length(var.budget_alert_emails) == 0 ? [] : [1]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = 80
      threshold_type             = "PERCENTAGE"
      notification_type          = "FORECASTED"
      subscriber_email_addresses = var.budget_alert_emails
    }
  }
}

resource "aws_iam_role" "external_dns" {
  count = var.route53_zone_id == "" ? 0 : 1
  name  = "${local.resource_name}-external-dns"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "external_dns" {
  count = var.route53_zone_id == "" ? 0 : 1
  name  = "route53-records"
  role  = aws_iam_role.external_dns[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:ListTagsForResource"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
        Resource = "arn:${data.aws_partition.current.partition}:route53:::hostedzone/${var.route53_zone_id}"
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "external_dns" {
  count           = var.route53_zone_id == "" ? 0 : 1
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "external-dns"
  role_arn        = aws_iam_role.external_dns[0].arn
}
