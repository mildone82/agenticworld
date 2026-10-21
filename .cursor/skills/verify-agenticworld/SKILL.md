---
name: verify-agenticworld
description: Drive the agenticworld Multica checkout and record proof. Use when a change needs launch, doctor, a user-path drive, Go or make check evidence, or the AWS deployment gate. Covers the Go CLI, the Go API health routes, and the Next.js web app.
---

# Verify agenticworld

Multica in this repo is a Go API (`multica/server`, module `go 1.26.1`), a Next.js web app (`multica/apps/web`, port 3000), and the `multica` CLI (`multica/server/cmd/multica`). PostgreSQL is required to boot the API. `make check` in `multica/` is the upstream full pipeline. This skill drives those entrypoints and writes proof under `evidence/runs/<run-id>/`. Cleanup deletes only `/tmp/verify-agenticworld-<run-id>/`.

Run every helper from the repository root. Do not invent compose files, ports, or a queue. The task queue is Postgres `agent_task_queue`.

## Launch

CLI mode is the isolated default. It does not bind ports and does not touch a database.

```bash
./scripts/verify/launch.sh
```

Ready means `evidence/runs/<run-id>/launch.log` contains `ready:` and `multica version --output json` exited 0. The binary path is `MULTICA_BIN` in `launch.env`. Two CLI runs use different run ids and different scratch directories.

Full stack, only when `multica/.env` or `multica/.env.worktree` already exists:

```bash
VERIFY_LAUNCH=full ./scripts/verify/launch.sh
```

That runs the same steps as `cd multica && make start`: `scripts/ensure-postgres.sh`, `go run ./cmd/migrate up`, `go run ./cmd/server`, and `pnpm dev:web`. Ready means `GET http://127.0.0.1:<PORT>/health` returns `{"status":"ok"}`. Default `PORT` is 8080 and the web port is 3000, unless the env file overrides them. `/health` is liveness. Usable API state also requires `GET /readyz` with `checks.db=ok` and `checks.migrations=ok`.

If `/health` is already open, full launch exits 1 and does not attach to that process. Do not start a second full instance on the shared ports or the shared database named in the env file. Worktrees that need isolation use `cd multica && make worktree-env` first; this skill does not generate a second database.

There is no teardown inside launch. Use Cleanup.

## Doctor

Run this before driving, and again whenever the instance looks wrong.

```bash
./scripts/verify/doctor.sh
```

The report is `doctor.txt`. CLI mode is worth driving when `doctor=ok` and `instance.cli=ok`. The script builds `./cmd/multica` if launch did not. `dep.go_matches_mod=yes` means `go env GOVERSION` inside `multica/server` is `go1.26.*` (Go 1.21+ downloads that toolchain from the `go 1.26.1` line).

`make_check=not_ready` lists what `cd multica && make check` still needs: `multica/.env`, `multica/node_modules`, Node 22, pnpm (package.json pins `pnpm@10.28.2`), and the Docker Compose plugin. A CLI doctor does not claim the web app is up. Full mode fails the doctor when `/health` is down.

## Drive

Harness: `./scripts/verify/drive.sh <feature-id>`.

Mapped ids: `cli-version`, `backend-health`, `web-login`, `cli-issue-list`. Recipes and selectors live in `features/`. Drive the feature you changed. A proof that only runs `cli-version` does not cover a feature whose file lists another entrypoint.

Commands:

```bash
./scripts/verify/drive.sh cli-version
./scripts/verify/drive.sh backend-health
./scripts/verify/drive.sh web-login
./scripts/verify/drive.sh cli-issue-list
```

Stable handles:

- CLI: `multica version --output json`, `multica issue list --output json`
- API: `GET /health`, `GET /readyz`, `GET /healthz` (`multica/server/cmd/server/router.go`)
- Web login: `http://127.0.0.1:3000/login`, input `#login-email`, heading text `Sign in to Multica`, button `Continue`
- Web issues: `/{workspaceSlug}/issues`

An unmet precondition exits 1 and writes `result=unmet_precondition` in `drive/<feature>.meta.txt`. Do not switch features to make the command pass.

## Evidence

Every helper writes under `evidence/runs/<run-id>/` (or `VERIFY_EVIDENCE_DIR`). `evidence/current-run` holds the latest id. Layout: `evidence/README.md`.

Capture the command, the exit code, and the resulting state. For `cli-version`, keep `drive/cli-version.json` and `drive/cli-version.meta.txt`. For health, keep both `/health` and `/readyz` bodies. For login, keep the HTTP body and show that it contains `login-email` or `Sign in to Multica`. For issue list, keep stdout and stderr; a non-zero exit is not a pass.

Link the directory from handoffs with `docs/AGENT_SHARE_PROGRESS.md`. Do not copy secrets, `.env`, kubeconfigs, or AWS keys into the evidence files. The helpers do not print `sts get-caller-identity` output.

### AWS gate

```bash
./scripts/verify/aws-gate.sh
```

The verdict is only `aws-gate.json` field `status`, mirrored by a `status:` line in `aws-gate.log`.

| Status | Meaning | Exit |
|---|---|---|
| `PASS` | `scripts/validate-deployment.sh` exited 0, AWS credentials worked, the cluster answered, and pods in namespace `multica` (override `MULTICA_NAMESPACE`) are Running, Completed, or Succeeded. `seams` is false and `live_cluster_proven` is true. | 0 |
| `FAIL` | The static script ran and failed, or the live pod probe ran and failed. | 1 |
| `BLOCKED` | No usable AWS credentials and/or no reachable cluster, or Helm/Terraform/Python were missing so the static script did not run. Not a pass, including when a previous static log says artifacts passed. | 2 |
| `SKIP` | Every committed, staged, unstaged, and untracked path is markdown, `docs/`, `multica/docs/`, `LICENSE`, or `NOTICE`. The committed range is `VERIFY_BASE` (default `origin/bootstrap`) against `HEAD`. `changed_files` lists them. An empty set is not a skip. | 0 |

`scripts/validate-deployment.sh` lints Helm, renders dev/prod, runs `scripts/validate-deployment.py`, and runs `terraform fmt`/`validate`. It does not talk to a cluster. A green static run must not be copied forward as `PASS`. If that script exits non-zero, the gate is `FAIL` even when credentials and the cluster are absent. On this checkout the script exits non-zero once `helm`, `terraform`, and Python `jsonschema` are installed: `deploy/aws/terraform/vendor` is not in the tree, and `data.aws_caller_identity.current` is declared in both `deploy/aws/terraform/versions.tf` and `deploy/aws/terraform/identity.tf`. CI does not install those tools, so a stock runner records `static_validation=BLOCKED` and overall `BLOCKED`.

`VERIFY_AWS_GATE_TEST_SEAMS=1` is only for `scripts/verify/aws-gate.test.sh`. A seam result has `seams: true` and `live_cluster_proven: false`.

## Cleanup

```bash
./scripts/verify/cleanup.sh
```

This signals only a live pid recorded in the run's scratch `pids/` directory whose command line contains `verify-agenticworld-full-start`, then deletes `/tmp/verify-agenticworld-<run-id>/`. It does not use `killall` or `pkill` by process name. It does not delete `evidence/runs/<run-id>/`.

Confirm after cleanup that `drive/cli-version.json` (or the feature you drove) and `aws-gate.json` are still on disk.

## Helpers

| Script | Role |
|---|---|
| `./scripts/verify/run.sh` | Launch test, AWS decision table, CLI launch, doctor, check, `cli-version` drive, AWS gate, cleanup, `summary.md` |
| `./scripts/verify/launch.sh` | CLI build, or full `make start` equivalent |
| `./scripts/verify/doctor.sh` | Dependency report and CLI build / health check |
| `./scripts/verify/check.sh` | `cd multica && make check` or the minimal Go alternative |
| `./scripts/verify/drive.sh` | One feature |
| `./scripts/verify/aws-gate.sh` | AWS status gate |
| `./scripts/verify/cleanup.sh` | Stop this run, keep evidence |
| `./scripts/verify/aws-gate.test.sh` | Decision table, no cluster required |
| `./scripts/verify/launch.test.sh` | Full launch refuses a missing env file |

`./scripts/verify/check.sh` modes (`VERIFY_CHECK`):

- `auto` (default): `cd multica && make check` when Node 22, pnpm, `node_modules`, an env file, and Docker Compose are present. Otherwise it runs the minimal alternative and records the missing pieces in `check-status.txt`. It does not report `make check` as passed.
- `full`: always `cd multica && make check`. Missing prerequisites exit 1.
- `minimal`: `multica/scripts/test-go.test.sh`, `go test` of `TestUpdateCommandRegistersDownloadTimeoutFlag` and `TestRunUpdateRejectsNonPositiveDownloadTimeout` in `./cmd/multica`, and `go build` of `./cmd/multica`, `./cmd/server`, and `./cmd/migrate`. Packages whose `TestMain` exits 0 when Postgres is down (`./cmd/server`, `internal/handler`) are not in this mode, because that exit would be a false pass.
- `go`: `go run ./cmd/migrate up` and `multica/scripts/test-go.sh` against `DATABASE_URL`. If the log says the database suites were skipped, the check exits 1.

CI (`.github/workflows/verify.yml`) runs `VERIFY_CHECK=minimal` and `VERIFY_CHECK=go` (Postgres 17 + Redis). Either job fails the PR when the command exits non-zero. The AWS job fails the PR only on gate status `FAIL`. `BLOCKED` stays `BLOCKED` in the step summary.

## Proof boundary

A run on a machine without Docker, `multica/.env`, `node_modules`, Helm, Terraform, AWS credentials, or a kube context can prove CLI launch, doctor, the minimal Go check, `cli-version`, and an AWS `BLOCKED` result. It cannot prove `make start`, Playwright, or a live cluster. Those stay unverified until `VERIFY_LAUNCH=full`, `VERIFY_CHECK=full`, and a gate with `live_cluster_proven: true`.

Keep the feature map current with `/maintain-verification-skill` when routes or CLI commands change.
