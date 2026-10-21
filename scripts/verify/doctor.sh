#!/usr/bin/env bash
# Read-only dependency report plus a build/instance check.
# Exit 0 when the selected launch mode is worth driving.
# Exit 1 when the CLI cannot be built or a full instance is not healthy.
# Missing Node, pnpm, Docker, Helm, or AWS credentials do not by themselves
# fail CLI mode; they are recorded so the agent does not claim a full stack.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"

EVIDENCE=$(verify_evidence_dir)
REPORT="$EVIDENCE/doctor.txt"
: >"$REPORT"

say() {
  printf '%s\n' "$*" | tee -a "$REPORT"
}

have() {
  local name=$1
  if command -v "$name" >/dev/null 2>&1; then
    say "dep.${name}=present"
    return 0
  fi
  say "dep.${name}=absent"
  return 1
}

say "repo=$VERIFY_REPO_ROOT"
say "run_id=${VERIFY_RUN_ID:-}"

if have go; then
  if (
    cd "$VERIFY_REPO_ROOT/multica/server"
    go version
  ) >>"$REPORT" 2>&1; then
    toolchain=$(
      cd "$VERIFY_REPO_ROOT/multica/server"
      go env GOVERSION
    )
    say "dep.go_toolchain=$toolchain"
    case "$toolchain" in
      go1.26.*) say "dep.go_matches_mod=yes" ;;
      *) say "dep.go_matches_mod=no" ;;
    esac
  else
    say "dep.go_toolchain=unusable"
    say "dep.go_matches_mod=no"
  fi
else
  say "dep.go_toolchain=absent"
  say "dep.go_matches_mod=no"
fi

if have node; then
  say "dep.node_version=$(node --version 2>/dev/null || echo unknown)"
fi
if have pnpm; then
  want=$(sed -n 's/.*"packageManager": "pnpm@\([^"]*\)".*/\1/p' "$VERIFY_REPO_ROOT/multica/package.json" | head -n 1)
  have_pnpm=$(pnpm --version 2>/dev/null || echo unknown)
  say "dep.pnpm_version=$have_pnpm"
  say "dep.pnpm_package_manager=${want:-unknown}"
fi
have python3 || true
have docker || true
have helm || true
have terraform || true
have kubectl || true
have aws || true

if [ -f "$VERIFY_REPO_ROOT/multica/.env" ] || [ -f "$VERIFY_REPO_ROOT/multica/.env.worktree" ]; then
  say "dep.multica_env=present"
else
  say "dep.multica_env=absent"
fi
if [ -d "$VERIFY_REPO_ROOT/multica/node_modules" ]; then
  say "dep.node_modules=present"
else
  say "dep.node_modules=absent"
fi

miss=$(verify_missing_make_check_prereqs || true)
if [ -z "$miss" ]; then
  say "make_check=ready"
else
  say "make_check=not_ready"
  say "make_check_missing=$miss"
fi

MODE=cli
BIN=""
BACKEND_PORT=8080
FRONTEND_PORT=3000
if [ -f "$EVIDENCE/launch.env" ]; then
  # shellcheck disable=SC1090
  . "$EVIDENCE/launch.env"
  MODE=${VERIFY_LAUNCH_MODE:-cli}
  BIN=${MULTICA_BIN:-}
  BACKEND_PORT=${BACKEND_PORT:-8080}
  FRONTEND_PORT=${FRONTEND_PORT:-3000}
fi
say "launch_mode=$MODE"

if [ "$MODE" = "full" ]; then
  if curl -sf "http://127.0.0.1:${BACKEND_PORT}/health" >"$EVIDENCE/doctor-health.json" 2>/dev/null; then
    say "instance.health=ok"
  else
    say "instance.health=down"
    say "doctor=fail"
    say "doctor_reason=full instance has no /health on 127.0.0.1:${BACKEND_PORT}"
    exit 1
  fi
  health_body=$(cat "$EVIDENCE/doctor-health.json" || true)
  case "$health_body" in
    *'"status":"ok"'*|*'"status": "ok"'*) ;;
    *)
      say "doctor=fail"
      say "doctor_reason=/health body is not status ok"
      exit 1
      ;;
  esac
  if curl -sf "http://127.0.0.1:${FRONTEND_PORT}/login" >/dev/null 2>&1; then
    say "instance.frontend=ok"
  else
    say "instance.frontend=down"
  fi
  say "doctor=ok"
  exit 0
fi

SCRATCH=$(verify_scratch_dir)
if [ -z "$BIN" ]; then
  BIN="$SCRATCH/bin/multica"
fi
if ! verify_build_cli "$BIN" >>"$EVIDENCE/doctor-build.log" 2>&1; then
  say "instance.cli=build_failed"
  say "doctor=fail"
  say "doctor_reason=go build ./cmd/multica failed; see doctor-build.log"
  exit 1
fi
if ! "$BIN" version --output json >"$EVIDENCE/doctor-version.json" 2>>"$EVIDENCE/doctor-build.log"; then
  say "instance.cli=version_failed"
  say "doctor=fail"
  say "doctor_reason=multica version failed"
  exit 1
fi
say "instance.cli=ok"
say "instance.cli_bin=$BIN"

# Record the binary for drive.sh when launch.sh was not used.
if [ ! -f "$EVIDENCE/launch.env" ]; then
  cat >"$EVIDENCE/launch.env" <<EOF
VERIFY_RUN_ID=${VERIFY_RUN_ID}
VERIFY_SCRATCH=${SCRATCH}
VERIFY_LAUNCH_MODE=cli
MULTICA_BIN=${BIN}
BACKEND_PORT=${BACKEND_PORT}
FRONTEND_PORT=${FRONTEND_PORT}
EOF
fi

say "full_stack=not_proven_by_cli_doctor"
say "doctor=ok"
exit 0
