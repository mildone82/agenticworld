# AWS EKS deployment and operations guide

## 1. Architecture contract

The deployment artifacts implement the Gate 0 verified topology, not the earlier inferred worker topology.

```text
Browser / external daemon
          |
       HTTPS/WSS
          |
       ALB + ACM
       /        \
frontend:3000  backend:8080 ---- RDS PostgreSQL 17 candidate
                    |             (application data + agent_task_queue)
                    +---------- Redis TLS (multi-backend fanout/liveness)
                    +---------- S3/KMS (backend attachments only)
                    +---------- approved external integrations
```

The `multica daemon` remains outside EKS. It receives notifications over WSS and claims/reports tasks through `/api/daemon/*` REST. Its worktree, repository cache, coding-agent credentials, CPU, memory, and local disk are not backend Pod resources and are not stored in the attachment bucket.

The PostgreSQL `agent_task_queue` is the only task queue. It uses row locking, leases, compare-and-swap updates, and finite attempts. The delivery boundary is at-least-once: a daemon crash after an external side effect but before completion reporting can cause recovery or retry. Operators must not claim exactly-once external effects.

## 2. Profiles and production gates

| Profile | Backend | Redis | Attachments | Reliability statement |
| --- | ---: | --- | --- | --- |
| `values-dev.yaml` | 1 replica | in-process only | local fallback only | Development/PoC; backend and uploads are single points of failure |
| `values-prod.yaml` | 2 replicas | TLS endpoint required | private S3/KMS required | Candidate HA profile; enable only after the multi-replica tests below pass |

Production remains gated on all of the following:

1. All 297 `*.up.sql` migrations pass on the selected RDS PostgreSQL 17 minor version, including required extension checks.
2. Multi-backend Redis fanout, daemon liveness, embedded loops, database pool limits, rolling update, and S3 attachment semantics pass.
3. RDS failover, backup/PITR restore, Redis failover, Pod deletion, daemon restart, and WSS-to-HTTP fallback pass.
4. Image SBOM and vulnerability scans pass; release images are signed and deployed by digest.
5. SLO, RTO, RPO, data classification, monthly budget, PAT scope/rotation, and the reopened EKS-versus-ECS ADR are approved.

## 3. Prerequisites

- Terraform in the version range declared by `deploy/aws/terraform/versions.tf`
- AWS CLI credentials authorized for the planned account and region
- `kubectl`, Helm 3, and Helmfile
- A Route 53 hosted zone when Terraform should validate an ACM certificate
- A remote, encrypted Terraform backend with state locking; the example intentionally does not create its own backend
- A release tag/digest pair for both images from the same Multica source revision

Before applying infrastructure, review the plan for account, region, CIDRs, database deletion protection, NAT topology, public EKS endpoint settings, DNS, and budget recipients. `terraform apply` creates billable production resources and is intentionally a Stage 4 action.

## 4. Provision the AWS foundation

```bash
cp deploy/aws/terraform/terraform.tfvars.example deploy/aws/terraform/terraform.tfvars
# Edit non-secret account/environment inputs.
terraform -chdir=deploy/aws/terraform init
terraform -chdir=deploy/aws/terraform plan -out=plan.tfplan
terraform -chdir=deploy/aws/terraform apply plan.tfplan
```

The modules are version-pinned. The foundation contains:

- public ALB subnets, private EKS application subnets, and isolated data subnets across three AZs;
- an EKS managed node group (Karpenter is intentionally not required without measured node-elasticity demand);
- RDS PostgreSQL with Multi-AZ, encryption, managed master password, backups, deletion protection, Performance Insights, and PostgreSQL logs;
- a TLS/encrypted Redis replication group used only for realtime/shared ephemeral state;
- a private, versioned S3 bucket with SSE-KMS and incomplete-upload cleanup;
- immutable/scanned backend and frontend ECR repositories;
- application and External Secrets Pod Identity roles, an ALB Controller IRSA role, ACM DNS validation, and an AWS budget.

Terraform creates the application Secrets Manager container but no secret value, so credentials do not enter Terraform state.

## 5. Install cluster add-ons and secrets

Configure cluster access, create the restricted namespace, and install pinned add-ons:

```bash
aws eks update-kubeconfig --name "$(terraform -chdir=deploy/aws/terraform output -raw cluster_name)"
kubectl apply -f deploy/aws/kubernetes/namespace.yaml

export EKS_CLUSTER_NAME="$(terraform -chdir=deploy/aws/terraform output -raw cluster_name)"
export AWS_LB_CONTROLLER_ROLE_ARN="$(terraform -chdir=deploy/aws/terraform output -raw load_balancer_controller_role_arn)"
export EXTERNAL_DNS_ENABLED=true
export EXTERNAL_DNS_DOMAIN=multica.example.com
helmfile -f deploy/aws/addons/helmfile.yaml sync
```

Populate the Terraform-created application secret out of band. Use an encrypted temporary input file or an approved secret-management workflow rather than command-line literals. The JSON object must contain at least:

| Key | Requirement |
| --- | --- |
| `DATABASE_URL` | URL-encoded RDS DSN with `sslmode=require`; use a dedicated application role, not the RDS master role |
| `JWT_SECRET` | Cryptographically random, minimum 32 bytes |
| `REDIS_URL` | `rediss://` endpoint; include credentials only if Redis authentication was enabled |
| `RESEND_API_KEY` | Empty only when email flows are intentionally disabled |
| `GOOGLE_CLIENT_SECRET` | Empty only when Google OAuth is disabled |
| `MULTICA_VCS_SECRET_KEY` | Required when self-hosted VCS integration is enabled |
| `CLOUDFRONT_PRIVATE_KEY` | Empty unless signed CloudFront delivery is configured |
| `MULTICA_DEV_VERIFICATION_CODE` | Must be disabled/empty in production |

The Helm ConfigMap contains only non-sensitive defaults. A value in `multica-secrets` overrides a same-named ConfigMap variable, allowing an authenticated `REDIS_URL` to stay secret.

Prepare `deploy/aws/kubernetes/external-secret.yaml.example` by replacing the region and application secret name, then apply it. Wait for the target Secret before installing the chart because the pre-install migration Job consumes it.

```bash
kubectl apply -f prepared-external-secret.yaml
kubectl -n multica wait --for=condition=Ready externalsecret/multica-secrets --timeout=120s
kubectl -n multica get secret multica-secrets
```

Do not print Secret data in logs or CI output.

## 6. Build and publish images

### Base image source and availability limits

The Dockerfiles default to the Docker Official Images namespace in [AWS Public ECR Gallery](https://gallery.ecr.aws/) instead of Docker Hub. The references were resolved on 2026-08-06, verified as OCI multi-architecture indexes with both `linux/amd64` and `linux/arm64`, and pinned to the Public ECR index digest:

| Build use | Pinned reference |
| --- | --- |
| Go builder | `public.ecr.aws/docker/library/golang:1.26-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2` |
| Backend runtime | `public.ecr.aws/docker/library/alpine:3.21@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d` |
| Frontend build/runtime | `public.ecr.aws/docker/library/node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32` |

Recheck an update before changing a digest:

```bash
docker buildx imagetools inspect public.ecr.aws/docker/library/golang:1.26-alpine
docker buildx imagetools inspect public.ecr.aws/docker/library/alpine:3.21
docker buildx imagetools inspect public.ecr.aws/docker/library/node:22-alpine
```

`GO_BASE_IMAGE`, `RUNTIME_BASE_IMAGE`, and `NODE_BASE_IMAGE` are build args for a controlled registry override. Overrides must use reviewed `repository:tag@sha256:digest` references and then repeat the build, SBOM, vulnerability, and signature checks. A tag-only automatic fallback is intentionally not implemented because it would make provenance dependent on which registry happened to respond.

Public pulls can be anonymous, but AWS documents separate defaults: unauthenticated pulls at 1 pull/second, pulls to ECS/Fargate/EC2 resources at 10 pulls/second, and 500 GB/month for unauthenticated customers; the transfer allowance and AWS-resource pull rate are not adjustable. Authenticated pulls default to 10 pulls/second (adjustable), require `ecr-public:GetAuthorizationToken` and `sts:GetServiceBearerToken`, and use a token valid for 12 hours. Authenticate high-volume or shared CI builders without logging the token:

```bash
aws ecr-public get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin public.ecr.aws
```

AWS Public ECR removes the observed Docker Hub base-layer dependency, but it does not make builds offline or eliminate all external availability risk:

- `apk add` still reaches Alpine package mirrors, `go mod download` reaches configured Go module sources, and Corepack/pnpm may reach package registries.
- Public ECR remains a public external service with quotas and possible network/service failures. Production CI should cache layers and, where required, import approved base images into private ECR, pin the private digest, and retain source/SBOM/signature provenance.
- Public ECR and Docker Hub tag names do not guarantee permanent byte-for-byte parity. The Public ECR digest is the build contract; digest updates are explicit dependency changes.
- Multi-architecture index pinning preserves amd64/arm64 selection, but every target architecture still requires its own build and runtime smoke test.

AWS references: [pulling public images](https://docs.aws.amazon.com/AmazonECR/latest/public/docker-pull-ecr-image.html) and [Public ECR service quotas](https://docs.aws.amazon.com/AmazonECR/latest/public/public-service-quotas.html).

### Build and publish application images

Build both images from one source commit, scan them, emit SBOMs, sign the resulting ECR digests, and set those immutable digests in a private production values override. A network-enabled CI runner should run the build, non-root-user, SBOM, and High/Critical vulnerability checks.

Terraform outputs the two ECR repositories. A minimal publish flow is:

```bash
BACKEND_REPO="$(terraform -chdir=deploy/aws/terraform output -json ecr_repository_urls | jq -r .backend)"
FRONTEND_REPO="$(terraform -chdir=deploy/aws/terraform output -json ecr_repository_urls | jq -r .frontend)"
REGISTRY="${BACKEND_REPO%%/*}"
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
RELEASE="$(git -C multica rev-parse --short=12 HEAD)"
docker build -f multica/Dockerfile -t "$BACKEND_REPO:$RELEASE" multica
docker build -f multica/Dockerfile.web -t "$FRONTEND_REPO:$RELEASE" multica
docker push "$BACKEND_REPO:$RELEASE"
docker push "$FRONTEND_REPO:$RELEASE"
```

Read each pushed digest from ECR, sign it with the approved keyless/KMS policy, and replace **repository, tag, and digest** for both images in the production override. Do not leave the GHCR development defaults when images were published to ECR.

The backend runtime image uses UID/GID 10001. `RUN_MIGRATIONS=false` lets the Deployment start without repeating schema changes; the Helm migration Job runs `/app/migrate up` once before install/upgrade. The frontend already runs as UID 1001. Both production containers drop all capabilities, disallow privilege escalation, use the runtime-default seccomp profile, and use read-only root filesystems with an ephemeral `/tmp` mount.

Never use the placeholder zero digests from `values-prod.yaml` for a real deployment.

## 7. Database migration and pool capacity

The migration Job is a blocking `pre-install,pre-upgrade` Helm hook with a 15-minute deadline. A failed Job is retained for inspection and prevents the release transition. Do not run destructive down migrations during rollback. Application migrations must use expand/contract semantics before switching a rolling backend release.

Preflight the target RDS instance with an application-equivalent role:

```sql
SELECT version();
SELECT extname FROM pg_extension ORDER BY extname;
SHOW max_connections;
SHOW shared_preload_libraries;
```

`pgcrypto` and `pg_trgm` are expected by current migrations; optional extensions must not be assumed. Record migration duration, lock waits, failed statement, and RDS CPU/IO/WAL impact. Test on a production-sized clone before the first production upgrade.

Initial connection budget (not a capacity promise):

| Profile | Backend pool | Migration/metrics | Operator/failover reserve | Planned total |
| --- | ---: | ---: | ---: | ---: |
| Dev | `1 × 20 = 20` | 1 | 10 | 31 |
| Prod | `2 × 20 = 40` | 1 | 10 | 51 |

Keep `backend replicas × DATABASE_MAX_CONNS + auxiliary connections + reserve` below the measured RDS `max_connections`; use 70% as an initial planning/alert threshold only. Validate reconnect storms during failover before changing pool or replica counts. Track queue oldest age, claim latency, stale reclaim/attempt/terminal failure, DB connections, lock waits, IOPS, WAL, autovacuum, and table/index bloat. Run `EXPLAIN (ANALYZE, BUFFERS)` against claim/recovery queries at representative queue size before considering partitioning or a different queue technology.

## 8. Install or upgrade Multica

Copy the production values into an environment-owned override and replace all placeholders: hostname, ACM ARN, bucket, Redis endpoint, region, VPC ingress CIDR, image tags, and image digests.

```bash
helm upgrade --install multica deploy/aws/helm/multica \
  --namespace multica \
  --values deploy/aws/helm/values-prod.yaml \
  --values production-overrides.yaml \
  --wait --timeout 20m
```

The ALB routes `/api`, `/auth`, `/uploads`, and `/ws` to backend port 8080 and `/` to frontend port 3000. Service annotations set backend target health to `/healthz` and frontend target health to `/`; ExternalDNS publishes the Ingress ALB address to the Route 53 hostname in `ingress.host`. Wait for the DNS record and ACM certificate before external daemon tests. The 120-second ALB idle timeout is an initial value, not an SLO; calibrate it against the protocol heartbeat, WSS idle behavior, draining, and representative network interruption tests.

Keep backend at one replica until Redis/S3/multi-version compatibility tests pass. A `RollingUpdate` with `maxUnavailable=0` is valid only after migrations are backward compatible. Otherwise use the dev-style single backend with `Recreate` and explicitly accept the outage/SPOF.

## 9. Acceptance tests

### HTTP, WebSocket, and attachments

1. Verify ALB target health and frontend/backend probes.
2. Complete login and OAuth callback through the same hostname; verify secure cookie scope and real client information.
3. Exercise REST and browser WebSocket traffic through the ALB.
4. Upload/download an allowed attachment and verify the object is private, SSE-KMS encrypted, and checksum/content constraints are enforced.
5. Deny or fail S3 temporarily and confirm attachment state is not reported as successful.

### External daemon channel

Use a test workspace, least-privilege PAT, and an external daemon host with encrypted local disk. Never place the PAT in an image, shell history, task prompt, or log.

1. Start the real `multica daemon` against the ALB HTTPS URL and confirm registration, WSS notification, REST claim, progress, usage, and completion.
2. Block WSS while keeping HTTPS available; confirm HTTP polling/heartbeat continues without task loss.
3. Drain/delete the connected backend Pod; confirm readiness removal precedes termination and the daemon reconnects.
4. Kill/restart the daemon during a task; record lease/reclaim/attempt behavior and verify the local workspace can resume.
5. Revoke and expire the PAT; confirm new calls are rejected, logged without token content, and operational rotation works.
6. Test lost claim/completion responses and document where duplicate external effects are possible.

Collect daemon heartbeat age, healthy/used slots, poll fallback, task duration, local disk/GC, token expiry, and queue oldest age. Backend CPU is not a daemon-capacity signal.

### Multi-backend and failover

1. Confirm Redis stream/Lua/client compatibility and TLS, then deploy two backends.
2. Verify realtime fanout and daemon wakeups when REST and WSS land on different Pods.
3. Fail Redis and confirm PostgreSQL remains the task source of truth; do not silently split into independent in-memory islands.
4. Trigger an RDS Multi-AZ failover and measure API 503 window, pool recreation, claim recovery, stale reclaim, and duplicate boundary.
5. Exercise Redis failover and S3 error/retry behavior.
6. Run a Helm rolling upgrade with active browser and daemon WSS connections.

## 10. Rollback

Application rollback:

1. Stop or pause new work when schema compatibility is uncertain.
2. Inspect the failed migration Job and backend logs without dumping environment variables.
3. Roll back to the previous digest with `helm rollback multica <revision> --wait` only when the current schema is backward compatible.
4. If compatibility is not proven, restore into a separate RDS instance from snapshot/PITR, validate it, and switch through an approved recovery procedure. Do not run automatic down migrations.

Infrastructure rollback is component-specific. Helm rollback does not revert RDS, Redis, S3, KMS, Secrets Manager, or VPC resources. Keep deletion protection and final snapshots enabled. Review every Terraform destroy/replacement plan; production data deletion requires separate human approval.

## 11. Minimum alerts and runbooks

Alert on:

- ALB unhealthy targets, frontend/backend available replicas, 5xx, p95/p99 latency, WSS churn, Pod restart/OOM, and rollout stalls;
- queue depth/oldest age, claim p95, stale reclaim, attempt exhaustion, DB pool saturation, locks, storage, WAL, autovacuum, bloat, and failover recovery;
- Redis connection/latency/memory/eviction/stream errors and failover;
- S3 4xx/5xx, pending attachment operations, object growth, and KMS denial;
- daemon heartbeat age, available slots, fallback polling, task duration, local disk/GC, and PAT expiry/anomalous use;
- NAT/egress, log cardinality, AWS budget, and RDS/Redis/S3 cost trends.

For PostgreSQL outage, return bounded 503/backpressure and retry with bounded exponential backoff plus jitter; never create an unbounded in-memory task queue. For poison tasks, preserve the terminal failed state and use audited manual retry/cancel procedures. For Redis failure in HA mode, page rather than silently downgrading to per-Pod memory.

## 12. Known limitations and follow-up decisions

- The production resource requests/limits are conservative starting points and require load-test evidence.
- Redis is TLS-encrypted and security-group isolated by Terraform; if policy requires application-layer authentication, enable Redis ACL/auth through an approved secret path and keep credentials out of Terraform state.
- The chart exposes metrics and logs; first-party OpenTelemetry tracing is not claimed.
- NetworkPolicy external integration egress defaults to HTTPS (`443`) on `0.0.0.0/0` because integrations and OAuth endpoints vary; database and Redis egress are separately limited to their ports/VPC CIDRs, metrics are limited to the configured monitoring selector, and the migration hook can reach only DNS and PostgreSQL. Replace broad HTTPS with approved CIDRs or an egress proxy before strict production authorization.
- Formal PAT workspace/runtime scoping and 90-day credential rotation must be verified against the deployed application version.
- EKS remains conditionally accepted. If representative testing shows no Kubernetes-specific need or the team cannot support EKS upgrades/add-ons/on-call, compare the same images and external data services on ECS before production platform lock-in.
- Third-party hosted use must satisfy the repository license and commercial-use obligations.
