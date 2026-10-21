# Agenticworld verification map

This directory is the maintained source for verifying user-facing Multica behavior in this checkout. Read this index, then follow one feature file. Do not report a skipped entrypoint as verified through a different one.

## Baseline preconditions

- Repository root is the current working directory.
- CLI drives use `./scripts/verify/launch.sh` (default mode `cli`) and `./scripts/verify/doctor.sh` with `doctor=ok`.
- HTTP and web drives use `VERIFY_LAUNCH=full ./scripts/verify/launch.sh` and a doctor that reports `instance.health=ok`.
- Evidence for the run stays in `evidence/runs/<run-id>/`. Cleanup must not delete it.
- Do not drive a full stack whose `/health` was already open before this run.

## Driving conventions

- Start from the baseline for that feature.
- Treat the commands in the feature file as literal.
- Run drives through `./scripts/verify/drive.sh <feature-id>`.
- CLI proof is the command, stdout, stderr, and exit code under `drive/`.
- HTTP proof is the response body, not only the curl exit code.
- `/health` status `ok` does not prove `/readyz`.
- Record an unreachable path as `result=unmet_precondition` with the command that failed.

## Feature entry contract

Each feature file has an H1, one short paragraph, then these H2 sections in order: `Sub-features`, `How to get to it (user POV)`, `Driving it with verify-agenticworld`, `Gotchas`.

## Features

- [CLI version](./cli-version.md) prints the built CLI identity with no server.
- [Backend health](./backend-health.md) is liveness `GET /health` and readiness `GET /readyz`.
- [Web login](./web-login.md) is the `/login` email form.
- [Issue list](./cli-issue-list.md) is `multica issue list` and the workspace issues page.
