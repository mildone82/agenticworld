# Backend health

Backend health tells an operator whether the Go API process is alive and whether Postgres and migrations are ready.

## Sub-features

- `live` answers `GET /health` with `{"status":"ok"}`.
- `ready` answers `GET /readyz` and `GET /healthz` with database and migration checks.

## How to get to it (user POV)

- Request `http://127.0.0.1:8080/health` (or the `PORT` from the env file).
- Request `http://127.0.0.1:8080/readyz`.
- Request `http://127.0.0.1:8080/healthz`.

## Driving it with verify-agenticworld

Preconditions:

- `VERIFY_LAUNCH=full ./scripts/verify/launch.sh` reached `ready:`.
- `./scripts/verify/doctor.sh` reports `instance.health=ok`.
- The port is the one in `launch.env` `BACKEND_PORT`.

- **Liveness and readiness.** Run `./scripts/verify/drive.sh backend-health`. Exit code 0. `drive/backend-health.json` is `{"status":"ok"}`. `drive/backend-ready.json` has `status` `ok`, `checks.db` `ok`, and `checks.migrations` `ok`.
- **Same route family.** Run `curl -sf "http://127.0.0.1:${BACKEND_PORT}/healthz"` and save the body beside the readyz proof. The JSON checks match `/readyz`.

## Gotchas

- The server process exits if it cannot ping `DATABASE_URL` (default `postgres://multica:multica@localhost:5432/multica?sslmode=disable` when unset). Do not stub that URL inside the proof.
- `/health` can be `ok` while readiness is not. A drive that only saves `/health` is incomplete for this feature.
- If nothing is listening, `drive.sh` exits 1 with `result=unmet_precondition`. Do not satisfy this feature with `multica version`.
- `make check` starts its own API for Playwright and then stops it. Do not point this drive at that short-lived process.
