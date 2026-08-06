# agenticworld

本仓库在 `multica/` 中保存 Multica 的可构建源码工作树，用于 agentic engineering 的 AWS 部署设计与验证。

## 源码来源

- 上游：<https://github.com/multica-ai/multica>
- 上游分支：`main`
- 导入提交：`854b6c172300a218e056e6bb30a361d59e0377e3`
- 导入方式：GitHub 源码归档展开为普通工作树；未保留嵌套 `.git`
- 机器可读版本：`.multica-source-revision`

上游的完整 `LICENSE` 与 `NOTICE` 已随 `multica/` 保留。该许可证允许组织内部使用和公开源码分发，但未经商业许可不得向第三方提供托管/嵌入式商业服务，并包含品牌与归属要求；部署前必须复核 `multica/LICENSE`。

## 构建与运行

```bash
cd multica

# 官方自托管镜像
# backend: Go 1.26 Alpine multi-stage image
# frontend: Node 22 / Next.js standalone image
docker compose -f docker-compose.selfhost.yml \
  -f docker-compose.selfhost.build.yml build

# 上游完整检查（需要 Node 22、pnpm 10.28.2、Go 1.26.1 和 PostgreSQL 17）
make check
```

官方运行入口还包括 `docker-compose.selfhost.yml` 和 `deploy/helm/multica/`。生产参数与 AGE-6 假设核对见 [`docs/GATE0_COMPONENT_PROFILE.md`](docs/GATE0_COMPONENT_PROFILE.md)。
