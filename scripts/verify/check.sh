#!/usr/bin/env bash
# Run the repo's verification pipeline and keep the log.
#
#   VERIFY_CHECK=auto     (default)
#       `cd multica && make check` when Node 22, pnpm, Docker Compose,
#       node_modules, and an env file are all present. Otherwise the
#       documented minimal Go alternative below. The chosen mode is written
#       to check-status.txt. A missing prerequisite never becomes a pass of
#       `make check`.
#   VERIFY_CHECK=full     require `cd multica && make check`. Exit 1 if the
#       toolchain is incomplete. Exit with make's status when it runs.
#   VERIFY_CHECK=minimal  Go build of the three server commands, plus Go
#       tests that do not exit 0 when Postgres is absent.
#   VERIFY_CHECK=go       migrations and `multica/scripts/test-go.sh`.
#       Requires a reachable DATABASE_URL. A suite that skips because the
#       database is down is a failure, not a pass.
#
# `make check` (multica/scripts/check.sh) is typecheck, Vitest, Go tests,
# then Playwright against a server it starts itself. It needs the env file,
# PostgreSQL 17, Node 22, and pnpm 10.28.2 as declared in package.json.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"

EVIDENCE=$(verify_evidence_dir)
LOG="$EVIDENCE/check.log"
STATUS="$EVIDENCE/check-status.txt"
MODE=${VERIFY_CHECK:-auto}
REASON=""
CODE=1

write_status() {
  local status=$?
  cat >"$STATUS" <<EOF
mode=${MODE}
exit=${CODE}
reason=${REASON}
EOF
  return "$status"
}
trap write_status EXIT

: >"$LOG"
note() { printf '%s\n' "$*" | tee -a "$LOG"; }

run_logged() {
  note "+ $*"
  local status=0
  set +e
  "$@" >>"$LOG" 2>&1
  status=$?
  set +e
  return "$status"
}

minimal_tests() {
  note "minimal alternative to: cd multica && make check"
  note "runs multica/scripts/test-go.test.sh, a DB-free cmd/multica test, and go build of cmd/multica cmd/server cmd/migrate"
  note "does not run Playwright, pnpm typecheck, or packages whose TestMain exits 0 when Postgres is down (cmd/server, internal/handler)"
  run_logged bash "$VERIFY_REPO_ROOT/multica/scripts/test-go.test.sh" || return $?
  run_logged bash -c "cd '$VERIFY_REPO_ROOT/multica/server' && go test -count=1 -timeout 20m -v -run 'TestUpdateCommandRegistersDownloadTimeoutFlag|TestRunUpdateRejectsNonPositiveDownloadTimeout' ./cmd/multica" || return $?
  run_logged bash -c "cd '$VERIFY_REPO_ROOT/multica/server' && go build -o /dev/null ./cmd/multica" || return $?
  run_logged bash -c "cd '$VERIFY_REPO_ROOT/multica/server' && go build -o /dev/null ./cmd/server" || return $?
  run_logged bash -c "cd '$VERIFY_REPO_ROOT/multica/server' && go build -o /dev/null ./cmd/migrate" || return $?
}

go_suite() {
  export DATABASE_URL="${DATABASE_URL:-postgres://multica:multica@localhost:5432/multica?sslmode=disable}"
  note "go suite uses DATABASE_URL (host only logged)"
  python3 - "$DATABASE_URL" <<'PY' | tee -a "$LOG"
import sys
from urllib.parse import urlparse
u = urlparse(sys.argv[1])
print(f"database host={u.hostname} port={u.port} db={u.path}")
PY
  run_logged bash -c "cd '$VERIFY_REPO_ROOT/multica/server' && go run ./cmd/migrate up" || return $?
  run_logged bash "$VERIFY_REPO_ROOT/multica/scripts/test-go.test.sh" || return $?
  run_logged bash "$VERIFY_REPO_ROOT/multica/scripts/test-go.sh" || return $?
  if grep -Eq 'Skipping (integration )?tests: (could not connect|database not reachable)' "$LOG"; then
    note "database suites skipped; refusing to treat that as a pass"
    return 1
  fi
}

MISS=$(verify_missing_make_check_prereqs || true)
case "$MODE" in
  auto)
    if [ -z "$MISS" ]; then
      MODE=full
      REASON="prerequisites for make check are present"
    else
      MODE=minimal
      REASON="make check not run; missing: $MISS"
      note "$REASON"
    fi
    ;;
  full|minimal|go) ;;
  *)
    REASON="unknown VERIFY_CHECK=$MODE"
    note "$REASON"
    CODE=2
    exit 2
    ;;
esac

set +e
case "$MODE" in
  full)
    if [ -n "$MISS" ]; then
      REASON="VERIFY_CHECK=full refused; missing: $MISS"
      note "$REASON"
      CODE=1
    else
      REASON="cd multica && make check"
      note "+ cd multica && make check"
      (cd "$VERIFY_REPO_ROOT/multica" && make check) >>"$LOG" 2>&1
      CODE=$?
    fi
    ;;
  minimal)
    if [ -z "$REASON" ]; then
      REASON="VERIFY_CHECK=minimal"
    fi
    minimal_tests
    CODE=$?
    ;;
  go)
    REASON="migrate + multica/scripts/test-go.sh"
    go_suite
    CODE=$?
    ;;
esac
set -e

note "check exit=$CODE mode=$MODE"
if [ "$CODE" -ne 0 ]; then
  exit "$CODE"
fi
exit 0
