# Multica AWS deployment artifacts

This directory implements the Stage 3 EKS path from the Gate 0 architecture review. It deploys only the real Multica control-plane topology:

- Next.js frontend on port 3000
- Go backend on ports 8080 (HTTP/WSS) and 9090 (private metrics)
- External RDS PostgreSQL as both OLTP store and `agent_task_queue`
- External Redis-compatible service for multi-backend realtime fanout and liveness
- Private S3/KMS attachment storage
- External `multica daemon` runtimes connecting through the public ALB over HTTPS/WSS

It intentionally creates no SQS queue, DLQ, outbox relay, in-cluster agent worker, or KEDA resource. Daemon worktrees, repository caches, credentials, and agent sessions remain on each daemon host; S3 stores backend attachments only.

## Contents

- `helm/multica`: AWS production derivative of the official chart. It adds immutable digest support, external data configuration, a release migration Job, probes, PDBs, topology spread, restricted security contexts, NetworkPolicies, Pod Identity ServiceAccount, ALB routing, ServiceMonitor, and PrometheusRule.
- `helm/values-dev.yaml`: single-backend, in-memory realtime, no-S3 profile. This is not HA.
- `helm/values-prod.yaml`: two-backend Redis/S3 profile. Placeholder hostnames, endpoints, certificate ARN, bucket, and image digests must be replaced.
- `terraform`: three-AZ VPC, EKS managed node group, RDS PostgreSQL 17 candidate, encrypted Redis replication group, S3/KMS, ECR, Secrets Manager shell, IAM/Pod Identity, ACM, and budget.
- `addons/helmfile.yaml`: pinned AWS Load Balancer Controller, External Secrets, metrics-server, and optional ExternalDNS releases.
- `kubernetes`: namespace and External Secrets examples.

## Validation

Run `./scripts/validate-deployment.sh`. The script lints and renders both Helm profiles, validates their schema and topology invariants, rejects forbidden resources, checks the non-root backend image contract, and runs `terraform fmt`/`validate`.

No `terraform apply` is part of Stage 3. See `docs/AWS_EKS_DEPLOYMENT.md` for deployment, migration, daemon-channel verification, rollback, and production gates.
