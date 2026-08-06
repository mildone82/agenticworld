# Multica Gate 0：真实组件与资源画像

## 结论

基于 `multica-ai/multica@854b6c172300a218e056e6bb30a361d59e0377e3` 的代码核查，Multica 的真实部署形态不是 AGE-6 假定的“API + SQS + 集群内 Agent Worker”。官方自托管拓扑是：

```text
browser ─HTTP/WS─> Next.js frontend :3000 ─HTTP/WS proxy─> Go backend :8080
                                                        │
                                                        ├─ PostgreSQL 17（状态、任务队列、租约、调度）
                                                        ├─ Redis（可选；多 backend 实例的实时事件/临时请求状态）
                                                        ├─ S3/CloudFront（可选；否则使用 backend 本地上传目录）
                                                        └─ 外部邮件、OAuth、Git/VCS、聊天和 LLM/API

local/desktop multica daemon ─HTTPS/WSS─> backend /api/daemon/*
          └─ 在用户/运行时机器上检出仓库并启动 Claude/Codex/Kiro 等 coding CLI
```

因此：EKS 可承载 frontend/backend，但真实 agent 执行面当前是外部 daemon/运行时机器；SQS、Outbox Relay、KEDA queue worker 均不是现有实现。生产 AWS 设计应先部署真实拓扑，再把“迁移到 SQS worker”作为独立产品改造，而不是基础设施配置项。

## 证据范围

- 导入源码：4,161 个文件，约 59.2 MB；1,057 个 Go 文件、1,880 个 TypeScript/TSX 文件。
- 数据库：`server/migrations/` 有 297 个 `*.up.sql` 迁移。
- 官方部署：`docker-compose.selfhost.yml`、`Dockerfile`、`Dockerfile.web`、`deploy/helm/multica/`。
- 架构与协议：`server/cmd/server/main.go`、`server/cmd/server/router.go`、`server/internal/daemon/`、`CLI_AND_DAEMON.md`。
- 队列：`server/pkg/db/queries/agent.sql` 使用 PostgreSQL `FOR UPDATE SKIP LOCKED`、状态机和 prepare lease 领取任务。

## 真实组件清单

| 组件/进程 | 部署位置与职责 | 协议/端口 | 持久化与扩缩容约束 |
|---|---|---|---|
| `multica-web` | Next.js standalone frontend；代理 `/api`、`/auth`、`/uploads`、`/ws` 到 backend | HTTP 3000；外部 TLS 由 Ingress/反向代理终止 | 无业务持久状态；官方 Helm 默认 1 副本、100m/256Mi request、1 CPU/1Gi limit。镜像以 UID 1001 非 root 运行。Helm 未提供 frontend probes/HPA/PDB/topology spread。 |
| `server` / `multica-backend` | Go Chi API、用户 WS、daemon WS、鉴权、调度器、Webhook worker、运行时清扫、渠道连接和媒体回收均在同一进程 | HTTP 8080；`GET /healthz`；用户 WS `/ws`；daemon WS `/api/daemon/ws`；REST `/api/*` | 必须连接 PostgreSQL。单实例可用内存 hub；多实例必须配置 Redis 才能跨实例实时 fanout，并应配置 S3 或 RWX 上传卷。官方 Helm 默认 1 副本、100m/256Mi request、1 CPU/1Gi limit，`Recreate` 策略。 |
| `migrate` | backend 容器 entrypoint 在启动 server 前执行全部迁移 | PostgreSQL wire protocol 5432 | 迁移 runner 使用 advisory lock 处理并发启动。应作为发布门禁验证；不要让不兼容 schema 与旧 backend 混跑。 |
| `postgres` | 唯一强制的持久状态层；业务数据、任务队列、租约、cron 执行审计、附件元数据 | PostgreSQL 5432 | Compose/Helm 默认 `pgvector/pgvector:pg17`。Helm 内置实例为单副本 10Gi PVC、100m/256Mi request、1 CPU/1Gi limit；生产应启用 `postgres.external.enabled=true` 并用托管 PostgreSQL。每个 backend 默认 pgx pool 为 max 25/min 5，扩副本时必须汇总连接预算。 |
| Redis（可选） | backend 多实例的 sharded/legacy Redis Streams 实时 relay、daemon wakeup、liveness 与 runtime-local request store | Redis TCP/TLS（由 `REDIS_URL` 决定） | 不配置时 backend 明确退化为进程内 hub/single-node mode。AGE-6 未列出该生产横向扩容依赖。应在 ElastiCache/Valkey 与单 backend 之间做显式选择。 |
| S3/CloudFront（可选） | 附件/头像/渠道媒体对象 | AWS S3 HTTPS；可选 CloudFront | `S3_BUCKET` 为空时写 `/app/data/uploads`；Compose 使用 named volume，Helm 默认 5Gi RWO PVC。多 backend + RWO 不可调度；生产横向扩容建议 S3，并关闭 uploads PVC。 |
| `multica` CLI + daemon | 本地/桌面运行时；检测 coding CLI、同步 workspace、领取任务、创建隔离 worktree、执行 agent、上报 transcript/usage/result | 出站 HTTPS REST + WSS `/api/daemon/ws`；WS 不可用时回退 HTTP polling/heartbeat。本机 loopback health 端口默认 19514 | 不在官方 backend Helm chart 中。默认 poll 30s、heartbeat 15s、机器级并发上限 20；单任务无绝对时限，idle watchdog 30m、tool watchdog 2h。使用本地 `~/multica_workspaces`、bare repo cache 和 agent session，因此需要可写临时盘、Git 与对应 coding CLI/凭据。资源与磁盘消耗取决于被检出仓库和 agent 工具，不能用 backend 的 100m/256Mi 画像代替。 |
| 一次性工具 | `backfill_task_usage_hourly`、`backfill_codex_usage_cache` 等维护二进制随 backend 镜像发布 | PostgreSQL / 外部 API | 应按变更说明作为受控 Job 运行，不是常驻 worker。 |
| 可选客户端 | Electron desktop、Expo mobile、Fumadocs docs | HTTPS/WSS | 不属于核心服务端生产依赖；desktop 可管理本地 daemon。 |

## 协议、入口与健康检查

- 外部请求：frontend 3000 与 backend 8080 均为 HTTP；生产必须在 Ingress/ALB 终止 TLS。
- backend API：REST/JSON `/api/*`，Bearer/JWT/PAT 与 workspace header；浏览器实时通道为 `/ws`。
- daemon 控制协议：`/api/daemon/ws` 发送 task-available、heartbeat 等帧；领取、开始、进度、消息、usage、complete/fail 等通过 `/api/daemon/*` REST。WSS 断开时保留 HTTP 心跳和轮询回退。
- backend 健康：`GET /healthz` 检查数据库；Helm 配置 startup/readiness/liveness probe。
- 指标：仅设置 `METRICS_ADDR` 时启动独立 Prometheus HTTP listener；建议使用 loopback/private 地址。当前 chart 没有为它声明 Service/ServiceMonitor。未发现 backend 的第一方 OpenTelemetry tracing 初始化；lockfile 中的 OTel 依赖不能视为已完成 tracing。
- frontend：官方 Helm 未配置 readiness/liveness probe，生产需补齐。

## 持久化依赖

### PostgreSQL

PostgreSQL 是强制依赖，也是任务消息系统：

- `agent_task_queue` 保存 queued/dispatched/running/waiting/terminal 状态。
- claim 查询以 `FOR UPDATE SKIP LOCKED` 和 `(issue, agent)` 串行化规则防止同 agent 重复并发。
- prepare lease、heartbeat、attempt/retry 与 CAS 更新提供崩溃恢复和重复领取保护。
- `sys_cron_executions` 是内部周期任务的分布式 lease/audit log；新代码不依赖独立 SQS 或 Kubernetes CronJob。
- backend 每 Pod 默认连接池 max 25/min 5；metrics sampler 还会创建独立小池。

扩展要求：

- `pgcrypto`：强制创建。
- `pg_trgm`：强制创建，用于 fallback 搜索索引。
- `pg_bigm`：可选，迁移捕获失败；缺失时跳过 CJK bigram 索引。
- `pg_cron`：可选，迁移捕获失败；当前 hourly rollup 已由 backend DB-backed scheduler 替代。
- 官方镜像包含 pgvector，但迁移未创建 `vector` 扩展，当前代码证据不能把 pgvector 列为强制生产依赖。

RDS 选型前应以目标 engine/version 实测全部 297 个迁移，尤其确认扩展权限和 `CREATE INDEX CONCURRENTLY` 行为。

### 对象与本地文件

- 配置 S3：附件存 S3，可使用自定义 endpoint/path-style 和 CloudFront 签名下载。
- 未配置 S3：附件存 backend 本地目录；这使 Pod 有状态并限制横向扩容。
- agent 任务工作区不在 backend/S3：位于 daemon 主机本地。长任务检查点、本地 Git 状态和 coding CLI session 的恢复语义依赖该主机磁盘。

### 队列

代码中没有作为核心任务总线的 SQS/Kafka/RabbitMQ。PostgreSQL 队列表是当前事实来源；Redis 只承担实时 fanout、liveness 和部分短期请求状态，不替代任务队列。

## 配置与环境变量

完整示例以 `multica/.env.example` 为准，部署时至少按以下组管理：

| 组 | 关键变量 | 说明 |
|---|---|---|
| 核心 | `DATABASE_URL`, `JWT_SECRET`, `PORT`, `APP_ENV`, `MULTICA_APP_URL`, `FRONTEND_ORIGIN`, `CORS_ALLOWED_ORIGINS` | `JWT_SECRET` 和 DB 凭据必须来自 Secret；backend 内部端口默认 8080。 |
| DB 容量 | `DATABASE_MAX_CONNS`, `DATABASE_MIN_CONNS` | 默认每 backend 25/5；副本数 × pool + 运维/迁移/metrics 必须低于 DB 上限。 |
| 横向扩容 | `REDIS_URL`, `REALTIME_RELAY_MODE`, `REALTIME_RELAY_SHARDS`, `REALTIME_RELAY_STREAM_MAXLEN` | 不配置 Redis 时只保证单 backend 进程内实时分发。 |
| 对象存储 | `S3_BUCKET`, `S3_REGION`, `AWS_ENDPOINT_URL`, `S3_USE_PATH_STYLE`, AWS credential/provider chain, `CLOUDFRONT_*`, `ATTACHMENT_DOWNLOAD_*` | 在 EKS 上应使用 Pod Identity，不写静态 AWS key。 |
| 可观测 | `METRICS_ADDR`, `MULTICA_SHUTDOWN_HOLD_DURATION` | metrics 默认关闭；shutdown hold 可配合负载均衡摘流。 |
| 邮件/Auth | `RESEND_*` 或 `SMTP_*`, `GOOGLE_*`, `COOKIE_DOMAIN`, signup allowlists | 邮件未配置时验证码可能写日志，不适合生产。 |
| 集成 | `GITHUB_*`, `MULTICA_LARK_*`, `MULTICA_SLACK_*`, `MULTICA_VCS_*`, Composio/Cloud runtime 配置 | 每项均需独立密钥、出网和 webhook 策略。 |
| frontend | `REMOTE_API_URL`, `NEXT_PUBLIC_API_URL`, `NEXT_PUBLIC_WS_URL`, `DOCS_URL` | 同源部署可由 frontend runtime proxy 转发。 |
| daemon | server URL/token/profile、workspace root、poll/heartbeat、并发、timeout/watchdog、GC 与 agent executable path | 主要保存在 CLI profile/config，也可由 `MULTICA_*` 环境覆盖；daemon 主机需对应 agent 凭据。 |

官方 Helm 只引用预创建的 `existingSecret`，并未自带 Secrets Manager CSI/External Secrets/Pod Identity。AGE-6 的密钥方案仍需平台层实现。

## 镜像与构建

| 镜像 | 构建方式 | 运行安全现状 |
|---|---|---|
| `ghcr.io/multica-ai/multica-backend` | `Dockerfile`：Go 1.26 Alpine builder，静态构建 `server`、`multica`、`migrate` 和 backfill 工具；Alpine 3.21 runtime | 暴露 8080；未声明 `USER`，当前默认 root；entrypoint 先 migrate 后 server。生产需验证 non-root、read-only rootfs 与 writable uploads/temp 路径。 |
| `ghcr.io/multica-ai/multica-web` | `Dockerfile.web`：Node 22 + pnpm 10.28.2，Next.js standalone | UID 1001 `nextjs` 非 root，暴露 3000。 |
| `pgvector/pgvector:pg17` | 外部官方镜像 | 仅适合开发/最小自托管；生产采用 external PostgreSQL。 |

Compose 默认 `MULTICA_IMAGE_TAG=latest`，Helm 未固定 tag 时回退 `Chart.appVersion`（源码 chart 为 `latest`）。这推翻 AGE-6“已按 digest 部署”的隐含完成度；生产流水线必须固定 digest、生成 SBOM/扫描/签名，且 backend/frontend 使用同一发布版本。

## AGE-6 假设逐条对照

| AGE-6 假设/设计 | 结论 | 真实代码证据与影响 |
|---|---|---|
| HTTP/API 控制面 | **验证，但需拆成 frontend + backend** | Next.js 3000 + Go REST/WS 8080；不能只部署一个 API Deployment。 |
| API 完全无状态、可直接 3 副本 | **部分推翻** | 本地 uploads 和 in-memory hub/store 是默认路径；多副本至少需要 S3/RWX + Redis，并重新验证 embedded workers、连接池和迁移。官方默认 1 副本/Recreate。 |
| 独立异步 Agent Worker | **推翻** | agent 在外部 `multica daemon` 主机执行 coding CLI；backend 内只有内嵌调度/清扫/Webhook worker。官方 chart 无 worker Deployment。 |
| SQS Standard + DLQ | **推翻** | 核心任务队列是 PostgreSQL `agent_task_queue`；无 SQS 消费者、visibility extension 或 DLQ 管理实现。 |
| Transactional Outbox → SQS | **推翻** | 任务创建、领取、租约和状态直接落 PostgreSQL；没有该 relay 拓扑。若引入属于应用重构。 |
| 至少一次 + lease/fencing/idempotency | **部分验证** | DB queue 有 lease、attempt、CAS、`SKIP LOCKED` 和 daemon 重试/terminal report；不能据此宣称所有外部副作用已有统一幂等键，仍需故障测试。 |
| PostgreSQL 为持久状态 | **验证** | 强依赖，297 个迁移；RDS external URL 受官方 Helm 支持。需要 `pgcrypto`/`pg_trgm`，`pg_bigm`/`pg_cron` 可选。 |
| S3 为必需制品层 | **部分推翻** | S3 可选；默认 local uploads。生产多副本时 S3 是合理目标，但 daemon 工作树仍在本地磁盘。 |
| Redis 不需要 | **推翻（多副本场景）** | `REDIS_URL` 是多 backend realtime fanout/liveness/短期 store 的真实依赖；无 Redis 时日志明确为 single-node mode。 |
| KEDA 按 SQS 扩 worker | **推翻** | 没有 SQS worker。daemon 容量由运行时机器与 `MaxConcurrentTasks` 控制；需要新的容量/注册/任务时长指标设计。 |
| EKS + Karpenter 是必要基线 | **未验证为必要** | 官方 Helm 证明 Kubernetes 可部署 web/backend/Postgres，但代码没有 Operator/Kubernetes API 依赖；ECS 仍是有效替代。外部 daemon 才是重执行面。ADR-001 应重开评估。 |
| RDS Multi-AZ | **兼容但未实测** | external PostgreSQL 有配置入口；仍需跑完整迁移、failover、连接恢复与扩展兼容测试。 |
| Secrets Manager + Pod Identity 已有接入 | **未实现** | chart 只接收预创建 K8s Secret；平台 IaC/CSI/ESO/Pod Identity 是开放工作。 |
| OTel/ADOT tracing 已有 | **推翻** | backend 有结构化日志和可选 Prometheus metrics；未发现第一方 tracing 初始化。 |
| 健康探针/HPA/PDB/topology spread/NetworkPolicy 已具备 | **部分推翻** | backend 有 `/healthz` probes；frontend probes、HPA、PDB、topology spread、NetworkPolicy 均不在 chart。 |
| 非 root/只读根文件系统 | **部分推翻** | web 非 root；backend 镜像默认 root，chart 未声明 pod/container securityContext 或 readOnlyRootFilesystem。 |
| 镜像 digest/SBOM/签名 | **开放** | 有可构建 Dockerfile 和 GHCR 发布流程，但部署默认仍可用 `latest`/tag。 |

## 资源画像与容量线索

### 已由代码关闭

- web/backend/Postgres 的 Helm baseline：各 100m CPU、256Mi memory request；各 1 CPU、1Gi limit。
- 内置 Postgres 10Gi PVC；本地 uploads 5Gi PVC。
- backend 每 Pod DB pool 25 max/5 min，代码注释记录生产 daemon-poll 流量曾达到约 3,800 DB acquires/s，并出现 claim 尾延迟；数据库与连接数是已知热点。
- daemon 默认机器总并发 20；任务可持续很久，无 wall-clock cap；本地 workspace/cache 具有不可忽略的临时盘需求。
- backend 是混合进程：HTTP/WS 与多个 background loops 共用同一 CPU/内存/DB pool，单纯按 RPS HPA 可能遗漏 scheduler/webhook/channel 压力。

这些值只是开发/自托管默认值，不是生产容量结论。

### 仍开放，必须压测/采集

1. 峰值 API RPS、WS 并发/广播率、daemon 数、heartbeat 与 task-claim QPS。
2. 每类 coding agent 的 p50/p95/最长执行时长、CPU/内存、workspace/repo cache/session 临时盘、Git/LLM 出网量。
3. backend embedded worker 的 webhook/channel/media/scheduler 吞吐与多副本行为。
4. PostgreSQL 数据量/增长、连接数、锁等待、claim 查询 p95、IOPS/吞吐、迁移时间和 failover 恢复。
5. Redis Streams 容量、保留、故障降级和 ElastiCache/Valkey 兼容性。
6. S3 对象大小/增长、下载模式、生命周期与 CloudFront 流量。
7. 正式 SLO、RTO/RPO、数据分级、租户隔离与月预算。
8. 对每个外部副作用进行 kill/retry 测试，确认重复执行边界；当前代码结构不足以承诺“重复副作用为 0”。

## 修订后的 AWS 最小拓扑建议

1. ALB → frontend Service/Task；frontend 同源代理到 backend。
2. backend 初期 1 副本；在启用 S3 + Redis、验证 DB pool/embedded workers 后再扩为多 AZ 副本。
3. RDS PostgreSQL 17 Multi-AZ 候选；先执行 297 个迁移与 failover 测试，再锁定版本/参数组。
4. S3 存 backend 附件；daemon 工作树仍使用其运行时主机的加密本地盘/EBS，不混为 S3 artifact worker。
5. 多 backend 时增加 ElastiCache/Valkey（Redis-compatible），验证 Streams、Lua 和 client naming 行为。
6. agent daemon 作为独立运行时层设计：可先保留开发者/自托管机器；若上云，需要专门的 EC2/ECS/EKS runner 镜像、coding CLI 凭据隔离、repo cache、可写临时盘和长任务生命周期设计。
7. 不创建 SQS/KEDA/Outbox 资源，除非产品团队批准并实现从 PostgreSQL queue 到消息总线的迁移。

## Gate 0 状态

| 项目 | 状态 |
|---|---|
| 真实源码、来源 SHA、许可证 | **关闭** |
| 可构建 backend/frontend 源码与 Dockerfile | **关闭** |
| 进程、端口、REST/WS/daemon 协议 | **关闭** |
| PostgreSQL schema/迁移/扩展与任务队列语义 | **关闭（RDS 实机兼容测试仍开放）** |
| 对象存储、本地文件与 Redis 依赖 | **关闭** |
| 配置/环境变量分类与 Secret 边界 | **关闭（AWS 注入实现仍开放）** |
| 镜像构建和默认资源线索 | **关闭** |
| 实测 API/daemon/agent/DB/S3/Redis 资源与成本 | **开放：需要代表性负载** |
| SLO、RTO/RPO、合规、数据分级、预算 | **开放：需要业务决策** |
| EKS vs ECS ADR | **开放：真实代码不要求 EKS；需按 daemon 运行形态重审** |
| 生产安全上下文、扩缩容、PDB/NetworkPolicy、OTel、digest 供应链 | **开放：现有 chart 未实现** |
| 第三方托管许可 | **开放（如适用）**：内部单组织使用允许；对第三方托管/嵌入需商业许可 |
