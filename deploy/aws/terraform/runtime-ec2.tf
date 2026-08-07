# Multica agent runtime EC2 (external daemon host)
#
# Validated 2026-08-06: EC2 (AL2023 arm64, t4g.medium) in the public ALB
# subnet with SSH-only ingress from the operator IP. The host runs the
# `multica` CLI daemon plus the Kiro CLI (`kiro-cli`, ACP coding agent) and
# registers a `kiro` runtime into the multica workspace over the ALB (WS).

variable "runtime_instance_type" {
  type    = string
  default = "t4g.medium"
}

variable "runtime_ami_id" {
  type        = string
  description = "AL2023 arm64 AMI. Pin to the validated image (2026-08-06): ami-043b741b00491c65e"
  default     = "ami-043b741b00491c65e"
}

variable "runtime_public_subnet_id" {
  type        = string
  description = "Public subnet for the runtime EC2 (e.g. one of the VPC public subnets). Required; provide via tfvars or -var."
}

variable "runtime_ssh_cidrs" {
  type        = list(string)
  description = "Operator egress CIDRs allowed to SSH to the runtime EC2 (e.g. [\"203.0.113.10/32\"]). Required; provide via tfvars or -var."
}

variable "runtime_public_key" {
  type        = string
  description = "SSH public key for the runtime EC2. Provide via tfvars (generated with `aws ec2 create-key-pair`)."
}

resource "aws_key_pair" "runtime" {
  key_name   = "${local.resource_name}-runtime-kiro"
  public_key = var.runtime_public_key
}

resource "aws_security_group" "runtime" {
  name        = "${local.resource_name}-runtime-kiro-sg"
  description = "SSH access for the multica kiro runtime EC2"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "runtime_ssh" {
  security_group_id = aws_security_group.runtime.id
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = var.runtime_ssh_cidrs[0]
}

resource "aws_vpc_security_group_egress_rule" "runtime_all" {
  security_group_id = aws_security_group.runtime.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_instance" "runtime" {
  ami                         = var.runtime_ami_id
  instance_type               = var.runtime_instance_type
  key_name                    = aws_key_pair.runtime.key_name
  subnet_id                   = var.runtime_public_subnet_id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.runtime.id]
  user_data                   = file("${path.module}/runtime-ec2-user-data.sh")

  tags = merge(local.tags, {
    Name = "${local.resource_name}-runtime-kiro"
  })
}

output "runtime_instance_id" {
  value = aws_instance.runtime.id
}

output "runtime_public_ip" {
  value = aws_instance.runtime.public_ip
}
