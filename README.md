# agenticworld — Multica on AWS (EKS + PostgreSQL)

本仓库提供 [Multica](https://github.com/multica-ai/multica)（agent 调度与协作平台）在 AWS 上的完整生产部署方案，已在 AWS 宁夏区域（cn-northwest-1）实地部署验证：EKS + RDS PostgreSQL 17 + ElastiCache Redis + S3 + ECR，经 ALB 对外服务，并支持将集群外 EC2 注册为 agent runtime。

`multica/` 目录保存 Multica 的可构建源码工作树（上游 `multica-ai/multica@854b6c1`，完整 `LICENSE`/`NOTICE` 已保留；未经商业许可不得向第三方提供托管/嵌入式商业服务，部署前请复核 `multica/LICENSE`）。

## 架构概览

```text
用户浏览器 ──HTTP──▶ ALB（公有子网）
                        │  /api · /auth · /uploads · /ws → backend；其余 → frontend
                        ▼
              EKS（私有应用子网，3 AZ）
              ├─ frontend Deployment（Next.js :3000）
              ├─ backend Deployment（Go :8080，Pod Identity 取密钥）
              ├─ 迁移 Job（Helm pre-install/upgrade）
              └─ ALB Controller · External Secrets · metrics-server
                        │
        ┌───────────────┼─────────────────┐
        ▼               ▼                 ▼
 RDS PostgreSQL 17   ElastiCache      S3 + KMS
 （OLTP +            Redis            （附件存储，
  agent_task_queue   （多实例 fanout/   私有加密）
  任务队列租约）      liveness）

集群外：EC2 agent runtime（kiro-cli + multica daemon，systemd 常驻）
        经 WSS /api/daemon/* 通过 ALB 领取并执行任务
出口：NAT Gateway → 外部 LLM / API（HTTPS）
```

关键设计决策（基于真实源码核验，见 `docs/GATE0_COMPONENT_PROFILE.md`）：

- **任务队列就是 PostgreSQL**：Multica 原生用 `agent_task_queue` 表 + `FOR UPDATE SKIP LOCKED` 租约领取任务，不需要也不创建 SQS/DLQ/outbox。
- **agent 执行面在集群外**：真实执行体是外部/local `multica daemon`，经 WSS 领任务；其 CPU/内存/临时盘独立于 backend Pod 画像，本方案用独立 EC2 承接。
- **Redis 是横向扩容依赖**：多 backend 实例的实时 fanout/liveness 依赖 Redis；单实例可退化为进程内模式（dev profile）。
- **S3 为可选附件层**：未配置时 backend 使用本地上传卷（dev profile）。

## 目录结构

| 路径 | 内容 |
|---|---|
| `deploy/aws/terraform` | 3 AZ VPC、EKS 托管节点组、RDS PG 17、加密 Redis、S3/KMS、ECR、Secrets Manager、IAM/Pod Identity、ACM（可选）、预算告警、runtime EC2 |
| `deploy/aws/helm/multica` | 官方 chart 的 AWS 生产派生版：digest 固定、外部数据配置、迁移 Job、探针、PDB、拓扑分散、受限安全上下文、NetworkPolicy、ALB 路由 |
| `deploy/aws/helm/values-dev.yaml` | 单 backend、进程内 realtime、无 S3 的开发档（非 HA） |
| `deploy/aws/helm/values-prod.yaml` | 双 backend、Redis/S3 的生产档（占位符需替换） |
| `deploy/aws/addons` | 固定版本的 ALB Controller / External Secrets / metrics-server（helmfile） |
| `deploy/aws/scripts` | 部署校验与 runtime EC2 一键供给脚本 |
| `docs/AWS_EKS_DEPLOYMENT.md` | 部署、迁移、daemon 通道验证、回滚与生产门禁手册 |
| `docs/GATE0_COMPONENT_PROFILE.md` | 基于真实源码的组件与资源画像 |

## 安装（部署到 AWS）

前置条件：AWS CLI 凭证（目标账户）、Terraform、helm、kubectl、helmfile、Docker。

```bash
# 1. 基础设施（会创建计费资源，先 review plan）
cd deploy/aws/terraform
cp terraform.tfvars.example terraform.tfvars   # 按环境修改占位符
terraform init && terraform plan && terraform apply

# 2. 集群插件（ALB Controller、External Secrets、metrics-server）
cd ../addons && helmfile apply

# 3. 应用密钥写入 Secrets Manager（数据库连接串由 Terraform 生成，
#    应用密钥如 OAuth/SMTP 由运维手工填充，详见 docs/AWS_EKS_DEPLOYMENT.md）

# 4. 构建并推送镜像到 ECR（backend/frontend Dockerfile 默认使用
#    AWS Public ECR 官方镜像命名空间并按 digest 固定）
#    详见 docs/AWS_EKS_DEPLOYMENT.md 的镜像章节

# 5. 部署应用（生产档）
cd ../..
helm upgrade --install multica ./deploy/aws/helm/multica \
  -n multica --create-namespace \
  -f ./deploy/aws/helm/values-prod.yaml   # 先替换其中的端点/域名/digest 占位符

# 6. 校验
./deploy/aws/scripts/validate-deployment.sh
kubectl -n multica get pods    # backend/frontend Running，迁移 Job Completed
```

部署、迁移执行、daemon 通道验证、回滚与上线门禁的完整步骤见 [`docs/AWS_EKS_DEPLOYMENT.md`](docs/AWS_EKS_DEPLOYMENT.md)。

### 可选：注册集群外 agent runtime（EC2）

```bash
export OPERATOR_IP=<运维出口IP> ALB_DNS=<ALB域名> WORKSPACE_ID=<工作区UUID> SUBNET_ID=<公有子网ID>
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...   # 仅经 stdin 传入，不落日志/仓库
export MULTICA_PAT=<multica个人访问令牌>
./deploy/aws/scripts/setup-runtime-ec2.sh
```

脚本创建 EC2（AL2023 arm64）、安装 kiro-cli 与 multica CLI、以 systemd 常驻 daemon 并把 `kiro` runtime 注册进指定工作区。

## 使用

1. 打开 `http://<ALB_DNS>`（未配置域名时）；配置 DNS + ACM 后为 `https://<你的域名>`。
2. 创建账号/登录：生产默认 `ALLOW_SIGNUP=false`，用 `ALLOWED_EMAILS` 白名单放行指定邮箱；配置 Resend/SMTP 或 Google OAuth 后验证码直达邮箱（未配置时验证码在后端日志中）。
3. 在 Web 控制台创建/选择工作区，向已注册的 runtime 下发 agent 任务；附件经 S3，任务状态与幂等记录落 PostgreSQL。
4. 日常运维（扩缩容、备份恢复、告警、升级）见 `docs/AWS_EKS_DEPLOYMENT.md`。

## 本地构建（源码）

```bash
cd multica
docker compose -f docker-compose.selfhost.yml \
  -f docker-compose.selfhost.build.yml build   # backend: Go 1.26；frontend: Node 22 / Next.js
make check   # 上游完整检查（需要 Node 22、pnpm 10.28.2、Go 1.26.1、PostgreSQL 17）
```

官方自托管入口还包括 `docker-compose.selfhost.yml` 和 `multica/deploy/helm/multica/`。生产参数与真实代码的逐条核对见 [`docs/GATE0_COMPONENT_PROFILE.md`](docs/GATE0_COMPONENT_PROFILE.md)。
