#!/usr/bin/env bash
# Stop processes this verification run started and delete scratch.
# Evidence under evidence/runs/<id>/ is kept.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"

EVIDENCE=$(verify_evidence_dir)
LOG="$EVIDENCE/cleanup.log"
: >"$LOG"
note() { printf '%s\n' "$*" | tee -a "$LOG"; }

SCRATCH=""
if [ -f "$EVIDENCE/launch.env" ]; then
  # shellcheck disable=SC1090
  . "$EVIDENCE/launch.env"
  SCRATCH=${VERIFY_SCRATCH:-}
fi

if [ -n "$SCRATCH" ] && [ -d "$SCRATCH/pids" ]; then
  for pidfile in "$SCRATCH"/pids/*; do
    [ -e "$pidfile" ] || continue
    pid=$(tr -d '[:space:]' <"$pidfile")
    [ -n "$pid" ] || continue
    if ! kill -0 "$pid" 2>/dev/null; then
      note "pid $pid already exited ($(basename "$pidfile"))"
      continue
    fi
    args=$(ps -p "$pid" -o args= 2>/dev/null || true)
    case "$args" in
      *verify-agenticworld-full-start*) ;;
      *)
        note "refusing to signal pid $pid; command is not verify-agenticworld-full-start"
        continue
        ;;
    esac
    note "stopping process group $pid ($(basename "$pidfile"))"
    kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL -- -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    fi
  done
fi

if [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ]; then
  # Only remove the scratch directory this run created.
  case "$SCRATCH" in
    /tmp/verify-agenticworld-*)
      rm -rf "$SCRATCH"
      note "removed scratch $SCRATCH"
      ;;
    *)
      note "leaving scratch $SCRATCH (outside /tmp/verify-agenticworld-*)"
      ;;
  esac
else
  note "no scratch directory to remove"
fi

note "evidence kept at $EVIDENCE"
