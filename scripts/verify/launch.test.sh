#!/usr/bin/env bash
# Full launch must refuse to invent an env file. It must not start processes.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)

if [ -f "$ROOT/multica/.env" ] || [ -f "$ROOT/multica/.env.worktree" ]; then
  echo "launch.test: env file exists; skip the missing-env refusal check"
  exit 0
fi

dir=$(mktemp -d)
set +e
VERIFY_EVIDENCE_DIR="$dir" VERIFY_RUN_ID="launch-test" VERIFY_LAUNCH=full \
  bash "$SCRIPT_DIR/launch.sh" >"$dir/stdout.txt" 2>"$dir/stderr.txt"
code=$?
set -e
if [ "$code" -eq 0 ]; then
  echo "full launch without .env exited 0" >&2
  exit 1
fi
if ! grep -q 'multica/.env is missing' "$dir/launch.log"; then
  echo "missing the refusal message" >&2
  cat "$dir/launch.log" >&2 || true
  exit 1
fi
if pgrep -af 'verify-agenticworld-full-start' >/dev/null 2>&1; then
  echo "full start process leaked" >&2
  exit 1
fi
rm -rf "$dir"
echo "launch refusal check passed"
