#!/usr/bin/env bash
# Drive one mapped feature and store the command output under evidence.
# Usage: scripts/verify/drive.sh <cli-version|backend-health|web-login|cli-issue-list>
# A missing server, frontend, or login is an unmet precondition (exit 1), not a pass.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"

FEATURE=${1:-}
EVIDENCE=$(verify_evidence_dir)
DRIVE="$EVIDENCE/drive"
mkdir -p "$DRIVE"

if [ -f "$EVIDENCE/launch.env" ]; then
  # shellcheck disable=SC1090
  . "$EVIDENCE/launch.env"
fi

BIN=${MULTICA_BIN:-}
PORT=${BACKEND_PORT:-8080}
FRONT=${FRONTEND_PORT:-3000}

fail_unmet() {
  local feature=$1
  shift
  {
    printf 'feature=%s\n' "$feature"
    printf 'result=unmet_precondition\n'
    printf '%s\n' "$*"
  } >"$DRIVE/${feature}.meta.txt"
  printf '%s\n' "$*" >&2
  exit 1
}

case "$FEATURE" in
  cli-version)
    if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
      fail_unmet cli-version "CLI binary missing. Run scripts/verify/launch.sh or scripts/verify/doctor.sh first."
    fi
    set +e
    "$BIN" version --output json >"$DRIVE/cli-version.json" 2>"$DRIVE/cli-version.err"
    code=$?
    set -e
    {
      printf 'feature=cli-version\n'
      printf 'command=%s version --output json\n' "$BIN"
      printf 'exit=%s\n' "$code"
    } >"$DRIVE/cli-version.meta.txt"
    if [ "$code" -ne 0 ]; then
      echo "cli-version failed with exit $code" >&2
      exit "$code"
    fi
    python3 - "$DRIVE/cli-version.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
missing = [key for key in ("version", "commit", "go", "os", "arch") if key not in doc]
if missing:
    raise SystemExit("version json missing: " + ", ".join(missing))
PY
    ;;
  backend-health)
    set +e
    curl -sf "http://127.0.0.1:${PORT}/health" >"$DRIVE/backend-health.json" 2>"$DRIVE/backend-health.err"
    health_code=$?
    curl -sf "http://127.0.0.1:${PORT}/readyz" >"$DRIVE/backend-ready.json" 2>>"$DRIVE/backend-health.err"
    ready_code=$?
    set -e
    {
      printf 'feature=backend-health\n'
      printf 'health_url=http://127.0.0.1:%s/health\n' "$PORT"
      printf 'ready_url=http://127.0.0.1:%s/readyz\n' "$PORT"
      printf 'health_exit=%s\n' "$health_code"
      printf 'ready_exit=%s\n' "$ready_code"
    } >"$DRIVE/backend-health.meta.txt"
    if [ "$health_code" -ne 0 ]; then
      fail_unmet backend-health "GET /health failed. Full launch is not up on port ${PORT}."
    fi
    python3 - "$DRIVE/backend-health.json" "$DRIVE/backend-ready.json" "$ready_code" <<'PY'
import json, sys
health = json.load(open(sys.argv[1]))
if health.get("status") != "ok":
    raise SystemExit("/health status is not ok")
if int(sys.argv[3]) != 0:
    raise SystemExit("/readyz did not return success; liveness is not readiness")
ready = json.load(open(sys.argv[2]))
checks = ready.get("checks") or {}
if ready.get("status") != "ok" or checks.get("db") != "ok" or checks.get("migrations") != "ok":
    raise SystemExit("/readyz is not fully ok: " + json.dumps(ready))
PY
    ;;
  web-login)
    set +e
    curl -sf "http://127.0.0.1:${FRONT}/login" >"$DRIVE/web-login.html" 2>"$DRIVE/web-login.err"
    code=$?
    set -e
    {
      printf 'feature=web-login\n'
      printf 'url=http://127.0.0.1:%s/login\n' "$FRONT"
      printf 'exit=%s\n' "$code"
    } >"$DRIVE/web-login.meta.txt"
    if [ "$code" -ne 0 ]; then
      fail_unmet web-login "GET /login failed. The Next.js app is not up on port ${FRONT}."
    fi
    if ! grep -Eq 'login-email|Sign in to Multica' "$DRIVE/web-login.html"; then
      echo "login page did not contain login-email or Sign in to Multica" >&2
      exit 1
    fi
    ;;
  cli-issue-list)
    if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
      fail_unmet cli-issue-list "CLI binary missing. Run scripts/verify/launch.sh first."
    fi
    set +e
    "$BIN" issue list --output json >"$DRIVE/cli-issue-list.json" 2>"$DRIVE/cli-issue-list.err"
    code=$?
    set -e
    {
      printf 'feature=cli-issue-list\n'
      printf 'command=%s issue list --output json\n' "$BIN"
      printf 'exit=%s\n' "$code"
    } >"$DRIVE/cli-issue-list.meta.txt"
    if [ "$code" -ne 0 ]; then
      fail_unmet cli-issue-list "issue list exited ${code}. Auth, server URL, or workspace is missing. See cli-issue-list.err. This is not a pass."
    fi
    python3 - "$DRIVE/cli-issue-list.json" <<'PY'
import json, sys
json.load(open(sys.argv[1]))
PY
    ;;
  *)
    echo "usage: scripts/verify/drive.sh cli-version|backend-health|web-login|cli-issue-list" >&2
    exit 2
    ;;
esac
