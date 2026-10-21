#!/usr/bin/env bash
# Start one verification instance.
#   VERIFY_LAUNCH=cli   (default) build server/cmd/multica into scratch
#   VERIFY_LAUNCH=full  background `make start` in multica/ (needs .env, Postgres, Node)
# Proof artifacts go to evidence/runs/<id>/. The process and binary live in
# /tmp/verify-agenticworld-<id>/ and are removed by cleanup.sh.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"

MODE=${VERIFY_LAUNCH:-cli}
EVIDENCE=$(verify_evidence_dir)
SCRATCH=$(verify_scratch_dir)
LAUNCH_LOG="$EVIDENCE/launch.log"
: >"$LAUNCH_LOG"

log() {
  printf '%s\n' "$*" | tee -a "$LAUNCH_LOG"
}

write_env() {
  local bin=$1
  cat >"$EVIDENCE/launch.env" <<EOF
VERIFY_RUN_ID=${VERIFY_RUN_ID}
VERIFY_SCRATCH=${SCRATCH}
VERIFY_LAUNCH_MODE=${MODE}
MULTICA_BIN=${bin}
BACKEND_PORT=${BACKEND_PORT:-8080}
FRONTEND_PORT=${FRONTEND_PORT:-3000}
EOF
}

case "$MODE" in
  cli)
    BIN="$SCRATCH/bin/multica"
    log "launch mode=cli"
    log "building $BIN"
    verify_build_cli "$BIN" >>"$LAUNCH_LOG" 2>&1
    write_env "$BIN"
    if ! "$BIN" version --output json >>"$LAUNCH_LOG" 2>&1; then
      log "launch failed: multica version exited non-zero"
      exit 1
    fi
    log "ready: $BIN version --output json"
    ;;
  full)
    APP="$VERIFY_REPO_ROOT/multica"
    if [ ! -f "$APP/.env" ] && [ ! -f "$APP/.env.worktree" ]; then
      log "full launch refused: multica/.env is missing."
      log "Create it from multica/.env.example (or make worktree-env). This script does not invent a database or secrets."
      write_env ""
      exit 1
    fi
    ENV_FILE="$APP/.env"
    if [ ! -f "$ENV_FILE" ]; then
      ENV_FILE="$APP/.env.worktree"
    fi
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
    BACKEND_PORT=$(printf '%s' "${PORT:-${BACKEND_PORT:-8080}}")
    FRONTEND_PORT=$(printf '%s' "${FRONTEND_PORT:-3000}")
    if curl -sf "http://127.0.0.1:${BACKEND_PORT}/health" >/dev/null 2>&1; then
      log "full launch refused: 127.0.0.1:${BACKEND_PORT}/health is already open."
      log "Refusing to drive a server this run did not start."
      write_env ""
      exit 1
    fi
    log "launch mode=full env_file=$(basename "$ENV_FILE") backend_port=${BACKEND_PORT} frontend_port=${FRONTEND_PORT}"
    # setsid makes this bash the session leader. Cleanup signals that process
    # group only. The marker keeps cleanup from killing a recycled pid.
    setsid bash -c '
      set -euo pipefail
      echo "verify-agenticworld-full-start"
      cd "$1"
      bash scripts/ensure-postgres.sh "$2"
      (cd server && go run ./cmd/migrate up)
      (cd server && go run ./cmd/server) &
      pnpm dev:web &
      wait
    ' verify-agenticworld-full-start "$APP" "$ENV_FILE" >>"$EVIDENCE/full-start.log" 2>&1 &
    START_PID=$!
    printf '%s\n' "$START_PID" >"$SCRATCH/pids/full-start.pid"
    write_env ""
    elapsed=0
    until curl -sf "http://127.0.0.1:${BACKEND_PORT}/health" >/dev/null 2>&1; do
      if ! kill -0 "$START_PID" 2>/dev/null; then
        log "full launch failed: make start exited before /health. See full-start.log"
        exit 1
      fi
      sleep 1
      elapsed=$((elapsed + 1))
      if [ "$elapsed" -ge 120 ]; then
        log "full launch failed: /health did not answer within 120s. See full-start.log"
        kill -- -"$START_PID" 2>/dev/null || kill "$START_PID" 2>/dev/null || true
        exit 1
      fi
    done
    log "ready: http://127.0.0.1:${BACKEND_PORT}/health (${elapsed}s). Frontend target http://127.0.0.1:${FRONTEND_PORT}/"
    ;;
  *)
    log "unknown VERIFY_LAUNCH=$MODE (expected cli or full)"
    exit 2
    ;;
esac
