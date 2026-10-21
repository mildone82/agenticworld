#!/usr/bin/env bash
# Shared helpers for scripts/verify. Source this file; do not execute it.

_VERIFY_LIB_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VERIFY_REPO_ROOT=$(CDPATH= cd -- "$_VERIFY_LIB_DIR/../.." && pwd)

# Directory for this run's proof. Honors VERIFY_EVIDENCE_DIR so tests can
# write to a temp dir without touching evidence/current-run.
verify_evidence_dir() {
  if [ -n "${VERIFY_EVIDENCE_DIR:-}" ]; then
    mkdir -p "$VERIFY_EVIDENCE_DIR"
    printf '%s\n' "$VERIFY_EVIDENCE_DIR"
    return 0
  fi
  if [ -z "${VERIFY_RUN_ID:-}" ] && [ -f "$VERIFY_REPO_ROOT/evidence/current-run" ]; then
    VERIFY_RUN_ID=$(tr -d '[:space:]' < "$VERIFY_REPO_ROOT/evidence/current-run")
  fi
  if [ -z "${VERIFY_RUN_ID:-}" ]; then
    VERIFY_RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "$VERIFY_REPO_ROOT/evidence"
    printf '%s\n' "$VERIFY_RUN_ID" > "$VERIFY_REPO_ROOT/evidence/current-run"
  fi
  mkdir -p "$VERIFY_REPO_ROOT/evidence/runs/$VERIFY_RUN_ID"
  printf '%s\n' "$VERIFY_REPO_ROOT/evidence/runs/$VERIFY_RUN_ID"
}

# Scratch for binaries and pid files. Never store proof here.
verify_scratch_dir() {
  verify_evidence_dir >/dev/null
  local scratch="${VERIFY_SCRATCH:-/tmp/verify-agenticworld-${VERIFY_RUN_ID:-adhoc}}"
  mkdir -p "$scratch/bin" "$scratch/pids"
  printf '%s\n' "$scratch"
}

# Build the multica CLI into $1. Reuses an existing executable.
verify_build_cli() {
  local dest=$1
  if [ -x "$dest" ]; then
    return 0
  fi
  mkdir -p "$(dirname -- "$dest")"
  (
    cd "$VERIFY_REPO_ROOT/multica/server"
    go build -o "$dest" ./cmd/multica
  )
}

# Space-separated missing pieces for `cd multica && make check`.
# Empty output means the full pipeline can be attempted.
verify_missing_make_check_prereqs() {
  local miss=""
  local root="$VERIFY_REPO_ROOT/multica"
  if [ ! -f "$root/.env" ] && [ ! -f "$root/.env.worktree" ]; then
    miss+=" multica/.env"
  fi
  if [ ! -d "$root/node_modules" ]; then
    miss+=" multica/node_modules"
  fi
  if ! command -v node >/dev/null 2>&1; then
    miss+=" node"
  else
    case "$(node --version 2>/dev/null || true)" in
      v22.*) ;;
      *) miss+=" node-22" ;;
    esac
  fi
  if ! command -v pnpm >/dev/null 2>&1; then
    miss+=" pnpm"
  fi
  if ! command -v docker >/dev/null 2>&1; then
    miss+=" docker"
  elif ! docker compose version >/dev/null 2>&1; then
    miss+=" docker-compose-plugin"
  fi
  if ! command -v go >/dev/null 2>&1; then
    miss+=" go"
  fi
  printf '%s' "${miss# }"
}

# Print changed paths, one per line. Test seams may inject the list.
# Production always uses git diff against VERIFY_BASE or origin/bootstrap.
verify_list_changed_files() {
  if [ "${VERIFY_AWS_GATE_TEST_SEAMS:-}" = "1" ] && [ -n "${VERIFY_CHANGED_FILES+x}" ]; then
    printf '%s\n' "$VERIFY_CHANGED_FILES"
    return 0
  fi
  local base="${VERIFY_BASE:-}"
  if [ -z "$base" ]; then
    if git -C "$VERIFY_REPO_ROOT" rev-parse --verify --quiet origin/bootstrap >/dev/null; then
      base=origin/bootstrap
    elif git -C "$VERIFY_REPO_ROOT" rev-parse --verify --quiet bootstrap >/dev/null; then
      base=bootstrap
    fi
  fi
  # Committed range plus staged and unstaged paths. A dirty deploy file must
  # not SKIP just because the last commit was documentation.
  {
    if [ -n "$base" ]; then
      git -C "$VERIFY_REPO_ROOT" diff --name-only "${base}...HEAD" 2>/dev/null \
        || git -C "$VERIFY_REPO_ROOT" diff --name-only "$base" HEAD 2>/dev/null \
        || true
    fi
    git -C "$VERIFY_REPO_ROOT" diff --name-only --cached
    git -C "$VERIFY_REPO_ROOT" diff --name-only
    git -C "$VERIFY_REPO_ROOT" ls-files --others --exclude-standard
  } | awk 'NF && !seen[$0]++'
}

# Documentation-only when every changed path is markdown, LICENSE/NOTICE, or docs/.
# An empty diff is not documentation-only: the gate still runs.
verify_diff_is_doc_only() {
  local any=0
  local path
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    any=1
    case "$path" in
      *.md|*.mdx|LICENSE|NOTICE|multica/LICENSE|multica/NOTICE|docs/*|multica/docs/*) ;;
      *) return 1 ;;
    esac
  done
  [ "$any" -eq 1 ]
}
