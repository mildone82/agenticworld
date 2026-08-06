variable "name" {
  description = "Resource name prefix."
  type        = string
  default     = "multica"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "az_count" {
  type    = number
  default = 3
  validation {
    condition     = var.az_count == 3
    error_message = "The production topology requires exactly three availability zones."
  }
}

variable "single_nat_gateway" {
  description = "Cost-saving non-HA NAT mode. Keep false for production."
  type        = bool
  default     = false
}

variable "cluster_version" {
  type    = string
  default = "1.32"
}

variable "cluster_endpoint_public_access" {
  type    = bool
  default = false
}

variable "cluster_public_access_cidrs" {
  type    = list(string)
  default = []
}

variable "node_instance_types" {
  type    = list(string)
  default = ["m7i.large"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "node_max_size" {
  type    = number
  default = 6
}

variable "postgres_engine_version" {
  type    = string
  default = "17"
}

variable "postgres_instance_class" {
  type    = string
  default = "db.m7g.large"
}

variable "postgres_allocated_storage" {
  type    = number
  default = 100
}

variable "postgres_max_allocated_storage" {
  type    = number
  default = 500
}

variable "postgres_deletion_protection" {
  type    = bool
  default = true
}

variable "redis_node_type" {
  type    = string
  default = "cache.t4g.small"
}

variable "redis_num_cache_clusters" {
  type    = number
  default = 2
}

variable "domain_name" {
  description = "Public application hostname. Empty disables ACM creation."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Route 53 hosted zone used for ACM DNS validation."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  type    = number
  default = 1500
}

variable "budget_alert_emails" {
  type    = list(string)
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}

check "dns_inputs" {
  assert {
    condition     = (var.domain_name == "") == (var.route53_zone_id == "")
    error_message = "domain_name and route53_zone_id must either both be set or both be empty."
  }
}
